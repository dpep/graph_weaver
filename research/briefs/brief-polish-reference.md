# Scribe B: the reference

Read /tmp/claude/graph_weaver/brief-polish-common.md. You own the reference a working developer reaches for by topic: **docs/scalars.md, docs/errors.md, docs/i18n.md, docs/logging.md, docs/transports.md, docs/federation.md, docs/real_world.md, docs/upgrading.md**.

Specific asks:
- federation.md is 1107 lines and has a role signpost at the top; use it as the structure. A client team reads maybe a fifth of it. Order: what you need as a client (tag, one spec, the refusal table), then as a subgraph author, then as the supergraph owner, then the CI section, then Details. The refusal table stays complete (a spec requires every category label to appear) but its prose shrinks. The parity paragraphs against the JS gateway and the Rust router collapse to one.
- scalars.md (541) and errors.md (593): each leads with the three cases 90% of apps hit — a stdlib scalar registered by class, a Money object scalar, a mapped enum; a wrong-typed variable, a server validation error, a transport failure — then the reference tables. "What no check can see" stays, shorter.
- logging.md: the payload contract table and the two tracing snippets are the substance; the channel table (13 rows) stays but as a table with one-line policies, no narration. The process-global paragraph stays as a table.
- transports.md: the request body, the two transports, retries, proxies — reference order. The Faraday-vs-bundled explanation is longer than the decision.
- i18n.md and real_world.md: trim to current behavior.
- upgrading.md (677): history by nature, but nobody is on 0.5.1 or 0.6.0 anymore. Keep "Upgrading from 0.7.0" and "Upgrading from 0.6.1" as checklists; delete the older sections (git has them) and say at the top that older paths are in the tag history. Every remaining row must still be true.

Report as the common brief says.
