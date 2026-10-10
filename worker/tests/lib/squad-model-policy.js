'use strict';
// Squad role-model policy (issue #150): drift checks over the repository's
// EFFECTIVE instruction map, plus the in-memory mutants that prove the checks bite.
//
// Driven by worker/tests/test_squad_model_policy.sh. Reads files only; it never
// writes, never touches the network, and mutates nothing on disk: every mutant is
// a string transform applied to an in-memory copy.
//
// SCOPE, STATED HONESTLY. This checks the TEXT the coordinator and the spawned
// agents read: .squad/config.json, the charters, routing, the operative
// squad.agent.md, the after-agent Scribe reference, Ralph's instructions and the
// decision log. It does not prove a runtime honoured a model on any given spawn.
//
// Not covered, deliberately: the generic SDK catalogs and templates
// (.squad/templates/model-selection-reference.md, skills/**), casting, history,
// runtime and state files. They carry their own defaults and are overridden by the
// authoritative policy in squad.agent.md rather than rewritten here.

const fs = require('fs');
const path = require('path');

const JUDGE = 'gpt-6.1-sol';
const EXEC = 'claude-sonnet-5.5';
const SMALL = 'claude-haiku-5.5';

// The approved assignment (issue #150, updated judgement). Hardcoded on purpose:
// the config is checked AGAINST the policy, so drift in either direction is caught.
const EXPECTED = {
  lead: JUDGE, advisor: JUDGE, security: JUDGE, rai: JUDGE, 'fact-checker': JUDGE,
  engineer: EXEC, reviewer: EXEC, devrel: EXEC, ralph: EXEC,
  scribe: SMALL, docs: SMALL,
};
const APPROVED = new Set([JUDGE, EXEC, SMALL]);

const MODEL_ID = /\b(?:claude-(?:opus|sonnet|haiku)|gpt)-\d+(?:\.\d+)*(?:-[a-z][a-z0-9]*)*/g;

// Duties of the reference Scribe prompt that a spawn must keep (issue #150: the
// Scribe overlay changes name and model only, never shortens the prompt).
const SCRIBE_DUTIES = [
  'SPAWN MANIFEST',
  'DECISIONS ARCHIVE [HARD GATE]',
  'DECISION INBOX',
  'ARCHIVAL SAFETY RULES',
  'DESTINATION MUST BE TRACKED',
  'APPEND FIRST, VERIFY, THEN DELETE',
  'COUNT ENTRIES, NOT BYTES',
  'NEVER REPORT A GATE OUTCOME YOU DID NOT MEASURE',
  'ORCHESTRATION LOG',
  'SESSION LOG',
  'CROSS-AGENT',
  'HISTORY SUMMARIZATION [HARD GATE]',
  'HEALTH REPORT',
];

const CURRENT_DECISION = /^2026-10-09: Squad member models are gpt-6\.1-sol, claude-sonnet-5\.5 and claude-haiku-5\.5/;

const FIXED_FILES = [
  '.squad/config.json',
  '.squad/routing.md',
  '.squad/ralph-instructions.md',
  '.squad/decisions.md',
  '.squad/decisions-archive.md',
  '.squad/team.md',
  '.github/agents/squad.agent.md',
  '.squad/templates/after-agent-reference.md',
];

const charterPath = (m) => `.squad/agents/${m}/charter.md`;

function modelIds(text) {
  return [...new Set(text.match(MODEL_ID) || [])];
}

// Text from `start` up to the first of `ends` that follows it; null if `start` is absent.
function sliceFrom(text, start, ends) {
  const i = text.indexOf(start);
  if (i < 0) return null;
  let end = text.length;
  for (const e of ends) {
    const j = text.indexOf(e, i + start.length);
    if (j >= 0 && j < end) end = j;
  }
  return text.slice(i, end);
}

function firstFence(text) {
  const m = /```[^\n]*\n([\s\S]*?)\n```/.exec(text);
  return m ? m[1] : null;
}

// Parameter lines of a spawn block; everything from `prompt: |` onward is the prompt.
function parseSpawn(block) {
  if (block == null) return null;
  const out = {};
  const p = block.search(/^prompt:/m);
  const head = p >= 0 ? block.slice(0, p) : block;
  for (const m of head.matchAll(/^(agent_type|model|mode|name|description):\s*"(.*)"\s*$/gm)) out[m[1]] = m[2];
  if (p >= 0) out.prompt = block.slice(p);
  return out;
}

function tableRows(text) {
  return [...text.matchAll(/^\|(.+)\|\s*$/gm)]
    .map((m) => m[1].split('|').map((c) => c.trim()))
    .filter((cells) => !cells.every((c) => /^-+$/.test(c)));
}

function loadRepo(root) {
  const read = (rel) => {
    const p = path.join(root, rel);
    return fs.existsSync(p) ? fs.readFileSync(p, 'utf8').replace(/\r\n/g, '\n') : null;
  };
  const files = {};
  for (const rel of FIXED_FILES) {
    const t = read(rel);
    if (t !== null) files[rel] = t;
  }
  const agentsDir = path.join(root, '.squad', 'agents');
  const members = [];
  for (const e of fs.readdirSync(agentsDir, { withFileTypes: true })) {
    if (!e.isDirectory()) continue;
    const t = read(charterPath(e.name));
    if (t === null) continue;
    files[charterPath(e.name)] = t;
    members.push(e.name);
  }
  return { files, members: members.sort() };
}

function buildContext(repo) {
  const ctx = { files: repo.files, members: repo.members, cfg: null, cfgError: null };
  try {
    ctx.cfg = JSON.parse(repo.files['.squad/config.json']);
  } catch (e) {
    ctx.cfgError = `.squad/config.json does not parse: ${e.message}`;
  }
  ctx.overrides = (ctx.cfg && ctx.cfg.agentModelOverrides) || {};
  ctx.scribeModel = ctx.overrides.scribe;
  return ctx;
}

const CHECKS = [];
const def = (id, desc, fn) => CHECKS.push({ id, desc, fn });

// ---------------------------------------------------------------- config.json
def('config.parse', 'config.json parses', (c) => (c.cfgError ? [c.cfgError] : []));

def('config.keys-are-folders',
  'agentModelOverrides keys equal the .squad/agents/<name>/ folders, exact case, no extras',
  (c) => {
    const keys = Object.keys(c.overrides);
    const p = [];
    for (const m of c.members) if (!keys.includes(m)) p.push(`folder '${m}' has no agentModelOverrides key; it would silently inherit defaultModel`);
    for (const k of keys) if (!c.members.includes(k)) p.push(`agentModelOverrides key '${k}' matches no .squad/agents/<name>/ folder (keys are exact and case-sensitive)`);
    return p;
  });

def('config.role-models', 'each role resolves to its approved model (gpt-6.1-sol / claude-sonnet-5.5 / claude-haiku-5.5)',
  (c) => Object.entries(EXPECTED)
    .filter(([role, model]) => c.overrides[role] !== model)
    .map(([role, model]) => `${role}: expected ${model}, config has ${c.overrides[role]}`));

def('config.default-and-policy', 'defaultModel and modelPolicy.* models are the approved ones',
  (c) => {
    const mp = (c.cfg && c.cfg.modelPolicy) || {};
    const want = [['defaultModel', c.cfg && c.cfg.defaultModel, EXEC], ['modelPolicy.executorModel', mp.executorModel, EXEC],
      ['modelPolicy.advisorModel', mp.advisorModel, JUDGE], ['modelPolicy.scribeModel', mp.scribeModel, SMALL]];
    return want.filter(([, got, exp]) => got !== exp).map(([k, got, exp]) => `${k}: expected ${exp}, config has ${got}`);
  });

def('config.approved-only', 'every model the config assigns is one of the three approved models',
  (c) => {
    const mp = (c.cfg && c.cfg.modelPolicy) || {};
    const assigned = { defaultModel: c.cfg && c.cfg.defaultModel, ...c.overrides,
      executorModel: mp.executorModel, advisorModel: mp.advisorModel, scribeModel: mp.scribeModel };
    return Object.entries(assigned).filter(([, v]) => !APPROVED.has(v)).map(([k, v]) => `${k} assigns unapproved model ${v}`);
  });

// ------------------------------------------------------------------- charters
def('charter.model-section', 'each charter has a ## Model section naming the same model as the config',
  (c) => {
    const p = [];
    for (const m of c.members) {
      const t = c.files[charterPath(m)];
      const sec = sliceFrom(t, '## Model', ['\n## ']);
      if (!sec || !/^## Model\s*\n/.test(sec)) { p.push(`${m}: charter has no ## Model section`); continue; }
      const use = /Use `([^`]+)`/.exec(sec);
      if (!use) { p.push(`${m}: ## Model section names no model`); continue; }
      const want = c.overrides[m];
      if (use[1] !== want) p.push(`${m}: charter says ${use[1]}, config says ${want}`);
      if (EXPECTED[m] && use[1] !== EXPECTED[m]) p.push(`${m}: charter says ${use[1]}, policy says ${EXPECTED[m]}`);
    }
    return p;
  });

def('charter.no-stale-models', 'no charter names an unapproved model id or an Opus version',
  (c) => {
    const p = [];
    for (const m of c.members) {
      const t = c.files[charterPath(m)];
      for (const id of modelIds(t)) if (!APPROVED.has(id)) p.push(`${m}: charter names unapproved model ${id}`);
      if (/\bOpus\s*\d/.test(t)) p.push(`${m}: charter names an Opus version`);
    }
    return p;
  });

def('paths.canonical-folders', 'no .squad/agents/<Name>/ reference differs in case from a real member folder',
  (c) => {
    const p = [];
    const scan = [...c.members.map(charterPath), '.github/agents/squad.agent.md', '.squad/routing.md', '.squad/ralph-instructions.md', '.squad/team.md'];
    for (const f of scan) {
      const t = c.files[f];
      if (!t) continue;
      for (const m of t.matchAll(/\.squad\/agents\/([A-Za-z][A-Za-z0-9_-]*)\//g)) {
        const real = c.members.find((x) => x.toLowerCase() === m[1].toLowerCase());
        if (real && real !== m[1]) p.push(`${f}: '.squad/agents/${m[1]}/' must be '.squad/agents/${real}/' (exact case)`);
      }
    }
    return [...new Set(p)];
  });

// -------------------------------------------------------------------- routing
const routingOf = (c) => c.files['.squad/routing.md'] || '';

def('routing.model-table', 'routing Model Policy table matches the config for every member exactly once',
  (c) => {
    const sec = sliceFrom(routingOf(c), '## Model Policy', ['\n## ']);
    if (!sec) return ['routing.md has no ## Model Policy section'];
    const p = [];
    const seen = {};
    for (const m of sec.matchAll(/^\|\s*[A-Za-z ]+?\s*\|\s*`([^`]+)`\s*\|\s*([^|]+?)\s*\|/gm)) {
      for (const name of m[2].split(',').map((s) => s.trim())) {
        if (seen[name]) p.push(`${name} appears twice in the Model Policy table`);
        seen[name] = m[1];
        if (!c.members.includes(name)) p.push(`Model Policy table names '${name}', which is not a member folder (exact case)`);
        else if (m[1] !== c.overrides[name]) p.push(`${name}: table says ${m[1]}, config says ${c.overrides[name]}`);
      }
    }
    for (const role of Object.keys(EXPECTED)) if (!seen[role]) p.push(`${role} missing from the Model Policy table`);
    return p;
  });

def('routing.route-names', 'every routing table names members by their exact lowercase folder', (c) => {
  const t = routingOf(c);
  const p = [];
  const a = sliceFrom(t, '## Routing Table', ['\n## ']);
  const b = sliceFrom(t, '## Work Type', ['\n## ']);
  if (!a || !b) return ['routing.md is missing the Routing Table or Work Type tables'];
  const check = (name, where) => {
    if (name && name !== '—' && !c.members.includes(name)) p.push(`${where}: '${name}' is not a member folder (exact case)`);
  };
  for (const [, who] of tableRows(a).slice(1)) check(who, 'Routing Table');
  for (const [, primary, secondary] of tableRows(b).slice(1)) { check(primary, 'Work Type Primary'); check(secondary, 'Work Type Secondary'); }
  return p;
});

def('routing.scribe-rule', 'routing rule 2 spawns Scribe as name "scribe" with the config model', (c) => {
  const line = routingOf(c).split('\n').find((l) => l.startsWith('2. **Scribe always runs**')) || '';
  const p = [];
  if (!line.includes('name: "scribe"')) p.push('rule 2 does not spawn Scribe as name: "scribe"');
  if (!line.includes(`model: "${c.scribeModel}"`)) p.push(`rule 2 does not pass model: "${c.scribeModel}"`);
  return p;
});

def('routing.no-silent-downgrade', 'routing forbids retrying on another model and omitting model', (c) => {
  const t = routingOf(c);
  return t.includes('Do not retry on another model and do not omit the `model` parameter.') ? [] : ['routing.md allows a downgrade or an omitted model'];
});

def('routing.no-stale-models', 'routing names no unapproved model id', (c) =>
  modelIds(routingOf(c)).filter((id) => !APPROVED.has(id)).map((id) => `routing.md names unapproved model ${id}`));

// ------------------------------------------------------------ squad.agent.md
const AGENT = '.github/agents/squad.agent.md';
const agentOf = (c) => c.files[AGENT] || '';
const policyOf = (c) => sliceFrom(agentOf(c), '### Per-Agent Model Selection', ['\n### ']) || '';

def('agent.model-policy-resolved', 'squad.agent.md resolved-models bullet matches the policy for every role', (c) => {
  const sec = policyOf(c);
  if (!sec.includes('**Repository model policy (authoritative')) return ['squad.agent.md has no authoritative Repository model policy'];
  const p = [];
  for (const model of APPROVED) {
    const m = new RegExp('`' + model.replace(/\./g, '\\.') + '` — ([a-z][a-z-]*(?:, [a-z][a-z-]*)*)').exec(sec);
    const got = m ? m[1].split(', ').sort() : [];
    const want = Object.keys(EXPECTED).filter((r) => EXPECTED[r] === model).sort();
    if (got.join() !== want.join()) p.push(`${model}: squad.agent.md lists [${got}], policy says [${want}]`);
  }
  return p;
});

def('agent.model-policy-keys', 'squad.agent.md key list equals the member folders (lowercase)', (c) => {
  const line = policyOf(c).split('\n').find((l) => l.startsWith('- **The key is the lowercase member name**')) || '';
  const m = /\(((?:`[A-Za-z-]+`(?:, )?)+)\)/.exec(line);
  const got = m ? [...m[1].matchAll(/`([^`]+)`/g)].map((x) => x[1]).sort() : [];
  return got.join() === c.members.join() ? [] : [`squad.agent.md key list [${got}] != member folders [${c.members}]`];
});

def('agent.no-silent-downgrade', 'squad.agent.md forbids silent downgrade and the omitted model for members', (c) => {
  const sec = policyOf(c);
  const p = [];
  if (!sec.includes('**No silent downgrade.**')) p.push('no "No silent downgrade" rule');
  if (!sec.includes('stop and report which member and model')) p.push('no stop-and-report on an unavailable model');
  if (!sec.includes('Do not retry on another model and do not omit the `model` parameter.')) p.push('retry/omit-model is not forbidden');
  if (!sec.includes('except for a configured member, which never falls back')) p.push('the generic silent-fallback line has no member exception');
  if (!sec.includes('Scribe is not exempt')) p.push('Scribe is not stated as covered by the model policy');
  return p;
});

def('agent.scribe-overlay', 'Scribe spawn overlay: config model, name "scribe", background, and NO replacement prompt', (c) => {
  const sec = sliceFrom(agentOf(c), '**Scribe Spawn Template**', ['\n**On-demand reference:**']);
  if (!sec) return ['squad.agent.md has no Scribe Spawn Template'];
  const o = parseSpawn(firstFence(sec));
  if (!o) return ['Scribe Spawn Template has no parameter block'];
  const p = [];
  if (o.model !== c.scribeModel) p.push(`overlay model is ${o.model}, config says ${c.scribeModel}`);
  if (o.name !== 'scribe') p.push(`overlay name is ${o.name}, expected "scribe"`);
  if (o.mode !== 'background') p.push(`overlay mode is ${o.mode}, expected "background"`);
  if (o.agent_type !== 'general-purpose') p.push(`overlay agent_type is ${o.agent_type}`);
  if (o.prompt !== undefined || /^prompt:/m.test(sec)) p.push('overlay carries its own prompt: it would replace the full reference prompt');
  return p;
});

def('agent.scribe-overlay-duties', 'Scribe overlay defers to the full reference prompt and names its duties', (c) => {
  const sec = sliceFrom(agentOf(c), '**Scribe Spawn Template**', ['\n**On-demand reference:**']) || '';
  const need = ['use its full Scribe spawn prompt unchanged', 'not a replacement task list', 'spawn manifest',
    'archival safety rules and size gates', 'orchestration and session logs', 'permitted cross-agent history updates',
    'history summarization gate', 'health report', 'stop and report it rather than inventing a shortened prompt'];
  return need.filter((n) => !sec.includes(n)).map((n) => `Scribe overlay text is missing: "${n}"`);
});

def('agent.after-agent', 'After Agent Work preserves the reference Scribe prompt and overrides only name and model', (c) => {
  const sec = sliceFrom(agentOf(c), '### After Agent Work', ['\n### ']) || '';
  const want = 'Preserve its full Scribe prompt and follow-up sequence; override only the canonical `name` and configured `model` parameters';
  return sec.includes(want) ? [] : ['After Agent Work does not say to preserve the full Scribe prompt and override only name and model'];
});

def('agent.no-stale-models', 'squad.agent.md names no unapproved model id', (c) =>
  modelIds(agentOf(c)).filter((id) => !APPROVED.has(id)).map((id) => `squad.agent.md names unapproved model ${id}`));

// ----------------------------------------------- after-agent-reference.md + EFFECTIVE spawn
const REF = '.squad/templates/after-agent-reference.md';

function referenceSpawn(c) {
  const sec = sliceFrom(c.files[REF] || '', '4. **Spawn Scribe**', ['\n5. **Immediately assess']);
  return sec ? { text: sec, spawn: parseSpawn(firstFence(sec)) } : null;
}

def('reference.scribe-spawn', 'reference Scribe spawn takes the config model (never a hardcoded older one) and name "scribe"', (c) => {
  const r = referenceSpawn(c);
  if (!r || !r.spawn) return ['after-agent-reference.md has no Scribe spawn block'];
  const s = r.spawn;
  const p = [];
  if (s.model !== '{scribe_model}' && s.model !== c.scribeModel) p.push(`reference Scribe model is ${s.model}; expected {scribe_model} or ${c.scribeModel}`);
  if (s.name !== 'scribe') p.push(`reference Scribe name is ${s.name}`);
  if (s.mode !== 'background') p.push(`reference Scribe mode is ${s.mode}`);
  if (!r.text.includes('`agentModelOverrides.scribe`')) p.push('reference does not say where {scribe_model} comes from (agentModelOverrides.scribe)');
  return p;
});

def('reference.scribe-duties', 'reference Scribe prompt keeps manifest, archival gates, logs, history and health duties', (c) => {
  const r = referenceSpawn(c);
  const prompt = r && r.spawn && r.spawn.prompt;
  if (!prompt) return ['reference Scribe spawn has no prompt'];
  return SCRIBE_DUTIES.filter((d) => !prompt.includes(d)).map((d) => `reference Scribe prompt lost: ${d}`);
});

// What the after-agent Scribe spawn actually is: the reference, with the overlay's
// parameters applied on top. A prompt in the overlay replaces the reference's.
function effectiveScribe(c) {
  const r = referenceSpawn(c);
  const sec = sliceFrom(agentOf(c), '**Scribe Spawn Template**', ['\n**On-demand reference:**']);
  const o = sec ? parseSpawn(firstFence(sec)) : null;
  if (!r || !r.spawn || !o) return null;
  const e = { ...r.spawn, ...o };
  if (e.model === '{scribe_model}') e.model = c.scribeModel;
  return e;
}

def('effective.scribe-spawn', 'effective after-agent Scribe spawn: haiku-5.5 from config, name "scribe", full prompt duties', (c) => {
  const e = effectiveScribe(c);
  if (!e) return ['cannot build the effective Scribe spawn (reference or overlay missing)'];
  const p = [];
  if (e.model !== EXPECTED.scribe) p.push(`effective Scribe model is ${e.model}, policy says ${EXPECTED.scribe}`);
  if (e.name !== 'scribe') p.push(`effective Scribe name is ${e.name}`);
  const missing = SCRIBE_DUTIES.filter((d) => !(e.prompt || '').includes(d));
  if (missing.length) p.push(`effective Scribe prompt lost: ${missing.join('; ')}`);
  return p;
});

// ------------------------------------------------------------ ralph-instructions
def('ralph.models-section', 'ralph-instructions names the config model for ralph and forbids downgrade/omitted model', (c) => {
  const sec = sliceFrom(c.files['.squad/ralph-instructions.md'] || '', '### Models', ['\n### ']);
  if (!sec) return ['ralph-instructions.md has no ### Models section'];
  const flat = sec.replace(/\s+/g, ' ');
  const p = [];
  if (!flat.includes('agentModelOverrides')) p.push('Models section does not point at agentModelOverrides');
  if (!flat.includes(`You are \`ralph\` and run \`${c.overrides.ralph}\``)) p.push(`Models section does not state ralph runs ${c.overrides.ralph}`);
  if (!flat.includes('do not retry on another model and do not omit the `model` parameter')) p.push('Models section does not forbid downgrade or an omitted model');
  return p;
});

// --------------------------------------------------------------------- decisions
// The decision log is decisions.md plus its archive: Scribe moves old entries across,
// and an archived entry is still a preserved one.
const decisionLog = (c) => (c.files['.squad/decisions.md'] || '') + '\n' + (c.files['.squad/decisions-archive.md'] || '');

function decisionBlocks(text) {
  return text.split(/^### /m).slice(1).map((b) => ({ heading: b.split('\n')[0], body: b }));
}

def('decisions.current-decision', 'the decision log records the current model decision, naming what it supersedes', (c) => {
  const b = decisionBlocks(decisionLog(c)).find((x) => CURRENT_DECISION.test(x.heading));
  if (!b) return ['the decision log has no 2026-10-09 model decision'];
  const p = [];
  for (const m of [JUDGE, EXEC, SMALL]) if (!b.body.includes(`\`${m}\``)) p.push(`current decision does not name ${m}`);
  if (!/\*\*Supersedes:\*\*/.test(b.body)) p.push('current decision does not say what it supersedes');
  return p;
});

def('decisions.superseded-labels', 'every older decision that names an unapproved model carries a Superseded label', (c) => {
  const p = [];
  for (const b of decisionBlocks(decisionLog(c))) {
    if (CURRENT_DECISION.test(b.heading)) continue;
    const stale = modelIds(b.body).filter((id) => !APPROVED.has(id));
    if (stale.length && !/^> \*\*Superseded /m.test(b.body)) p.push(`'${b.heading}' names ${stale.join(', ')} but is not labelled Superseded`);
  }
  return p;
});

def('decisions.history-preserved', 'superseded decisions keep their original text (labelled, not rewritten)', (c) => {
  const blocks = decisionBlocks(decisionLog(c));
  const anchors = [[/^2026-07-28: All Squad members run Claude Opus 5 only/, 'uses `claude-opus-5`'],
    [/^2026-07-15: Route development through Squad/, 'using `gpt-5.6-luna`'],
    [/^2026-07-15: Route development through Squad/, 'using `claude-opus-4.8`']];
  return anchors.flatMap(([re, text]) => {
    const b = blocks.find((x) => re.test(x.heading));
    if (!b) return [`decision matching ${re} was removed`];
    return b.body.includes(text) ? [] : [`'${b.heading}' no longer contains its original text: ${text}`];
  });
});

// ------------------------------------------------------------------ run + mutants
function check(repo) {
  const ctx = buildContext(repo);
  const results = {};
  for (const ch of CHECKS) {
    try { results[ch.id] = ch.fn(ctx); } catch (e) { results[ch.id] = [`check crashed: ${e.message}`]; }
  }
  return results;
}

// A mutant is a deliberate regression. It must be caught by the named check(s); a
// mutation whose target text is absent throws instead of silently doing nothing.
function once(text, find, repl) {
  const n = text.split(find).length - 1;
  if (n !== 1) throw new Error(`mutation target must occur exactly once (found ${n}): ${JSON.stringify(find.slice(0, 80))}`);
  return text.replace(find, () => repl);
}
const edit = (file, find, repl, expect, name) => ({ name, expect, edits: [{ file, fn: (t) => once(t, find, repl) }] });
const cfg = (name, expect, fn) => ({ name, expect, edits: [{ file: '.squad/config.json', fn: (t) => { const o = JSON.parse(t); fn(o); return JSON.stringify(o, null, 2); } }] });
const rename = (o, from, to) => { o.agentModelOverrides[to] = o.agentModelOverrides[from]; delete o.agentModelOverrides[from]; };

const ROUTING = '.squad/routing.md';
const RALPH = '.squad/ralph-instructions.md';
const DEC = '.squad/decisions.md';
const SUP_LABEL = '> **Superseded 2026-10-09** — the single-model policy below no longer applies. See "Squad member models are gpt-6.1-sol, claude-sonnet-5.5 and claude-haiku-5.5". Kept unchanged as history.\n\n';

const MUTANTS = [
  cfg('config: lead reverts to claude-opus-5.5', ['config.role-models'], (o) => { o.agentModelOverrides.lead = 'claude-opus-5.5'; }),
  cfg('config: engineer reverts to claude-opus-4.8', ['config.role-models', 'config.approved-only'], (o) => { o.agentModelOverrides.engineer = 'claude-opus-4.8'; }),
  cfg('config: scribe reverts to claude-haiku-4.5', ['config.role-models', 'config.approved-only'], (o) => { o.agentModelOverrides.scribe = 'claude-haiku-4.5'; }),
  cfg('config: docs given the executor model', ['config.role-models'], (o) => { o.agentModelOverrides.docs = EXEC; }),
  cfg('config: devrel given unapproved gpt-5.6-luna', ['config.approved-only'], (o) => { o.agentModelOverrides.devrel = 'gpt-5.6-luna'; }),
  cfg('config: rai key re-cased to Rai', ['config.keys-are-folders', 'config.role-models'], (o) => rename(o, 'rai', 'Rai')),
  cfg('config: scribe key re-cased to Scribe', ['config.keys-are-folders', 'config.role-models'], (o) => rename(o, 'scribe', 'Scribe')),
  cfg('config: fact-checker key becomes factchecker', ['config.keys-are-folders'], (o) => rename(o, 'fact-checker', 'factchecker')),
  cfg('config: reviewer key deleted', ['config.keys-are-folders', 'config.role-models'], (o) => { delete o.agentModelOverrides.reviewer; }),
  cfg('config: developer alias key added', ['config.keys-are-folders'], (o) => { o.agentModelOverrides.developer = EXEC; }),
  cfg('config: defaultModel reverts to claude-opus-5.5', ['config.default-and-policy', 'config.approved-only'], (o) => { o.defaultModel = 'claude-opus-5.5'; }),
  cfg('config: modelPolicy.advisorModel reverts to claude-opus-5.5', ['config.default-and-policy'], (o) => { o.modelPolicy.advisorModel = 'claude-opus-5.5'; }),
  {
    name: 'config: a new agent folder with no config key',
    expect: ['config.keys-are-folders'],
    edits: [],
    addMember: { name: 'newbie', charter: '# Newbie\n\n## Model\n\nUse `claude-sonnet-5.5`.\n' },
  },

  edit(charterPath('lead'), 'Use `gpt-6.1-sol`', 'Use `claude-opus-5.5`', ['charter.model-section', 'charter.no-stale-models'], 'charter: lead reverts to claude-opus-5.5'),
  edit(charterPath('engineer'), 'Use `claude-sonnet-5.5`', 'Use `claude-sonnet-5`', ['charter.model-section', 'charter.no-stale-models'], 'charter: engineer reverts to claude-sonnet-5'),
  edit(charterPath('scribe'), 'Use `claude-haiku-5.5`', 'Use `claude-haiku-4.5`', ['charter.model-section', 'charter.no-stale-models'], 'charter: scribe reverts to claude-haiku-4.5'),
  { name: 'charter: reviewer loses its ## Model section', expect: ['charter.model-section'],
    edits: [{ file: charterPath('reviewer'), fn: (t) => once(t, '## Model', '## Notes') }] },
  { name: 'charter: lead still tells the engineer to run claude-opus-4.8', expect: ['charter.no-stale-models'],
    edits: [{ file: charterPath('lead'), fn: (t) => `${t}\nThe engineer uses \`claude-opus-4.8\`.\n` }] },
  { name: 'charter: rai points at .squad/agents/Rai/history.md', expect: ['paths.canonical-folders'],
    edits: [{ file: charterPath('rai'), fn: (t) => `${t}\nSee \`.squad/agents/Rai/history.md\`.\n` }] },

  edit(ROUTING, '| Scribe | `claude-haiku-5.5` |', '| Scribe | `claude-haiku-4.5` |', ['routing.model-table', 'routing.no-stale-models'], 'routing: scribe tier reverts to claude-haiku-4.5'),
  edit(ROUTING, '| Advisor | `gpt-6.1-sol` |', '| Advisor | `claude-opus-5.5` |', ['routing.model-table', 'routing.no-stale-models'], 'routing: judgement tier reverts to claude-opus-5.5'),
  edit(ROUTING, '| RAI review | rai |', '| RAI review | Rai |', ['routing.route-names'], 'routing: Rai routed by display name'),
  edit(ROUTING, ' with `model: "claude-haiku-5.5"` (`agentModelOverrides.scribe`)', '', ['routing.scribe-rule'], 'routing: Scribe rule drops its model'),
  edit(ROUTING, 'Do not retry on another model and do not omit the `model` parameter.', 'Retry on another model if it is unavailable.', ['routing.no-silent-downgrade'], 'routing: allows a silent downgrade'),

  edit(AGENT, '`claude-sonnet-5.5` — engineer, reviewer', '`claude-sonnet-5.5` — reviewer', ['agent.model-policy-resolved'], 'agent: resolved-models list drops engineer'),
  edit(AGENT, '`scribe`, `rai`, `fact-checker`', '`Scribe`, `Rai`, `fact-checker`', ['agent.model-policy-keys'], 'agent: key list uses display names'),
  edit(AGENT, '**No silent downgrade.**', '**Graceful fallback.**', ['agent.no-silent-downgrade'], 'agent: no-silent-downgrade rule removed'),
  edit(AGENT, ' — except for a configured member, which never falls back (see the repository model policy below)', '', ['agent.no-silent-downgrade'], 'agent: silent-fallback line loses its member exception'),
  edit(AGENT, 'model: "claude-haiku-5.5"\nmode: "background"\nname: "scribe"', 'model: "claude-haiku-4.5"\nmode: "background"\nname: "scribe"', ['agent.scribe-overlay', 'effective.scribe-spawn', 'agent.no-stale-models'], 'agent: Scribe overlay model reverts to claude-haiku-4.5'),
  edit(AGENT, 'model: "claude-haiku-5.5"\nmode: "background"\nname: "scribe"', 'mode: "background"\nname: "scribe"', ['agent.scribe-overlay'], 'agent: Scribe overlay drops its model'),
  edit(AGENT, 'mode: "background"\nname: "scribe"\ndescription: "\u{1F4CB} Scribe: Log session & merge decisions"\n```\n\nKeep the reference', 'mode: "background"\nname: "Scribe"\ndescription: "\u{1F4CB} Scribe: Log session & merge decisions"\n```\n\nKeep the reference', ['agent.scribe-overlay', 'effective.scribe-spawn'], 'agent: Scribe overlay name is the display name'),
  edit(AGENT, '```\n\nKeep the reference prompt', 'prompt: |\n  You are the Scribe. Log and merge decisions.\n```\n\nKeep the reference prompt', ['agent.scribe-overlay', 'effective.scribe-spawn'], 'agent: Scribe overlay carries a shortened replacement prompt'),
  edit(AGENT, 'history summarization gate, ', '', ['agent.scribe-overlay-duties'], 'agent: Scribe overlay stops naming the summarization gate'),
  edit(AGENT, 'stop and report it rather than inventing a shortened prompt', 'write a short prompt instead', ['agent.scribe-overlay-duties'], 'agent: Scribe overlay allows a shortened prompt when the reference is missing'),
  edit(AGENT, 'Preserve its full Scribe prompt and follow-up sequence; override only the canonical `name` and configured `model` parameters', 'Replace its Scribe prompt with the template above', ['agent.after-agent'], 'agent: After Agent Work replaces the Scribe prompt'),
  { name: 'agent: a stale claude-haiku-4.5 example is reintroduced', expect: ['agent.no-stale-models'],
    edits: [{ file: AGENT, fn: (t) => `${t}\nExample: \`model: "claude-haiku-4.5"\`\n` }] },
  edit(AGENT, '| rai | RAI Reviewer | .squad/agents/rai/charter.md |', '| Rai | RAI Reviewer | .squad/agents/Rai/charter.md |', ['paths.canonical-folders'], 'agent: Rai roster entry uses the display-cased folder'),

  edit(REF, 'model: "{scribe_model}"', 'model: "claude-haiku-4.5"', ['reference.scribe-spawn'], 'reference: Scribe model hardcoded to claude-haiku-4.5 (the original defect)'),
  edit(REF, 'model: "{scribe_model}"', 'model: "claude-opus-5.5"', ['reference.scribe-spawn'], 'reference: Scribe model hardcoded to an unapproved model'),
  edit(REF, 'name: "scribe"', 'name: "Scribe"', ['reference.scribe-spawn'], 'reference: Scribe name is the display name'),
  edit(REF, ' `{scribe_model}` is `agentModelOverrides.scribe` from', ' `{scribe_model}` is chosen from', ['reference.scribe-spawn'], 'reference: no longer says the model comes from agentModelOverrides.scribe'),
  edit(REF, 'DECISIONS ARCHIVE [HARD GATE]', 'DECISIONS ARCHIVE', ['reference.scribe-duties', 'effective.scribe-spawn'], 'reference: archive size gate dropped'),
  edit(REF, '  SPAWN MANIFEST: {spawn_manifest}\n\n', '', ['reference.scribe-duties', 'effective.scribe-spawn'], 'reference: spawn manifest dropped'),
  edit(REF, '7. HEALTH REPORT:', '7. REPORT:', ['reference.scribe-duties', 'effective.scribe-spawn'], 'reference: health report dropped'),
  { name: 'reference: prompt shortened to inbox merge only', expect: ['reference.scribe-duties', 'effective.scribe-spawn'],
    edits: [{ file: REF, fn: (t) => {
      const a = t.indexOf('  3. ORCHESTRATION LOG');
      const b = t.indexOf('  Runtime state tools own persistence');
      if (a < 0 || b < 0 || b < a) throw new Error('shortening anchors not found');
      return t.slice(0, a) + t.slice(b);
    } }] },

  edit(RALPH, 'run `claude-sonnet-5.5`', 'run `claude-opus-5.5`', ['ralph.models-section'], 'ralph: instructions name the wrong model'),
  edit(RALPH, 'and do not omit the `model` parameter', 'or omit the model parameter', ['ralph.models-section'], 'ralph: instructions allow an omitted model'),

  edit(DEC, SUP_LABEL, '', ['decisions.superseded-labels'], 'decisions: Opus 5-only decision loses its Superseded label'),
  edit(DEC, '> **Superseded 2026-07-28**', '> **Note 2026-07-28**', ['decisions.superseded-labels'], 'decisions: 2026-07-15 decision loses its Superseded label'),
  edit(DEC, '— uses `claude-opus-5`.', '— uses the current policy.', ['decisions.history-preserved'], 'decisions: historical text is rewritten rather than labelled'),
  { name: 'decisions: the current model decision is deleted', expect: ['decisions.current-decision'],
    edits: [{ file: DEC, fn: (t) => {
      const a = t.indexOf('### 2026-10-09: Squad member models');
      const b = t.indexOf('### 2026-07-28: All Squad members');
      if (a < 0 || b < a) throw new Error('decision anchors not found');
      return t.slice(0, a) + t.slice(b);
    } }] },
];


function applyMutant(repo, m) {
  const files = { ...repo.files };
  for (const e of m.edits) {
    if (!(e.file in files)) throw new Error(`mutation target file missing: ${e.file}`);
    const next = e.fn(files[e.file]);
    if (next === files[e.file]) throw new Error(`mutation changed nothing in ${e.file}`);
    files[e.file] = next;
  }
  const members = [...repo.members];
  if (m.addMember) { files[charterPath(m.addMember.name)] = m.addMember.charter; members.push(m.addMember.name); members.sort(); }
  return { files, members };
}

function main(root) {
  const repo = loadRepo(root);
  const lines = [];
  const base = check(repo);
  for (const ch of CHECKS) {
    const p = base[ch.id];
    if (p.length === 0) lines.push(`ok - ${ch.id}: ${ch.desc}`);
    else for (const msg of p) lines.push(`FAIL: ${ch.id}: ${msg}`);
  }
  for (const m of MUTANTS) {
    let note;
    try {
      const got = Object.entries(check(applyMutant(repo, m))).filter(([, p]) => p.length > 0).map(([id]) => id);
      const missing = m.expect.filter((id) => !got.includes(id));
      note = missing.length === 0
        ? `ok - mutant rejected: ${m.name} -> ${m.expect.join(', ')}`
        : `FAIL: mutant NOT rejected by ${missing.join(', ')}: ${m.name} (failed: ${got.join(', ') || 'nothing'})`;
    } catch (e) {
      note = `FAIL: mutant could not be applied: ${m.name} (${e.message})`;
    }
    lines.push(note);
  }
  return lines;
}

module.exports = { main, check, loadRepo, applyMutant, MUTANTS, CHECKS, EXPECTED };

if (require.main === module) {
  const root = path.resolve(process.argv[2] || path.join(__dirname, '..', '..', '..'));
  for (const l of main(root)) console.log(l);
}
