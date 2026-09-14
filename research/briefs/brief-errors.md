# Brief: input errors a program can act on, stable keys for i18n, and two header edges

Read /tmp/claude/graph_weaver/brief-common.md for toolchain, gate, trailers and method; baseline is main **e898484** (1268 examples, surface 452). Read CLAUDE.md ("Errors are part of the interface", "Refuse rather than guess"), `lib/graph_weaver/errors.rb` end to end, `lib/graph_weaver/coerce.rb`, `lib/graph_weaver/input_struct.rb`, `lib/graph_weaver/internal/redact.rb`, `docs/errors.md`, `docs/scalars.md` (the coercion sections), and how graphql-ruby reports argument problems (`GraphQL::Schema::Validator` errors, `extensions: { "code" => "argumentLiteralsIncompatible" … }`, `problems`, `argumentName`, `path`) — check the installed gem source with `find-gem graphql` or `bundle show graphql`. Worktree branch; don't push.

## Who you are

The platform expert who owns the external contract. A potential customer asked, in effect: *a user gives bad input to a GraphQL call — wrong type, right type but out of range, not an enum member, bad semantic format, invalid option — how does graph_weaver let me catch that and surface it programmatically, tied to the field that was wrong, in a standard shape? And how do I translate it?* Your job is a design the maintainer can say yes or no to in one read, plus the two small header changes below, implemented. If the honest answer to part of the question is "graph_weaver already does this and the docs don't say so", say that — docs are the deliverable there.

## Part 1 — assess, then propose (no implementation beyond docs unless it's a one-liner)

Map every way bad input surfaces today, with a running example for each:

- **Client-side, before the wire**: `InputError` from `Coerce` and `InputStruct` (a String where Int goes, a Boolean given a string, an enum given a non-member, a custom scalar whose cast raised, a nested input-object field three levels down). What does the error carry today — `field:`, `struct:`, the operation, the value (redacted?), a path? Is the path a stable coordinate (`$filter.range.min`) or prose? Is there a machine-readable *kind* (type mismatch vs unparseable vs refused) or only a message?
- **Server-side, after the wire**: `GraphQLError` with `code`, `path`, `extensions`. What does graphql-ruby actually put in extensions for argument validation failures (`problems`, `argumentName`, `explanation`)? For `validates:` rules (range, format, inclusion)? For a custom scalar's `coerce_input` raising `GraphQL::CoercionError`? For a required field missing in an input object? Run each against a scratch schema and record the JSON verbatim. What do Apollo Router / Federation and the spec say (`GRAPHQL_VALIDATION_FAILED`, `BAD_USER_INPUT`)?
- **What the customer can do today** with `Response#errors`, `field_errors`, `QueryError`, `ValidationError` — write the code they'd write. Where it needs message-string matching, that's the gap.

Then propose. The shape I expect, but argue with it: **one error surface for input problems regardless of where they were caught**, carrying a stable coordinate for the field (`operation` + `path` like `["filter","range","min"]`, plus the GraphQL type coordinate `RangeInput.min`), a stable machine key from a short closed vocabulary (something like `:type_mismatch`, `:unparseable`, `:out_of_range`, `:not_a_member`, `:missing`, `:invalid_format`, `:refused` — pick names, define each in one sentence, say which side can produce which), the offending value redacted through `filter_parameters`, the human message as today, and `to_h` for logging/API responses. Say whether client-side `InputError` and a server-side per-field error should be *one class* or two classes sharing a module — pick, with the reason. Say what graphql-ruby gives you for free and what needs a convention the server must follow (and how a server *not* following it degrades: to `:refused` with the raw message, never to a guess).

**i18n.** The minimum is stable keys: a key per error kind that a `t()` call can map, and the interpolation values (`field`, `type`, `value`, `min`/`max`, `members`) exposed as data, never baked into the message only. Propose the key scheme (e.g. `graph_weaver.input.not_a_member`), whether graph_weaver should ship a default `en` locale file for Rails I18n (I lean no — ship the keys and the data, document the mapping, let the app own the strings; argue if you disagree), and draft **`docs/i18n.md`**: one page, what's stable, what's data, a Rails `I18n` example, and the honest boundary (graph_weaver's own refusals and generation-time errors are for developers and stay English). Link it from docs/errors.md and the README's "Dig deeper" list.

Deliver Part 1 as `docs/errors.md` edits only where today's behavior is undocumented, the new `docs/i18n.md` as a draft clearly marked as describing the *proposed* keys (or, if you conclude the keys can be shipped without a breaking change and the change is small, ship them — your call, say which), and a design section in your report with the vocabulary table.

## Part 2 — implement (small, decided)

1. **Dynamic request headers on `Transport::HTTP`**: a header value may be a Proc, called per request with no arguments (`headers: { "Authorization" => -> { "Bearer #{Tokens.fetch}" } }`), the same way `schema:` and `context:` take a lambda. A proc returning nil omits the header. Faraday users keep Faraday's middleware — say so in `docs/transports.md`, one sentence, beside the existing sample. Spec with a spy server or WebMock (webmock is a dev dep).
2. **Case-insensitive response headers on `ServerError`**: `headers` is downcased at construction today, so `headers["Retry-After"]` misses. Make the lookup answer any casing without changing what `#headers` iterates or what `to_h`/logging show. Smallest honest shape (a tiny Hash subclass or `Rack::Utils::HeaderHash`-like wrapper under `Internal`); no new public names beyond what's needed. Spec: both spellings read the same value; iteration yields lowercase.

CHANGELOG: one contiguous block under a new `## Unreleased` heading (0.7.0 is cut). Public surface list updated in the same commit as any new name.

## Ownership

`lib/graph_weaver/errors.rb`, `lib/graph_weaver/coerce.rb`, `lib/graph_weaver/input_struct.rb`, `lib/graph_weaver/transport/http.rb`, `lib/graph_weaver/transport/faraday.rb`, `lib/graph_weaver/internal.rb` + new `internal/*.rb`, `spec/errors_spec.rb`, `spec/http_spec.rb`, `spec/builtin_coercion_spec.rb`, `spec/error_handling_spec.rb`, new specs, `docs/errors.md`, `docs/i18n.md`, `docs/transports.md`, `README.md` (the one list line), `CHANGELOG.md`, `spec/support/public_surface.txt`. A hunting agent is running read-only in parallel; nobody else edits.

## Gate

Brief-common gate as separate commands; two random seeds; `bin/round-trip -c 2000` if coercion changes.

## Report

Shas; Part 1 as a design the maintainer can answer yes/no to: the vocabulary table, the one-vs-two-classes call, what's free from graphql-ruby vs convention, the i18n key scheme and the locale-file call; what you shipped vs drafted; Part 2 messages/specs; `git status` clean.
