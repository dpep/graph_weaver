# Junior Dev Log - graph_weaver + countries API

## Step 1: Read README.md

Read the whole README top to bottom. Key things I noticed:
- Gem generates Ruby structs from .graphql files, checked with Sorbet.
- Rails setup: `rails g graph_weaver:install https://api.example.com/graphql`
- There's also a no-Rails console path: `GraphWeaver.new(url)` + `api.parse(...)`.
- Points me to docs/getting_started.md for the "production path in Rails, step by step" - that's what I need since I'm building a Rails app.
- Also mentions docs/testing.md for fakes/cassettes - I'll need that for the request spec.

Surprise: the gem doesn't require Rails at all really - it's a general graphql client with Rails glue on top. Good, that matches my task (a Rails app with a page).

Plan: follow docs/getting_started.md next.

## Step 2: Read docs/getting_started.md

Long doc, read it fully. Confusion #1: this is a LOT to take in for step "2. Run the generator" -
there's immediately a table of 3 source types, 2 flags, then a huge sub-section about
"more than one schema" that I don't need at all (I only have one schema: the countries API).
I had to skim past ~100 lines of "graphs" content that doesn't apply to me yet.

Confusion #2: `--auth` flag defaults to reading `GRAPHWEAVER_AUTH` env var - not relevant since
countries API needs no auth, but I had to read it to confirm I could just omit `--auth` entirely.
Doc doesn't explicitly say "no auth needed, omit the flag" - I inferred it.

Noted for later: section 4 "Test against fakes" says a fresh `rails g rspec:install` leaves
`spec/support` glob commented out - I will need to check for that in my app.

Plan:
1. rails new junior-app
2. add gem "graph_weaver", path: ...
3. bundle install
4. rails g graph_weaver:install https://countries.trevorblades.com/
5. write app/graphql/queries/countries.graphql
6. rake graph_weaver:generate
7. build controller + view
8. write request spec using graphql: :fake tag (per docs/testing.md, need to read that next for exact syntax against a real schema with real field names)

## Step 3: Build the app

Commands run:
  cd /tmp/claude/graph_weaver
  ~/.rvm/wrappers/ruby-3.4.9/rails new junior-app --minimal --skip-active-record --skip-test
  (added `gem "graph_weaver", path: "/Users/dpepper/code/lib/ruby/graph_weaver"` and `gem "rspec-rails"` to Gemfile)
  ~/.rvm/wrappers/ruby-3.4.9/bundle install
  ~/.rvm/wrappers/ruby-3.4.9/rails g graph_weaver:install https://countries.trevorblades.com/

Generator output (verbatim, matched docs exactly):
      create  config/initializers/graph_weaver.rb
      create  app/graphql/queries/.keep
      create  app/graphql/fragments/.keep
      create  app/graphql/generated/.keep
      create  graphql.config.yml
  introspect  app/graphql/schema.json from https://countries.trevorblades.com/

Surprise (good one): worked FIRST TRY, byte for byte matching what the doc said it would print.
No auth flag needed - I just omitted --auth entirely since countries API needs none. Docs never say
"omit for no auth" explicitly but it was the obvious inference.

Confusion #3: the docs never tell me what fields exist on the `Country` type - I had to peek at
the generated app/graphql/schema.json myself with a one-off ruby -e JSON.parse to find `capital`,
`name`, `code` field names. This is arguably fine (it's MY generated schema dump, not gem internals)
but the docs don't mention "you can/should inspect schema.json to see available fields" - I only
thought to do it because I vaguely remembered the countries API shape from JS work. A newcomer with
zero GraphQL knowledge of this specific API would be stuck here with no guidance from the gem's docs
on "how do I know what to query" beyond "write a query" - graphql.config.yml enables IDE autocomplete
per docs/editors.md but I'm not verifying that in an actual editor here.

Wrote app/graphql/queries/countries.graphql:
  query { countries { code name capital } }

Command:
  cd /tmp/claude/graph_weaver/junior-app
  ~/.rvm/wrappers/ruby-3.4.9/bundle exec rake graph_weaver:generate

Output: `wrote app/graphql/generated/countries_query.rb` - first try, no errors.

Read the generated file to learn the calling convention (module name = CountriesQuery, from
filename countries.graphql, per the doc's "naming" pointer). `CountriesQuery.execute!.countries`
returns an array of `Countries` structs with `.code`, `.name`, `.capital`. Everything matched what
getting_started.md promised in its person.graphql/PersonQuery example - good consistency, no surprise.

Built CountriesController#index (root route) + app/views/countries/index.html.erb, a plain HTML
table. Sanity-checked with `rails runner` first (successfully returned live Andorra/UAE/Afghanistan
data), then booted `rails server -p 3099` and curled `/` - got a real 200 with a populated table.
Page works end-to-end against the LIVE countries.trevorblades.com API, first try, no debugging needed.

This was the easiest part of the whole exercise so far - much easier than I expected for a typed
codegen tool. No manual struct-building, no manual HTTP client setup.

## Step 4: Read docs/testing.md

Long, dense doc but well organized - table up top telling me which mode to reach for was
genuinely useful ("most unit tests: :fake"). Decided to use `graphql: :fake` for the request spec,
since I just want to assert the page renders a table row per country - I don't need to hit the
real network in a spec (and definitely don't want a slow/flaky test depending on
countries.trevorblades.com being up).

Confusion #4: the doc has an important parenthetical buried mid-paragraph, easy to miss on a skim:
"(In Rails, put it **above** the `spec/support` glob in `rails_helper.rb` — rspec-rails requires
those partway through, and a support file mentioning `GraphWeaver::Testing` before this line dies
on `NameError`.)" - this is critical ordering info but it's a parenthetical aside, not a numbered
step or callout. I almost missed it on first read and had to re-read this section once I hit
config issues (see below).

Confusion #5: getting_started.md section 4 said "put the require in `spec/support/graph_weaver.rb`"
but testing.md says put `require "graph_weaver/rspec"` in `rails_helper.rb` ABOVE the support glob,
which contradicts using a spec/support file for the require itself (a support file's require
would run AFTER the glob line executes it, unless it's the exact line that IS the glob... actually
re-reading: the require has to be literally above the "Dir[...].each { |f| require f }" line in
rails_helper.rb - so putting it inside spec/support/graph_weaver.rb only works if that files's
requires happen to be required in time). getting_started.md's suggestion ("or put the require in
rails_helper.rb itself") is the safer one and the one testing.md's parenthetical actually demands.
I went with putting it directly in rails_helper.rb to avoid the footgun.

## Step 5: Write and run the request spec

Ran `rails g rspec:install` - confirmed the doc's warning first-hand: the generated
rails_helper.rb DOES leave `spec/support/**/*.rb` glob commented out, exactly as
docs/getting_started.md section 4 said it would. Good, doc was accurate.

Added `require 'graph_weaver/rspec'` directly to spec/rails_helper.rb, right after
`require 'rspec/rails'` (both are "above the support glob" since I didn't even
enable the glob - no support files needed for this small app).

Confusion #6 (resolved correctly, but took real thought): the `graphql_fake` pin key.
The query field is `countries` (plural), and the generated Ruby struct class is named
`Countries` (capitalized field name, per generated_modules.md's naming rule mentioned
in passing back in getting_started.md). But testing.md's pin examples use the GraphQL
*schema type name* as the key ("Product.name" pins on the `Product` type). The
countries API's schema type is `Country` (singular) even though the field returning
a list of them is `countries`. So the correct pin is `graphql_fake("Country" => {...})`
- NOT `"Countries"`, which is what I'd have guessed if I pattern-matched on the
generated class name I'd just been looking at instead of the actual schema type.
I only got this right because I re-checked the schema.json for the type name rather
than assuming the Ruby class name was the pin key. This is a real trap: the docs never
explicitly say "pin keys are schema type names, which may differ from the generated
class name for a list field" - it's implied by "keys are schema vocabulary" but a
newcomer skimming would very plausibly copy the class name they just saw generated.

Spec:
  spec/requests/countries_spec.rb
  RSpec.describe "Countries", type: :request do
    it "lists countries and their capitals", graphql: :fake do
      graphql_fake("Country" => { "name" => "Wakanda", "capital" => "Birnin Zana" })
      get "/"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Wakanda")
      expect(response.body).to include("Birnin Zana")
    end
  end

Command: cd /tmp/claude/graph_weaver/junior-app && bundle exec rspec spec/requests/countries_spec.rb
Result: PASSED first try - "1 example, 0 failures"

No network, no cassette, no live server needed for the spec - :fake mode fabricated
a schema-correct response for every OTHER field/country, and my pin overrode name/capital
on the first fabricated country. Confirmed no HTTP calls happen in this mode (didn't need
webmock/VCR at all, matching what testing.md promised).

## Wrap-up

Total elapsed effort: comfortably under an afternoon. Every command worked first try except
none actually failed - genuinely surprised by that, expected at least one red herring.
Never had to open anything under lib/ or spec/ in the gem repo - README -> getting_started.md
-> testing.md was a complete, sufficient path.

Full spec suite: `bundle exec rspec` -> "1 example, 0 failures", green.
