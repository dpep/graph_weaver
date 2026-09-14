# Senior federation evaluation log (session C)

03:23:12 - start, cleared senior-app-C
03:23 - read docs/federation.md (full, 650 lines) + examples/federation.rb + README federation section, to learn the intended path before touching lib/spec
03:25 - read spec/support/federation/{compose.mjs,gateway.mjs,gateway_static.mjs,recompose.rb,package.json} — these are the node composition + real-gateway parity harnesses I'll reuse (read-only, copied out, never edited in place)
03:27 - read spec/support/federation_router_graph.rb in full (the gem's own demo graph: accounts/products/reviews with @requires, @provides, nested @key, unions/interfaces crossing subgraphs). Reading this before writing my own schemas so I don't reinvent the apollo-federation-gem incantations badly; my subgraphs are a different domain (not copy-pasted) so I still hit the "never seen this gem" evaluation honestly.
03:28 - grepped lib/ for @override / @interfaceObject / @context support to see what's a real refusal category vs silently-ignored composition metadata (schema_loader.rb:192, planner.rb:227/389, testing/router.rb:42-49)
03:30 - scaffolded Rails 8.1.3.1 app (rails new --minimal --skip-git --skip-test --skip-bundle -d sqlite3) specifically so the Zeitwerk-unloaded-subgraph-class scenario is real, not simulated
03:33 - Gemfile: graph_weaver (path), graphql, apollo-federation, webmock; bundle install --local succeeded fully offline (81 gems)
03:35-03:52 - wrote three subgraph schemas (Accounts::Schema, Products::Schema, Reviews::Schema) in app/graphql/{accounts,products,reviews}/schema.rb, apollo-federation + graphql-ruby. Entities: User@key(id); Product@key(upc) w/ @shareable name; Bundle@key(upc) implementing Purchasable w/ Product; Warehouse@key(code,region) composite key; Listing@key("sku warehouse { code }") nested/object key. reviews extends User+Product+Warehouse+Listing, @requires (flat: shippingEstimate needs weight; nested: giftWrapEligible needs "weight dimensions { length width }"; supportTier on User needs email), @provides (Review.author needs username), @override (Product.popularity migrating from products), @interfaceObject (Purchasable, reviews attaches to it without knowing Product/Bundle), SearchResult union crossing User/Product/Review.
03:53 - hit uninitialized constant Reviews::Listing referencing the class directly before Reviews::Schema — genuine Zeitwerk trap (one file per module convention means only the file's own matching constant, Schema, is autoload-registered; siblings only appear as a side effect of loading that file). Non-issue once app code references the Schema class (the pattern this gem's own docs assume), but worth remembering when writing ad hoc console/debug snippets against a federated Rails app.
03:55-04:05 - orphan_types Bundle/Listing/Purchasable/Warehouse silently vanished from federation_sdl and (more importantly) the _entities union despite being present in Schema.types — root-caused via isolated repro (tmp/repro.rb, deleted after): apollo-federation's `query` class method computes the router's `_Entity` union (schema_entities) at the moment `query` is called, from whatever orphan_types are registered *so far*. Declaring orphan_types after query/mutation in the class body means they're never counted — an apollo-federation gem ordering footgun, not a graph_weaver bug. Fixed by moving orphan_types above query/mutation in all three schemas. ~10 min sunk here; logging it because a fresh team adopting this stack would hit the same wall with no error message at all (silent, not even a warning).
04:08-04:30 - first composition attempt failed twice on real Apollo Federation rules (both are Apollo/apollo-federation-gem semantics, not graph_weaver): (1) @shareable/@override/@interfaceObject unknown until `federation version: "2.5"` declared per schema (fed1 default silently accepts none of fed2's directives — a footgun for anyone who forgets the version bump); (2) "@interfaceObject in subgraph X so X should not define any implementation types of the interface, but it defines type Product" — my Purchasable interface was implemented by Product AND separately extended by reviews as @interfaceObject in the same subgraph, which fed2 forbids outright. Fixed by decoupling: Purchasable now implemented only by Bundle/GiftCard (products), Product instead implements a separate plain Node interface also implemented by accounts' User — gives me both "interface implemented in two subgraphs" and "@interfaceObject" as clean, non-conflicting scenarios.
04:30-04:45 - third composition error: "Non-shareable field User.username is resolved from multiple subgraphs ... defined as non-shareable in subgraph accounts" even though reviews declared it @external. Root-caused with an isolated repro (tmp/repro2.rb, deleted after): fed2 requires a field that is the target of another subgraph's @provides to be marked @shareable at its ORIGIN — @external alone is not enough once you add @provides. This is real, current Apollo Federation 2 semantics (not fed1, not this gem's holdover), and it is exactly the case graph_weaver's docs point at when they say composition itself is Apollo's job, not something the local router or codegen re-validates. Fixed by adding `shareable: true` to Accounts::User.username.
04:46 - `federation_harness/compose.rb` (Apollo's own composeServices, copied read-only from spec/support/federation/compose.mjs) now composes cleanly: 5.8KB supergraph.graphql, api_schema.graphql derived. Confirms Purchasable interface's reviews field (from @interfaceObject) correctly fans out onto both Bundle and GiftCard in the API schema, popularity appears once (override resolved), Node implemented by both Product and User.
04:50-04:55 - copied supergraph.graphql to app root, ran `rails g graph_weaver:install supergraph.graphql` — correctly detected "composed supergraph (3 subgraphs: accounts, products, reviews)" and pointed the generator's console output straight at federation:diff/subgraphs and graphql: :router, unprompted. Good UX: it told me the right next step before I asked.
04:56-05:05 - wrote 6 cross-subgraph queries (dashboard, purchasables, search, warehouse, listings, add_review mutation) exercising: a plain 2-hop chain (me->reviews->product), an interface fanning through @interfaceObject with an inline fragment, a 3-subgraph union, the composite-key Warehouse, the object-shaped-key Listing, and a mutation whose result crosses back into accounts via author.
05:05 - `rake graph_weaver:generate` refused purchasables.graphql: "select __typename on Purchasable so the union can dispatch — unaliased and not under @skip/@include, since from_h reads it on every response — or narrow to a single `... on Type` condition" — exactly the kind of actionable, specific refusal docs/federation.md promises elsewhere for the router; good to see codegen hold itself to the same bar. Fixed by adding __typename (same fix needed on search.graphql for SearchResult, which is a genuine 3-subgraph union: User/accounts, Product/products, Review/reviews).
05:06 - `rake graph_weaver:generate` succeeded: 6 files, 934 lines total, all `# typed: strict`.
05:07-05:20 - `srb tc`: sorbet/tapioca aren't in the app's Gemfile by default and the app is a `path:` gem dependency, so the deprecated `srb init` hidden-definition flow produced 1043 spurious errors from a stale bundled `sorbet-typed/thor.rbi` fighting DSL-generated RBIs. Threw that away, `tapioca init` + `tapioca gem graph_weaver` instead (the modern/correct flow for a gem installed via a local path) — generated `sorbet/rbi/gems/graph_weaver@0.7.0.rbi` by runtime reflection since there's no source-scanning option for a path gem. `srb tc`: **No errors.** All three subgraph schemas and all six generated query modules typecheck clean.

## FINDING (high severity): @interfaceObject poisons its interface's OTHER implementers' subgraph, not just the interfaceObject field

05:25-05:45 - Building the router spec with subgraphs pinned explicitly (`Testing.config.router = { subgraphs: {...} }`) failed at Router.new construction:

    GraphWeaver::ConfigurationError:
      subgraphs["products"] is Products::Schema, which doesn't define Bundle.reviews, GiftCard.reviews — the supergraph says products resolves them. Did two entries get swapped?

Nothing was swapped — Products::Schema correctly does NOT define reviews on Bundle/GiftCard (that field is only ever answered by reviews' `@interfaceObject`). Root-caused:

  $ ruby -e require table.owners checks (tmp/routing.rb, deleted after):
    table.owners("Bundle", "reviews")       # => ["products"]   -- WRONG, should not be products at all
    table.owners("GiftCard", "reviews")     # => ["products"]   -- same
    table.owners("Purchasable", "reviews")  # => ["reviews"]    -- correct
    table.interface_objects                 # => {"Purchasable" => ["reviews"]}   -- correct

The composed supergraph.graphql shows why: Apollo's composer emits a bare, argument-less `@join__field` (no `graph:`, not `external:`) on EACH concrete implementer for a field that's actually contributed by an `@interfaceObject` elsewhere —

    type Bundle implements Purchasable @join__type(graph: PRODUCTS, key: "upc") {
      reviews: [Review!]! @join__field        # <- present, but empty
    }
    interface Purchasable @join__type(graph: PRODUCTS) @join__type(graph: REVIEWS, key: "upc", isInterfaceObject: true) {
      reviews: [Review!]! @join__field(graph: REVIEWS)   # <- the real, correct attribution
    }

`SchemaLoader::RoutingTable#owners` (lib/graph_weaver/schema_loader.rb:976-982) doesn't distinguish "no @join__field at all" (the documented "lives wherever its type does" case) from "a @join__field directive present with zero arguments" (fed2's actual signal for "this concrete type's copy is a placeholder — the real owner is the interfaceObject's own attribution"). Both fall through to the same `field.graphs.any? ? field.graphs : (external? [] : declared_in(type_name))` branch, so Bundle/GiftCard's phantom `reviews` gets attributed to their sole home graph (products) instead of being excluded or pointed at reviews.

Impact, verified two ways:
  1. `Router.new(subgraphs: { "products" => Products::Schema, ... })` refuses to construct at all — ConfigurationError, not Unplannable, so it isn't even a per-query refusal; it kills the whole router for a graph that has nothing else wrong with it.
  2. Worse: with NO explicit `subgraphs:` (the documented zero-config default), auto-detection reports `absent=["products"]` even with Products::Schema fully loaded and correct, and a query that never goes near Purchasable/Bundle/GiftCard —

     router.execute("{ products { name price } }")
     # => Unplannable(:absent_subgraph): "Query.products resolves in \"products\", which no
     #    schema here serves — nothing loaded defines what the supergraph says \"products\"
     #    resolves. Rails autoloads, so the class is probably just not loaded yet: eager-load
     #    it ..."

  The error message actively misdirects here — it blames autoloading, but Products::Schema *is* loaded; the real cause is two phantom fields the routing table incorrectly thinks products must define. Anyone hitting this would burn time on `config.eager_load` before finding the real cause.

This is a real graph_weaver bug, not an apollo-federation-gem or Apollo-composition issue (the composed SDL is legitimate fed2 output for `@interfaceObject`). Given it blocks testing the REST of the products subgraph with real resolvers whenever `@interfaceObject` shares a supergraph with the interface's other implementers, I removed Purchasable/Bundle/GiftCard from the shared 3-subgraph demo (kept Node/composite-key/nested-key/@override/@requires — all unaffected) so the rest of the router matrix could actually run against real resolvers, and kept this repro as its own isolated finding instead of entangling it with the working suite.

## FINDING (medium severity): local router is correct but less efficient than a real gateway — extra round trips, not wrong data

06:10-06:30 - Built a real-gateway parity check by hand, modeled on the gem's own spec/integration/router_parity_spec.rb pattern (WEBrick-serving the three real Ruby schemas + a real `@apollo/gateway` via gateway_static.mjs against the same supergraph, with per-subgraph request counters) — same technique the task asked for, just assembled myself since router_parity_spec.rb lives in the gem repo and I copy harness *scripts*, not specs. For the dashboard-shaped query (me -> reviews -> product, with a flat @requires on User.supportTier and both a flat and nested @requires on Product):

  gateway per-subgraph HTTP request counts: {"accounts"=>1, "reviews"=>2, "products"=>1}  (total 4)
  local router trace:                       {"accounts"=>1, "reviews"=>3, "products"=>2}  (total 6)
  response bodies: byte-identical (MATCH: true)

Data correctness is perfect. But the local router makes 1.5x the fetches: it issues a separate `_entities` call to `reviews` for `supportTier` and another for `reviews { ... }` on the very same User node (2 calls where the real gateway merges sibling field groups on one entity into 1), and separately fetches `products` once for the plain external fields (`name price`) and again for the `@requires` prefetch (`weight`, `dimensions{length width}`) on the identical 2 Product entities, where the real gateway merges those into 1. The docs correctly promise batching *across rows at one level* ("every node at one level goes in ONE _entities call") but that's a different guarantee from merging *sibling field groups* destined for the same subgraph on the same node — the local router doesn't do the second kind of merge, a real router does.

Because `router.trace`/fetch-count is explicitly marketed as a regression-testing tool ("router.trace records the fetches made ... which is the whole point"), this matters beyond a benchmark number: a team writing `expect(router.trace.size).to eq N` to guard against an N+1-shaped regression would be asserting a number that doesn't match what production actually costs. Not a correctness bug, but a real gap in the "faithful subset" claim as applied to *fetch count*, worth flagging as additive (batch sibling field-groups per subgraph+node the way a level's rows are already batched) rather than breaking.

06:35 - spec/federation_router_spec.rb: 16 examples, 0 failures after fixing my own wrong assumptions:
  - :undefined_fragment and :operation_type (subscription) Unplannable categories only fire for a document that PASSES graphql-ruby's own validation but that the router specifically can't handle (e.g. a real subscription against a schema that HAS a Subscription root, or a fragment named in a sibling file the router's own parse didn't carry). A truly undefined fragment name, or a subscription against a schema with no Subscription type at all, is rejected by graphql-ruby's ordinary document validation first — same layering a plain single-schema client gets, never reaching the router's planner. Not a bug, just a layering detail worth knowing before writing a test that expects Unplannable specifically.
  - shadowed_key, root_fields_span, ambiguous_operation (multi-op no name), mixed_introspection all correctly reach the router's own Unplannable, each naming the right category.
First verbatim refusal captured (alias shadowing an injected @key):
an alias shadowing an injected @key
User.reviews is fetched on User's "id", and this selection aliases username as "id" over it — the local router injects the @key it crosses on under a reserved response key and Apollo injects it under the field's own name, so either way this alias claims a key the fetch needs. Rename the alias.

06:45 - Genuine subgraph absence, in a fresh `rails runner` process (nothing autoloads Products::Schema, deliberately never referenced):
    #<GraphWeaver::Testing::Router subgraphs=["accounts", "reviews"] absent=["products"]>
    ok: {"data"=>{"me"=>{"username"=>"dpep","reviews"=>[{"body"=>"Love it"},{"body"=>"Overpriced for what it is"}]}}}
    refused (absent_subgraph): Query.warehouse resolves in "products", which no schema here serves ...
  A query that never reaches products' fields runs fine with real data; one that does refuses loudly, at plan time, before anything executes. Matches docs/federation.md exactly. Separately confirmed in spec/federation_absent_and_fake_spec.rb that naming only SOME subgraphs explicitly does NOT make the rest "absent" — they're derived from whatever's loaded in the process, so within one shared rspec run, once any earlier example has touched Products::Schema, "absence" can no longer be demonstrated there; it only shows up in a genuinely fresh process (or an app's very first request after boot, mid-migration).
06:50 - spec/federation_absent_and_fake_spec.rb: 5/5 passing — :fake substituting for an absent subgraph (schema-correct fabricated data, `router.faked` lists it, trace entries carry `faked: true`), per-example `fake:` pins overriding a faked subgraph's data, `graphql_context` propagating far enough to change a DOWNSTREAM subgraph's derived answer (reviews' supportTier depends on the accounts context), and two schemas matching one subgraph raising `ConfigurationError` (not `Unplannable`) at construction.

06:55 - spec/federation_wire_spec.rb: 2/2. graphql: :wire posts a real HTTP request through GraphWeaver.client to the initializer's configured URL (webmock-stubbed, served by the same router this graph resolves to) and reads back via the real `from_h` — confirms the "hop, not a capability" claim: the mutation-spans-subgraphs refusal still fires identically over the wire.
07:00 - Full suite together: 23 examples, 0 failures (spec/federation_router_spec.rb, federation_absent_and_fake_spec.rb, federation_wire_spec.rb).

07:05 - Baseline rake federation:* on a clean, in-sync state:
  federation:diff       -> "supergraph.graphql: matches the schemas here (checked 3 of 3 subgraphs)" exit 0
  federation:subgraphs  -> paste-ready map, each entry says WHY it matched (three sample coordinates), e.g. "reviews" => Reviews::Schema, # matched: defines Listing.condition, Mutation.addReview, Product.popularity
  federation:coverage   -> "5/5 queries plannable locally (100%), 5 servable here / accounts+products+reviews 2, products+reviews 2, reviews 1"

07:10 - federation:diff after a subgraph change without recompose: renamed Products::Product.price -> currency (in the Ruby schema only, supergraph.graphql untouched):

    /private/.../supergraph.graphql: 1 stale, 1 not composed in (checked 3 of 3 subgraphs)
    stale — the supergraph carries these, no schema here defines them (recompose):
      Product.price (products)
    not composed in — a schema here defines these, the supergraph doesn't carry them:
      Product.currency (Products::Schema)
    the supergraph is out of date — recompose it and commit the result
    exit code: 1

  Exactly matches docs/federation.md's worked example, both directions correctly attributed to "products" for the stale side. Recomposed -> back to "matches the schemas here (checked 3 of 3 subgraphs)", exit 0. Reverted the rename (queries/generated code reference `price`) and reran the full spec suite: 23/23 green again.

07:15 - Added a 4th subgraph (inventory, extending Warehouse with stockLevel) without recomposing first: federation:diff stayed at "matches the schemas here (checked 3 of 3 subgraphs)", exit 0 — completely silent about the new subgraph. Expected once I thought about it (diff only iterates subgraphs the SUPERGRAPH already names, so a brand-new one loaded in-process but nowhere in the routing table is invisible to it — it's a drift detector against a known table, not a schema-discovery tool), but worth knowing: adding a subgraph gives you zero signal from federation:diff until you both recompose AND the new subgraph earns at least one attributable coordinate.
07:16 - Recomposed with all 4: federation:diff -> "checked 4 of 4 subgraphs", federation:subgraphs lists all 4 with sample coordinates, federation:coverage unchanged (5/5, no query touches inventory yet, correctly).

## FINDING (medium-high severity): removing a subgraph from the supergraph is invisible to federation:diff, even with the orphaned schema class still fully loaded

07:20-07:25 - Simulated retiring the "reviews" subgraph: recomposed supergraph.graphql from only accounts+products+inventory (Reviews::Schema untouched, still fully loaded and defining Review/Mutation.addReview/the Product+User extensions in this very process).

    rake graph_weaver:federation:diff
    => "supergraph.graphql: matches the schemas here (checked 3 of 3 subgraphs)"   exit 0

No mention of reviews at all — a totally clean bill of health, indistinguishable from the case where reviews was never a subgraph to begin with. `federation:subgraphs` likewise lists only 3, silently. This is the mirror image of the documented "not checked... or the subgraph is gone" case (that one is for a subgraph the SUPERGRAPH still names but nothing here serves); this is the reverse — a schema class the CODE still fully defines that the supergraph no longer routes to at all. Since every federation:* task "runs once per declared graph" (iterating the routing table's own subgraph list), there's structurally no path for it to notice a loaded class that matches none of them.

Practical impact: a team that retires a subgraph by recomposing without it, but forgets (or isn't sure it's safe) to delete the Ruby schema file, gets zero signal — no warning, no exit code, nothing — that dead federation code is sitting in the app. Given the whole selling point of federation:diff is "quietly describes a graph that no longer exists is the failure that bites a federated app mid-migration, and the one the other checks don't ask about" (docs' own words), this is exactly the shape of silent gap the tool exists to catch, just from the other direction. I'd rate this additive (a distinct "unused — loaded here but nothing in the supergraph attributes to it" section, or at minimum a documented caveat) rather than breaking anything existing.

07:26 - Restored the 4-subgraph supergraph (accounts+products+reviews+inventory) via tmp/compose.rb; federation:diff back to "checked 4 of 4", clean.

07:35 - Tightened up sorbet/tapioca setup: tapioca's require.rb needed `require "graph_weaver/testing"` (only `graph_weaver` itself was reflected on first pass, so `GraphWeaver::Testing::Unplannable` in specs was unresolved). Adding `require "graph_weaver/rspec"` too broke tapioca's OWN gem-loading boot (`RSpec.configure` called before RSpec's core `configure` API exists in tapioca's partial-boot environment) — an integration-order footgun specific to generating RBIs for a gem that eagerly calls `RSpec.configure` at require time, not a graph_weaver defect in normal app boot (Rails' own to_prepare timing avoids this). Backed that one out; added `--ignore=spec/` to sorbet/config instead of chasing full rspec-core/rspec-rails RBI generation, which is orthogonal to this evaluation. Final state: `srb tc` -> "No errors!" for every subgraph schema, all 5 generated query modules, and the initializer.
07:36 - Full check, one more time, clean: rake graph_weaver:generate (5 already up to date) / srb tc (No errors!) / rspec (23 examples, 0 failures) / rake graph_weaver:federation:diff (checked 4 of 4, exit 0).

07:45 - @inaccessible: added Warehouse.internalNotes @inaccessible in products, recomposed. Confirmed three ways: (1) present in supergraph.graphql on the wire (`internalNotes: String! @inaccessible @join__field(graph: PRODUCTS)`); (2) absent from Apollo's own derived api_schema.graphql; (3) `GraphWeaver::SchemaLoader.load("supergraph.graphql").types["Warehouse"].fields.keys` => ["code","name","region","supportContact"] — matches Apollo's own derivation exactly, confirming the docs' claim that weaver's @inaccessible stripping doesn't need Apollo's JS tooling to subtract the API schema first. (4) `rake graph_weaver:generate` on a query selecting `internalNotes` refuses at the validation step: "Field 'internalNotes' doesn't exist on type 'Warehouse'" — a client genuinely cannot see or query a field mid-rollout. Reverted both the field and the test query afterward to keep the working baseline clean.

07:50 - "same type name in two subgraphs with different fields" — composed two throwaway subgraphs both declaring `type Widget { id: ID! ... }` with a DIFFERENT second field each and no @key. Apollo's own composeServices refuses outright, before a supergraph exists at all:
    Non-shareable field "Widget.id" is resolved from multiple subgraphs: it is resolved from subgraphs "a" and "b" and defined as non-shareable in all of them
  Confirms graph_weaver never has to think about this case — a supergraph with a genuine type conflict never gets composed, so it can't reach codegen or the router. Consistent with the "composition is Apollo's job, not this library's" design stance stated throughout docs/federation.md.

07:55 - "supergraph composed with a newer federation version": bumped only the join spec's version in the @link URL (v0.3 -> v0.6), no directive/argument shapes changed. Completely transparent — federation:diff, federation:subgraphs, and the full rspec suite (23/23) all passed unchanged, confirming "which names count as machinery is read off the schema, not a fixed list."
07:56 - Then injected a genuinely new, undeclared directive (`@join__futureDirective(graph: ACCOUNTS)` on Query) to simulate an actual future join-spec addition the gem doesn't know about yet:
    routing_table.unsupported => ["Query applies @join__futureDirective, which this table doesn't read"]
    Router.new(supergraph: ...) => refused at construction (unsupported_federation): "this supergraph uses federation constructs the local router doesn't read: ... — the routing table is incomplete, so every answer it gives about this supergraph would be a guess. Run this graph's queries against a real router."
  Exactly the documented behavior: the ONE refusal category that fires at construction rather than per-query, and it fires even though every query in my whole corpus is completely unaffected by the unknown directive (it's on Query, but no field it actually decorates). That's the conservative, correct call — "an incomplete table makes every answer about this supergraph a guess" — though it does mean a single cosmetic/inconsequential future directive anywhere in a large supergraph would take down local-router testing for the ENTIRE graph until the gem ships support for it, not just the queries that touch it. Worth knowing as an upgrade-timing risk: adopting a newer federation-version feature anywhere in a large org's supergraph (even in a part your team doesn't own) could break your team's `graphql: :router` specs before you've touched anything.
  Restored the original supergraph.graphql afterward.

08:00 - Final full check: rake graph_weaver:generate (5 already up to date), srb tc (No errors!), rspec (23/23), federation:diff (checked 4 of 4, exit 0), federation:coverage (5/5 plannable, 5 servable). Session end.

## Time accounting (wall clock, from timestamps above)
- 03:23-03:33 (10m): scaffold Rails app, Gemfile, bundle install
- 03:23-03:30 (~10m, overlapping): read docs/federation.md, README, examples/federation.rb, harness scripts, RouterGraph reference schema
- 03:30-04:46 (~75m): write 3 subgraph schemas + fix 2 apollo-federation-gem footguns (orphan_types ordering, Zeitwerk direct-constant-reference) + debug and fix 3 real composition errors (federation version declaration, @interfaceObject/concrete-type exclusivity, @shareable+@provides) — most of this bucket is genuine unfamiliarity friction with apollo-federation, not graph_weaver
- 04:46-05:07 (~20m): compose, install generator, write + generate 6 queries, fix 2 codegen refusals (missing __typename on unions/interfaces)
- 05:07-05:20 (~15m): sorbet/tapioca setup for a `path:` gem dependency
- 05:20-07:00 (~100m): rspec suite (router matrix, absent/fake, wire), including finding + isolating the @interfaceObject routing-table bug and the real-gateway parity fetch-count gap
- 07:00-08:00 (~60m): rake federation:* tasks (baseline, drift, add subgraph, remove subgraph), @inaccessible, same-type-name conflict, newer-federation-version (both transparent-bump and genuinely-new-directive cases)
- Total: ~4h35m
