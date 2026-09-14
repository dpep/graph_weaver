# Junior dev log — graph_weaver + PokeAPI search page

16:50 Starting. Task: build Pokemon search page in new Rails app using graph_weaver gem, reading only README + docs/.

## 16:51 Read README.md
- Key facts: `rails g graph_weaver:install <url>` sets up initializer + app/graphql layout.
- `rake graph_weaver:generate` compiles .graphql -> Ruby. Dev server auto-regenerates.
- Testing: `require "graph_weaver/rspec"`, tag `graphql: :fake` for fakes, `:in_process`/`:router`/`:wire` for real clients, cassettes mentioned for record/replay.
- Errors doc exists: docs/errors.md - "Response envelope, error hierarchy, field-level reports". This is likely where the bad-limit handling comes from — but limit is a *variable*, so maybe docs/i18n.md ("Translating input errors ... bad input, on either side of the wire") is more relevant.
- Custom scalars doc: docs/scalars.md.
- Plan: read getting_started.md next to scaffold the app, then testing.md, errors.md, i18n.md, scalars.md, cassettes.md as needed.

## 16:53 Read docs/getting_started.md
- Plan: `gem "graph_weaver"`, then `rails g graph_weaver:install <url>` -> writes initializer, app/graphql/{queries,fragments,generated}, graphql.config.yml, schema.json.
- Write .graphql query file, `rake graph_weaver:generate`.
- Test: `require "graph_weaver/rspec"` in spec/support, tag `graphql: :fake`.
- Note: PokeAPI url is https://beta.pokeapi.co/graphql/v1beta, public, no auth -> omit --auth flag.
- Nothing in getting_started.md about bad-limit/input validation errors — need docs/errors.md and docs/i18n.md.
- Nothing about custom scalars beyond registering; will check docs/scalars.md once I know what scalar the query touches.

## 16:52 App scaffolded
- `rails new junior-app-2 --minimal --skip-active-record` - fine, no DB needed.
- Added `gem "graph_weaver", path: "..."` and `gem "rspec-rails"` to Gemfile, `bundle install` — fast, no issues.
- `rails g rspec:install` — standard.
- `rails g graph_weaver:install https://beta.pokeapi.co/graphql/v1beta` — introspection completed in under a minute (schema.json ended up 5.7MB / large — thousands of Hasura-generated types for PokeAPI's aggregate/bool_exp/order_by machinery per table). Much faster than the task description implied ("may take a while").
- Peeked at app/graphql/schema.json directly (this is documented in getting_started.md as "the whole schema as plain JSON, already in your repo" — so treating this as fair game, not "opening lib/").
- Found: `pokemon_v2_pokemon` query root field takes `where: pokemon_v2_pokemon_bool_exp`, `limit: Int` (nullable scalar Int, no special validation type — Hasura leaves limit validation to the DB/server, not the schema).
- Found custom scalar `jsonb` (used by e.g. `pokemon_v2_pokemonsprites.sprites`). Only custom scalar besides Int/String/Boolean/Float. Plan: include a sprites field to justify registering it, per docs/scalars.md.

## 16:53 Read docs/errors.md
- `execute!` raises `GraphWeaver::QueryError` on top-level GraphQL errors (200 w/ errors); `execute` returns envelope w/ `.errors`, `.input_errors`.
- Client-side: passing a top-level scalar variable that "won't convert" raises `GraphWeaver::InputError` before the request leaves — exact example given: `execute(count: "lots")` => `$count of Compute: expected an Int, got "lots"`. This is my "lots" case exactly — client-side rescue.
- `InputError` has `#kind`, `#path`, `#coordinate`, `#value`, `#details`, `#field`, `#struct`. `#field` = path's last named segment = the form field to highlight. This is what the task wants me to use to name the field.
- Server-side input errors: `response.input_errors` / `QueryError#input_errors` re-reads *ordinary* GraphQLErrors into InputError **only when the server's error matches a known shape** — graphql-ruby's coercion-failure shape, or a code in `GraphWeaver::GraphQLError::INPUT_CODES` (Apollo's BAD_USER_INPUT + 4 graphql-ruby rule names). Docs explicitly warn: "Nothing here is portable" and "a server that follows none of this degrades; it does not guess."
- PokeAPI is Hasura, not graphql-ruby/Apollo — tested live against the real endpoint (curl) to see what it actually sends for limit=-5 and limit="lots":
  - limit="lots" (string in a declared $limit:Int slot): "expected a non-negative 32-bit integer for type 'Int', but found a string", extensions.code = "validation-failed", extensions.path = "$.selectionSet.pokemon_v2_pokemon.args.limit" (a JSON-pointer-ish STRING, not an array).
  - limit=-5 (real negative int): "expected a non-negative 32-bit integer for type 'Int', but found a number", same code/path shape.
  - Neither "validation-failed" is in graph_weaver's known INPUT_CODES list, so response.input_errors will almost certainly come back [] for both — confirmed this is a real gap, not just theoretical, by reading the code list in docs (BAD_USER_INPUT, argumentLiteralsIncompatible, variableMismatch, missingRequiredInputObjectAttribute, argumentNotAccepted) vs Hasura's "validation-failed".
- CONFUSION #1 candidate: docs promise "one rescue point" (`input_errors`) unifies client + server input errors, but that unification is opt-in per-server (needs graphql-ruby or Apollo-shaped codes). Against a real third-party API (Hasura) it silently returns [] and you're back to reading response.errors by hand. The docs do say this ("nothing here is portable") but it's easy to skim past given how confidently `input_errors` is pitched earlier in the doc.
- Decision: since -5 never reaches graph_weaver's InputError machinery (it's a valid Int, sent to server, server-shape unrecognized), I'll build the friendly message myself for that path: catch GraphWeaver::QueryError, try #input_errors first (future-proof / correct per docs), and fall back to inspecting response.errors' message/extensions myself, naming "limit" since that's the only variable in the query.

## 16:55 Read docs/i18n.md and docs/scalars.md
- i18n.md confirms exactly what I need for "lots": kind vocabulary (:type_mismatch, :unparseable, etc.), and gives a ready `render_input_error` helper pattern + a paste-able en.yml. Will use `error.field`/`error.kind`/`error.details` — not raw #message — per the doc's own advice.
- i18n.md also explicitly documents the -5 gap: ":out_of_range and :invalid_format ... cannot be produced from either side without the server convention" and "for any server that isn't graphql-ruby, the server states it under extensions.input" — Hasura doesn't, confirming my finding above is expected/documented behavior, not a gem bug.
- scalars.md: `jsonb` is not one of the pre-registered names (ID/String/Int/Float/Boolean/Date*/DateTime*/BigInt/JSON). Since Hasura's jsonb is arbitrary JSON, registering it like the built-in `JSON` scalar: `GraphWeaver.register_scalar("jsonb", "T.untyped")`. Confirmed pattern from docs: "A scalar that is *meant* to be untyped belongs in the registry too — GraphWeaver.register_scalar(\"Json\", \"T.untyped\")".
- Also learned: query-string params are always Strings, and `execute(first: params[:first])` auto-coerces "5" -> 5 via the going-out table; only a genuinely unparseable string like "lots" raises InputError. This matters for the controller: I should NOT pre-cast params[:limit].to_i myself (to_i turns "lots" into 0, silently swallowing the bad input!) — pass the raw param string through to execute and let graph_weaver's coercion raise for me. CONFUSION avoided by reading closely, but easy trap for someone using to_i out of habit.

## 16:57 First two specs written & run
- Wrote controller (app/controllers/pokemon_controller.rb), view, routes, en.yml with the paste-able locale block from i18n.md, spec/support/graph_weaver.rb with `require "graph_weaver/rspec"`, and uncommented the spec/support glob in rails_helper.rb (getting_started.md's own warning: "Nothing warns you that a support file went unread" — true, would have silently no-opped without that note).
- Ran `bundle exec rspec spec/requests/pokemon_search_spec.rb`:
  - fake-pinned-name spec: GREEN first try. Pin key had to be the literal schema type name `pokemon_v2_pokemon` (snake_case, Hasura's actual GraphQL type name), not a guessed PascalCase Ruby class name — matches testing.md's explicit warning ("schema vocabulary, not Ruby").
  - bad-limit spec: FAILED first try — not a graph_weaver problem, an HTML-escaping one: my expectation string had a literal apostrophe but Rails auto-escapes the rendered `isn't` to `isn&#39;t`. Fixed by matching the escaped string. Minor, not a doc gap, but worth noting as a "why isn't this easier" moment since the underlying friendly message worked exactly as documented on the FIRST try:
    - Verbatim message produced: `limit isn't a valid Int.`
    - This is InputError#kind == :unparseable, i18n.md's own template applied: "%{field} isn't a valid %{type}." with field="limit", type="Int" — confirms the InputError#kind/#field/#details plumbing works exactly as docs describe, no network call involved (client-side coercion catches "lots" before dispatch).
- Now re-running to confirm green, then building the -5 case and the cassette spec.

## 16:59 Cassette spec, first attempt: anonymization ate the assertion
- Followed cassettes.md exactly: `GraphWeaver::Testing.cassette("pokemon_search", client: GraphWeaver.client)`, first run auto-recorded `spec/cassettes/pokemon_search.yml` against the real PokeAPI.
- Had `config.anonymize = true` set globally in spec/support/graph_weaver.rb (copied straight from the docs' anonymization section since it read as "the responsible default"). Result: FAILED — real pokemon names got rewritten to "name-1", "name-3", etc, and jsonb sprites blobs became "jsonb-2" etc, because anonymization (per its own doc table) replaces every plain String, not just PII-looking ones — it can't tell "pikachu" (a public dataset value) from a real user's email.
- CONFUSION #2 candidate: the docs pitch anonymize as the responsible default for any cassette ("since recordings hold real data"), but for a fully public, non-sensitive API (PokeAPI names are the product, not PII) it silently defeats the entire point of a cassette test that pins specific real values — the table (which strings get replaced) is documented, but there's no explicit guidance on "skip this for a public API," so I had to infer it and re-record.
- Fix: removed `config.anonymize = true` (this app touches no sensitive data — no PII, no tokens, PokeAPI is a public reference dataset), deleted the anonymized cassette, and re-recorded plain.

## 17:00 All specs green
- Added a 4th spec (3rd spec type wasn't strictly required per-scenario, but wanted actual coverage of the -5/server-rejection code path, not just the client-side "lots" path) using `GraphWeaver::Testing::Failure.graphql(msg)` to simulate PokeAPI's real server-side rejection without depending on PokeAPI's exact wording staying stable. Passed first try.
- Full suite: `bundle exec rspec` -> 4 examples, 0 failures.
  - spec/requests/pokemon_search_spec.rb: "lists matching pokemon" -> mode: graphql: :fake (pinned name)
  - spec/requests/pokemon_search_spec.rb: "shows a friendly message for a limit that isn't a number" -> mode: graphql: :fake (though the InputError path never even dispatches to a client, so mode doesn't matter here — tagged :fake defensively)
  - spec/requests/pokemon_search_spec.rb: "shows a friendly message when the server itself rejects the limit" -> mode: untagged/:live, but client replaced by GraphWeaver::Testing::Failure.graphql(...) directly (simulated failure, no network)
  - spec/queries/pokemon_search_query_spec.rb: "matches real PokeAPI pikachu-family results from a recorded cassette" -> mode: cassette (GraphWeaver::Testing.cassette against GraphWeaver.client), recorded once against the real live PokeAPI, replayed from spec/cassettes/pokemon_search.yml thereafter.

## 17:00 Manual end-to-end smoke test against the REAL live PokeAPI (not a doc requirement, but wanted to see it for real before calling it done)
- Booted `rails server -p 3099` and curled:
  - `?name=pika&limit=5` -> real pikachu family list, works.
  - `?name=pika&limit=lots` -> `<p class="error">limit isn't a valid Int.</p>` — no 500.
  - `?name=pika&limit=-5` -> `<p class="error">Limit: expected a non-negative 32-bit integer for type 'Int', but found a number</p>` — no 500.
- First error message ever seen in this whole session, verbatim (the very first exception/error output at all, from the curl probe against the raw PokeAPI endpoint before any Rails code was written): `{"errors":[{"message":"unbound variable \"limit_dummy\"","extensions":{"path":"$","code":"validation-failed"}}]}` — that was my own curl typo (a stray leftover variable reference), not a graph_weaver or PokeAPI bug; fixed immediately in the next curl.

## 17:02 Confirmed exact exception shapes via `rails runner` (only place I stepped outside pure docs-reading, to get exact values for the final report)
- "lots": GraphWeaver::InputError, message `$limit of PokemonSearchQuery: expected an Int, got "lots"`, kind=:unparseable, path=["limit"], field="limit", coordinate=nil, value="lots", details={type: "Int"}.
- "-5": GraphWeaver::QueryError, message `GraphQL query failed: expected a non-negative 32-bit integer for type 'Int', but found a number [validation-failed]`, input_errors=[] (confirmed empty, as predicted from reading errors.md/i18n.md), underlying GraphQLError: message "expected a non-negative 32-bit integer for type 'Int', but found a number", code="validation-failed", path=nil, extensions={"path"=>"$.selectionSet.pokemon_v2_pokemon.args.limit", "code"=>"validation-failed"}.

## 17:02 Done. Total wall time from a cold start (never seen this gem) to a working app + 4 green specs: ~12 minutes.
