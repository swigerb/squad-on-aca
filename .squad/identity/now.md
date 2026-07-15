---
updated_at: 2026-07-15T15:15:00.000Z
focus_area: Squad on ACA remote runner
active_issues: []
---

# What We're Focused On

Maintaining Squad on Azure Container Apps as a thin remote runner for Brady Gaster's Squad. The repo contains ACA deployment scripts, the `squad-aca` control-plane wrapper, a Copilot agent template, Ralph scheduling, session jobs, and Aspire telemetry.

Current priorities:

- Keep `squad-aca` focused on remote execution instead of reimplementing Squad.
- Preserve repo-local `.squad/` history so future agents understand design decisions and operational context.
- Validate changes through PowerShell parser checks, worker shell syntax checks, and targeted ACA smoke tests when cloud behavior changes.
