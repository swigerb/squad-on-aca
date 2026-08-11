#!/usr/bin/env node
'use strict';

/**
 * fake-git-https-server.js — a REAL git remote over HTTPS that REQUIRES a
 * credential.
 *
 * WHY THIS EXISTS, AND WHY A SIMPLER FIXTURE WOULD BE WORTHLESS.
 *
 * Issue #32 replaces a token baked into `url.<...>.insteadOf` with a git
 * credential helper that re-reads a token file. The obvious test -- "clone the
 * repository and check it worked" -- proves NOTHING about that change, because
 * squad-on-aca's own repository is PUBLIC: an unauthenticated clone succeeds,
 * and so does a clone with an expired token. A green test there would be
 * describing the network, not the helper.
 *
 * So this fixture is a git remote that answers 401 until a correct credential
 * arrives. Against it:
 *
 *   * a push that succeeds proves the helper was CONSULTED and its answer was
 *     accepted -- there is no other source for the password;
 *   * the auth log records exactly which username/password git presented, so
 *     the assertion is about the credential that crossed the wire rather than
 *     about the exit code alone;
 *   * rewriting only the token file and pushing again reproduces the
 *     mid-session refresh end to end, in one process, with no re-clone.
 *
 * It is a real HTTPS server driving the real `git http-backend` CGI, so the
 * client under test is stock `git` doing stock smart-HTTP. Nothing about the
 * credential path is simulated.
 *
 * Usage:
 *   node fake-git-https-server.js --root <dir> --cert <pem> --key <pem>
 *        --token-file <file> [--auth-log <file>] [--request-log <file>]
 *        [--delay-ms <n>] [--port-file <file>]
 *
 * Prints "LISTENING <port>" on stdout once bound, and writes the port to
 * --port-file if given.
 *
 * --token-file is re-read on EVERY request on purpose: the fixture must be able
 * to "rotate" the accepted credential mid-test, which is how the stale-token
 * half of the refresh probe is staged.
 *
 * --delay-ms holds the response open for the git-receive-pack POST, which gives
 * a deterministic window in which /proc can be scanned for a token in any
 * process's argv. Without a window the scan is a race, and a racy absence
 * assertion is indistinguishable from an assertion that never ran.
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const { spawn } = require('child_process');

function argValue(name, fallback) {
  const idx = process.argv.indexOf(name);
  if (idx === -1 || idx === process.argv.length - 1) return fallback;
  return process.argv[idx + 1];
}

const ROOT = argValue('--root', '');
const CERT = argValue('--cert', '');
const KEY = argValue('--key', '');
const TOKEN_FILE = argValue('--token-file', '');
const AUTH_LOG = argValue('--auth-log', '');
const REQUEST_LOG = argValue('--request-log', '');
const DELAY_MS = Number(argValue('--delay-ms', '0')) || 0;
const PORT_FILE = argValue('--port-file', '');
const BACKEND = argValue('--backend', '/usr/lib/git-core/git-http-backend');

/**
 * The longest this fixture will wait for `git-http-backend` before answering
 * the client itself.
 *
 * This exists to convert a HANG into a failure, not to bound normal work, so
 * it is deliberately far longer than any healthy request against a fixture
 * repository of a few commits -- which completes in well under a second. A
 * bound tight enough to fire on a slow-but-healthy request would turn a
 * loaded CI runner into a spurious failure, which is worse than the defect it
 * guards against.
 *
 * It still has to be shorter than the per-suite timeout in
 * `worker/tests/run-tests.sh` (120s), or the suite would be killed before the
 * fixture ever got the chance to explain itself.
 */
const BACKEND_TIMEOUT_MS = Number(argValue('--backend-timeout-ms', '60000')) || 60000;

/**
 * Every backend still running, so none can outlive this server.
 *
 * The backends stay in this fixture's process group -- see the spawn below --
 * so the suite runner's own group sweep already reaches them. This is the
 * belt to that braces: if the server is asked to stop, it does not leave a
 * backend behind for the sweep to have to catch.
 */
const LIVE_BACKENDS = new Set();
function killAllBackends() {
  for (const c of LIVE_BACKENDS) {
    try { c.kill('SIGKILL'); } catch { /* already gone */ }
  }
  LIVE_BACKENDS.clear();
}
// Deliberately NOT installed on SIGTERM/SIGINT/SIGHUP. Installing a handler
// replaces node's default "die now" with "run this, then die", and this
// fixture is torn down by a plain `kill` from its suite's cleanup -- so a
// handler here changes how the fixture dies for no benefit. The backends stay
// in the suite's process group, which the runner sweeps anyway.
process.on('exit', killAllBackends);

/**
 * A fixture that dies silently is worse than one that never started.
 *
 * If this server throws, every subsequent git operation in the suite blocks
 * against a port with nothing behind it -- which presents as the SUITE
 * hanging, with no indication that the fixture is the thing that broke. That
 * cost a full day of chasing the wrong process (issue #96), so an unexpected
 * throw now says so loudly, in the request log the suite keeps, and the
 * process stays up rather than taking the suite down with it.
 */
process.on('uncaughtException', (err) => {
  append(REQUEST_LOG, `fixture-uncaught ${err && err.stack ? err.stack.split('\n')[0] : err}`);
  process.stderr.write(`fake-git-https-server: uncaught ${err && err.message}\n`);
});
process.on('unhandledRejection', (err) => {
  append(REQUEST_LOG, `fixture-unhandled-rejection ${err && err.message ? err.message : err}`);
});

if (!ROOT || !CERT || !KEY || !TOKEN_FILE) {
  process.stderr.write('fake-git-https-server: --root, --cert, --key and --token-file are required\n');
  process.exit(64);
}

function append(file, line) {
  if (!file) return;
  try {
    fs.appendFileSync(file, `${line}\n`);
  } catch (err) {
    /* a logging failure must never change what the fixture answers */
  }
}

// Re-read on every request: the accepted credential is allowed to change while
// the server is up, which is what stages "the token the worker holds went
// stale".
function expectedToken() {
  try {
    return fs.readFileSync(TOKEN_FILE, 'utf8').replace(/[\r\n]+$/, '');
  } catch (err) {
    return '';
  }
}

function unauthorized(res, reason) {
  res.writeHead(401, {
    'WWW-Authenticate': 'Basic realm="Squad"',
    'Content-Type': 'text/plain'
  });
  // The phrase GitHub itself returns for a bad or expired token. The worker's
  // classifier is matched against real remote text, so the fixture must emit
  // real remote text.
  res.end(`Invalid username or token: ${reason}\n`);
}

function runBackend(req, res, user) {
  const url = new URL(req.url, 'https://localhost');
  const env = {
    PATH: process.env.PATH,
    GIT_PROJECT_ROOT: ROOT,
    GIT_HTTP_EXPORT_ALL: '1',
    PATH_INFO: url.pathname,
    QUERY_STRING: url.search.replace(/^\?/, ''),
    REQUEST_METHOD: req.method,
    REMOTE_USER: user,
    REMOTE_ADDR: '127.0.0.1',
    CONTENT_TYPE: req.headers['content-type'] || '',
    // git http-backend needs the committer identity for receive-pack hooks.
    GIT_COMMITTER_NAME: 'Squad Fixture',
    GIT_COMMITTER_EMAIL: 'fixture@example.invalid'
  };
  // Pass every request header through in CGI form; http-backend needs
  // HTTP_CONTENT_ENCODING to decode a gzipped upload-pack request, and reading
  // them generically means a future git that adds one does not silently break.
  for (const [key, value] of Object.entries(req.headers)) {
    env[`HTTP_${key.toUpperCase().replace(/-/g, '_')}`] = String(value);
  }
  if (req.headers['content-length']) env.CONTENT_LENGTH = String(req.headers['content-length']);

  // NOT detached. Detaching would let the timeout below signal a whole
  // process group, but it also takes the backend OUT of the suite's process
  // group -- and `worker/tests/run-tests.sh` terminates that group to clean up
  // after a suite. A backend that escapes it outlives the suite, which is the
  // very leak this file is being fixed for. Staying in the group means the
  // runner's own sweep reaches every descendant, so the timeout only has to
  // deal with the direct child.
  const child = spawn(BACKEND, [], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  LIVE_BACKENDS.add(child);
  child.once('close', () => LIVE_BACKENDS.delete(child));
  req.pipe(child.stdin);

  /**
   * The whole response is sent from `child.on('close')`, so it depends on the
   * backend exiting AND every one of its pipes closing. With nothing bounding
   * that, a backend which blocks -- waiting on a stdin that never ends, or
   * holding a pipe open -- means the client never receives a single byte and
   * `git clone` waits FOREVER, because git applies no timeout of its own.
   *
   * That is not hypothetical: it is issue #96. `git clone` against this
   * fixture was observed stuck for over seven minutes with the backend still
   * running, which is what made `test_credential_withholding.sh` hang
   * intermittently and, before the per-suite timeout existed, hung CI itself.
   *
   * So the backend gets a bounded lifetime. If it has not finished in time it
   * is killed by PROCESS GROUP -- signalling the direct child alone leaves
   * `git-http-backend`'s own children holding the pipes, which is the same
   * mistake in miniature -- and the client gets a 504 saying so. A test
   * fixture that hangs teaches nothing; one that fails says exactly what
   * happened.
   */
  let replied = false;
  /**
   * Answer once, and never on a response the client has already abandoned.
   *
   * `git` closes connections routinely -- it aborts `info/refs` the moment it
   * has what it needs. Writing to a response whose socket is gone THROWS, and
   * an uncaught throw here takes the whole fixture server down. Every later
   * git operation in the suite then blocks against a port with nothing behind
   * it, which reads as the suite hanging.
   *
   * The original code got away with writing unguarded because it only ever
   * wrote from `child.on('close')`, at a moment the client was usually still
   * there. Introducing a timeout added a second, much later moment -- long
   * after an aborted client has gone -- so the guard has to exist now.
   */
  const reply = (status, headers, body) => {
    if (replied) return;
    replied = true;
    clearTimeout(deadline);
    if (res.writableEnded || res.destroyed || res.headersSent) return;
    try {
      res.writeHead(status, headers);
      res.end(body);
    } catch (e) {
      append(REQUEST_LOG, `reply-failed ${req.method} ${url.pathname}: ${e.message}`);
    }
  };
  const deadline = setTimeout(() => {
    append(REQUEST_LOG, `backend-timeout ${req.method} ${url.pathname} after ${BACKEND_TIMEOUT_MS}ms`);
    try { child.kill('SIGKILL'); } catch { /* already gone */ }
    reply(504, { 'Content-Type': 'text/plain' },
      `fixture: ${BACKEND} did not finish within ${BACKEND_TIMEOUT_MS}ms\n`);
  }, BACKEND_TIMEOUT_MS);

  // An aborted client leaves the backend with nowhere to write and its stdin
  // half of the pipe broken. Both raise errors that are fatal if unhandled --
  // EPIPE on the stdin pipe, and the abort itself -- so both are handled, and
  // the backend is stopped rather than left running for a client that has
  // gone. This is the same leak the timeout exists for, arriving by a
  // different route.
  child.stdin.on('error', () => { /* EPIPE: the backend closed stdin first */ });
  req.on('aborted', () => {
    append(REQUEST_LOG, `client-aborted ${req.method} ${url.pathname}`);
    clearTimeout(deadline);
    replied = true;
    try { child.kill('SIGKILL'); } catch { /* already gone */ }
  });
  res.on('error', () => { /* the client went away mid-write */ });

  const chunks = [];
  child.stdout.on('data', (chunk) => chunks.push(chunk));
  child.stderr.on('data', (chunk) => append(REQUEST_LOG, `backend-stderr ${chunk.toString().trim()}`));

  child.on('error', (err) => {
    reply(500, { 'Content-Type': 'text/plain' },
      `fixture could not run ${BACKEND}: ${err.message}\n`);
  });

  child.on('close', () => {
    const raw = Buffer.concat(chunks);
    const split = raw.indexOf('\r\n\r\n') !== -1 ? raw.indexOf('\r\n\r\n') : raw.indexOf('\n\n');
    const sep = raw.indexOf('\r\n\r\n') !== -1 ? 4 : 2;
    const headerText = split === -1 ? '' : raw.slice(0, split).toString('utf8');
    const body = split === -1 ? raw : raw.slice(split + sep);

    let status = 200;
    const headers = {};
    for (const line of headerText.split(/\r?\n/).filter(Boolean)) {
      const idx = line.indexOf(':');
      if (idx === -1) continue;
      const name = line.slice(0, idx).trim();
      const value = line.slice(idx + 1).trim();
      if (name.toLowerCase() === 'status') {
        status = parseInt(value, 10) || 200;
      } else {
        headers[name] = value;
      }
    }
    reply(status, headers, body);
  });
}

const server = https.createServer(
  { cert: fs.readFileSync(CERT), key: fs.readFileSync(KEY) },
  (req, res) => {
    append(REQUEST_LOG, `${req.method} ${req.url}`);

    const header = req.headers.authorization || '';
    if (!header.startsWith('Basic ')) {
      // git's FIRST request is deliberately anonymous. Answering 401 here is
      // what makes git go and ask a credential helper at all -- the whole
      // mechanism under test hangs off this branch.
      append(AUTH_LOG, 'ANONYMOUS');
      unauthorized(res, 'no credential presented');
      return;
    }

    const decoded = Buffer.from(header.slice('Basic '.length), 'base64').toString('utf8');
    const idx = decoded.indexOf(':');
    const user = idx === -1 ? decoded : decoded.slice(0, idx);
    const pass = idx === -1 ? '' : decoded.slice(idx + 1);
    append(AUTH_LOG, `PRESENTED ${user}:${pass}`);

    const expected = expectedToken();
    if (!expected || pass !== expected) {
      unauthorized(res, 'the presented credential is not the accepted one');
      return;
    }

    append(AUTH_LOG, `ACCEPTED ${user}`);

    if (DELAY_MS > 0 && req.method === 'POST') {
      setTimeout(() => runBackend(req, res, user), DELAY_MS);
      return;
    }
    runBackend(req, res, user);
  }
);

server.listen(0, '127.0.0.1', () => {
  const port = server.address().port;
  if (PORT_FILE) fs.writeFileSync(PORT_FILE, String(port));
  process.stdout.write(`LISTENING ${port}\n`);
});

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
