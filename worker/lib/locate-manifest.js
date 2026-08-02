#!/usr/bin/env node
'use strict';

/**
 * locate-manifest.js
 *
 * THE ONE implementation of "is this manifest path safe, and where does it
 * actually land". Two consumers share it:
 *
 *   1. worker/lib/resolve-capability-route.js  (control-plane routing decision)
 *   2. worker/lib/squad-capability-preflight.sh (in-worker session gate), via
 *      the CLI below, because bash cannot require() a module.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * Until this file, the rules below existed TWICE: once here-ish in the resolver
 * and once as an inline `node - <<'NODE'` heredoc inside the preflight. Two
 * implementations of a path-traversal boundary is the shape of a future CVE: a
 * rule added to one copy and not the other applies to routing but not to the
 * gate that actually runs in the session (or the reverse), and nothing fails.
 * See docs/adr/0003-capability-manifest-future-work.md, finding 2.
 *
 * THE RULES (unchanged by the unification -- this was a refactor with a
 * behavioural-equivalence proof, not a hardening pass):
 *
 *   - an empty path is refused
 *   - an absolute path is refused
 *   - a path containing a control character (U+0000-U+001F, U+007F) is refused
 *   - a repository directory that cannot be resolved to a real directory is
 *     refused (caught here, never thrown -- see "NEVER THROWS" below)
 *   - a candidate that escapes the repository working tree is refused
 *   - a candidate that does not exist is ABSENT, not unsafe
 *   - a symlink AT the manifest path is refused, wherever it points
 *   - a resolved target that escapes the working tree is refused
 *   - a resolved target that is not a regular file is refused
 *
 * Two behaviours here are subtle, load-bearing, and asserted by
 * worker/tests/test_manifest_path_corpus.sh:
 *
 *   - A DANGLING SYMLINK reports "absent", NOT "unsafe". fs.existsSync follows
 *     the link, gets false, and returns before the lstat check is ever reached.
 *     That is the behaviour both copies had; preserving it is the point.
 *   - A symlink at the manifest path is refused even when it points INSIDE the
 *     working tree. The check is "is this a symlink", not "does it escape".
 *
 * NEVER THROWS. Every filesystem call is inside a catch that returns
 * { status: 'unsafe' }. The resolver already did this; the preflight's heredoc
 * did not, and let the throw surface as node exit 1. Both reached the same
 * verdict, which is exactly why nothing caught the drift. Now there is one
 * answer, and the CLI cannot exit 1 for any input -- so a caller that sees
 * exit 1 knows the MODULE is broken or missing, not that the path is bad.
 *
 * CLI CONTRACT (the preflight depends on every line of this)
 * ----------------------------------------------------------
 *   usage: node locate-manifest.js <repo-dir> <manifest-relative-path>
 *
 *   exit 0   present -- the resolved absolute path is written to stdout
 *   exit 3   absent  -- nothing on stdout
 *   exit 4   unsafe  -- nothing on stdout
 *   exit 64  usage error (wrong argument count)
 *   exit 70  internal error (should be unreachable; stderr explains)
 *
 * The verdicts are DISTINCT EXIT CODES rather than a stdout sentinel plus
 * "any non-zero means unsafe", which is what the preflight used to do. Under
 * the old scheme a module that failed to load (node exit 1) would have been
 * indistinguishable from "the path is unsafe" -- fail-closed by luck. Under
 * this scheme any code outside {0,3,4} is unclaimed, and the preflight refuses
 * the session on it. A missing shared locator can therefore never masquerade
 * as "no manifest present", which is the fail-OPEN this sprint had to rule out.
 */

const fs = require('fs');
const path = require('path');

const STATUS_PRESENT = 'present';
const STATUS_ABSENT = 'absent';
const STATUS_UNSAFE = 'unsafe';

const EXIT_PRESENT = 0;
const EXIT_ABSENT = 3;
const EXIT_UNSAFE = 4;
const EXIT_USAGE = 64;
const EXIT_INTERNAL = 70;

const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/;

function realpath(value) {
  return typeof fs.realpathSync.native === 'function' ? fs.realpathSync.native(value) : fs.realpathSync(value);
}

function isWithin(root, candidate) {
  const relative = path.relative(root, candidate);
  return (
    relative === '' ||
    (!relative.startsWith(`..${path.sep}`) && relative !== '..' && !path.isAbsolute(relative))
  );
}

function locateManifest(repoDir, manifestRelativePath) {
  if (
    typeof manifestRelativePath !== 'string' ||
    !manifestRelativePath ||
    path.isAbsolute(manifestRelativePath) ||
    CONTROL_CHARACTERS.test(manifestRelativePath)
  ) {
    return { status: STATUS_UNSAFE };
  }

  let repoRoot;
  try {
    repoRoot = realpath(repoDir);
    if (!fs.statSync(repoRoot).isDirectory()) return { status: STATUS_UNSAFE };
  } catch (err) {
    return { status: STATUS_UNSAFE };
  }

  const candidatePath = path.resolve(repoRoot, manifestRelativePath);
  if (!isWithin(repoRoot, candidatePath)) return { status: STATUS_UNSAFE };

  // Deliberately BEFORE the lstat: existsSync follows the link, so a dangling
  // symlink is reported absent rather than unsafe. Both original copies did
  // this and the corpus asserts it by name.
  if (!fs.existsSync(candidatePath)) return { status: STATUS_ABSENT };

  try {
    if (fs.lstatSync(candidatePath).isSymbolicLink()) return { status: STATUS_UNSAFE };
    const resolvedPath = realpath(candidatePath);
    if (!isWithin(repoRoot, resolvedPath)) return { status: STATUS_UNSAFE };
    if (!fs.statSync(resolvedPath).isFile()) return { status: STATUS_UNSAFE };
    return { status: STATUS_PRESENT, path: resolvedPath };
  } catch (err) {
    return { status: STATUS_UNSAFE };
  }
}

function main(argv) {
  if (argv.length !== 2) {
    process.stderr.write('usage: locate-manifest.js <repo-dir> <manifest-relative-path>\n');
    return EXIT_USAGE;
  }

  const located = locateManifest(argv[0], argv[1]);
  if (located.status === STATUS_PRESENT) {
    process.stdout.write(`${located.path}\n`);
    return EXIT_PRESENT;
  }
  if (located.status === STATUS_ABSENT) return EXIT_ABSENT;
  return EXIT_UNSAFE;
}

if (require.main === module) {
  let code;
  try {
    code = main(process.argv.slice(2));
  } catch (err) {
    // Unreachable by design: locateManifest catches everything. If it ever is
    // reached, the caller must be able to tell it apart from a verdict.
    process.stderr.write(`locate-manifest: internal error: ${err && err.message}\n`);
    code = EXIT_INTERNAL;
  }
  process.exit(code);
}

module.exports = {
  EXIT_ABSENT,
  EXIT_INTERNAL,
  EXIT_PRESENT,
  EXIT_UNSAFE,
  EXIT_USAGE,
  STATUS_ABSENT,
  STATUS_PRESENT,
  STATUS_UNSAFE,
  isWithin,
  locateManifest,
  realpath
};
