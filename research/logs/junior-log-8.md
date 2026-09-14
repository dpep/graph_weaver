# Junior dev log — graph_weaver 0.6.1 -> 0.7.0 upgrade

2026-09-12 19:30:43 - starting: checked ruby/rails/bundle versions (ruby 3.4.9, Rails 8.1.3.1, bundler 4.0.10). Read docs/getting_started.md, docs/testing.md, docs/errors.md, docs/scalars.md at v0.6.1, plus current docs/upgrading.md and CHANGELOG.md v0.7.0 entry, before touching the app.

2026-09-12 19:32:56 - built Rails 8.1.3.1 app at /tmp/claude/graph_weaver/junior-app-8 with `rails new --minimal -T`. Added `gem "graph_weaver", git: "...", tag: "v0.6.1"` and rspec-rails. `bundle install` succeeded cleanly (79 gems).
2026-09-12 19:32:56 - ran `rails g graph_weaver:install https://countries.trevorblades.com/`. Worked first try, introspected the live schema, wrote initializer + app/graphql/{queries,fragments,generated}/.keep + graphql.config.yml + schema.json. Noted: the initializer unconditionally wrote `auth: ENV["GRAPHWEAVER_AUTH"]` even though no --auth flag was given and the API needs no token — this is exactly what the 0.7.0 changelog says it fixed ("no longer wires auth you didn't ask for").
2026-09-12 19:32:56 - enabled the commented-out example line from the initializer for real: `GraphWeaver.register_scalar("DateTime", Time, serialize: :iso8601, requires: "time")`. The countries schema declares no DateTime scalar, so this is a no-op registration (docs say an unmatched name only warns, doesn't fail) — no warning appeared.
2026-09-12 19:32:56 - wrote app/graphql/queries/country.graphql (`query($code: ID!) { country(code: $code) { code name capital } }`) and app/graphql/queries/continents.graphql (`continents { code name countries { name capital } }`). `rake graph_weaver:generate` wrote country_query.rb and continents_query.rb with no errors.
2026-09-12 19:32:56 - `rails g rspec:install` confirmed 0.6.1's testing.md claim verbatim: the fresh rails_helper.rb ships the spec/support glob commented out. Put `require "graph_weaver/rspec"` directly into rails_helper.rb (above nothing else needed it) rather than uncommenting the glob, per the doc's alternative.
2026-09-12 19:32:56 - wrote spec/queries_spec.rb with the four specs the task asked for: (1) graphql: :fake with a graphql_fake("Country.name" => "Wakanda") override, (2) graphql: false hitting the real live API for code "US" (expects "United States"), (3) rescuing GraphWeaver::TypeError from CountryQuery.from_response with a response missing the required "name" field, (4) GraphWeaver::InputError#field == "code" for `CountryQuery.execute!(code: { bad: "shape" })`.
2026-09-12 19:32:56 - `bundle exec rspec`: 4 examples, 0 failures, first try. No debugging needed for the 0.6.1 baseline.
2026-09-12 19:33:01 - baseline committed: git sha 5c46d6c. Starting upgrade to 0.7.0. Per task instructions, will follow ONLY docs/upgrading.md and CHANGELOG.md's v0.7.0 entry from here, not opening lib/ or spec/ in the gem repo unless stuck.
2026-09-12 19:33:14 - bundle install: graph_weaver 0.6.1 -> 0.7.0, clean, no dependency conflicts.
2026-09-12 19:33:14 - guide step: 'grep -rn "GraphWeaver::TypeError|GraphWeaver::ValidationError" app lib spec'
2026-09-12 19:33:21 - grep 1 found 5 hits in generated/*.rb (expected to be fixed by regenerate) plus 2 hits in my own spec/queries_spec.rb (GraphWeaver::TypeError used in a rescue-equivalent matcher) — that one needs a manual rename to GraphWeaver::CastError since it's app code, not generated.
2026-09-12 19:33:21 - guide step: grep -rn "graph_weaver.execute" app lib config spec
2026-09-12 19:33:26 - guide step: rake graph_weaver:generate
2026-09-12 19:33:33 - per the Renames table, manually renamed GraphWeaver::TypeError -> GraphWeaver::CastError in spec/queries_spec.rb (the one hand-written hit grep found).
2026-09-12 19:33:44 - guide step: bundle exec rspec

2026-09-12 19:33:52 - FIRST FAILURE. `bundle exec rspec` failed 1/4: the "hits the real countries API" spec tagged `graphql: false`. Verbatim error:
```
GraphWeaver::Error:
  graphql: false is not a mode — :live, :fake, :in_process, :router, :wire. :live leaves GraphWeaver.client exactly as it is, which is how one example steps back out of config.default_mode.
```
This is the guide's #1 documented rename (Renames table: `graphql: false` -> `graphql: :live`), so no digging needed — the error message itself names the fix. Guide coverage: YES, exact.
2026-09-12 19:34:06 - all three guide commands (two greps + rake generate) done, plus 'bundle exec rspec' now green (4/4) after the graphql: :live rename. No sorbet/ dir in this app (the install generator doesn't set up Sorbet), so srb tc isn't part of this app's own upgrade path — noted as an aside, not a guide step.
2026-09-12 19:34:47 - the guide's top section (not 0.6.1-specific) calls rake graph_weaver:verify 'the detector' for whether the checked-in Ruby matches what this version emits, so ran it as a sensible follow-up to generate:

2026-09-12 19:35:09 - final `bundle exec rspec`: 4 examples, 0 failures. `rake graph_weaver:verify` confirms tree is up to date.
2026-09-12 19:35:09 - Observed but not a failure: log/test.log now shows a line "GraphWeaver CountryQuery (238.9ms) ok" for the :live example that wasn't there in the 0.6.1 baseline log — exactly the new auto-instrumentation the guide's "Behavior that changed under you" section warned about. Cost nothing, changed no assertion, verified only by reading the log file.
2026-09-12 19:35:09 - git diff --stat after the whole upgrade:
```
 Gemfile                                   |  2 +-
 Gemfile.lock                              |  8 +++-----
 app/graphql/generated/continents_query.rb | 13 ++++++++-----
 app/graphql/generated/country_query.rb    | 10 ++++++----
 spec/queries_spec.rb                      |  6 +++---
 5 files changed, 21 insertions(+), 18 deletions(-)
```
Total hand-edits required: 1 line in Gemfile (git: tag -> path, done by the task itself, not the guide), 1 rename in spec/queries_spec.rb (GraphWeaver::TypeError -> CastError, guide's Renames table), 1 rename in spec/queries_spec.rb (graphql: false -> graphql: :live, guide's Renames table, discovered via the one and only test failure). Everything else (Gemfile.lock, both generated files) was mechanical: bundle install and rake graph_weaver:generate.
2026-09-12 19:35:09 - never had to open lib/ or spec/ in the gem repo during the upgrade itself — the two doc files (upgrading.md, CHANGELOG.md) plus the test failure's own error message were sufficient.
