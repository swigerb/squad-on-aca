#!/usr/bin/env node
'use strict';

/**
 * fake-gh.js — an offline stand-in for the `gh` CLI.
 *
 * Implements exactly the surface worker/lib/dispatch-lease.js uses (git refs,
 * git commits, and the Contents API) plus the `issue edit` call Ralph makes,
 * backed by a throwaway directory. Nothing here touches the network.
 *
 * It is shared by BOTH harnesses on purpose:
 *   worker/tests/*.sh              (bash, via a `gh` shim that execs node)
 *   scripts/tests/cli-stub-harness.ps1 (Windows, via a `gh.cmd` that runs node)
 * so the two languages are tested against identical GitHub semantics.
 *
 * The Contents API semantics that matter, reproduced faithfully:
 *   * PUT without `sha` on an existing path -> HTTP 422. This is the atomic
 *     create-once the claim protocol relies on.
 *   * PUT with a stale `sha` -> HTTP 409. This is the compare-and-swap a
 *     heartbeat relies on.
 *   * GET of a missing path or ref -> HTTP 404 on stderr, exit 1.
 *
 * Environment:
 *   FAKE_GH_STATE     directory holding refs/ and contents/ (required for api)
 *   FAKE_GH_LOG       append one line per invocation: "<subcommand> <summary>"
 *   SQUAD_CALL_LOG    shared, ordered, cross-tool call log. The fake `az`
 *                     appends to the same file, so a test can assert that the
 *                     lease write happens BEFORE the compute request by INDEX.
 *   FAKE_GH_FAIL_MODE auth | throttle | network — makes every `api` call fail
 *                     the way a real credential/permission/rate-limit fault
 *                     does, so cleanup paths can be proven to surface it.
 *   FAKE_GH_FAIL_PATH substring; only api calls whose path contains it fail.
 */

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const argv = process.argv.slice(2);
const state = process.env.FAKE_GH_STATE || '';

function appendLog(file, line) {
  if (!file) return;
  try {
    fs.appendFileSync(file, `${line}\n`);
  } catch (err) {
    /* logging must never break a test run */
  }
}

function die(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function readStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch (err) {
    return '';
  }
}

function sha1(text) {
  return crypto.createHash('sha1').update(text).digest('hex');
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function slug(value) {
  return String(value).replace(/[^A-Za-z0-9._-]+/g, '_');
}

function refFile(branch) {
  return path.join(state, 'refs', `${slug(branch)}.sha`);
}

function contentFile(branch, filePath) {
  return path.join(state, 'contents', slug(branch), slug(filePath));
}

const FAILURES = {
  auth: 'gh: Bad credentials (HTTP 401)',
  forbidden: 'gh: Resource not accessible by integration (HTTP 403)',
  throttle: 'gh: API rate limit exceeded (HTTP 429)',
  network: 'gh: Post "https://api.github.com": dial tcp: lookup api.github.com: no such host'
};

function handleApi(args) {
  let method = 'GET';
  let target = '';
  let readInput = false;
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--method' || arg === '-X') {
      method = String(args[i + 1] || 'GET').toUpperCase();
      i += 1;
    } else if (arg === '--input') {
      readInput = String(args[i + 1] || '') === '-';
      i += 1;
    } else if (!arg.startsWith('-') && !target) {
      target = arg;
    }
  }

  const [rawPath, rawQuery] = target.replace(/^\/+/, '').split('?');
  const query = {};
  for (const pair of (rawQuery || '').split('&').filter(Boolean)) {
    const idx = pair.indexOf('=');
    query[decodeURIComponent(pair.slice(0, idx))] = decodeURIComponent(pair.slice(idx + 1));
  }

  appendLog(process.env.SQUAD_CALL_LOG, `gh api ${method} ${rawPath}`);

  const mode = process.env.FAKE_GH_FAIL_MODE || '';
  const failPath = process.env.FAKE_GH_FAIL_PATH || '';
  if (mode && FAILURES[mode] && (!failPath || rawPath.includes(failPath))) {
    die(FAILURES[mode]);
  }

  if (!state) die('gh: fake-gh requires FAKE_GH_STATE');

  const body = readInput ? JSON.parse(readStdin() || '{}') : {};
  const segments = rawPath.split('/');
  // repos/<owner>/<name>/<rest...>
  const rest = segments.slice(3).join('/');

  // --- git refs ------------------------------------------------------------
  if (rest.startsWith('git/ref/heads/')) {
    const branch = rest.slice('git/ref/heads/'.length);
    const file = refFile(branch);
    if (!fs.existsSync(file)) die('gh: Not Found (HTTP 404)');
    process.stdout.write(
      `${JSON.stringify({ ref: `refs/heads/${branch}`, object: { sha: fs.readFileSync(file, 'utf8') } })}\n`
    );
    return;
  }
  if (rest === 'git/commits' && method === 'POST') {
    process.stdout.write(`${JSON.stringify({ sha: sha1(JSON.stringify(body)) })}\n`);
    return;
  }
  if (rest === 'git/refs' && method === 'POST') {
    const branch = String(body.ref || '').replace(/^refs\/heads\//, '');
    const file = refFile(branch);
    if (fs.existsSync(file)) die('gh: Reference already exists (HTTP 422)');
    ensureDir(path.dirname(file));
    fs.writeFileSync(file, String(body.sha || ''));
    process.stdout.write(`${JSON.stringify({ ref: body.ref })}\n`);
    return;
  }

  // --- contents ------------------------------------------------------------
  if (rest.startsWith('contents/')) {
    const filePath = rest.slice('contents/'.length);
    const branch = query.ref || body.branch || '';
    if (!branch) die('gh: Not Found (HTTP 404)');
    if (!fs.existsSync(refFile(branch))) die('gh: Not Found (HTTP 404)');

    if (method === 'GET') {
      const file = contentFile(branch, filePath);
      if (fs.existsSync(file)) {
        const content = fs.readFileSync(file, 'utf8');
        process.stdout.write(
          `${JSON.stringify({
            name: path.posix.basename(filePath),
            path: filePath,
            sha: sha1(content),
            content: Buffer.from(content, 'utf8').toString('base64'),
            encoding: 'base64'
          })}\n`
        );
        return;
      }
      // Directory listing.
      const dirPrefix = `${slug(`${filePath}/`)}`;
      const dir = path.join(state, 'contents', slug(branch));
      if (fs.existsSync(dir)) {
        const entries = fs
          .readdirSync(dir)
          .filter((name) => name.startsWith(dirPrefix))
          .map((name) => ({
            name: name.slice(dirPrefix.length),
            path: `${filePath}/${name.slice(dirPrefix.length)}`,
            type: 'file'
          }));
        if (entries.length > 0) {
          process.stdout.write(`${JSON.stringify(entries)}\n`);
          return;
        }
      }
      die('gh: Not Found (HTTP 404)');
    }

    if (method === 'PUT') {
      const file = contentFile(branch, filePath);
      const exists = fs.existsSync(file);
      if (exists && !body.sha) die('gh: Invalid request. "sha" wasn\'t supplied. (HTTP 422)');
      if (exists && sha1(fs.readFileSync(file, 'utf8')) !== body.sha) {
        die('gh: is at <sha> but expected <other> (HTTP 409)');
      }
      if (!exists && body.sha) die('gh: Not Found (HTTP 404)');
      const content = Buffer.from(String(body.content || ''), 'base64').toString('utf8');
      ensureDir(path.dirname(file));
      fs.writeFileSync(file, content);
      appendLog(process.env.SQUAD_CALL_LOG, `gh lease-write ${path.posix.basename(filePath)}`);
      process.stdout.write(`${JSON.stringify({ content: { path: filePath, sha: sha1(content) } })}\n`);
      return;
    }

    if (method === 'DELETE') {
      const file = contentFile(branch, filePath);
      if (!fs.existsSync(file)) die('gh: Not Found (HTTP 404)');
      fs.unlinkSync(file);
      process.stdout.write('{}\n');
      return;
    }
  }

  die('gh: Not Found (HTTP 404)');
}

function main() {
  const sub = argv[0] || '';
  appendLog(process.env.FAKE_GH_LOG, argv.join(' '));

  if (sub === 'api') {
    handleApi(argv.slice(1));
    return;
  }

  if (sub === 'issue' && argv[1] === 'edit') {
    appendLog(process.env.SQUAD_CALL_LOG, `gh issue-edit ${argv[2] || ''}`);
    appendLog(process.env.GH_LABEL_LOG, String(argv[2] || ''));
    process.exit(0);
  }

  if (sub === 'repo' && argv[1] === 'view') {
    process.stdout.write('octo/demo\n');
    process.exit(0);
  }
  if (sub === 'pr') {
    process.stdout.write('[]\n');
    process.exit(0);
  }

  process.exit(0);
}

main();
