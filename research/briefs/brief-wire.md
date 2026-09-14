# Brief: `graphql: :wire` — the local router served a network hop away

Read /tmp/claude/graph_weaver/brief-common.md first (toolchain, gate, commit trailers, method). Baseline main is c0c3684 (1167 examples, surface 442 names). Work in your worktree branch; don't push.

## Who you are for this task

You are the engineer who has to explain this tag to a federated team tomorrow, in one sentence, and whose own transport carries APM headers they need to see reach the server. Fewer concepts beats more capability. If a change makes the rule longer to state, it is the wrong change. If you conclude any part of this is worse than the status quo, say so and stop.

## The gap (from a user, verbatim in spirit)

`Testing::Router` sits in the client slot: it plans and stitches a cross-subgraph query in-process against the composed supergraph over real resolvers or fakes, and hands back a result hash *above the wire*. So it never exercises the transport: no request serialization, no wire response, no `from_h` over real bytes. An adopter who keeps their own transport (for APM tracing, caller tags, mTLS) most needs to test exactly that seam. A hand-rolled WebMock stub keeps the transport in the loop but has no planner, so it can only answer what one subgraph resolves. Cassettes replay wire bytes but don't plan.

## What to build

A fourth tag, `graphql: :wire`, and its helper `graphql_wire(fake: nil)` (same options as `graphql_router`). The rule, which goes in the tag table at the top of `lib/graph_weaver/rspec.rb` and in docs:

```
:wire   your resolvers, served at config.endpoint so your real transport runs
```

What sits behind the wire is decided the way the other tags already decide: the router when the dump is a supergraph, the in-process schema class otherwise. One rule, no `:router` vs `:in_process` fork to explain again. The client for the example is the app's real one (`GraphWeaver.client`, or whatever the generated module's default client is), left in place — that is the whole point.

Pieces, smallest first, each its own commit:

1. **A Rack face.** `GraphWeaver::Testing::Router#call(env)` (and the same for the in-process case — pick the simplest home; a tiny `Testing::Endpoint`/`Wire` wrapper around any object satisfying the client contract is probably right, so one Rack app serves either). Parse the JSON body (`query`, `variables`, `operationName`), run `execute`, return `[200, {"content-type" => "application/json"}, [JSON.generate(result)]]`. Parse and validation failures already come back as GraphQL `errors` from the router — they go over the wire exactly that way, with 200, which is how a real router and graphql-ruby answer. A body that isn't JSON or isn't a POST gets a 400 with a message that names what it got. Keep it ~30 lines. Consult the routers' `execute` and `Internal::Wire` before inventing anything.
2. **Context from headers.** Today `Router#context` is a hash handed to every subgraph. Allow a proc: `context: ->(headers) { { current_user: User.find_by(token: headers["Authorization"]) } }`, called per request with the Rack request headers (normalized: a Hash keyed by the header name as sent, e.g. `"Authorization"`, `"X-Caller"`). This is the identity-propagation seam. Keep the hash form working. Same for the in-process case if it's cheap; if it isn't, say so.
3. **The tag.** Add `:wire` to `CLIENT_MODES` and the `when` table in `rspec.rb`. On claim: require WebMock to be loaded (`defined?(WebMock)`), refuse otherwise naming the gem and the one line to add; resolve the endpoint URL from the client (`Transport::HTTP#url` / Faraday connection url — look at what they expose; add a reader if one is missing and put it on the surface list); refuse when the client is not an HTTP transport, naming its class and saying `:wire` has nothing to serve then; `stub_request(:post, url).to_rack(app)` (WebMock's native `to_rack`), and remove the stub after the example (WebMock's `remove_request_stub`, or reset — check what `require "graph_weaver/rspec"` should and should not do to a suite that already uses WebMock: never `WebMock.disable_net_connect!` on their behalf, never `reset!` their other stubs). `rspec --tag graphql:wire` must work like the others.
4. **Docs.** A section in `docs/testing.md` after "A federated graph — `graphql: :router`", titled ``## Over the wire — `graphql: :wire` ``, and a paragraph in `docs/federation.md` under "The local router" pointing to it. Say what it exercises (request serialization, real planning, response deserialization, header-driven context), what it doesn't (the ceiling is the same Unplannable categories; anything refused falls back to a cassette or a live gateway), that WebMock is the dependency and why (it hooks Net::HTTP, Faraday and HTTPX, which is every transport we document), and that the Rack app is mountable by anyone who has something else. Write it the way the rest of that file reads. Add the README's testing paragraph one clause if it earns it.
5. **CHANGELOG** under `## Unreleased`, one entry, saying what a user can now do. **`spec/support/public_surface.txt`** gets every new public name in the same commit as the name. **Gemfile/gemspec**: `webmock` as a development dependency; it is optional at runtime like faker and factory_bot.

## The proof that matters — write this spec first

The closed-loop trap: if the response were re-encoded through the client's own `serialize:` registrations, the round trip would pass even when that codec disagrees with what a real server writes. The router's result hash is already assembled from subgraph execution results, never through client codecs, so `JSON.generate` of it is independent wire bytes. **Prove it stays that way**: register a scalar whose client `serialize:` writes something the server would not (e.g. a `Money` that serializes as `"$12.50"` while the subgraph's scalar emits `"12.50"`), run a query through `:wire`, and assert the bytes the transport received are the server's spelling, and that `from_h` cast them. Then a second spec where the client's *cast* is wrong for what the server writes, and the example fails through the wire naming the field — the double must surface a real disagreement, not hide it.

Other specs, each watched failing first:
- a cross-subgraph query through `:wire` returns the same data `:router` returns for the same query (use the fixture supergraph the router parity spec uses), and WebMock saw exactly one POST at the endpoint with `query`/`variables`/`operationName` in the body
- a header set on the app's transport reaches resolver context through the `context:` proc
- refusals: no WebMock; client not an HTTP transport; `fake: { seed: }` refused like `graphql_router`
- the stub is gone after the example (a following example without the tag hits no stub)
- the Rack app itself: bad JSON → 400 naming it; a GraphQL parse error → 200 with `errors`

Run `INTEGRATION=1 bundle exec rspec spec/integration/router_parity_spec.rb` if you touch router.rb at all (needs node; if it can't run in your shell, say so).

## Traps

- `Transport::HTTP` holds a connection pool; WebMock hooks Net::HTTP underneath it, so pooled connections are fine, but check the transport's `Accept`/`Content-Type` and that WebMock's `to_rack` sees the body as a String.
- `GraphWeaver.client` is process-global; the rspec integration already swaps it per example and restores. `:wire` must NOT swap it — leaving the real client in place is the feature — but must still restore anything else it touched.
- `spec/public_surface_spec.rb` fails on any new public constant/method not in the list; `bin/public-surface` regenerates the list — diff it, don't blindly accept.
- `private_constant` must sit at class-body level, not inside a method.
- The rspec integration is `lib/graph_weaver/rspec.rb` + `lib/graph_weaver/testing.rb` (`CLIENT_MODES`, `client_for`); the reference spec is `spec/rspec_spec.rb`.

## Ownership

You own: `lib/graph_weaver/testing/**`, `lib/graph_weaver/testing.rb`, `lib/graph_weaver/rspec.rb`, `lib/graph_weaver/transport/*.rb` (readers only), `spec/**` for the specs above, `docs/testing.md`, `docs/federation.md`, `README.md` (one clause at most), `CHANGELOG.md`, `Gemfile`, `Gemfile.lock`, `graph_weaver.gemspec`, `spec/support/public_surface.txt`. Nobody else is running. Report anything you'd change outside that list rather than changing it.

## Report

Shas per commit; the closed-loop proof spec's failure output when the guard is removed; the exact rule sentence you ended up with; the refusal messages verbatim; what you left out and why; `git status` clean.
