#!/usr/bin/env node
'use strict';

/**
 * dispatch-inputs.js
 *
 * Manual dispatch is deliberately narrow: a human with write access may ask the
 * Actions transport to start one session, with a handful of one-run overrides.
 * Those overrides are carried to ACA through env values in an ARM REST body, not
 * through a shell command line, but they are still user-controlled strings that
 * cross trust boundaries. This module is the ONE place they are normalised and
 * validated before the workflow turns them into execution state.
 *
 * The rules here are intentionally conservative and fail closed:
 *   * booleans accept only the exact wire format GitHub Actions sends;
 *   * free-text overrides accept only an allow-listed character set;
 *   * reviewer ids are checked against the repository's active casting registry;
 *   * a base branch is accepted only if it BOTH looks safe and exists in the
 *     target repository right now.
 *
 * Keeping this logic pure and injectable makes it independently testable. The
 * default branch-existence probe uses the same safe `gh` wrapper and failure
 * classification as the lease store, but tests can substitute a stub and stay
 * fully offline.
 */

const fs = require('fs');
const path = require('path');

const { invokeGhSafe, isGoneResult } = require('./dispatch-lease.js');

const DEFAULT_REPO_DIR = path.resolve(__dirname, '..', '..');
const SIMPLE_VALUE_PATTERN = /^[A-Za-z0-9._-]+$/;
const BRANCH_VALUE_PATTERN = /^[A-Za-z0-9._/-]+$/;

function normalizeOptionalString(value) {
  if (value === undefined || value === null || value === true) return '';
  return String(value);
}

function normalizeBooleanInput(name, rawValue, defaultValue, errors) {
  const value = normalizeOptionalString(rawValue);
  if (value === '') return defaultValue ? 'true' : 'false';
  if (value === 'true' || value === 'false') return value;
  errors.push(`${name} must be exactly 'true' or 'false' when provided; received '${value}'.`);
  return defaultValue ? 'true' : 'false';
}

function validateAllowedChars(name, value, pattern, allowedText, errors) {
  if (!pattern.test(value)) {
    errors.push(`${name} may contain only ${allowedText}; received '${value}'.`);
    return false;
  }
  return true;
}

function validateBranchShape(branch, errors) {
  if (branch.startsWith('/') || branch.endsWith('/')) {
    errors.push(`base_branch must not start or end with '/'; received '${branch}'.`);
    return false;
  }
  if (branch.includes('//')) {
    errors.push(`base_branch must not contain an empty path segment ('//'); received '${branch}'.`);
    return false;
  }
  return true;
}

function normalizeRepository(repository) {
  return String(repository || '');
}

function isRepositoryName(value) {
  return /^[^/\s]+\/[^/\s]+$/.test(normalizeRepository(value));
}

function registryPathFor(repoDir) {
  return path.join(path.resolve(repoDir || DEFAULT_REPO_DIR), '.squad', 'casting', 'registry.json');
}

function loadActiveReviewerRegistryIds(repoDir) {
  const registryPath = registryPathFor(repoDir);
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(registryPath, 'utf8'));
  } catch (err) {
    throw new Error(`could not read ${registryPath}: ${err.message}`);
  }

  const agents = parsed && parsed.agents;
  if (!agents || typeof agents !== 'object' || Array.isArray(agents)) {
    throw new Error(`${registryPath} does not contain an 'agents' object.`);
  }

  const activeIds = new Set();
  for (const [id, agent] of Object.entries(agents)) {
    if (!agent || typeof agent !== 'object') continue;
    if (String(agent.status || '').toLowerCase() !== 'active') continue;
    activeIds.add(String(id).toLowerCase());
  }
  return activeIds;
}

function compactGhOutput(result) {
  return [result && result.stderr, result && result.stdout]
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function defaultCheckBranchExists(repository, branch) {
  const result = invokeGhSafe(['api', `repos/${repository}/git/ref/heads/${branch}`]);
  if (result.exitCode === 0) return true;
  if (isGoneResult(result)) return false;

  const detail = compactGhOutput(result);
  throw new Error(detail || `gh api exited ${result.exitCode}`);
}

async function validateDispatchInputs(rawInputs, options) {
  const opts = options || {};
  const normalized = {
    model: '',
    baseBranch: '',
    publishPr: 'true',
    reviewer: '',
    watchOnly: 'false'
  };
  const errors = [];
  const repoDir = path.resolve(opts.repoDir || DEFAULT_REPO_DIR);
  const repository = normalizeRepository(opts.repository);
  const branchExists = typeof opts.checkBranchExists === 'function'
    ? opts.checkBranchExists
    : defaultCheckBranchExists;

  normalized.publishPr = normalizeBooleanInput('publish_pr', rawInputs && rawInputs.publishPr, true, errors);
  normalized.watchOnly = normalizeBooleanInput('watch_only', rawInputs && rawInputs.watchOnly, false, errors);

  const model = normalizeOptionalString(rawInputs && rawInputs.model);
  if (model !== '' && validateAllowedChars('model', model, SIMPLE_VALUE_PATTERN, "letters, digits, '.', '_' and '-'", errors)) {
    normalized.model = model;
  }

  const reviewerInput = normalizeOptionalString(rawInputs && rawInputs.reviewer);
  if (reviewerInput !== '') {
    const reviewer = reviewerInput.toLowerCase();
    if (validateAllowedChars('reviewer', reviewerInput, SIMPLE_VALUE_PATTERN, "letters, digits, '.', '_' and '-'", errors)) {
      try {
        const activeReviewers = loadActiveReviewerRegistryIds(repoDir);
        if (!activeReviewers.has(reviewer)) {
          errors.push(
            `reviewer '${reviewerInput}' is not an active squad member id in .squad/casting/registry.json.`
          );
        } else {
          normalized.reviewer = reviewer;
        }
      } catch (err) {
        errors.push(`reviewer could not be validated: ${err.message}`);
      }
    }
  }

  const baseBranch = normalizeOptionalString(rawInputs && rawInputs.baseBranch);
  if (
    baseBranch !== '' &&
    validateAllowedChars(
      'base_branch',
      baseBranch,
      BRANCH_VALUE_PATTERN,
      "letters, digits, '.', '_', '-' and '/'",
      errors
    ) &&
    validateBranchShape(baseBranch, errors)
  ) {
    if (!isRepositoryName(repository)) {
      errors.push(`base_branch requires --repository in owner/name form so its existence can be verified; received '${repository || ''}'.`);
    } else {
      try {
        const exists = await branchExists(repository, baseBranch);
        if (!exists) {
          errors.push(`base_branch '${baseBranch}' does not exist in ${repository}.`);
        } else {
          normalized.baseBranch = baseBranch;
        }
      } catch (err) {
        errors.push(`base_branch '${baseBranch}' could not be verified in ${repository}: ${err.message}`);
      }
    }
  }

  return { ok: errors.length === 0, errors, normalized };
}

module.exports = {
  BRANCH_VALUE_PATTERN,
  DEFAULT_REPO_DIR,
  SIMPLE_VALUE_PATTERN,
  defaultCheckBranchExists,
  loadActiveReviewerRegistryIds,
  validateDispatchInputs
};
