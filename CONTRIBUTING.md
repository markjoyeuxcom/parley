# Contributing

Parley is open source under the Apache License 2.0. Bug reports, reproducible
compatibility findings, focused design discussion and well-scoped code changes
are welcome.

Bug reports, reproducible compatibility findings and focused design discussion
are welcome. Please search existing issues first and include the Parley build,
macOS version, vendor CLI version and the smallest safe reproduction. Remove
credentials, private repository content and terminal transcripts before
posting. Report security concerns through [SECURITY.md](SECURITY.md), never a
public issue.

Before starting a substantial change, open an issue so its scope can be agreed.
Keep pull requests focused, preserve the product invariants and include tests
for non-trivial behavior. Under section 5 of the Apache License, contributions
intentionally submitted for inclusion are provided under Apache License 2.0
unless explicitly marked otherwise.

## Development checks

Read [AGENTS.md](AGENTS.md) before changing product behavior. In particular,
preserve subscription CLIs, native interactive sessions, explicit cross-vendor
targeting, visible human control, local-only coordination and the mandatory
agent process boundary.

Run the deterministic gates before proposing a change:

```bash
npm run scan:public
npm test
npm run build
```

These commands must not launch a vendor CLI or spend subscription quota. Live
vendor conformance is a separate, explicit maintainer operation.
