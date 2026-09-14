# Senior T log — the subgraph author

2026-09-13T23:47:00Z Start. Read brief-senior-T.md + brief-round6-common.md + docs/federation.md
(the `_entities` / Representations section, "Producing a supergraph"). Skimmed
senior-log-S.md (observability, unrelated) and senior-log-C.md (federation
client-side lane — reused its WEBrick+real-gateway parity technique and its
app as a base). Checkout HEAD is df7043b (one commit past the brief's
00038e5, "Put an object pin's list and its ID on the wire the way a server
would" — not federation, no rebase needed).

00:00 - Copied /tmp/claude/graph_weaver/senior-app-C-fix -> senior-app-T
(rsync, excluding node_modules; symlinked federation_harness/node_modules
back in rather than re-installing 100M of npm deps). Repointed Gemfile's
graph_weaver path at the checkout root (the old path pointed at a worktree
that no longer exists). `bundle lock --local && bundle install` clean.

00:05 - Read the four subgraph schemas (products/accounts/inventory/reviews)
and the three existing federation_*_spec.rb files to learn this app's
conventions before adding to them. Reviews already extends Product (@key
upc), User (@key id), Warehouse (@key "code region", composite),
Listing (@key "sku warehouse { code }", nested object) — three of the four
@key shapes docs/federation.md's Representations table names. The fourth,
the LIST hop ("id lineItems { sku }" over a [LineItem!]!), wasn't exercised
anywhere in this supergraph.

00:10 - DESIGN DECISION (stating the rule once, per this repo's own
philosophy): rather than force a second, narratively-unmotivated key onto
User, I completed the shape matrix on Product, which reviews already
extends. Added `Product.variants: [Variant!]!` for real in products/schema.rb
(a genuine resolver, not external-only — needed so composition has a
non-external definition to point at) and a second `@key(fields: "upc
variants { sku }")` on Product; mirrored as an external field + the same
second key in reviews' extension. So reviews' own four extended entities —
Product (scalar + list), User (scalar), Warehouse (composite), Listing
(nested) — now cover every @key shape the docs describe, without inventing
a shape on an entity with no reason to have it.

00:12 - Added `Reviews::Query.platformSummary: String!` — the "calls the
supergraph" field. Its resolver does `GraphWeaver.client.execute("{ products
{ upc name } }", variables: {})`, i.e. reviews' own resolver reaches for the
composed graph the way a cross-cutting report might, not through
@key/@requires. This is the seam nobody has driven: the subgraph the router
runs IS ALSO a caller of GraphWeaver.client, which under test tags is the
very same router.

00:14 - `bin/rails runner tmp/compose.rb` (federation_harness/compose.mjs via
@apollo/composition) recomposed clean with the new key: supergraph.graphql
now carries `@join__type(graph: PRODUCTS, key: "upc variants { sku }")` and
the REVIEWS extension of the same key. No composition errors.

00:16 - Baseline rspec (23 examples) green after the copy+repoint.
`federation:subgraphs`/`:diff`/`:coverage` baseline: 4/4 matched, "matches
the schemas here", 5/5 queries plannable.

00:20 - Wrote spec/federation_dual_role_spec.rb (3 examples): reviews'
platformSummary field (Query.platformSummary: String!) calls
GraphWeaver.client.execute("{ products { upc name } }") from INSIDE a
resolver that the router/wire/in_process stand-ins ALSO run through. All
three predictions confirmed on first run, no debugging needed:
  - :router — reenters Testing::Router from inside one of its own
    subgraphs' resolvers. Plans fine (single-subgraph verbatim plan for the
    outer call), and router.trace records ["reviews", "products"] in CALL
    order, not return order — Router#fetch appends to @trace before
    invoking Schema.execute, so nesting doesn't scramble it.
  - :wire — two real, reentrant HTTP POSTs to the one stubbed gateway URL
    (WebMock.have_requested(...).twice), same data.
  - :in_process, testing Reviews::Schema alone — the resolver's own
    GraphWeaver.client call redirects to ITSELF (the only thing
    graphql_in_process(Reviews::Schema) repointed the client to), so
    `{ products { upc name } }` runs against a schema with no root
    `products` field. No exception, no error in the outer response —
    platformSummary silently returns "0 products: ". THE FINDING the brief
    is fishing for: every test mode either plans correctly or fails loudly,
    EXCEPT this one, which is silently wrong in exactly the way this
    library's own design principle says is the worst outcome it can produce.

00:35 - Built tmp/entities_probe.rb: WEBrick-serves Reviews::Schema for
real, raw `_entities` POSTs with 12 hand-built representations (every valid
@key shape reviews had at the time — scalar/list/composite/nested — plus
missing key, extra field, wrong __typename x2, wrong-typed key field, list
sent as a single object, no __typename, empty batch) and a batch of 500.
Exact messages in the report below. Headline: a bad __typename is an
UNCAUGHT RuntimeError from apollo-federation-ruby's entities_field.rb, not
a GraphQL error — first request came back as WEBrick's own HTML 500 page
until I wrapped the handler in rescue myself. Not graph_weaver's bug (it
isn't on this path at all), but it's exactly what "what does graphql-ruby
do with the rest" was asking.

00:50 - Reused graph_weaver's CLIENT-side codegen against reviews' OWN
subgraph SDL (Reviews::Schema.federation_sdl -> GraphWeaver.graph
:reviews_self, an experiment only — not part of the app's real setup) to
see whether the typed Representations builder can be repurposed to
validate an incoming raw `_entities` representation before resolve_reference
ever sees it. tmp/representations_reuse_probe.rb. It can, and the messages
are much better than apollo-federation-ruby's crashes (GraphWeaver::InputError
naming the type/field) for MULTI-key entities — but two rough edges specific
to this off-label use: (1) a single-@key entity types its builder as
REQUIRED kwargs (by design, for a literal Ruby call site), so splatting a
raw JSON hash with a missing or extra field raises Ruby's own ArgumentError
("missing keyword: :region" / "unknown keyword: :extra"), not
GraphWeaver::InputError — inconsistent depending on whether the entity
happens to have one key or several; (2) when two @key sets share a field,
`Representation.build` picks the FIRST fully-satisfied one and silently
drops fields only the second needs (`key_sets.find { ... }`,
representation.rb:34) — by design ("nothing extraneous reaches the
router"), but a caller deliberately trying to exercise the SECOND key gets
redirected to the first with no signal beyond inspecting the returned hash.
Declaring a second Rails-wide GraphWeaver.graph for this experiment broke
19 of the existing specs (ambiguous graph: errors, :wire's "two graphs post
to the same endpoint" refusal) until I removed the initializer — both
refusals are correct, documented behavior, not bugs; removed the initializer,
kept the one already-generated file as an artifact.

01:05 - Schema evolution matrix, five steps, `federation:diff`/`:coverage`
before AND after each recompose (`bin/rails runner tmp/compose.rb`):
  1. ADD a @key (User + a second key on username, then on email) —
     confirmed reproducible: 2+ @key directives on one extend_type'd type,
     combined with ANY OTHER field-set directive (@requires/@provides) on
     that SAME type, crashes @apollo/composition itself with "Unexpected
     element: federation__provides" / "federation__requires" — an
     apollo-federation-ruby/@apollo-composition interaction bug (unimported,
     `federation__`-prefixed directives + multiple @key), not graph_weaver's.
     Reverted; retried the "add a key" step on Product instead (no
     colliding @requires/@provides text), which composed fine — this is
     the Product list key from the setup phase.
  2. REMOVE a @key (Product's list key, reviews side only) — composed
     clean after also dropping the now-orphaned external `variants` field
     apollo-federation-ruby refused to leave dangling ("marked @external
     but is not used in any federation directive").
  3. change resolvable: (Warehouse's sole key -> resolvable: false, while
     reviews still adds support_contact) — composition correctly refuses:
     "none of the @key defined on type Warehouse in subgraph reviews are
     resolvable." Reverted.
  4. add @requires on a NEW field (Product.discountedPrice requires price) —
     composed clean.
  5. add @shareable to something another subgraph owns (Warehouse.name) —
     composed clean once BOTH copies (products' origin AND reviews' new
     one) declared shareable: true; the local Testing::Router and a real
     gateway agree on which subgraph answers it ("products", "New York DC").

  THE PATTERN, confirmed three separate ways (steps 1/2/3): federation:diff
  never once flagged an @key change (add, remove, or resolvable:) as drift,
  even the resolvable: change that made the NEXT recompose impossible. Step
  5 sharpens it further: adding a brand-new, colliding, non-shareable field
  (Warehouse.name) ALSO passed diff clean, because the field COORDINATE
  already existed in the supergraph (from products) — diff's "uncomposed"
  check is keyed on coordinates present in the loaded schema but absent
  from the supergraph, not on which subgraph a coordinate is attributed to,
  so a same-name collision is invisible to it too. Contrast: step 4 (a
  genuinely NEW field) WAS caught — "1 not composed in: Product.discountedPrice".
  federation:diff answers "did you forget to recompose the schema you have",
  never "would the next recompose even succeed" — a fair scope (the second
  question needs the JS composer, which is a network/npm dependency diff
  doesn't take), but worth being explicit about, since two of five ordinary
  evolutions here would have silently broken the next recompose with diff
  green throughout.

01:30 - Real @apollo/gateway round trip (tmp/real_gateway_probe.rb):
WEBrick-served the four real Ruby schemas, rewrote supergraph.graphql's
placeholder join__graph urls to the WEBrick ports, booted gateway_static.mjs
for real. discountedPrice and the shared Warehouse.name both matched the
local router exactly. platformSummary — THE BIGGEST FINDING OF THE PASS —
500s under the real gateway: reviews' own resolver calls GraphWeaver.client,
which in this app is hardcoded to POST to https://gateway.example.test/graphql
(a fake hostname that only ever resolves because :wire specs stub it with
WebMock). Outside a test process there is no stub, so the call is a real
DNS lookup that fails (Socket::ResolutionError), an uncaught exception
inside the reviews resolver, which the gateway reports as reviews' own
subgraph failing. Every one of graph_weaver's test modes (:router, :wire,
:in_process) either plans this correctly or fails in a well-understood way
— NONE of them would have caught that the pattern has no real-world analog
at all, because all three conveniently intercept the exact call that breaks
in production. A green suite in every mode, and the feature never worked.

01:40 - Confirmed dual-role coexistence (Reviews::Schema serving the
router's "reviews" subgraph AND separately being config.schema for a
scratch :reviews_self graph) does NOT confuse federation:diff/:subgraphs/
:coverage — :reviews_self has no composed supergraph, so
Internal::Tasks.supergraphs! silently excludes it from every federation:*
task; :app's report is unaffected. warn_unplaced never fires in this app
(every loaded schema class does belong to the one supergraph read here) —
provoking it needs a genuinely orphaned federated class, which nothing in
this app's own dual-role setup naturally produces; time-boxed rather than
manufacturing an artificial 5th schema just to see the warning fire (its
code path was already read directly, tasks.rb:57-67).

01:45 - Three spellings comparison (Reviews::Schema.federation_sdl vs
SchemaLoader.load on that dump vs the composed supergraph's
@join__type(graph: REVIEWS, ...) view): SchemaLoader.load synthesizes
_entities/_service/_Entity correctly from the raw dump exactly as
docs/federation.md promises, even though the federation_sdl text itself
never mentions them and every directive in it is `federation__`-prefixed
(apollo-federation-ruby's default un-imported style, only @inaccessible/@tag
actually go through @link). No disagreement found between the three views
for the coordinates checked (Product's key set, external flags). This is a
confirmation, not a new finding — recorded so the "does any pair disagree"
question has an answer either way.

01:50 - Final rspec run: 26 examples (23 baseline + 3 dual-role), 0
failures. `srb tc`: clean (informational only — this is the throwaway app,
not the gem). Gem checkout untouched: `git status` clean at df7043b.

Total: ~2h10m. lib/ reads: representation.rb (twice — once to predict the
key_sets.find behavior before testing it, once to confirm after), router.rb
(the fetch/@trace ordering, before writing the dual-role spec so the
prediction was falsifiable rather than post-hoc), tasks.rb (unplaced/shape
drift, before claiming diff's scope). spec/ reads: none of the gem's own
spec/ — this pass drives entirely from the app, per the brief.
