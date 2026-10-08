#!/usr/bin/env node
/**
 * failure-summary.js
 *
 * Issue #144: a failed Squad on ACA job (or CI job run for this repository)
 * used to require manual archaeology before a fix could be dispatched --
 * read the failed check, discover only metadata was captured, re-read the
 * job logs directly, pull the `test.out`-style artifact out of the noise,
 * and search the raw log for the exact `FAIL` lines. This module makes that
 * extraction automatic and repeatable.
 *
 * It is deliberately PURE: given log text (and, when available, a known
 * artifact such as a captured `test.out`/`run-tests.out`), it returns a
 * concise, actionable markdown summary. It performs no network calls, does
 * not know about GitHub, Azure or any specific CI provider, and reads no
 * environment -- the whole extraction surface is testable with plain
 * strings. Callers (a workflow step, the ACA log CLI, a Hub reporter) own
 * *where* the text comes from and what they do with the markdown.
 *
 * Preference order (explicit, see pickSource()):
 *   1. A known artifact file's content (e.g. `test.out`, `run-tests.out`) --
 *      this is the runner's own captured stdout/stderr, already free of the
 *      surrounding CI-provider chrome (timestamps, step banners).
 *   2. The raw job/workflow log, when no such artifact was captured.
 *   3. Neither: extraction FAILS EXPLICITLY (see buildExtractionFailure())
 *      rather than returning an empty or misleadingly confident summary.
 */

'use strict';

/**
 * Lines that are wrapper/shell-echo metadata rather than actionable test or
 * job output. Each entry is a RegExp tested against the line with leading
 * whitespace stripped, so indentation inside a step does not defeat a match.
 *
 * These patterns are intentionally narrow: a pattern that is too broad could
 * swallow a real failure line (e.g. a test asserting on the literal string
 * "Run " would be a disaster to filter out). Every pattern here matches
 * infrastructure noise observed in this repository's own workflows
 * (worker-tests.yml) and the general shapes `bash -x` / GitHub Actions /
 * common CI wrappers produce.
 */
const WRAPPER_NOISE_PATTERNS = [
  // `set -x` / `bash -x` command echo: a line that is literally the command
  // about to run, prefixed with one or more `+`.
  /^\+{1,}\s/,
  // GitHub Actions step grouping and command annotations.
  /^::(group|endgroup|notice|warning|error|debug)::/,
  /^##\[(group|endgroup|section|command)\]/,
  // Actions' own "Run <script>" step-echo banner, which reprints the
  // workflow YAML verbatim before executing it.
  /^Run\s.+$/,
  // A shell prompt-style echo of the command about to run (used by several
  // wrapper scripts in this repo to announce a step before executing it).
  /^\$\s+\S/,
  // This repo's own wrapper boilerplate (worker-tests.yml's "Run worker
  // capability tests" step): the `set -o pipefail` / `rc=0` bookkeeping
  // lines are real lines of the step's own script, not test output.
  /^set -[a-z]+\s*$/,
  /^rc=\$\?\s*$/,
  /^rc=0\s*$/
];

/**
 * Lines that indicate an actual failure worth surfacing, independent of the
 * test framework that produced them. Kept deliberately generic -- a new
 * runner should not require editing this module -- but ordered so the most
 * specific / highest-signal patterns are tried first by matchFailureLine().
 */
const FAILURE_LINE_PATTERNS = [
  // This repo's own suite runner (worker/tests/run-tests.sh): "FAIL: <suite> ...".
  /^FAIL:\s*(.+)$/,
  // Generic "FAIL <name>" / "FAILED <name>" (go test, custom harnesses).
  /^FAILED?\s+(.+)$/,
  // TAP ("not ok 3 - some test").
  /^not ok\s+\d*\s*-?\s*(.+)$/,
  // Jest / Mocha-style failing-test markers.
  /^\s*(?:✗|✕|×)\s+(.+)$/,
  // pytest-style summary lines.
  /^FAILED\s+(.+)$/,
  // Assertion / error context worth keeping even without a named test.
  /^(AssertionError|Error|TypeError|ReferenceError)[:\s](.+)$/
];

/**
 * How many lines of context to keep before and after a detected failure
 * line. Generous enough to usually capture the assertion message that
 * follows a "FAIL: suite" banner, tight enough that ten failures do not
 * reproduce the entire log.
 */
const CONTEXT_BEFORE = 2;
const CONTEXT_AFTER = 6;

/** Maximum number of distinct failures surfaced in detail before summarizing the rest. */
const MAX_DETAILED_FAILURES = 10;

function toLines(text) {
  if (text == null) return [];
  return String(text).replace(/\r\n/g, '\n').split('\n');
}

/**
 * Remove wrapper/shell echo noise from a block of log text, returning only
 * the lines that plausibly carry actionable job/test output. Never throws;
 * an input that matches nothing real just returns an empty array, which
 * callers treat as "nothing actionable was found", not as an error.
 */
function filterWrapperNoise(text) {
  return toLines(text).filter((line) => {
    const trimmed = line.replace(/^[\t ]+/, '');
    if (trimmed.trim() === '') return true; // keep blank lines for context
    return !WRAPPER_NOISE_PATTERNS.some((re) => re.test(trimmed));
  });
}

/**
 * Does this line look like a failure marker? Returns the matched label
 * (e.g. the suite/test name) or null.
 */
function matchFailureLine(line) {
  const trimmed = line.trim();
  if (!trimmed) return null;
  for (const re of FAILURE_LINE_PATTERNS) {
    const m = re.exec(trimmed);
    if (m) {
      return (m[1] || m[2] || trimmed).trim();
    }
  }
  return null;
}

/**
 * Scan filtered lines for failures and return structured matches with
 * surrounding context, in first-seen order. Adjacent/overlapping context
 * windows are merged so a dense run of failures does not duplicate lines.
 */
function extractFailures(lines) {
  const hits = [];
  lines.forEach((line, idx) => {
    const label = matchFailureLine(line);
    if (label) hits.push({ index: idx, label, line });
  });

  const failures = [];
  for (const hit of hits) {
    const start = Math.max(0, hit.index - CONTEXT_BEFORE);
    const end = Math.min(lines.length - 1, hit.index + CONTEXT_AFTER);
    const prev = failures[failures.length - 1];
    if (prev && start <= prev.end + 1) {
      // Merge overlapping/adjacent windows rather than repeating lines.
      prev.end = Math.max(prev.end, end);
      prev.labels.push(hit.label);
      continue;
    }
    failures.push({ start, end, labels: [hit.label] });
  }

  return failures.map((f) => ({
    labels: Array.from(new Set(f.labels)),
    context: lines.slice(f.start, f.end + 1).join('\n')
  }));
}

/**
 * Pick which captured source to extract from, in the documented preference
 * order: a known artifact (e.g. test.out) first, the raw job log second.
 *
 * @param {object} opts
 * @param {string} [opts.testOutContent] content of a known artifact file
 *   (test.out, run-tests.out, or whatever the caller resolved as the
 *   project's canonical captured-test-output file).
 * @param {string} [opts.testOutPath] where that artifact came from, for the
 *   "pointer to raw logs" section even when it IS the source used.
 * @param {string} [opts.rawLogContent] the raw job/workflow log, used only
 *   when no usable artifact content was supplied.
 * @param {string} [opts.rawLogPath] where the raw log can be found/fetched.
 * @returns {{ text: string, origin: 'artifact'|'raw-log'|null }}
 */
function pickSource(opts) {
  const testOut = opts.testOutContent;
  if (typeof testOut === 'string' && testOut.trim() !== '') {
    return { text: testOut, origin: 'artifact' };
  }
  const rawLog = opts.rawLogContent;
  if (typeof rawLog === 'string' && rawLog.trim() !== '') {
    return { text: rawLog, origin: 'raw-log' };
  }
  return { text: '', origin: null };
}

function fenced(text) {
  const body = String(text == null ? '' : text).replace(/```/g, '`\u200b``');
  return '```\n' + body + '\n```';
}

/**
 * Build the explicit "extraction failed" summary required by the issue:
 * when no usable source text was supplied at all, the summary must say so
 * plainly and point at where raw logs can be found instead of silently
 * emitting nothing or a misleadingly empty "all clear".
 */
function buildExtractionFailure(opts) {
  const pointers = [];
  if (opts.testOutPath) pointers.push(`- Known artifact (expected but unavailable): \`${opts.testOutPath}\``);
  if (opts.rawLogPath) pointers.push(`- Raw job/workflow log: \`${opts.rawLogPath}\``);
  if (opts.artifactUrl) pointers.push(`- Artifact/run URL: ${opts.artifactUrl}`);
  if (pointers.length === 0) {
    pointers.push('- No log location was provided to the extractor; check the job/run directly.');
  }

  const lines = [
    '# Failure summary -- extraction failed',
    '',
    '**Extraction status:** FAILED -- no usable log or test-output content was available to summarize.',
    ''
  ];
  if (opts.command) lines.push(`**Command/step:** \`${opts.command}\``, '');
  if (opts.exitCode !== undefined && opts.exitCode !== null) {
    lines.push(`**Exit code:** ${opts.exitCode}`, '');
  }
  lines.push(
    '## Where to look instead',
    '',
    ...pointers,
    '',
    '_This file is generated by worker/lib/failure-summary.js. It reports an explicit extraction failure rather than guessing, per issue #144._'
  );
  return lines.join('\n') + '\n';
}

/**
 * @param {object} opts see pickSource() plus:
 * @param {string} [opts.command]   the failing command or workflow step name
 * @param {number|string} [opts.exitCode] the final process/job exit code
 * @param {string} [opts.status]    final status label (e.g. "failure", "cancelled")
 * @param {string} [opts.rawLogPath] pointer to the full raw log, always shown
 *   when present, regardless of which source was actually used for extraction.
 * @param {string} [opts.testOutPath] pointer to the known artifact file, always
 *   shown when present.
 * @param {string} [opts.artifactUrl] optional URL to the uploaded artifact / run.
 * @returns {{ markdown: string, origin: 'artifact'|'raw-log'|null, failureCount: number, extractionFailed: boolean }}
 */
function buildFailureSummary(opts) {
  const options = opts || {};
  const picked = pickSource(options);

  if (!picked.origin) {
    return {
      markdown: buildExtractionFailure(options),
      origin: null,
      failureCount: 0,
      extractionFailed: true
    };
  }

  const filtered = filterWrapperNoise(picked.text);
  const failures = extractFailures(filtered);

  const title = failures.length > 0
    ? '# Failure summary'
    : '# Failure summary -- no specific failures recognized';

  const lines = [title, ''];

  const statusLine = options.status
    ? `**Final status:** ${options.status}`
    : '**Final status:** failed';
  lines.push(statusLine, '');

  if (options.command) {
    lines.push(`**Failing command/step:** \`${options.command}\``, '');
  }

  if (options.exitCode !== undefined && options.exitCode !== null) {
    lines.push(`**Exit code:** ${options.exitCode}`, '');
  }

  lines.push(
    `**Source used for extraction:** ${picked.origin === 'artifact' ? `known artifact (\`${options.testOutPath || 'test output'}\`)` : 'raw job log (no known test-output artifact was available)'}`,
    ''
  );

  if (failures.length === 0) {
    lines.push(
      '## No failing test/step names were recognized',
      '',
      'The source text did not match any known failure pattern. This can happen when a',
      'job fails for a reason outside the test runner (e.g. a crash before tests started,',
      'or an unrecognized output format). The filtered output below is the best available signal.',
      ''
    );
    const tail = filtered.slice(-40).join('\n').trim();
    if (tail) {
      lines.push('### Tail of filtered output', '', fenced(tail), '');
    }
  } else {
    const detailed = failures.slice(0, MAX_DETAILED_FAILURES);
    const overflow = failures.length - detailed.length;

    lines.push(`## Failing tests/files (${failures.length})`, '');
    for (const f of failures) {
      lines.push(`- ${f.labels.join(', ')}`);
    }
    lines.push('');

    lines.push('## Assertion / error context', '');
    detailed.forEach((f, i) => {
      lines.push(`### ${i + 1}. ${f.labels.join(', ')}`, '', fenced(f.context), '');
    });
    if (overflow > 0) {
      lines.push(`_${overflow} additional failure(s) detected but omitted from detailed context to keep this summary readable; see the raw log._`, '');
    }
  }

  const pointerLines = [];
  if (options.testOutPath) pointerLines.push(`- Known artifact: \`${options.testOutPath}\``);
  if (options.rawLogPath) pointerLines.push(`- Raw job/workflow log: \`${options.rawLogPath}\``);
  if (options.artifactUrl) pointerLines.push(`- Artifact/run URL: ${options.artifactUrl}`);
  if (pointerLines.length > 0) {
    lines.push('## Raw logs / artifacts', '', ...pointerLines, '');
  }

  lines.push('_Generated by worker/lib/failure-summary.js (issue #144)._');

  return {
    markdown: lines.join('\n') + '\n',
    origin: picked.origin,
    failureCount: failures.length,
    extractionFailed: false
  };
}

// --- CLI -------------------------------------------------------------------
//
// Usage:
//   node failure-summary.js \
//     [--test-out <path>] [--raw-log <path>] \
//     [--command "<failing command/step>"] [--exit-code <n>] [--status <label>] \
//     [--artifact-url <url>] [--out <path>]
//
// Reads the content of --test-out (preferred) or --raw-log (fallback) from
// disk itself, so a workflow step only has to name files it already has --
// it never needs to pipe or interpolate log text through the shell. Writes
// markdown to --out, or stdout when --out is omitted.

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    const next = argv[i + 1];
    out[key] = next !== undefined && !next.startsWith('--') ? (i += 1, next) : 'true';
  }
  return out;
}

function readFileIfPresent(fs, path) {
  if (!path) return undefined;
  try {
    if (!fs.existsSync(path)) return undefined;
    return fs.readFileSync(path, 'utf8');
  } catch (err) {
    return undefined;
  }
}

function main(argv) {
  const fs = require('fs');
  const args = parseArgs(argv);

  const testOutContent = readFileIfPresent(fs, args.testOut);
  const rawLogContent = readFileIfPresent(fs, args.rawLog);

  const result = buildFailureSummary({
    testOutContent,
    testOutPath: args.testOut,
    rawLogContent,
    rawLogPath: args.rawLog,
    command: args.command,
    exitCode: args.exitCode,
    status: args.status,
    artifactUrl: args.artifactUrl
  });

  if (args.out) {
    fs.writeFileSync(args.out, result.markdown, 'utf8');
  } else {
    process.stdout.write(result.markdown);
  }

  // A workflow step can chain on this to decide whether to also post a PR
  // comment or append to $GITHUB_STEP_SUMMARY; it is informational only and
  // never fails the step (the EXTRACTION succeeded here even for a job that
  // failed -- that is the whole point of the module).
  process.stderr.write(
    `failure-summary: origin=${result.origin || 'none'} failures=${result.failureCount} extractionFailed=${result.extractionFailed}\n`
  );
  return 0;
}

if (require.main === module) {
  process.exit(main(process.argv.slice(2)));
}

module.exports = {
  filterWrapperNoise,
  matchFailureLine,
  extractFailures,
  pickSource,
  buildFailureSummary,
  buildExtractionFailure,
  WRAPPER_NOISE_PATTERNS,
  FAILURE_LINE_PATTERNS
};
