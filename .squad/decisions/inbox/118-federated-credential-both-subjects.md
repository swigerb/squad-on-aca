# Issue #118: Federated Credential Subject Formats

## Status: Ready for Implementation

## Summary

GitHub Actions sends different OIDC subject formats depending on the event type:
- **Classic (push/schedule):** `repo:<owner>/<repo>:ref:refs/heads/main`
- **ID-based (issues):** `repo:<owner>@<ownerId>/<repo>@<repoId>:ref:refs/heads/main`

With only the classic credential, `azure/login` fails with **AADSTS700213** when triggered from an `issues` event. Both credentials must be configured.

## Verified

- `swigerb/arcade-hall-of-fame` on 2026-09-30
- Issue triggered with ID-based subject; login failed with classic credential only
- Login succeeded after adding ID-based credential

## Decision

No script in this repository creates federated credentials. This is a manual operation documented in:
- `docs/actions-trigger.md` § GitHub OIDC Subject Format (with `az ad app federated-credential create` examples)
- Referenced in this issue: issue #117 (externalized state)

## Action Items

None — this is documentation-only. The Azure deployment automation does not manage federated credentials; they are set up once during initial Azure app registration and maintained manually or through a separate identity infrastructure-as-code process (Bicep/Terraform).

## Related

- Upstream: [bradygaster/squad#2140](https://github.com/bradygaster/squad/issues/2140) — docs: link community squad-on-aca and squad-hub
- Same repo: [#117](https://github.com/swigerb/squad-on-aca/issues/117) — detect externalized state before dispatch
- Same repo: [#112](https://github.com/swigerb/squad-on-aca/issues/112) — squad injects --yolo into watch/loop sessions
