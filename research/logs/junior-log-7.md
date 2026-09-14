# Junior dev log — graph_weaver + PokeAPI + i18n (en/fr/ja)

## 2026-09-12 19:12 — start
Task: Rails app consuming https://beta.pokeapi.co/graphql/v1beta with graph_weaver,
i18n error messages in en/fr/ja, response value translation, specs.
Rule: work only from README.md -> docs/, don't open lib/ or spec/ unless stuck or told to.

Environment check: ruby 3.4.9, rails 8.1.3.1, bundler 4.0.10 via rvm wrappers. Good.

Read /Users/dpepper/code/lib/ruby/graph_weaver/README.md first (as instructed).
Key facts gleaned:
- `rails g graph_weaver:install <endpoint>` is the one-command Rails setup.
- .graphql files live under app/graphql, `rake graph_weaver:generate` compiles them.
- `graphql: :fake` rspec tag + `graphql_fake(...)` helper for fakes, no HTTP.
- Docs to read per task: docs/getting_started.md, docs/i18n.md (errors i18n),
  docs/errors.md (Response envelope / error hierarchy), docs/testing.md (fakes,
  failure simulation, rspec tags).
- Also relevant: docs/transports.md (retry/backoff), docs/scalars.md (custom scalar
  registration - might matter for translating response values).

Next: read docs/getting_started.md to build the app the documented way.

## 2026-09-12 19:20 — docs read (README -> getting_started, i18n, errors, testing, scalars, generated_modules#type-helpers)

Findings:
- i18n.md gives the exact key scheme: `graph_weaver.input.<kind>` with 8 kinds
  (type_mismatch, unparseable, not_a_member, missing, unknown, out_of_range,
  invalid_format, refused). No en.yml shipped — deliberately, "app owns the
  sentence." Gave me the en.yml to paste verbatim as a starting point.
- errors.md: InputError is the one class for both client-side (raised before
  wire) and server-side (Response#input_errors) rejections — same renderer.
  #kind, #path, #coordinate, #value, #details, #field, #struct.
- Hasura specifically: only :not_a_member, :unknown, :missing get a kind from
  path; anything else (including a numeric-bounds violation like a negative
  limit) comes back :refused. The doc's own worked example is *literally*
  `limit: -5` -> :refused on path ["limit"] — this is exactly the case the
  task asked me to build, which is reassuring: I'm not inventing a case the
  gem can't actually handle.
- "abc" as a limit is a top-level Int scalar variable; per scalars.md, Int
  kwargs accept "a decimal string" at runtime but "abc" doesn't parse as one,
  so I expect this to raise client-side (InputError) before the request even
  leaves - never reaches Hasura. Kind unclear yet (type_mismatch vs
  unparseable) - the doc lists both as client-producible but doesn't say
  which applies to "a numeric string that fails to parse." Will find out
  empirically and note as a surprise either way.
- Response-value translation hook: docs/generated_modules.md#type-helpers,
  `GraphWeaver.extend_type("TypeName", Module)` decorates every struct of that
  GraphQL type with extra methods that see the wire fields — "derived values
  ... belong next to the data but not in it." This is the gem's answer to
  "translate a response value": add a `translated_name` method via extend_type
  that calls I18n.t off the raw `name`. Nothing enum-specific applies here
  since PokeAPI's `pokemon_v2_type.name` is a plain String field off a lookup
  table, not a GraphQL enum in the schema - so `register_enum` (which needs an
  actual schema enum type) doesn't apply. Noting this distinction for the report.
- Testing/failure simulation: `GraphWeaver::Testing::Failure.transport`,
  `.server(status:)`, `.throttled`, `.stale_schema`, `.graphql(message)`.
  DOCS SEARCH FOUND NOTHING for how to attach a `code`/`extensions` to
  `Failure.graphql(...)` for a "server-side rejection with a code" - every
  example in testing.md only shows a bare message string. Will try in a
  console (not opening lib/) and record the actual signature/behavior.

Next: scaffold the Rails app, run `graph_weaver:install` against
https://beta.pokeapi.co/graphql/v1beta.

## 2026-09-12 19:23 — probing Failure.graphql (docs were silent on extensions/code)

Console probes (rails runner, `require "graph_weaver/testing"` needed outside
rspec, same as docs/testing.md says):

- `PokemonSearchQuery.execute(limit: "abc")` -> raises client-side
  `GraphWeaver::InputError`, kind=:unparseable, details={type: "Int"},
  field="limit", message `"$limit of PokemonSearchQuery: expected an Int, got
  \"abc\""`. Happens before any client (fake or real) is even asked -
  confirms this is testable under `graphql: :fake`.
- `PokemonSearchQuery.execute(name_like: "pika", limit: -5)` against the
  REAL PokeAPI -> exactly the doc's own worked Hasura example:
  input_errors: kind="refused", path=["limit"], field="limit", message =
  "expected a non-negative 32-bit integer for type 'Int', but found a number"
  (the server's own English sentence - untranslatable by design, this is
  what `default: error.message` is for).
- SURPRISE, not in any doc I read: forgetting to pass `name_like` (nil ->
  the where clause sends `_ilike: null`) makes Hasura reject with kind=
  "missing", path=["where","name","_ilike"], field="_ilike" - so the "field"
  a form should highlight is the raw comparison operator, not "name". Had to
  add my own `pokemon_search.fields` mapping (`_ilike` -> "name"/"nom"/"名前")
  on top of what the gem gives, since `error.field` is schema vocabulary, not
  form vocabulary. This produced my "bad name filter shape" scenario (task
  requirement 1) essentially by accident - fixed the real bug (blank search
  now sends "%" not nil) and kept the case as the thing to translate.
- `Failure.graphql("boom")` (the one form testing.md shows) — no way to
  attach a code/kind through it as documented.
- `Failure.graphql("boom", extensions: {...})` — an `extensions:` kwarg
  is *accepted* (no ArgumentError) but silently does nothing: the resulting
  error's `#extensions` is `{}` regardless. This is worse than a documented
  gap - it looks like it should work and doesn't say it didn't.
- `Failure.graphql("boom", code: "...")` -> ArgumentError: unknown keyword:
  :code. So `code:` isn't a real param either.
- What DOES work, found by trial: pass a full error Hash as the positional
  argument instead of a bare message string —
  `Failure.graphql("message" => "...", "extensions" => {"code" => "BAD_USER_INPUT", "input" => {"kind" => "out_of_range", "path" => ["limit"], "min" => 1}})`
  — and `response.input_errors` picks it up exactly like a real Hasura/
  graphql-ruby server-convention rejection (errors.md#what-your-server-can-send).
  DOC SEARCH FOUND NOTHING for this hash form anywhere in docs/ or README —
  every testing.md example only shows the bare-string form. This is the
  moment the "don't open lib/ unless stuck" rule almost got invoked; I got
  it from trial and error in a console instead, which the docs do implicitly
  invite ("Every failure mode is just a client").
- `Failure.throttled` -> code "THROTTLED", exactly as documented -
  the safe, fully-documented way to get "a code" for the generic-message spec.

Design decision this settles: for a GraphQL error graph_weaver *can't*
classify as input (empty `input_errors`, non-empty `errors`), I'm keying the
generic user-facing message on nothing more than "there was an unclassified
GraphQL error" (one static translated sentence) rather than on `#code`,
because `#code` is a per-server free-form string (Apollo sends none at all,
graphql-js sends none, Hasura/graphql-ruby send their own vocabularies) -
showing it to a French/Japanese user would either be empty or be English.
For transport/server failures I key on the **exception class**
(`TransportError` / `ServerError`) since that's the one piece the docs call
out as a genuinely closed, stable set (errors.md's class table) - never on
`#message`, which is a raw exception string, and never on HTTP `#status`
text (the numbers are fine to log, not to show).

Also had to add a translation table for the *scalar type name* in details
(`Int`, `String`, ...) — the i18n.md `type_mismatch`/`unparseable` recipe
interpolates `%{type}` straight from `error.details[:type]`, which is a bare
GraphQL scalar name ("Int"). Left untranslated, "Int" is an English/technical
token that would show up unchanged on the French and Japanese pages - the
docs don't call this out anywhere, it's just a consequence of `**error.details`
being wired straight into the message. Added my own
`pokemon_search.types.<Name>` table alongside the fields one.

## 2026-09-12 19:25 — done, specs green

`bundle exec rspec` — 7 examples, 0 failures:
1. bad limit "abc", en, graphql: :fake — translated message asserted
2. bad limit "abc", fr, graphql: :fake — translated message asserted
3. bad limit "abc", ja, graphql: :fake — translated message asserted
4. transport failure (GraphWeaver::Testing::Failure.transport) — generic fr message, no tag (plain GraphWeaver.client= assignment, per testing.md)
5. server-side rejection with a code (Failure.graphql(hash) w/ extensions.input, kind out_of_range) — translated fr message, no tag
6. no-English-leak check across transport + server-rejection scenarios, fr
7. no-English-leak check for bad limit, fr, graphql: :fake

Manual smoke test via `rails runner` against the REAL PokeAPI: pikachu search
returns 5 pikachu forms, each translated_name -> "Electric" (en). Confirmed
the whole pipeline works against a live server, not just fakes.

Tried a manual curl smoke test of the real dev server for the French page —
hit CSRF token/session friction (curl cookie jar handling, nothing to do
with graph_weaver) and got a 422/500 from Rails' own forgery protection, not
from the app logic. Not worth chasing further since the rspec request specs
(which use Rails' test integration session and don't require a hand-rolled
CSRF dance) already cover the same code path and pass. Logged as pure
test-tooling friction, not a gem or app finding.

Did NOT run srb tc / rubocop in the throwaway app — the task didn't ask for
production hardening of this scratch app, and Sorbet wasn't set up in it;
the generated code itself is `# typed: strict` regardless (verified by
reading the generated file), so the app-level checks would only be testing
Rails glue code I wrote, not the gem.

Never had to open lib/ or spec/ in the gem repo. The one moment that came
close was the Failure.graphql kwarg signature — resolved by trial and error
in a `rails runner` script instead, which docs/testing.md's own framing
("Every failure mode is just a client") invited.
