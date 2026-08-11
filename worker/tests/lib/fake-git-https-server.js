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

  const child = spawn(BACKEND, [], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  req.pipe(child.stdin);

  const chunks = [];
  child.stdout.on('data', (chunk) => chunks.push(chunk));
  child.stderr.on('data', (chunk) => append(REQUEST_LOG, `backend-stderr ${chunk.toString().trim()}`));

  child.on('error', (err) => {
    res.writeHead(500, { 'Content-Type': 'text/plain' });
    res.end(`fixture could not run ${BACKEND}: ${err.message}\n`);
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
    res.writeHead(status, headers);
    res.end(body);
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
