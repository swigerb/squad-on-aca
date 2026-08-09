# Job egress, assessed

Sessions run with unrestricted outbound network access. This is the third of
three hardening items raised by the launcher assessment, and it is the one that
is **not being implemented**. The reasoning is recorded here because "we thought
about it" is worth nothing without the argument.

## What unrestricted egress actually risks

A session runs an agent executing a prompt, and a prompt is attacker-influenceable
input: an issue body, a comment, a file in a checked-out repository. If that
agent is induced to do something hostile, open egress is how the results leave.

Concretely, what is in the container worth taking:

| Secret | Still there after the identity work? | Would egress control help? |
|---|---|---|
| Azure managed identity | **No** — removed from every non-Ralph mode | n/a |
| GitHub token | Yes | No — GitHub is the destination it legitimately needs |
| Copilot GitHub token | Yes | No — same |
| Hub device token | Yes | No — the hub is a destination it needs |
| The checked-out repository | Yes | Only against destinations that are not GitHub |

That table is the whole argument. After
[the identity change](../scripts/deploy.ps1), the credential that reached
*Azure* is gone from the session entirely. Every remaining secret is one whose
legitimate destination is the same place an exfiltration would go. An egress
policy that permits GitHub — and it must, or nothing works — permits the
exfiltration of every credential still in the container.

What it would still buy: it stops a *novel* destination. A hostile prompt that
POSTs the repository to an attacker's host is blocked. That is a real gain, and
it is the reason this is a judgement call rather than an obvious no.

## What it would cost

Container Apps egress can only be restricted by placing the environment in a
VNet and putting something in front of the subnet. NSGs filter on IP address and
service tag, not on hostname — and the destinations that must be allowed
(`github.com`, `api.github.com`, the npm registry, the Copilot endpoints, the
hub) are CDN-fronted names whose addresses move. So an NSG cannot express the
policy; it takes Azure Firewall, which does FQDN rules.

Retail price, East US, queried rather than remembered:

| SKU | Per hour | Per month |
|---|---|---|
| Basic | $0.40 | ~$292 |
| Standard | $1.25 | ~$912 |
| Premium | $1.75 | ~$1,277 |

Plus per-gigabyte data processing on top. Against this environment's $1,500
monthly budget, the SKU that does what is needed consumes about 60% of it,
permanently, to block one class of destination while leaving every credential
reachable at its legitimate one.

There is also a migration cost that is easy to miss: **a Container Apps
environment cannot be moved into a VNet after it is created.** Adopting this
means recreating the environment, the jobs, and their secrets.

## The decision

Not implemented. The control is disproportionate to what it protects **given
that the Azure identity is no longer in the session** — which is the change that
altered this calculation, and which cost nothing.

This is a live judgement, not a permanent one. It should be revisited if any of
these become true:

- The session gains a credential whose legitimate destination is **not** also a
  plausible exfiltration destination.
- Sessions begin handling data whose disclosure matters more than this
  repository's source.
- The environment stops being a demo with a fixed monthly budget.

## If you do want it

The path, so this is a decision and not a dead end:

1. Create a VNet with a subnet of at least `/23`, delegated to
   `Microsoft.App/environments`.
2. Create the managed environment with
   `--infrastructure-subnet-resource-id <subnet id>`. This cannot be done to an
   existing environment.
3. Deploy Azure Firewall with a route table sending `0.0.0.0/0` to it.
4. Allow, as FQDN rules: `github.com`, `api.github.com`, `codeload.github.com`,
   `objects.githubusercontent.com`, `*.actions.githubusercontent.com`, the npm
   registry, the Copilot API endpoints, your Squad Hub hostname, and
   `*.azurecr.io` for image pulls.
5. Expect to add to that list. The failure mode is a session that hangs rather
   than one that says what it could not reach, so add firewall logging before
   you need it.

The order matters: step 4's list is the part that decays, and a stale allow-list
presents as an intermittently broken agent.
