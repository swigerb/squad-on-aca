# Squad Decisions

## Active Decisions

### 2026-07-15: Route development through Squad with explicit model policy

**Decision:** Development work in this repo should route through Squad. The Lead handles planning, sequencing, and coordination using `gpt-5.6-luna`. Code-writing work routes to `engineer` using `claude-opus-4.8`.

**Why:** Squad on ACA is now a public remote-runner project with enough moving parts that repo history, architecture decisions, implementation handoffs, and validation evidence should be maintained by the Squad itself.

**Implications:**

- The coordinator should avoid inline implementation work unless the user explicitly asks for local-only help.
- Implementation, tests, scripts, Dockerfiles, and refactoring route to `engineer`.
- Review work still routes to `reviewer`, and security-sensitive changes route to `security`.

### 2026-07-16: SandboxGroups feasibility remains Sprint-0-only

**By:** lead

**What:** Recorded a conditional GO for Sprints 0-2 only, with SandboxGroups runtime work beyond Sprint 2 blocked on Sprint 0 evidence gaps around API consistency, region/quota visibility, delete/recovery semantics, and identity isolation.

**Why:** Official ACA Sandbox docs confirm preview status and useful lifecycle/networking primitives, but the published API story is still inconsistent and several validation gates remain UNKNOWN.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
