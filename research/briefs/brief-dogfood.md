# Brief: dogfood the 0.7.0 testing story as a new adopter

Read /tmp/claude/graph_weaver/brief-common.md for toolchain and method (you will not commit to the gem; the gate section doesn't apply to you). Baseline: main at the sha in your launch message. **Read only the docs a user would read**: README, docs/getting_started.md, docs/testing.md, docs/federation.md, docs/scalars.md, docs/transports.md, docs/cassettes.md, CHANGELOG `v0.7.0`. Do not read lib/ to find out how something works until after you have recorded what the docs led you to expect. That gap is the product.

## Who you are

A senior Rails engineer at a company with two GraphQL services and a REST API, adopting graph_weaver this week. You are not here to fix the gem. You are here to use it exactly as documented, in a real app, and to report every place it surprised you, refused you unclearly, disagreed with its docs, or made you read source. Your deliverable is a ranked report with repros. Fixing anything in the gem is out of scope — if a bug blocks you, work around it in the app, note the workaround, and keep going.

## The app

Scratch Rails app **outside the repo**, at /tmp/claude/graph_weaver/dogfood-rails (delete and recreate if present), Gemfile pointing at the checkout with `path:`. Ruby via `~/.rvm/wrappers/ruby-3.4.9/`. Build it from the docs' install path (`rails g graph_weaver:install` if the docs say so), then grow it to:

1. **Two GraphQL graphs, two servers.** Declare both with the block DSL. One (`:catalog`) is an in-process graphql-ruby schema with real resolvers that read `context[:current_user]`, its client an HTTP transport at `https://catalog.test/graphql` with a caller-tag header (`X-Caller: web`) set by a Faraday middleware the app writes. The other (`:accounts`) is a federated supergraph composed from two subgraph SDLs (write small ones; `bin/federation-diff` in the repo shows how the fixture supergraph is composed if you need a reference — or hand-write the supergraph SDL with `@join__*` directives following spec/support/federation/supergraph.graphql), client at `https://accounts.test/graphql`, one subgraph served in-process and one faked. Each graph gets its own queries, output, namespace, and a scalar registration (`Money` → BigDecimal on catalog; a `Date` field on accounts). Generate, verify, `RAILS_ENV=production` boot, `rails zeitwerk:check`.
2. **A REST API beside them.** A `Weather` client using its own Faraday connection to `https://weather.test/v1/now`, and one plain `Net::HTTP.get` somewhere. Not GraphQL, not graph_weaver.
3. **A spec suite** (`require "graph_weaver/rspec"`, `require "webmock/rspec"`, factory_bot) with at least one example per cell of this grid, and a note for any cell that can't be filled:

   | | catalog module | accounts module | REST call |
   |---|---|---|---|
   | `:live` | reaches catalog.test only (WebMock stub the suite wrote) | reaches accounts.test only | reaches weather.test via the suite's own stub |
   | `:fake` | pins + a FactoryBot object; `Money` is a BigDecimal | fabricated Date is a Date | untouched |
   | `:in_process` | `graphql_context(current_user:)` reaches the resolver | refuses (no live class) — record the message | untouched |
   | `:router` | refuses or serves — record which and why | faked subgraph pinned via `config.router = { fake: }` | untouched |
   | `:wire` | request carries `X-Caller` (assert with WebMock); `context:` proc reads it | planned across subgraphs, response deserialized | untouched, and a suite stub for weather.test still stands after the example |
   | cassette | records catalog, does NOT capture the REST call | — | VCR cassette for weather.test does NOT capture a `:wire` request |

   Also: a module bound to its own client under `:fake` (it must be reached); `rspec --tag graphql:wire`; `--seed 4242` reproducing a fake; a typo'd pin; a typo in the graph block; `graphql: :none` and `graphql: false` (both must refuse naming `:live`); `graphql_context` under `:fake` (must refuse); `require "webmock"` without `/rspec` under `:wire` (what happens?); `config.default_mode = :fake` with one `graphql: :live` example stepping out.

4. **Non-GraphQL traffic under every mode must be untouched**: the point of the REST column. Assert the suite's own WebMock stubs survive each mode, that `:wire` never calls `WebMock.disable_net_connect!` or `reset!` (check `WebMock::StubRegistry.instance.request_stubs` before and after), and that with WebMock's net connect *allowed* a `:live` REST call would go out (stub it, but assert nothing graph_weaver did changed the allow state).

## Report format

Ranked, worst first. For each finding: **what you expected (quote the doc line)**, **what happened (exact output)**, **repro (file + command)**, and one line on what a fix would look like from a user's point of view (not a code change). Categories: bug / refusal that didn't say what to do / docs disagree with behavior / made me read source / paper cut. End with: the three things that felt best, and the sentence you'd put at the top of docs/testing.md if you could change one thing. Keep the app on disk; name its path.

Do not fix the gem. Do not commit in the repo. If a doc sample doesn't run, that is a finding, not something to quietly correct.
