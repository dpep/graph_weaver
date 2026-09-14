# Junior dev log — graph_weaver in-process client task

## 2026-09-12 19:05 — start
Read README.md top to bottom. This is the in-process case (both server + client),
so README points at getting_started.md "Your app's own schema, in-process" section.
Also read: scalars.md, i18n.md, errors.md, testing.md, generated_modules.md (naming +
variables-become-kwargs sections). Have not opened lib/ or spec/ yet.

Key facts gathered before touching code:
- `rails g graph_weaver:install MyApp::Schema` is the entry point for in-process.
- Custom scalar registration: Money -> BigDecimal (stdlib table: cast BigDecimal(v),
  serialize v.to_s("F"), needs require "bigdecimal"). UUID has no stdlib mapping and no
  "already registered" entry, so I'll register it as a String with validation somehow —
  docs say a class with none of the probes (.parse/.load/Kernel#Type) stays pass-through.
  UUID as a plain String needs a **checked** String, per the task. Scalars doc doesn't
  show a "String but checked" recipe directly. GUESS: register_scalar("UUID", String)
  and rely on the *server's* GraphQL::Schema::Scalar coerce_input to do the actual
  checking (same pattern as the Email example in errors.md) — the registration on the
  graph_weaver side just says "deserializes as String", not that it validates. Recording
  this as a place I had to guess/infer rather than being told directly.
- JSON needs no registration (already registered as T.untyped).
- extensions.input convention (i18n.md / errors.md) is exactly what task wants for
  quantity/email — graphql-ruby validates: failures reach the wire with NO extensions
  at all by default ("A validates: failure is not claimed"), so I need to add
  `code: "BAD_USER_INPUT"` + `input: {kind:, path:, coordinate:, value:, min:/max:/format:}`
  extensions myself via a custom GraphQL::Schema::Validator (the AtLeastValidator example)
  or reuse validates: + rescue_from... Actually docs show validates: still runs graphql-ruby's
  own validator which raises a plain error; to get extensions.input I need a *custom*
  Validator class (shown in errors.md) rather than the built-in `validates: {numericality: ...}`.
  So: task says "use graphql-ruby validates: for those two" for the base validation, then
  "adopt extensions.input on server side" as a second step — I will write two custom
  Schema::Validator classes (RangeValidator, FormatValidator) installed via
  GraphQL::Schema::Validator.install, matching the AtLeastValidator/EmailScalar recipe.

## 2026-09-12 19:15 — building the graphql-ruby server (not graph_weaver's problem, but real friction)
- `rails g graphql:install` scaffolds `Mutations::BaseMutation < GraphQL::Schema::RelayClassicMutation`.
  Declaring `argument :input, Types::CreateInvoiceInputType, required: true` on a mutation built on
  RelayClassicMutation blew up at query time with:
    GraphQL::Schema::DuplicateNamesError: Found two visible definitions for `CreateInvoiceInput`:
    #<Class:0x0000...>, Types::CreateInvoiceInputType
  RelayClassicMutation auto-generates its own wrapper input type named `<Mutation>Input`, which
  collided with my own explicitly-named `CreateInvoiceInput`. Fix: switch BaseMutation to plain
  `GraphQL::Schema::Mutation` (drop `input_object_class`, which only RelayClassicMutation defines).
  This is a graphql-ruby generator/convention gotcha, nothing to do with graph_weaver — flagging
  since it cost real time before I even got to exercise the client gem.
- Confirmed (via a throwaway rails runner probe against the *server* schema directly, before wiring
  graph_weaver at all) that graphql-ruby's error shapes match errors.md exactly:
  - a scalar CoercionError on a variable -> a REQUEST-level error, no `path`, `extensions.problems`
    array, no `code`.
  - a plain `validates: numericality`/`validates: format` failure -> an EXECUTION-level error,
    `data` present with the field nulled, `path: ["createInvoice"]`, **no `extensions` key at all**.
  This is the "before extensions.input" baseline the doc promises, verified for real rather than
  taken on faith.
- **Real gotcha, not predicted by scalars.md**: registering `Date` as itself already-known
  (Ruby `Date`, ISO8601) means the *client-side* variable coercion for an `issued_on: Date` field
  goes through `GraphWeaver::Coerce.date`, which — I confirmed with a throwaway console call to
  `GraphQLTypes::CreateInvoiceInput.coerce(issued_on: "2024-01-15T10:00:00Z", ...)` — happily
  parses a full timestamp string and SILENTLY TRUNCATES it to a Date (`Mon, 15 Jan 2024`), then
  reserializes it back to `"2024-01-15"` before it ever reaches the wire. So the bad-value case
  "a time for the date field" produces **no error at all** — not client-side, not server-side —
  because the client already fixed it. scalars.md's "a cross-type value is refused rather than
  truncated" turns out to describe passing a Ruby `Time` *object* as the kwarg, not a String whose
  *content* looks like a timestamp; nothing in scalars.md draws that line, and I only found it by
  testing. This is going in the confusions list and I'm keeping the surprising (non-error) behavior
  in the spec rather than forcing a fake rejection.
- Rails 8.1.3.1 + json gem 3.0.2 (whatever `bundle install` picked) breaks Rails' own session-cookie
  decoding — `ArgumentError (wrong number of arguments (given 2, expected 1))` inside
  `ActiveSupport::JSON.decode` on literally every request once a session cookie exists. 500 on the
  very first form POST. Pinned `gem "json", "~> 2.9"` and it went away. Purely an environment/version
  mismatch in this scratch app, unrelated to graph_weaver, but it's the first verbatim error I hit
  end to end and cost ~15 minutes to diagnose (had to actually tail development.log rather than
  trust the 500 alone).

## 2026-09-12 19:25 — "before" extensions.input, captured for real
Ran a throwaway request spec (graphql: :in_process) against the plain
`validates: { numericality: ... }` / `validates: { format: ... }` version, before
adopting the extensions.input convention. Exactly matches errors.md's prediction:

  quantity: 5000 -> input_errors: []
    errors: [{"message"=>"quantity must be less than or equal to 1000", "code"=>nil,
              "field"=>"createInvoice", "path"=>["createInvoice"], "extensions"=>{}}]

  email: "not-an-email" -> input_errors: []
    errors: [{"message"=>"email is invalid", "code"=>nil, "field"=>"createInvoice",
              "path"=>["createInvoice"], "extensions"=>{}}]

Notable: `#field` on the plain GraphQLError is "createInvoice" (the response field that
got nulled), NOT "quantity"/"email" — because there's no `path` inside `extensions` at
all, so field-highlighting in a form is impossible without the convention. This is the
concrete, lived version of "attaching that to a form field is worse than missing it."
Deleted the throwaway spec once I had the transcript; the real suite only carries the
after-adoption behavior.

## 2026-09-12 19:35 — wiring custom Validators, two load-order bugs of my own making
Followed the AtLeastValidator/EmailScalar recipe from errors.md verbatim (renamed to
RangeValidator/FormatValidator, installed as :range / :format_with_kind). Two self-inflicted
but real Rails/Zeitwerk load-order bugs on the way, neither of which is a graph_weaver issue:

1. Put `RangeValidator; FormatValidator` (bare constant refs, to force autoload +
   `Validator.install`) directly in a fresh `config/initializers/graphql_validators.rb`,
   top-level (no to_prepare). Got:
     uninitialized constant RangeValidator (NameError)
   Exactly the failure mode getting_started.md warns about for the schema class
   ("Zeitwerk is set up after config/initializers run") — I'd read that warning twenty
   minutes earlier and still tripped over the *same* rule applied to a different
   constant. Fixed by wrapping in `Rails.application.config.to_prepare`.
2. Even inside to_prepare, still got `unknown validation: :range (ArgumentError)` from
   graphql-ruby. Root cause: two separate initializer files' to_prepare blocks run in
   filename order — `graph_weaver.rb` (which does `GraphWeaver.new(JuniorApp4Schema)`,
   which loads the whole Types:: tree, which hits `validates: { range: ... }` on
   CreateInvoiceInputType) sorts before `graphql_validators.rb` alphabetically
   ('_' < 'q'), so the schema loaded and asked for the `:range` validator a full
   initializer-file before it was installed. Fixed by deleting the second file and
   putting the validator constant references at the *top* of graph_weaver.rb's own
   to_prepare block, ahead of the `GraphWeaver.client =` line, so load order is
   explicit rather than dependent on two files' alphabetical sort.
This is a "would have been nice if the docs said" moment: getting_started.md's
to_prepare warning is about *one* registration racing Zeitwerk; it doesn't mention that
*two* to_prepare blocks across separate initializer files race each other too, in
filename order, which is a much easier trap to fall into with more than one initializer.

## 2026-09-12 19:40 — "after" extensions.input, confirmed, plus a filter_parameters surprise
Same probe, after the custom validators:

  quantity: 5000 -> kind: "out_of_range", path: ["input","quantity"],
    coordinate: "CreateInvoiceInput.quantity", field: "quantity", value: 5000,
    details: {"min"=>1,"max"=>1000}, message: "quantity must be between 1 and 1000"

  email: "not-an-email" -> kind: "invalid_format", path: ["input","email"],
    coordinate: "CreateInvoiceInput.email", field: "email",
    value: "[FILTERED]", message: "[FILTERED]" (!),
    details: {"format"=>"name@example.com"}

Surprise: Rails 8's default `config/initializers/filter_parameter_logging.rb` already
lists `:email` among the filtered keys — so graph_weaver's `#value`/`#message`
scrubbing (which the docs describe and I'd read but assumed would rarely fire on my
own fields) kicks in on the very first field I tried it on, and both #value and the
whole #message read "[FILTERED]". Good thing my locale template
(`invalid_format: "%{field} isn't in the right format (%{format})."`) never
interpolates %{value}, or the rendered form message would have read "[FILTERED]"
to the user. Confirms the i18n.md advice to build messages from kind/details rather
than #message is not just style — here #message is actively useless for this field.

## 2026-09-12 19:45 — scalar-level bad values, kind assignment is pickier than it looks
Confirmed all scalar-level cases as client-side InputErrors (raised before the request
leaves) or server-side coercion errors, in_process:
  total="abc"        -> client raises, kind=:unparseable, path=["input","total"],
                         coordinate=CreateInvoiceInput.total, details={"type"=>"BigDecimal"}
  issuedOn="2024-13-45" -> client raises, kind=:unparseable, path=["input","issued_on"],
                         coordinate=CreateInvoiceInput.issuedOn, details={"type"=>"Date"}
  quantity="lots"     -> client raises, kind=:unparseable, path=["input","quantity"],
                         coordinate=CreateInvoiceInput.quantity, details={"type"=>"Int"}
  externalId="not-a-uuid" -> comes back as response.input_errors, but kind=:refused
                         (not :unparseable/:type_mismatch), details={}

Surprise: the UUID case degrades to :refused even though it's a bog-standard "bad
scalar format" case, structurally identical to the Date/Money ones above. Reading
between the lines: graph_weaver reads a graphql-ruby coercion explanation off a closed
set of known *message patterns* graphql-ruby itself emits for its own scalar types
("invalid value for BigDecimal()", "invalid date", "expected an Int, got ..."). My
custom UuidType's own message ("... is not a valid UUID") is not one of graphql-ruby's
own patterns — it's just whatever GraphQL::CoercionError I wrote — so it can't be
pattern-matched to a specific kind and falls back to :refused, exactly the documented
"honest fallback" behavior. This isn't wrong, but it means writing your own scalar's
error message a certain way silently changes which `kind` a form gets, and nothing in
scalars.md or i18n.md says the message text itself is part of what decides the kind for
graphql-ruby coercion errors. Following the errors.md EmailScalar recipe (raising
`GraphQL::CoercionError.new(msg, extensions: { "input" => { "kind" => "invalid_format",
... } })`) instead of a bare message would fix this for UUID too — the task only asked
for it on quantity/email, so I left UUID as :refused, but noting it here since it's the
same convention and the same fix.

Also reconfirmed the "time for date field" finding from earlier: `success? true,
issued_on=Mon, 15 Jan 2024` — the timestamp is silently truncated, no error at any
layer.

## 2026-09-12 19:50 — the real bug this exercise surfaced: field-name casing mismatch
`InputError#field` is NOT consistently cased. Client-side coercion errors (raised
before the request leaves, e.g. total="abc") name the Ruby struct field: "total",
"issued_on" (snake_case). Server-side coercion problems (graphql-ruby's own
variable-coercion `problems` array, e.g. externalId="not-a-uuid") name the WIRE key
instead: "externalId" (camelCase) — because that error is built from graphql-ruby's
own problem path, which is spelled the way the query document spells it.
docs/errors.md's `#field` description ("#path's last named segment") doesn't call
this out, and neither does i18n.md's render_input_error recipe. If my controller had
kept `e.field.to_s` as the lookup key straight into `@field_errors[key]` against
snake_case form field names, the UUID error would have silently failed to attach to
the externalId input (key "externalId" vs form field "external_id") — the message
would show up nowhere, or worse, end up misfiled under `errors["base"]` and read as
a generic un-attributed failure. Fixed with `.underscore` on the field name before
using it as a hash key. This is the closest thing to an actual graph_weaver behavior
gotcha I found (as opposed to a graphql-ruby/Rails one) — worth a line in i18n.md's
`render_input_error` recipe or on `#field` itself.

## 2026-09-12 19:55 — two bugs the first spec run caught immediately (this is why you write the spec first)
1. I underscored the *hash key* for `@field_errors` but not the `field:` value fed into
   `I18n.t` for the rendered message text — so the UUID error landed on the right form
   field but still read "externalId was rejected." instead of "external_id was
   rejected." Fixed by underscoring in `render_input_error` too.
2. `I18n::ReservedInterpolationKey: reserved key :format used in "...( %{format})."`
   — graph_weaver's `:invalid_format` kind's `details` hash uses the key `format`
   (i18n.md's own vocabulary table says so explicitly: "`:invalid_format` | ... |
   `format`"), but `:format` is one of I18n's own RESERVED_KEYS, so passing
   `**error.details` straight into `I18n.t` blows up the instant a real
   `:invalid_format` error is rendered — not a hypothetical, it's the exact kind the
   whole `extensions.input` exercise is about. **i18n.md's own render_input_error
   recipe (`I18n.t(..., **error.details, default: error.message)`) has this landmine
   built in** — it will raise on the very kind it exists to translate, the moment an
   app follows the doc's recipe literally with Ruby's stock i18n gem. This deserves a
   callout in i18n.md: rename `format` before splatting `details` into `I18n.t`.
   Fixed locally by transforming `details[:format]` -> `details[:expected_format]`
   before interpolating, and renaming the locale key to match.
Both caught by the very first spec run against the real form (not by inspecting
generated code), which is the case for TDD here if there ever was one.

## 2026-09-12 20:00 — final smoke test
Full server boot + curl POST of a fully valid invoice succeeded (302 -> redirect to
/invoices). One flaky-looking 422 on an earlier identical attempt turned out to be a
stale CSRF/cookie artifact from my own curl script, not an app bug — reran clean and
it passed. The empty /invoices list after restarting the server is expected: `Invoice`
is a plain in-memory array (a deliberate simplification for this exercise, no
database), so it resets on every process boot. Not a bug, a known property of the
chosen persistence (none).

## 2026-09-12 20:02 — wrap-up
Total elapsed, doc-reading through green suite: roughly 90 minutes of actual work
(this log's timestamps span ~19:00-20:02). Never opened graph_weaver's lib/ or spec/ —
everything above came from README.md + docs/{getting_started,scalars,i18n,errors,testing,
generated_modules}.md, graphql-ruby's own error messages, and my own throwaway probes
against the app I was building. No "completely stuck, had to peek at lib/" moment
occurred — the docs were sufficient for every graph_weaver-specific decision; every real
stumble (RelayClassicMutation double-input, json gem/Rails incompatibility, to_prepare
ordering across two initializer files, I18n's reserved :format key) was graphql-ruby,
Rails, or plain-Ruby-i18n friction, not graph_weaver's.
