# Brief: InputError carries a kind, a path and a coordinate — and a server's rejection becomes one too

Baseline: main at the sha in your launch message (after the four hunt lanes merged). Read /tmp/claude/graph_weaver/brief-common.md for toolchain, gate, trailers and method; CLAUDE.md ("Errors are part of the interface", "Refuse rather than guess"); then the design the platform expert wrote — `docs/i18n.md` (banner-marked proposed) and the new "When the server rejects the input" section of `docs/errors.md` — and the measured JSON shapes in `/tmp/claude/graph_weaver/platform-client-errors.rb`. Read `lib/graph_weaver/errors.rb`, `coerce.rb`, `input_struct.rb`, `response.rb`, `internal/redact.rb`. Worktree branch; don't push.

## Who you are

The platform expert who owns the external contract, building the design the maintainer approved with one simplification: **no new class.** The maintainer's reasoning, which is now the rule: `Response#errors` already holds unraised `GraphQLError` values, so an unraised `InputError` in `Response#input_errors` has precedent; one class, zero new nouns. If some part of this can't be built without the second class, say why and stop on that part.

## The shape

```ruby
GraphWeaver::InputError            # raised client-side as today; ALSO the value a server rejection becomes
  #kind        Symbol, one of the eight below
  #path        Array of String|Integer rooted at the variable: ["where", "_and", 0, "_not", "species"]
  #coordinate  String, the schema's name for the slot: "PetFilter.species" (nil when unknowable)
  #field       String — the last element of #path (unchanged meaning for existing callers)
  #struct      unchanged
  #value       the rejected value, through filter_parameters; nil when never known
  #details     Hash — kind-specific facts: type:, members:, min:, max:, format:, suggestion:
  #message     the human sentence, as today
  #to_h        {"kind","path","coordinate","field","value","details","message"} — strings, JSON-safe

GraphWeaver::GraphQLError#input_error   # an InputError (not raised) or nil when the error isn't about input
GraphWeaver::Response#input_errors      # [InputError]; [] when none
GraphWeaver::QueryError#input_errors    # same, on the raised envelope
```

Kinds (closed vocabulary; `docs/i18n.md` has the table — keep it in sync):

| kind | meaning | details | client | server free | needs `extensions.input` |
|---|---|---|---|---|---|
| `:type_mismatch` | not the declared type, no conversion applies | `type` | ✓ | ✓ | |
| `:unparseable` | right kind of thing, text doesn't parse as that scalar | `type` | ✓ | ✓ | |
| `:not_a_member` | not an allowed enum/inclusion value | `members` | ✓ | ✓ | |
| `:missing` | required and absent or null | — | ✓ | ✓ | |
| `:unknown` | a key the input type doesn't define | `suggestion` | ✓ | ✓ | |
| `:out_of_range` | outside stated bounds | `min`, `max` | | | ✓ |
| `:invalid_format` | parses, right type, fails a stated rule | `format` | | | ✓ |
| `:refused` | rejected with only a message — the fallback | — | ✓ | ✓ | |

## Client side

`Coerce.variable` today **overwrites** a nested failure's `field:` with the variable name — that one line is why a form can't point at an input field. Replace it with path accumulation: each layer (`Coerce.variable`, `InputStruct.coerce`/`#serialize` per field, list element by index) prepends its segment, so the innermost failure ends with the full path and the outer layers only add to it. `kind` is assigned where the refusal happens: `Coerce.integer`/`float`/`id`/`string` → `:type_mismatch` or `:unparseable` (a String that doesn't parse is `:unparseable`; a Hash where an Int goes is `:type_mismatch`), `boolean` → `:type_mismatch`, enum → `:not_a_member` with `members`, an unknown input-object key → `:unknown` with the spellcheck `suggestion` (already computed somewhere — find it), a required field missing → `:missing`, a custom scalar's cast raising → `:unparseable` (`:refused` when the cast raised something that isn't `ArgumentError`/`TypeError`). `coordinate` comes from the generated code — the emitter knows `PetFilter.species` at every `InputStruct::Field`; thread it through so the runtime never has to reflect. `value` goes through `Internal::Redact` exactly as messages do today. Messages stay word-for-word the same unless a path makes one strictly better (then say so in the report).

## Server side

`GraphQLError#input_error` maps the two graphql-ruby shapes measured in the platform script and the convention:

1. `extensions.input` present (`{kind, path, coordinate, value, min, max, members, format, suggestion}`): take it verbatim after validating `kind` is in the vocabulary (an unknown kind → `:refused`, never a guess).
2. Variable-coercion shape (`extensions.value` + `extensions.problems[]` with `path` and `explanation`): one `InputError` per problem; `kind` from a small named table over `explanation` (`Could not coerce value … to Int` → `:unparseable`/`:type_mismatch` by whether the value is a String; `Expected … to be one of` → `:not_a_member`; `… is required` → `:missing`; `… is not defined on` → `:unknown`; else `:refused`). `path` is `[variable] + problem.path`.
3. Rule codes in `extensions.code` (`argumentLiteralsIncompatible`, `missingRequiredInputObjectAttribute`, `argumentNotAccepted`, `variableMismatch`) → the corresponding kind, path from `path`/`argumentName` where present.
4. `validates:` failures (execution error, no extensions) → `:refused` with `path` = the response path and `coordinate` nil. That is the honest floor; the docs say what a server adds to do better.

`Response#input_errors` = `errors.filter_map(&:input_error)`. Every mapping rule is a spec with the JSON verbatim from the platform script.

## Docs

- `docs/errors.md`: the accessor table, one client-side and one server-side example, and a **"What your server can send"** section: the `extensions.input` convention with a graphql-ruby `Validator` example that raises `GraphQL::ExecutionError.new(msg, extensions: { "code" => "BAD_USER_INPUT", "input" => {…} })` and a `GraphQL::CoercionError` example for a scalar — both run against a scratch schema and their JSON shown. Say plainly: without it, a range/format failure is `:refused` with the message; with it, `:out_of_range`/`:invalid_format` with `min`/`max`/`format` as data.
- `docs/i18n.md`: remove the "proposed" banner; replace `InputProblem` with `InputError`; keep the Rails `I18n` block runnable in shape.
- CHANGELOG `## Unreleased`: one bullet, additive (MINOR), saying what a user can now do.
- `spec/support/public_surface.txt`: the new accessors, same commit.

## Gate

Brief-common gate as separate commands; `bin/round-trip -c 2000` (coercion changed); two random seeds. The `spec/filtered_messages_spec.rb` redaction specs must still pass — `value` is a second place a secret could leak.

## Report

Shas; the accessor table as shipped; every kind with the spec that pins it, client and server; what `coordinate` is nil for and why; messages that changed; `git status` clean.
