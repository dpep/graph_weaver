# junior-log-3

16:52 - Starting. Task: build bin/capitals CLI using graph_weaver gem, working only from docs. Read README.md at gem root first.

16:52 - README.md read. Key things noted:
- `rake graph_weaver:generate` is the normal Rails path.
- Non-Rails console path shown: `GraphWeaver.new(url)`, `api.parse("queries/country.graphql")`, `CountryQuery.execute!(...)`. This is the "skip the build step" path, not clear yet if this IS the codegen path or an alternative to it.
- Doc links: getting_started.md, generated_modules.md, testing.md, federation.md, transports.md, errors.md, i18n.md, scalars.md, cassettes.md, editors.md, real_world.md, logging.md, upgrading.md, alternatives.md.
- Task requires codegen path (checked-in generated Ruby), not the live-parse console path. Need to find docs on generating without rake/Rails.
- examples/ mentioned - "public API in 30 lines" - task says don't look outside README/docs unless stuck. Will avoid examples/ unless stuck.

16:55 - Read docs/getting_started.md fully. Found "Not Rails?" section at bottom - exactly matches my situation (plain Ruby project, no Rails). It says:
```ruby
GraphWeaver.client = GraphWeaver.new("https://api.example.com/graphql", auth: ENV["GRAPHWEAVER_AUTH"], cache: true)
GraphWeaver.load_generated!   # no Railtie to require the generated files
```
```sh
mkdir -p app/graphql/queries app/graphql/generated
rake graph_weaver:schema:refresh URL=https://api.example.com/graphql
```
"Add `require "graph_weaver/tasks"` to your Rakefile for the rake tasks — and since there's no `:environment` hook to run your registrations, require the file that does them from the Rakefile too."

Note: this "no Rails" path STILL uses rake (via a plain Rakefile with `require "graph_weaver/tasks"`), just not Rails' generator. Task phrasing "no rake/Rails" turns out ambiguous - docs treat "no Rails" and rake tasks as orthogonal; rake tasks work standalone via require. Going with this since it's literally what the docs say for my situation.

Still need: rake graph_weaver:generate itself (this doc mentions schema:refresh but generate is covered in the Rails section above - assuming it's the same task name `rake graph_weaver:generate` regardless of Rails).

Directory convention here is app/graphql/queries + app/graphql/generated even outside Rails - going with that since it's what the doc shows, though it feels odd naming a dir "app" with no Rails app.

16:58 - Read docs/transports.md and docs/logging.md and docs/testing.md fully.
Key findings for building the app:
- transports.md: `GraphWeaver.new(url, transport: :faraday, retries: N) { |conn| conn.use MyMiddleware; conn.adapter Faraday.default_adapter }` is the documented one-liner combining custom Faraday middleware + retries. Exactly what's needed for requirement (2).
- retries: `retries: N` counts attempts after the first; a plain integer is enough, no need for backoff/jitter options for "a small count".
- logging.md: GraphWeaver.logger is separate from GraphWeaver.instrumenter. LogSubscriber (one-line-per-operation) is Rails-only (railtie attaches it) - NOT available outside Rails per my reading. So for "log every request to a file with operation name and duration" outside Rails I have to write my own instrumenter callable (payload has :operation and :duration_ms), following the exact pattern shown for OpenTelemetry/Datadog (call block, then read payload in `ensure`, since "every key is filled in before your callable's block returns"). Docs don't hand me a ready file-logging instrumenter - I'm assembling one from the payload table + the ensure-block pattern shown for other APMs.
- testing.md :wire mode: `graphql: :wire` posts through GraphWeaver.client exactly as configured (not swapped) and webmock intercepts the real URL. Requires `require "webmock/rspec"` alongside `graph_weaver/rspec"`. It needs "that graph's live schema class" to serve real resolvers behind the endpoint since our graph isn't in a supergraph - concern: my app has no live schema class (I only have the introspected schema.json of the third-party API) - so :wire may refuse asking for `config.schema = ...`. Will need to build a small local GraphQL::Schema test double matching my query's shape and set `GraphWeaver::Testing.configure { |c| c.schema = TestSchema }`. Not explicitly spelled out in docs for a client-only (no server) app - noting as a likely friction point to hit for real.

17:02 - Read docs/generated_modules.md "Generating" section. FOUND the real answer to requirement (1): right under the rake command, docs literally say "Or call the same APIs directly:"
```ruby
schema = GraphWeaver::SchemaLoader.load(GraphWeaver.schema_path)
GraphWeaver.generate!(schema:)            # write the modules
GraphWeaver.verify_generated!(schema:)    # the freshness guard, one line in a spec
```
This is a genuinely rake-free codegen path, straight from the docs (not a guess). Combined with real_world.md's `GraphWeaver.new(url, cache: true).schema` to bootstrap+write the schema dump on first introspection, I have a complete no-rake, no-Rails codegen recipe:
```ruby
client = GraphWeaver.new(url, cache: true)
client.schema                                          # writes app/graphql/schema.json
schema = GraphWeaver::SchemaLoader.load(GraphWeaver.schema_path)
GraphWeaver.generate!(schema:)
```
Choosing this over the Rakefile+rake-task path from getting_started.md's "Not Rails?" section since it's more literally "no rake" and the docs present it as a direct equivalent. Will write this as bin/generate and run `ruby bin/generate`.

Now proceeding to scaffold the app.

17:10 - Ran `ruby bin/generate` (via ~/.rvm/wrappers/ruby-3.4.9/ruby bin/generate). Worked on the FIRST try, no errors. Wrote app/graphql/schema.json (via cache: true) and app/graphql/generated/continent_query.rb. No types.rb manifest was written since there's only one query and no shared types needed (per docs, types.rb/types/ only appear when something is hoisted). Genuinely easier than expected - no rake needed at all, matching my read of docs/generated_modules.md's "Or call the same APIs directly" snippet.

17:12 - Ran fake spec + cli spec: `bundle exec rspec spec/capitals_fake_spec.rb spec/cli_spec.rb` -> 2 examples, 0 failures, first try. Both straightforward once continent.graphql + generated module existed.

17:13 - Now tackling the :wire spec. My app has no live schema/resolvers of its own (it's a pure client of the third-party Countries API) - testing.md says :wire serves each graph's own "live schema class" (like :in_process needs), and my only schema artifact is the introspected schema.json dump (no resolvers). Going to try building a small graphql-ruby test schema matching just my query's shape, and setting it via GraphWeaver::Testing.configure { |c| c.schema = ... } to see what happens. Docs never show this scenario (client-only app, no server) explicitly for :wire - flagging this as a likely genuine gap/friction point.

17:15 - First real error running the :wire spec (verbatim):
```
GraphWeaver::Error:
  graphql: :wire needs rack — webmock's to_rack builds a Rack env with it, but doesn't depend on it. Add it to the Gemfile (group :test).
```
Good sign: the error is exactly the kind the gem's design doc promises ("Errors are part of the interface") - it named the fix directly, no guessing needed, and my WireTestSchema resolution (config.schema = WireTestSchema::Schema) was NOT what it complained about, so that guess apparently worked. Adding `gem "rack"` to the Gemfile test group as instructed.

17:18 - After adding `gem "rack"` to the test group and re-running `bundle install`, the :wire spec passed on the second attempt: 1 example, 0 failures. My guess about needing a small local GraphQL::Schema (WireTestSchema) to serve behind :wire, set via `GraphWeaver::Testing.configure { |c| c.schema = ... }` at the TOP LEVEL of the spec file (not inside a before block), turned out correct - :wire found it and served real resolvers behind the webmock-intercepted URL, and the X-Caller header assertion passed. So the friction was entirely about a missing gem (rack), not about the schema resolution guess - which is a relief but also means the docs are silent specifically on "what if I have no schema of my own" (a client-only app) even though webmock/rack are called out as its dependencies.

Minor: Ruby 3.4 warns that `ostruct` will leave default gems in Ruby 4.0 - added `require "ostruct"` explicitly already; will add to Gemfile too to be clean.

17:20 - Caught my own bug: my bin/generate printed "wrote N file(s)" using generate!'s return value directly, but docs/generated_modules.md says generate! returns EVERY file the plan produces (not just changed ones) - GraphWeaver.changed_files is the actual "what got rewritten" subset. Fixed to use changed_files. Re-ran bin/generate a second time: "wrote 0 file(s)" - confirms the gem's determinism claim (same schema+query -> byte-identical, no spurious diff) and that I initially misread my own script's semantics, not a gem bug.

17:22 - Full suite (3 specs: fake, wire, cli) green across two rspec seeds. Real network smoke test of bin/capitals EU against the live countries.trevorblades.com API works and produces 52 country/capital lines; log/graph_weaver.log picked up the operation name + duration line.

17:24 - Ran a few targeted searches (rg -il) against docs/ for terms I would have typed if I hadn't just read every page top to bottom:
- "local test server" -> no hits (my own informal name for what :wire mode does via webmock; not gem terminology)
- "test server" -> no hits
- "log file" -> no hits (the instrumenter payload table exists but nothing spells out "write to a file" - I assembled it from the OpenTelemetry/Datadog ensure-block examples)
- "rack" -> hits only in testing.md (buried inside the actual :wire section, not called out as a Gemfile prerequisite in a "what you need" list up front) and federation.md. So the fix was findable by reading testing.md carefully, but nothing warns you rack is needed for :wire BEFORE you hit the runtime error - webmock + rack aren't listed together as a pair anywhere.
- "x-caller" -> hits in testing.md only (the one example line), nowhere else, e.g. not in transports.md's custom-header examples.

17:26 - Task complete. Final suite run green (3 examples, 0 failures, 2 seeds). bin/capitals works against real API. Writing up final report now.
