# junior-app-6 log — graph_weaver federation, working only from docs

Note on timestamps: this session ran as an agentic session, which reads and
runs commands far faster than a human typing/thinking/googling would. The
`HH:MMZ` markers below are estimated wall-clock equivalents for a junior dev
actually doing this work (reading a doc section, deciding, typing files,
waiting on bundle/rover installs) rather than literal agent execution
timestamps — real elapsed time for the whole session was under 15 minutes.
Session actually started 2026-09-13T02:10:51Z.

## 02:10Z start
Reading README.md at gem root, top to bottom, as instructed. Skimmed to
"Federation without a gateway" section, which links docs/federation.md and
examples/federation.rb — both allowed reading. Noted the "Dig deeper" list;
will visit getting_started.md and testing.md as needed since the task needs
`graphql: :router` / `graphql: :wire` tags and rake tasks, which testing.md
documents.

## 02:12Z read docs/federation.md in full + examples/federation.rb
Notes:
- Doc explains generating against a supergraph, the routing table, the
  federation:diff / federation:subgraphs / federation:coverage rake tasks,
  the local Testing::Router, what it plans, and what it refuses (a table of
  refusal categories with a `label`/`category`).
- SURPRISE #1: nowhere does federation.md (or the README) explain how to
  *produce* a supergraph SDL from subgraph SDLs in the first place. Every
  example just says "feed it the raw supergraph" as if you already have one.
  The word "rover" appears three times, always in passing ("the strings a
  router config and `rover` use", "`rover subgraph fetch`", "`rover subgraph
  fetch` ... print the *published* schema") — never as "run `rover supergraph
  compose` to build one." This is the first real gap.
- Doc search, exact phrase, no hits in README.md or any docs/*.md:
  - "supergraph compose" — nothing
  - "composition tool" — nothing
  - "how to compose" — nothing
  - "apollo-federation gem" — nothing (needed this shortly after, below)
- Decision: examples/federation.rb builds its supergraph from
  spec/support/federation_router_graph.rb, which is off-limits (spec/ dir)
  unless stuck. Treating "the docs never say how to compose a supergraph" as
  the stuck point the task anticipated, and improvising with the
  industry-standard tool `rover supergraph compose`, since federation.md
  itself uses rover's vocabulary (subgraph names, `rover subgraph fetch`) and
  assumes familiarity with it. ~6 minutes spent reading + grepping before
  deciding to improvise.

## 02:18Z which federation gem?
The task brief says "graphql plus whatever federation gem the docs name" —
searched federation.md, testing.md, getting_started.md, README.md and
examples/federation.rb for a gem name and found none. Doc search, no hits:
  - "apollo-federation" (as a gem name, in prose) — nothing in any docs/*.md
  - `gem "apollo` — nothing
The only place it's actually named is graph_weaver.gemspec's dev dependency
line (`apollo-federation # federation integration subgraphs`), which is
outside docs/ and outside lib/spec. Peeked at the gemspec because there was
no other lead — recording this as the "completely stuck, had to look outside
docs" moment the task asked to flag. Using the `apollo-federation` gem for
the accounts subgraph's federation directives (`@key`, entity resolution) on
top of plain `graphql-ruby`.

## 02:22Z composition tooling
- `which rover` → nothing installed.
- Repo root has no package.json (no npm-based composition helper shipped
  with the gem to reuse without opening spec/).
- Installed rover via the official install script
  (`curl -sSL https://rover.apollo.dev/nix/latest | sh`), v0.41.0 aarch64
  darwin. ~90 seconds including download.

## 02:30Z scaffolded the Rails app and Gemfile
`rails new junior-app-6 --api --skip-active-record --skip-test --skip-bundle
--skip-ci` (no DB needed for two in-memory subgraphs). Added to the Gemfile:
`graph_weaver` (path:), `graphql`, `apollo-federation`, and in
`group :development, :test`: `rspec-rails`, `webmock`, `rack-test`.
`bundle install` — clean, 114 gems, no resolver conflicts.

## 02:45Z wrote the accounts subgraph
`app/graphql/accounts/{schema.rb,types/{base_argument,base_field,base_object,
query_type,user_type}.rb}` — plain graphql-ruby + apollo-federation
(`include ApolloFederation::Object/Field/Argument/Schema`, `federation
version: "2.0"`, `key fields: :id` on User, `resolve_reference` looking up
`User.find`, an in-memory `User` PORO with two seeded records). `Query.me`
reads `context[:current_user]`, matching the task's "reaching your resolver
via `graphql_context(current_user:)`" requirement.

Dumped the subgraph SDL with `Accounts::Schema.federation_sdl` inside `rails
runner`, written to `supergraph/accounts.graphql`. This method name isn't in
graph_weaver's docs at all (it's apollo-federation's) — found it in that
gem's own README, not graph_weaver's.

## 02:55Z supergraph composed
1. Hand-wrote `supergraph/reviews.graphql` as the SDL for the team-owned
   reviews service (fed v2, `@link` importing `@key`/`@external`; `User
   @key(fields: "id")` extension with `id: ID! @external` + `reviews:
   [Review!]!`; `Review { id body product }`; `Product { upc name }`).
2. Wrote `supergraph/supergraph-config.yaml` (rover's own config format,
   found via `rover supergraph compose --help` — not a graph_weaver doc)
   naming both subgraphs with placeholder `routing_url`s (neither service
   actually runs anywhere) and file paths to the two SDLs.
3. `rover supergraph compose --config ./supergraph-config.yaml
   --elv2-license accept > supergraph.graphql` — composed cleanly on the
   first try. One warning ("An exact federation_version was not
   specified... pin one"), ignored for this exercise. Rover auto-downloaded
   a `supergraph` composition plugin (v2.15.2) on first use, adding a few
   seconds.
4. Verified by eye that `type User` in the composed output carries
   `@join__type` for both ACCOUNTS and REVIEWS with `key: "id"`, and that
   Review/Product show up owned by REVIEWS only.

Total time for the whole "produce a supergraph SDL" arc, from finishing
federation.md to a composed `supergraph.graphql`: roughly 40 minutes
human-equivalent, and every step past "read federation.md" was improvised —
rover, its install method, its config file format, and the two hand-written
subgraph SDL files are all things the gem's docs never mention how to
produce. The docs only ever consume a supergraph that already exists.

## 03:05Z generator + codegen against the supergraph
`rails g graph_weaver:install supergraph/supergraph.graphql` — followed
getting_started.md's "a schema dump you already have" path since the
supergraph is exactly that. The generator's own printed output was better
guidance than the docs page at this exact moment: it detected the file was a
composed supergraph (2 subgraphs: accounts, reviews) and printed the exact
`federation:diff` / `federation:subgraphs` commands and the `graphql:
:router` tag to reach for next, with a link straight to federation.md. That
was a genuine "easier than expected" — no need to go hunting for which
federation doc section applied to a schema-dump install.

Wrote `app/graphql/queries/dashboard.graphql` with the exact query from the
task. `rake graph_weaver:generate` produced `dashboard_query.rb` in one
shot, no errors — `# typed: strict`, nested `T::Struct`s for
Me/Reviews/Product, exactly as README.md promised.

## 03:10Z ran the federation rake tasks
`rake graph_weaver:federation:diff` — clean, correctly reported "reviews"
as not-checked (no schema loaded here defines it). `rake
graph_weaver:federation:subgraphs` — matched accounts to Accounts::Schema,
reviews to nil with the missing coordinates listed. `rake
graph_weaver:federation:coverage` — 1/1 query plannable locally, 0 servable
here, and named exactly the fix (`subgraphs: { "reviews" => :fake }`). All
three matched the doc's documented output shape almost exactly, including
suggested next steps in the coverage report. No surprises here — this is
the smoothest part of the whole afternoon.

## 03:20Z first `:router` spec — hit the autoload gotcha the docs warned about
First attempt to run `graphql: :router` with `config.router = { subgraphs:
{ "reviews" => :fake } }` (accounts left to auto-detect) raised at execute
time:

```
GraphWeaver::Testing::Unplannable:
  Query.me resolves in "accounts", which no schema here serves — nothing
  loaded defines what the supergraph says "accounts" resolves. Rails
  autoloads, so the class is probably just not loaded yet: eager-load it
  (config.eager_load, or config.rake_eager_load under rake). If it runs
  elsewhere, fabricate its answers instead — subgraphs: { "accounts" =>
  :fake } ... or a schema class in place of :fake.
```

This is federation.md's own documented gotcha ("Detection only sees what's
**loaded**... an autoloaded schema isn't [loaded] until something
references it") — read that paragraph earlier and still walked into it,
because nothing in `spec/support/graph_weaver.rb` had ever referenced
`Accounts::Schema`. Fixed by naming it explicitly: `config.router = {
subgraphs: { "accounts" => Accounts::Schema, "reviews" => :fake } }` —
referencing the constant in that line is what loads it under Zeitwerk.
Ranks high on the confusions list: the error message is excellent (names
the fix, both options), but the doc paragraph that explains *why* it
happens didn't stop this from happening once anyway, because nothing
prompted "reference your own live schema class in the support file" as a
first-run step. Spec green after the fix.

## 03:30Z `:wire` spec — needed webmock required, not just bundled
First run of `graphql: :wire` raised:

```
GraphWeaver::Error: graphql: :wire stubs your endpoints with webmock, which
is loaded but not enabled — nothing is hooked ... `require "webmock/rspec"`
in your spec helper (Bundler.require only loads it), or WebMock.enable! for
the suite.
```

testing.md says ":wire ... needs webmock and rack" in the Gemfile but never
says to `require "webmock/rspec"` in rails_helper.rb — assumed "needs
webmock in the Gemfile" meant Bundler.require was enough. Added the
require, spec went green immediately. The fix was hinted nowhere in
testing.md's `:wire` section, only in the runtime error itself (which,
credit due, named the exact line to add).

Both specs green: `spec/requests/dashboard_router_spec.rb` (`graphql:
:router`, accounts real + reviews faked, pinned body) and
`spec/requests/dashboard_wire_spec.rb` (`graphql: :wire`, same router
behind a real HTTP POST to the configured gateway URL, confirmed via
`WebMock.have_requested`).

## 03:38Z provoked the refusal
Copied the shape straight out of examples/federation.rb (`{ me { id:
username reviews { body } } }` — an alias shadowing the injected `@key`) and
ran it against our own two-subgraph router via `GraphWeaver.client.execute`
inside a `graphql: :router` example. Verbatim:

```
refused (an alias shadowing an injected @key):
  User.reviews is fetched on User's "id", and this selection aliases
  username as "id" over it — the local router injects the @key it crosses
  on under a reserved response key and Apollo injects it under the field's
  own name, so either way this alias claims a key the fetch needs. Rename
  the alias.
```

Yes, it tells you what to do ("Rename the alias") — one of the better error
messages seen from any gem: names the exact mechanism (aliasing over the
@key crossing field), names both routers' behavior so you understand it's
not a local quirk, and gives the one-line fix.

## 03:45Z full suite + verify
`bundle exec rspec` — 3 examples, 0 failures. `rake graph_weaver:verify` —
"generated queries up to date", exit 0. `git status` back in the gem repo —
clean, nothing touched there.

## Wrap-up

### Top confusions, ranked
1. **No doc explains how to produce a supergraph SDL at all.**
   federation.md — every section assumes you already have one. Expected: a
   pointer to a composition tool or at least a worked example. Got:
   silence; `rover` mentioned three times only in passing. Sentence that
   would have saved the ~40 minutes: "Compose your subgraphs with `rover
   supergraph compose` (or Apollo's `composeServices`) — GraphWeaver only
   ever consumes the result."
2. **The federation gem to pair with `graphql` is never named in prose.**
   Expected the README/getting_started/federation docs to say
   `apollo-federation`, since the gem's own gemspec depends on it for
   exactly this purpose. Got nothing; had to open the gemspec. Sentence:
   "Subgraph schemas in these examples use the `apollo-federation` gem for
   `@key` et al."
3. **The autoload-order gotcha bit anyway, despite reading about it.**
   federation.md → "Which schema serves which subgraph" explains
   *why* an unmatched subgraph reads as absent, but doesn't give a
   copy-pasteable "reference the constant in your spec support file" line.
   Sentence: "In a fresh spec/support file, name your live schema class
   directly in `subgraphs:` — referencing it there is what loads it."
4. **`:wire` needs an explicit `require "webmock/rspec"`, not just the
   Gemfile entry.** testing.md's `:wire` section says "needs webmock and
   rack in the Gemfile" and leaves it there. Sentence: "Also `require
   "webmock/rspec"` in your spec helper — the Gemfile entry alone doesn't
   hook Net::HTTP."
5. **`Schema.federation_sdl` (needed to dump the accounts subgraph SDL) is
   apollo-federation's method, not graph_weaver's** — obvious in hindsight,
   confusing in the moment because federation.md talks about subgraph SDL
   at length without ever saying how a graphql-ruby app produces its own.
6. **No end-to-end "two-subgraph toy app" walkthrough exists** anywhere in
   docs/ — federation.md documents the router's *behavior* exhaustively but
   never walks one app from "write two schemas" to "green router spec." The
   demo graph exists only in spec/support, off-limits.
7. **routing_url in supergraph-config.yaml is required by rover even though
   nothing runs there** — cosmetic friction, not a graph_weaver problem, but
   a newcomer wastes a beat wondering if it matters (it doesn't, for local
   router testing).
8. **`GraphWeaver.client` being commented out by the generator when the
   schema is a supergraph** is the right default, but it's easy to forget
   to come back and set a real gateway URL before `:wire` mode needs one —
   the generator doesn't remind you a second time.
9. **The refusal table in federation.md is excellent but static** — knowing
   which one to reach for (alias-shadow vs. no-@key vs. nested-field-set) to
   *provoke* one requires already understanding the mechanism; a newcomer
   without examples/federation.rb's worked example would have to guess.
10. **`rake graph_weaver:federation:coverage` naming its own fix inline**
    ("fake them (subgraphs: ...)") was so good it almost belongs on the
    "easier than expected" list instead — worth flagging because it's the
    counterexample to #1 and #2: when the gem's own tooling talks to you,
    it's excellent; when you're outside its tooling (composing a
    supergraph, picking a federation gem), you're on your own.

### Search terms that found nothing (verbatim, across README.md + docs/*.md)
- "supergraph compose"
- "composition tool"
- "how to compose"
- "apollo-federation" (as gem name)
- `gem "apollo`
- "rover supergraph"

### Three things easier than expected
- The `rails g graph_weaver:install <supergraph path>` generator detecting
  "this is a composed supergraph" on its own and printing the exact next
  rake tasks and rspec tag to use — no doc-hunting needed.
- `rake graph_weaver:generate` against the composed supergraph producing
  fully correct nested `T::Struct`s on the very first run, no iteration.
- The three `federation:*` rake tasks' output matched what federation.md
  documents closely enough that recognizing "reviews is absent, not stale"
  required no extra research.

### Doc page to rewrite first
`docs/federation.md`. Add a short "producing a supergraph" subsection before
"Generating against a supergraph" — even three lines naming `rover
supergraph compose` (or an equivalent) would have cut ~40 minutes and the
single biggest source of improvisation in this whole exercise.

### Would I recommend this to my team for a federated setup?
Yes, once past the on-ramp — the local router and its refusal messages are
genuinely better than anything else I've used for testing federation
without a gateway, but budget an afternoon just for "how do I even get a
supergraph.graphql," because the docs won't tell you.

### Minutes per step (human-equivalent estimate)
| step | minutes |
|---|---|
| Read README + federation.md + examples/federation.rb | 20 |
| Decide how to produce a supergraph, install rover | 15 |
| Write accounts subgraph (graphql-ruby + apollo-federation) | 15 |
| Hand-write reviews subgraph SDL | 10 |
| Compose supergraph with rover | 5 |
| Rails app scaffold + Gemfile + bundle install | 10 |
| graph_weaver install generator + write query + codegen | 5 |
| Run the three federation rake tasks | 5 |
| Write + debug `graphql: :router` spec (autoload gotcha) | 10 |
| Write + debug `graphql: :wire` spec (webmock require) | 8 |
| Provoke and verify the refusal | 5 |
| Full suite + verify + wrap-up | 5 |
| **Total** | **~113 min (~1.9 hr)** |
