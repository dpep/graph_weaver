# Alternatives

Why another Ruby GraphQL client, what else exists, and where each one wins.
Read it before adopting — including the last section, which is where this gem
loses.

*Figures checked 2026-09-12. Every claim carries its source in an HTML comment
beside it; a maintainer re-checking this page should follow those, not trust the
prose.*

## Why another one

Ruby has **one** real GraphQL client — GitHub's `graphql-client` — and the two
maintained alternatives are wrappers around it.<!-- graphlient.gemspec deps: faraday ~>2.0, graphql-client; artemis.gemspec deps include graphql-client >= 0.13.0 — https://rubygems.org/api/v1/gems/graphlient.json, https://rubygems.org/api/v1/gems/artemis.json -->
All three share one design: the result object is built at runtime by
metaprogramming against an introspected schema, so a field you misspelled is a
`NoMethodError` on a production request rather than a red build.<!-- graphql-client lib/graphql/client/schema/object_type.rb:231-266 — method_missing raises UnimplementedFieldError/UnfetchedFieldError at runtime; a camelCase typo re-raises plain NoMethodError at :248-250 -->
And none of them ship anything to test with.<!-- graphql-client: no fakes/stubs/fixtures anywhere in lib/, no testing guide among its 14 guides — https://github.com/github-community-projects/graphql-client/tree/master/guides -->

GraphWeaver makes a different structural bet: **the schema is known at
generation time**, so result types can be real files on disk that `srb tc`
reads, and the same knowledge that makes them exact is what lets the gem
fabricate them for your tests. That second half is the part every code generator
in every language skips — and it is the reason precise types usually feel
expensive.

The honest counter: if your app doesn't use Sorbet, most of that value
evaporates, and [graphlient](#graphlient) is the better answer.

This idea was tried once before. `yogurt` generated Sorbet types from GraphQL
documents, shipped two versions 70 minutes apart in November 2020, and stopped —
its own README concedes it lacked named fragments and that the author "probably
got a lot of the decisions wrong".<!-- https://raw.githubusercontent.com/theorygeek/yogurt/master/README.md ; versions 0.1.1 16:52 and 0.2.0 18:02 on 2020-11-26 — https://rubygems.org/api/v1/versions/yogurt.json ; last real commit 29ef902 2020-11-26 -->
So the thesis is unproven, not proven wrong.

## The table

`graphql-ruby` isn't a column because it isn't a client — see
[graphql-ruby alone](#graphql-ruby-alone). "Hand-rolled" is `Net::HTTP` or
Faraday plus a query string and `response["data"]["..."]`, which is what most
vendor SDKs actually do.

| | **graph_weaver** | **graphql-client** | **graphlient** | **artemis** | **hand-rolled** |
|---|---|---|---|---|---|
| **Query lives in** | a `.graphql` file, one operation each<!-- README.md; DECISIONS.md "Directories organize queries" --> | a heredoc assigned to a Ruby constant (enforced)<!-- lib/graphql/client.rb:345-347 raises DynamicQueryError when definition.name is nil --> | a heredoc, a Ruby block DSL, or `parse`<!-- https://github.com/ashkan18/graphlient#usage ; lib/graphlient/query/serializer.rb --> | a `.graphql` file under `app/operations`<!-- https://github.com/yuki24/artemis#the-convention --> | a string in your code |
| **A result is** | a checked-in nested `T::Struct`<!-- README.md; lib/graph_weaver/result_struct.rb --> | an anonymous class, readers per selected field<!-- lib/graphql/client/schema/object_type.rb:10-22, 56-60 --> | the same (it returns graphql-client's `Response`)<!-- lib/graphlient/client.rb:41 --> | the same<!-- artemis lib/artemis/client.rb #execute delegates to client.query --> | a `Hash` |
| **A typo is caught** | at `srb tc`, before you run it | at runtime, on the request<!-- object_type.rb:243-266 --> | at runtime | at runtime | never |
| **Schema needed** | at codegen time: live class, introspection dump, SDL, or supergraph<!-- README.md; lib/graph_weaver/schema_loader.rb --> | at boot: dump recommended; SDL support merged but unreleased<!-- README.md:34-42; https://github.com/github-community-projects/graphql-client/pull/60 merged 2025-12-06, not in 0.26.0 --> | at runtime: introspects over HTTP lazily unless you pass `schema_path`<!-- lib/graphlient/schema.rb:16; lib/graphlient/client.rb:76 --> | a checked-in dump per service<!-- lib/artemis/railtie.rb schema_path vendor/graphql/schema/<service>.json --> | none |
| **Codegen** | yes — you check the Ruby in | none, all runtime metaprogramming<!-- lib/graphql/client/schema.rb:68-81 --> | none | none | none |
| **Typing** | Sorbet `# typed: strict`, per query<!-- README.md --> | none shipped; Tapioca PR stalled since 2024-11, and schema-wide not per-operation<!-- https://github.com/github-community-projects/graphql-client/pull/7 — open, mergeable_state blocked, last touched 2024-11-07 --> | none<!-- no .rbs/.rbi/sig in the gem --> | none | none |
| **Testing** | schema-driven fakes, pinning, failure simulation, cassettes<!-- docs/testing.md; lib/graph_weaver/rspec.rb; lib/graph_weaver/testing/ --> | nothing ships<!-- no stub/fake/fixture in lib/ --> | documented WebMock patterns only<!-- https://github.com/ashkan18/graphlient#testing-with-graphlient-and-rspec --> | `stub_graphql` + YAML fixtures, unvalidated against the schema<!-- lib/artemis/test_helper.rb; lib/artemis/adapters/test_adapter.rb returns fixtures verbatim --> | WebMock |
| **Federation** | plans and runs a supergraph in-process<!-- docs/federation.md; lib/graph_weaver/federation.rb --> | none; open crash against federated routers<!-- https://github.com/github-community-projects/graphql-client/issues/78 open since 2026-01-15 --> | none | none | none |
| **Errors** | typed envelope keeping partial data, hierarchy by failure site<!-- docs/errors.md; lib/graph_weaver/errors.rb --> | raw hashes; HTTP errors become a fake `errors` array<!-- lib/graphql/client/http.rb:80-85; https://github.com/github-community-projects/graphql-client/issues/67 --> | raises a real class hierarchy on every failure<!-- lib/graphlient/errors/ --> | thin hierarchy, mostly never raised<!-- lib/artemis/exceptions.rb — GraphQLError/GraphQLServerError defined, never raised --> | yours to write |
| **Transport** | `Net::HTTP` (pooled) or Faraday, plus `Retry`<!-- docs/transports.md; lib/graph_weaver/transport/ --> | stock adapter self-described as trivial<!-- lib/graphql/client/http.rb:17-19 "Production applications should consider implementing their own network adapter" --> | Faraday 2.x, full middleware access<!-- lib/graphlient/adapters/http/faraday_adapter.rb:36-48 --> | four adapters, no middleware layer<!-- lib/artemis/adapters.rb; https://github.com/yuki24/artemis/issues/57 open since 2019 --> | whatever you picked |
| **Rails** | generator, railtie, reload-on-edit, rake lifecycle<!-- lib/generators/graph_weaver/install_generator.rb; lib/graph_weaver/railtie.rb; lib/graph_weaver/tasks.rb --> | opt-in railtie, no generators; docs call the boot order "a mess"<!-- lib/graphql/client/railtie.rb:34-37 TODO; https://github.com/github-community-projects/graphql-client/blob/master/guides/rails-configuration.md --> | none | the whole pitch: generators, config, callbacks<!-- lib/artemis/railtie.rb; lib/generators/artemis/ --> | n/a |
| **Last release** | v0.7.0, 2026-09-12 | v0.26.0, 2025-05-29<!-- https://rubygems.org/api/v1/gems/graphql-client.json --> | v0.9.0, 2026-08-02<!-- https://rubygems.org/api/v1/gems/graphlient.json --> | v1.1.0, 2024-08-16<!-- https://rubygems.org/api/v1/gems/artemis.json --> | n/a |
| **Downloads** | 7.5k<!-- 7,478 — https://rubygems.org/api/v1/gems/graph_weaver.json --> | 94M<!-- 94,408,657 --> | 32M<!-- 32,287,626 --> | 430k<!-- 425,737 --> | n/a |

## graphql-client

**Where it shines.** It is GitHub's, it has a decade of production use, and 94M
downloads means someone has hit your problem before you. The duck-typed
`execute:` slot is genuinely good design — point it at a graphql-ruby schema and
queries run in-process with no socket.<!-- https://github.com/github-community-projects/graphql-client/blob/master/guides/local-queries.md -->
It ships two RuboCop cops, including `GraphQL/Overfetch`, which nobody else
has.<!-- lib/rubocop/cop/graphql/ in the unpacked gem -->

**Where it gaps.** Custom scalars don't deserialize when the schema came from a
dump — the path its own README recommends — and the suggested workaround is
monkey-patching `GraphQL::Schema::BUILT_IN_TYPES`; the issue has been open since
February 2024.<!-- https://github.com/github-community-projects/graphql-client/issues/17 --> Network
errors are discarded: a 403 surfaces as `KeyError: key not found: "data"`.<!-- https://github.com/github-community-projects/graphql-client/issues/67 open since 2025-04-11 -->
Fragments enforce Relay-style data masking, so a field another fragment fetched
raises even though the value is right there in the response — and users file
issues asking for plain reuse.<!-- object_type.rb:161-168, 261-264; https://github.com/github-community-projects/graphql-client/issues/76 -->
Its CI matrix stops at Ruby 3.2 and Rails 7.1.<!-- https://github.com/github-community-projects/graphql-client/blob/master/.github/workflows/ci.yml -->
Nine issues and seven PRs are open, several waiting on a maintainer to approve a
CI run.<!-- gh api search/issues, repo:github-community-projects/graphql-client, 2026-09-12 -->

**Pick it over graph_weaver when** institutional safety outweighs static types,
or when you need data masking as a feature rather than a constraint.

## graphlient

**Where it shines.** Quietly the healthiest Ruby client: 0.9.0 shipped
2026-08-02, more recently than graphql-client itself, adding DSL fragments,
directives and scalar registration.<!-- https://github.com/ashkan18/graphlient/blob/master/CHANGELOG.md -->
It fixes the failure everyone hits with its substrate — it raises a real,
rescuable error hierarchy instead of handing you a half-populated response.<!-- lib/graphlient/errors/ --> Faraday
means your existing middleware just works.

**Where it gaps.** It is a wrapper, so it inherits graphql-client's result
model, its fragment isolation, and its untyped everything — its own README
offers `to_query_string` as "the escape hatch if you want to replace the
graphql-client dependency entirely".<!-- https://github.com/ashkan18/graphlient#readme, 0.9.0 -->
Read and write timeouts default to nil, i.e. none.<!-- README config table; lib/graphlient/adapters/http/adapter.rb:33-40 -->
No Rails integration, no field aliasing, and 18 open issues, the most-reacted
dating to 2017.<!-- https://github.com/ashkan18/graphlient/issues/10 ; gh api repos/ashkan18/graphlient -->

**Pick it over graph_weaver when** you want to call an API without thinking
about it. For that job graph_weaver is over-engineered, and this is the right
answer.

## artemis

**Where it shines.** The best Rails story of the three: `rails g
artemis:install` writes the client, the config and the schema dump; `.graphql`
files map to methods by convention; `before_execute`/`after_execute` are real
hooks; and it has the only shipped test harness among the alternatives —
`stub_graphql(Artsy, :artist).to_return(:yayoi_kusama)` against YAML
fixtures.<!-- lib/artemis/test_helper.rb; https://github.com/yuki24/artemis#testing -->
It also batches, via `Client.multiplex`.<!-- lib/artemis/client.rb .multiplex/MultiplexQueue -->

**Where it gaps.** Fixtures are returned verbatim — nothing checks them against
the schema or the query's selection set, so a fixture can drift from reality and
stay green.<!-- lib/artemis/adapters/test_adapter.rb#execute -->
Its reloader and production preload are both gated on *not* using Zeitwerk,
which every Rails 7+ app does, so the README's preloading claim no longer
applies.<!-- lib/artemis/railtie.rb — graphql.client.set_reloader and graphql.client.preload both gated on not_on_zeitwerk -->
Last release August 2024; Rails 8 support exists only on `main`, and there have
been no commits since December 2025.<!-- gh api repos/yuki24/artemis/compare/v1.1.0...main ; last commit 8b3d76a 2025-12-04 -->

**Pick it over graph_weaver when** you want convention-over-configuration Rails
ergonomics and don't need types.

## graphql-ruby alone

`graphql-ruby` is a **server** library and ships no HTTP client at all — its
only three runtime dependencies are `base64`, `fiber-storage` and `logger`, and
the only `Net::HTTP` call in the gem fetches a checksum for graphql-pro.<!-- gem spec graphql-2.6.10.gem dependencies; lib/graphql/rake_task/validate.rb:38-44 -->
The thing called "client" in its docs is
[JavaScript](https://graphql-ruby.org/javascript_client/overview).

What it does give a client author is the substrate everyone here builds on:
[`GraphQL.parse`](https://graphql-ruby.org/api-doc/2.6.10/GraphQL.html),
[`GraphQL::Schema.from_definition`](https://graphql-ruby.org/schema/sdl.html)
and `from_introspection`, and `GraphQL::StaticValidation::Validator` for
checking a document against a schema.<!-- lib/graphql.rb:49; lib/graphql/schema.rb:105,115; lib/graphql/static_validation/validator.rb:11-18 -->
GraphWeaver uses exactly these — it is a code generator on top of graphql-ruby,
not a reimplementation of it.

**Subscriptions are server-side only** across the whole ecosystem: graphql-ruby
delivers them over ActionCable and every documented consumer is
JavaScript,<!-- https://graphql-ruby.org/subscriptions/action_cable_implementation — "See client usage for: Apollo Client, Relay Modern, GraphiQL" -->
and no Ruby gem consumes GraphQL subscriptions over websockets.<!-- rubygems search graphql+websocket, graphql-ws, subscriptions-transport-ws all return 0 results, 2026-09-12 -->
Nobody in Ruby has this, GraphWeaver included.

## Hand-rolled HTTP — the real incumbent

Most Ruby code talking to a GraphQL API isn't using a client library. It POSTs a
string and reads a hash, and that includes the vendors' own SDKs.

Shopify is the sharpest example. `shopify_api` v10 **removed** graphql-client,
saying so in its breaking-changes doc — "There is no need to dump the schema to
a local JSON file before using it anymore" — and the migration example replaces
`result.data.shop.name` with `response.body["data"]["shop"]["name"]`.<!-- https://github.com/Shopify/shopify-api-ruby/blob/main/BREAKING_CHANGES_FOR_V10.md:3,115,140-159 -->
The current gemspec declares `httparty`, `oj` and `sorbet-runtime` and no
`graphql` at all.<!-- https://github.com/Shopify/shopify-api-ruby/blob/main/shopify_api.gemspec:35-46 -->
The gem is `# typed: strict` throughout — and the GraphQL payload is typed
`T.any(T::Hash[String, T.untyped], String, OpenStruct)`.<!-- https://github.com/Shopify/shopify-api-ruby/blob/main/lib/shopify_api/clients/http_response.rb#L15-L16 -->
A Sorbet shop, shipping a Sorbet-typed SDK, with untyped GraphQL. Braintree does
the same thing without the Sorbet.<!-- https://github.com/braintree/braintree_ruby/blob/master/lib/braintree/graphql_client.rb#L13-L26 -->

**Where it shines.** Zero dependencies, zero build step, nothing to learn, and
it never gets in your way. For three queries against a stable API this is
genuinely the correct engineering call.

**Where it gaps.** Nothing validates the query, nothing knows the schema
changed, every response is `T.untyped`, and the error handling is a 40-line
layer you write once per project. The cost is invisible until the schema moves.

**Pick it over graph_weaver when** you have a handful of queries and no
appetite for a build step.

## Where graph_weaver loses

Said plainly.

- **Sorbet is a hard dependency.** `sorbet-runtime` is a runtime
  dependency,<!-- graph_weaver.gemspec: s.add_dependency "sorbet-runtime" --> and
  the payoff — a typo caught before you run — needs `srb tc` in your build. No
  RBS output. If Sorbet isn't in your stack, you're carrying the cost of
  generated code for a fraction of the benefit.
- **Codegen is a build step.** You check generated Ruby in, and regenerate on
  every gem upgrade, because any release can change what codegen emits. `rake
  graph_weaver:verify` exists precisely because that step is easy to skip. The
  alternatives have no build step at all.
- **No subscriptions.** A subscription document is refused outright:
  `GraphWeaver::Error: unsupported operation: subscription`.<!-- lib/graph_weaver/internal/selection.rb:48 --> Nobody
  in Ruby has this, but that doesn't make it present here.
- **No `@defer`, no file uploads, no persisted queries, no batching.** artemis
  has multiplex batching;<!-- lib/artemis/client.rb .multiplex --> this gem has
  none of the four.
- **One author, and it's new.** First commit July 2026, 4 stars, pre-1.0, and 28
  breaking-change notes in the changelog so far.<!-- gh api repos/dpep/graph_weaver created_at 2026-07-07, stargazers_count 4; grep -c breaking CHANGELOG.md -->
  Codegen is unforgiving and there is a lot of surface to get wrong.
  `verify` mitigates drift; nothing mitigates the maintainer. "No static types"
  is a cost many teams will rationally accept over that.

If you read that list and none of it stops you, the thing you get in exchange is
in [getting started](getting_started.md).
