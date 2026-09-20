# Errors

What comes back when something goes wrong, and what to rescue. Read it when you
write the first `rescue` around a query, or when you need to tell "the network
broke" apart from "the server said no" apart from "the response didn't fit".

Two names travel together here, and they're close enough to trip on:

- **`Result`** — the struct holding *this* query's data, e.g. `PersonQuery::Result`.
- **`Response`** — the **envelope** around it, `GraphWeaver::Response[Result]`,
  carrying `data`, `errors` and `extensions`.

`execute` returns the envelope rather than raising on GraphQL errors, so partial
data and top-level `extensions` (cost, throttle) survive. `execute!` is the
shortcut to the result:

```ruby
PersonQuery.execute!(id: "1")   # => Result, or raises QueryError  (== execute(...).data!)

response = PersonQuery.execute(id: "1")   # => GraphWeaver::Response[Result]
response.data           # T.nilable(Result) — typed, present even on partial success
response.errors         # Array[GraphWeaver::GraphQLError]
response.errors?        # any top-level errors?
response.success?       # the same question the other way round
response.extensions     # { "cost" => … } — rides on success too
response.data!          # the Result, or raise GraphWeaver::QueryError
```

**`execute!` raises whenever `errors` is non-empty** — partial data included, so a
mutation that created the order and then failed on the way out still raises, with
the data hanging off `QueryError#data`. Reach for `execute` when a partial answer
is one you can use.

Every `GraphQLError` exposes `#message`, `#locations`, `#path`, `#extensions`, and
`#code` (`extensions["code"]`) — match on the **code**, not the message string
(`response.errors.first.code == "THROTTLED"`).

## The three you'll meet first

**A variable that won't convert** raises `GraphWeaver::InputError` before the
request leaves — top-level scalars, input-object fields, at any depth. One rescue
point turns invalid input into a 422:

```ruby
rescue GraphWeaver::InputError => e
  render json: e.to_h, status: :unprocessable_entity
  # { "error" => "GraphWeaver::InputError",
  #   "message" => "$input of AdoptMutation: species: \"LIZARD\" is not a valid " \
  #                "GraphQLTypes::Species — expected one of: CAT, DOG",
  #   "kind" => "not_a_member", "path" => ["input", "species"],
  #   "coordinate" => "AdoptionInput.species", "field" => "species",
  #   "value" => "LIZARD", "details" => { "members" => ["CAT", "DOG"] },
  #   "struct" => "GraphQLTypes::AdoptionInput" }
end
```

**The server rejecting the input** arrives as ordinary `GraphQLError`s, and
`#input_errors` reads the ones that are about your input back into the same
`InputError` — so one renderer serves both halves:

```ruby
response = AdoptMutation.execute(input: params[:pet])

response.input_errors   # [GraphWeaver::InputError] — [] when none
response.errors         # still every error, input or not
```

**Everything else is a class to rescue.** The network broke, the server answered
non-2xx, or it answered 200 and complained:

```ruby
begin
  person = PersonQuery.execute!(id: "1").person
rescue GraphWeaver::TransportError
  retry                                   # network blip
rescue GraphWeaver::ServerError => e
  e.throttled? || e.status >= 500 ? backoff : raise  # a plain 4xx is our bug
rescue GraphWeaver::QueryError => e
  e.throttled? ? backoff : raise          # the same question, asked of the errors array
end
```

**Which arm catches a failure is the server's choice**, not a rule you can rely
on: an origin server answers 429 with no body and you get a `ServerError`, while
Apollo Router answers the same rate limit with `503` *and* a GraphQL errors body,
so it arrives as a `QueryError` — as do its 500s, 401s and 403s. So don't put the
retry decision in the `ServerError` arm: hand it to
[`Retry`](transports.md#retries), which asks the same question of both.
`#throttled?` spells the same on both for the same reason, and knows the codes the
big graphs send (`GraphWeaver::GraphQLError::THROTTLE_CODES` — Shopify's
`THROTTLED`, GitHub's `RATE_LIMITED`, Apollo Router's `REQUEST_RATE_LIMITED`).

## The classes

Everything GraphWeaver *concludes* descends from `GraphWeaver::Error` — a
transport failure, a rejected query, a response that wouldn't cast, a plan the
[local router](federation.md) refused, a subgraph map that doesn't add up. The
subclass says where it failed:

| Class | When |
|-------|------|
| `TransportError` | no response came back — DNS, connection refused, TLS, timeout, a socket that died mid-body — `#url`, `#cause` |
| `ServerError` | reached it, non-2xx HTTP — `#status`, `#body`, `#headers`, `#retry_after`, `#throttled?`, `#url` |
| `QueryError` | a body with top-level GraphQL errors, whatever its status — `#errors`, `#data`, `#extensions`, `#codes`, `#throttled?` |
| `CastError` | the response wouldn't cast into the generated structs — `#struct`, `#cause` |
| `InputError` | the variables wouldn't build into the generated input structs — unknown/typo'd key, missing required field, out-of-range enum, wrong-typed field, wrong number of @oneOf fields — `#kind`, `#path`, `#coordinate`, `#value`, `#details`, `#field`, `#struct` |
| `QueryValidationError` | build time: the query didn't validate against the schema |
| `Codegen::Aliases::UnknownSegment` | build time: an [`alias:`](generated_modules.md#flat-accessors-with-alias) path names a field no type here has — a typo, so `optional: true` won't skip it |
| `ConfigurationError` | setup judged against your schema — which Ruby schema serves which subgraph (`Testing::Router`, `federation:diff`) |
| `Testing::Unplannable` | the local test router won't plan this operation — `#category`, `#detail` |
| `Testing::MissingRecording` | a [cassette](cassettes.md) holds no entry for this request — the message prints the variables, and the ones it did record |

An argument that is wrong *on its face* raises a plain `ArgumentError` instead
(`pool_size: must be >= 1`), like any Ruby method — a bug at the call site, not a
condition to rescue. The line is whether the library had to read your schema to
reach the verdict: it did for `ConfigurationError`, which is why a spec helper can
rescue that one. A *missing* required kwarg is Ruby's own `ArgumentError` too
("missing keyword: :id").

**A status with an obvious next step says it.** A 3xx appends "redirects are not
followed" and the `Location` to repoint the client at — replaying a POST, with its
`Authorization` header, at a host the server named isn't the library's call. A 401
or 403 appends "check `auth:` — the token, and its scopes". Both name the endpoint,
in the message and on `#url`, with credentials
[folded to `[FILTERED]`](logging.md#filtered-variables) first.

**A partial answer only survives as far as the nearest nullable field.** That is
GraphQL's null propagation, not this client, and the conventional Relay payload is
exactly where it bites: given `ChargePayload { order: Order!, receiptUrl: String! }`,
a resolver that raises on `receiptUrl` *after the order was charged* nulls
`receiptUrl`, which is non-null, so the null climbs to the payload and on to the
root — `response.data` and `QueryError#data` are both `nil`, and the order you just
created is nowhere in the response. Making the **payload field** nullable doesn't
help: the null stops at `{"charge" => nil}` and the order was inside it. Two things
do — make the field *that can fail* nullable (`receiptUrl: String`), which leaves
`order` on `data` beside the error; or accept that the write's outcome is not in
the response and read the order back.

Business/validation failures returned *as data* (Shopify-style
`userErrors { field message code }`) aren't errors here — they're fields you
selected, so they deserialize onto `response.data` like anything else.

## Input errors

`InputError` is raised for anything you pass to `execute` that won't convert,
including a top-level scalar variable. The message names the variable and the
operation, since the value alone locates nothing in an app that runs a hundred
queries:

```
$count of Compute: expected an Int, got "lots"
```

The value is usually the whole diagnosis, so it is quoted — unless the key it
arrived under is one your `filter_parameters` covers, in which case the message
reads `$password of Login: [FILTERED]`, and a filtered key *inside* the value is
covered at any depth ([logging](logging.md#filtered-variables)).

`to_h` (above) carries only the keys that have something to say, so a key is
**absent** rather than `null` — `"value"` is missing both when the value was never
known and when it was null, and `"kind"` tells those apart. Read it with
`hash["value"]`, not `hash.key?("value")`.

**A JSON controller underscores on the way in.** Generated input structs take the
prop spelling, so a camelCase request body makes *every* key an unknown one —
`params.deep_transform_keys(&:underscore)` before `execute`. `details[:suggestion]`
is how you tell that from a typo: a casing problem hands the same key back in
snake_case (`customerEmail` → "did you mean 'customer_email'?"), a real typo
suggests a different field.

A nested filter reports the innermost input type, so the error points at the input
that actually held the bad field; passing something that is neither — a bare
`String` where the input goes — reports the same way. A call site that *spells* the
wrong type is caught earlier and better, by `srb tc`
([why](generated_modules.md#variables-become-typed-kwargs)). And once a boundary
of your own between that call site and `execute` carries a sig, sorbet-runtime
checks the value there first: the caller sees a plain `TypeError`, and none of
the structured, translatable detail below ever reaches it.

The one-shot `GraphWeaver.run` / `run!` mirror `execute` / `execute!`.

### What an InputError says, without reading English

`#message` is the developer's line and it will be reworded. Everything a form or
an API response needs is beside it, as data:

| | |
|---|---|
| `#kind` | one of eight Symbols — `GraphWeaver::InputError::KINDS`. The key an app translates; [i18n](i18n.md) has the table of what each means |
| `#path` | the route from the variable down, Strings and list indices: `["where", "_and", 0, "_not", "species"]`. Every named segment is the **schema's** spelling — see [which spelling](#which-spelling-a-path-is-in) |
| `#coordinate` | the [schema coordinate](https://github.com/graphql/graphql-spec/pull/794) for the slot — `"PetFilter.species"`. `nil` when there isn't one |
| `#value` | the rejected value, through [`filter_parameters`](logging.md#filtered-variables), and always JSON-representable (a non-finite Float travels as `"NaN"`/`"Infinity"`). `nil` when it was never known — a missing field has none, and an unknown key owns no slot to hold one |
| `#details` | kind-specific facts, never pre-formatted — `{ members: ["CAT", "DOG"] }`, `{ type: "Int" }`, `{ suggestion: "species" }`. `type` is the **schema's** name for the type (`Money`, `AdoptionInput`), never the Ruby class it maps to |
| `#field` | `#path`'s last *named* segment — the one field a form highlights. A trailing list index is a position, not a field, so `["ids", 2]` is still `"ids"` |
| `#struct` | the input type being built — the generated struct *class* where generation produced one, and the GraphQL type *name* where it didn't (a federation representation builds a plain Hash). `to_h`'s `"struct"` is the name either way |

So a form reads `e.field` and either `e.message` or — better — its own sentence
built from `e.kind` and `e.details`.

**When the leaf isn't a field.** A Hasura-shaped filter puts a comparison operator
at the bottom, so `where: { height: { _gte: "abc" } }` refuses with `#path`
`["where", "height", "_gte"]` and `#field` `"_gte"` — right by the rule, and
useless to a form. Key the form on `#path` there: the column is the segment before
the operator.

**Long values are cut.** An error is built for whatever a caller sent and whatever
a server echoed back, either of which can be megabytes, and every raised one writes
a `warn` line. So each String `#value` holds (at every depth), the value `#message`
quotes, and a sentence a server wrote are capped at
`GraphWeaver::InputError::VALUE_LIMIT` — 1024 bytes, with `…(N more bytes)` in
place of the rest.

#### Which spelling a path is in

**`#path`, `#field` and `#coordinate` are the schema's spelling** (`issuedOn`,
`externalId`) — one rule, whichever side refused. A server can produce no other,
and the client knows both, so this is the only spelling both halves can agree on:
a form keyed on `e.field` finds the same slot for a refusal raised before the
request left and for one the server sent back.

The **prop** (`issued_on`) is what you type in Ruby — `.new`, `.coerce`, the kwargs
of `execute` — and it is `#message`, the developer's line, that names it. In a
Rails form the field names are the props, so underscore on the way in — and give
the nil case a home, because **`#field` is `nil` whenever nothing named a slot**:

```ruby
form.errors.add(e.field&.underscore || :base, render_input_error(e))
```

The one segment that is neither is an **unknown key** — a typo names no field, so
the schema has no spelling for it. It comes back exactly as you wrote it, and
`details[:suggestion]` is the prop to type instead.

**`#path` is rooted at the variable**, so its first segment is the kwarg you passed
and its last is the field that actually held the value:

| you called | `#path` | `#coordinate` |
|---|---|---|
| `execute(input: {name: "Rex", species: "LIZARD"})` | `["input", "species"]` | `"AdoptionInput.species"` |
| `execute(input: {issued_on: "x", external_id: "lots"})` — a camelCase field | `["input", "externalId"]` — the schema's spelling | `"InvoiceInput.externalId"` |
| `execute(where: {_and: [{_not: {species: "LIZARD"}}]})` | `["where", "_and", 0, "_not", "species"]` | `"PetFilter.species"` |
| `execute(ids: [1, 2, "x"])` — a list of leaves | `["ids", 2]` | `nil` — a list element is a position, not a slot |
| `AdoptionInput.coerce(name: "Rex", speceis: "DOG")` — no variable to name | `["speceis"]` — a typo names no field, so it is echoed as written | `nil` — the type defines no such field |
| `execute(count: "lots")` — a top-level scalar | `["count"]` | `nil` — a variable names no schema element |

`#coordinate` is `nil` wherever the schema has no name for the slot: a variable, a
key the input type doesn't define, a nested `@key` path in a federation
representation, or a server that didn't say which type it meant.

### When the *server* rejects the input

**Nothing here is portable.** The GraphQL spec reserves `extensions` for
implementors and defines no codes at all, so "this error is about the input you
sent" is a convention each server invents — or doesn't. graph_weaver reads the
three it knows by name, and claims nothing from the rest:

| server | what marks an error as being about the input | what you get |
|---|---|---|
| **graphql-ruby** | the variable-coercion `problems` array, or one of four rule names in `extensions.code` (`GraphWeaver::GraphQLError::INPUT_CODES`) | the field, and a `kind` read off a closed table of its explanations |
| **Apollo** | `extensions.code` = `BAD_USER_INPUT` (Apollo Router's `VALIDATION_INVALID_TYPE_VARIABLE` is not read; graphql-js sends no `extensions` at all) | `:refused` with the server's sentence, and the field only where `argumentName` is stated |
| **Hasura** | `extensions.path` naming an argument — `"$.selectionSet.<field>.args.<name>"` — under `validation-failed` or `parse-failed` | the field; `:not_a_member`, `:unknown` or `:missing` for the three sentences it always writes, `:refused` otherwise |
| **anything else** | nothing | `#input_errors` is `[]` — see [the fallback](#when-your-server-marks-nothing) |

`QueryError#input_errors` asks the same question of the raised envelope, and
`GraphQLError#input_errors` of one error. It is **plural on every one of them**: a
single variable-coercion error routinely carries several problems about different
fields, and keeping only the first would lose the rest silently. These are values,
not raises — building one writes no log line. `#message` and `#value` go through
`filter_parameters` here exactly as they do on the client side: a server quotes the
value it rejected as a matter of course (`Could not coerce value "hunter2" to
Int`), and that is a message about a key your list covers.

Generated modules always send **variables**, never literals, which narrows a
graphql-ruby server to two shapes (measured against 2.6.10):

| the server's rejection | what arrives | `#input_errors` |
|---|---|---|
| the variable didn't coerce — wrong type, not an enum member, a required field null, a key the input type doesn't define, a custom scalar's `GraphQL::CoercionError` | a **request** error: no `data` key at all, one error with no `path`, and `extensions` = `{"value" => «the whole variable», "problems" => [{"path" => ["level2","count"], "explanation" => "Could not coerce value \"nope\" to Int"}]}` — but **no `code`** | one per problem, `kind` from a table over `explanation`, `path` = `[variable, *problem.path]` |
| a `validates:` rule failed — range, format, inclusion, length | an **execution** error: `response.data` is present with the field nulled (so `success?` is false on a response that still carries data), `path` is the **response** path (`["adopt"]` — the field, not the input field), and there is **no `extensions` key at all** | **nothing** — see below |

**A `validates:` failure is not claimed.** With no `extensions` at all it is
indistinguishable from "the database is down", and attaching *that* to a form field
is worse than missing it — so it stays an ordinary error in `response.errors`. One
line on the server fixes it, and [the next section](#what-your-server-can-send) is
that line.

**Hasura is read off the path, not a code.** `validation-failed` is the code it
sends for a query that doesn't parse *and* for a value it won't take, so the code
alone would attach your own `.graphql` file to a form field. The argument in
`extensions.path` is what settles it, and only three of its sentences earn a
`kind`: `limit: -5` comes back `:refused`, because the sentence Hasura writes for
it ("expected a non-negative 32-bit integer for type 'Int', but found a number")
is the same one it writes for `limit: "lots"`. The field is worth having; the guess
isn't. And the commonest real Hasura input mistake isn't read at all: a `where:`
value that Hasura's comparison type accepts but the underlying Postgres column
rejects (`{ id: { _eq: "abc" } }` on a `uuid`) gets past validation and fails at
the database, arriving as `data-exception` at path `"$"` with no argument named.

#### When your server marks nothing

Then `#input_errors` is `[]` and says so — which is the signal to render what the
server *did* send, not to parse its prose:

```ruby
response = AdoptMutation.execute(input: params[:pet])

if response.input_errors.any?
  response.input_errors.each { |e| form.errors.add(e.field&.underscore || :base, e.message) }
elsif response.errors.any?
  # nothing claimed to be about the input: show what was said, and log the
  # rest — #extensions is where a server you're onboarding states its own
  # convention, and the next section is how to make it one this reads
  flash[:alert] = response.errors.map(&:message).join(", ")
  Rails.logger.warn(response.report)
end
```

### What your server can send

Two of the eight kinds — `:out_of_range` and `:invalid_format`, the everyday
"right type, wrong value" — **cannot be produced from either side on their own.**
The client doesn't know the schema's bounds, and graphql-ruby puts a `validates:`
failure on the wire as a bare sentence. Only the server can say it, so there is one
key to say it under:

```json
"extensions": {
  "code": "BAD_USER_INPUT",
  "input": {
    "kind": "out_of_range",
    "path": ["input", "min"],
    "coordinate": "RangeInput.min",
    "value": 0,
    "min": 1
  }
}
```

`code` is the ecosystem's coarse bucket, so a client that has never heard of
graph_weaver still understands; `input` is the fine one. Only `kind` is required,
and it must come from [the table](i18n.md#the-vocabulary) — an unrecognized one
degrades to `:refused` rather than being passed through, and any key outside
`type`/`members`/`min`/`max`/`pattern`/`suggestion` is dropped rather than reaching
`#details`. None of those six is a name I18n reserves for itself, so
`I18n.t(key, **details)` can never raise on the splat.

`path` must be an **Array of field names and list indices**. A dotted String, or a
segment that is neither, is dropped whole rather than parsed — and nothing stands
in for it: `#path` is `[]` and `#field` is `nil`. In particular the GraphQL error's
own `path` is never borrowed, because it names a *selection* (`["createOrder"]`)
rather than an input slot, and a form that trusted `#field` there would highlight a
field called `create_order`. Everything else the server did state still stands.

In graphql-ruby it rides on two raises. A `GraphQL::Schema::Validator` raising
`GraphQL::ExecutionError` covers a `validates:` rule, with `validated` giving you
the argument's own name and owner for the `path` and `coordinate`:

```ruby
raise GraphQL::ExecutionError.new(
  "#{validated.graphql_name} must be at least #{@min}",
  extensions: { "code" => "BAD_USER_INPUT", "input" => {
    "kind" => "out_of_range", "path" => ["input", validated.graphql_name],
    "coordinate" => "#{validated.owner.graphql_name}.#{validated.graphql_name}",
    "value" => value, "min" => @min,
  } },
)
```

A custom scalar's `coerce_input` does the same with `GraphQL::CoercionError`
(`extensions: { "input" => { "kind" => "invalid_format", "pattern" => … } }`),
whose extensions arrive nested under `problems[i].extensions`.

The client then reads `{ "kind" => "out_of_range", "path" => ["input", "min"],
"coordinate" => "RangeInput.min", "field" => "min", "value" => 0, "details" =>
{ "min" => 1 }, "message" => "min must be at least 1" }` — a number your form can
compare against, where without the convention that range failure is `:refused` at
best, and only if the server stamped `BAD_USER_INPUT`. A server that follows none
of this degrades; it does not guess.

**You author that `path`, and a validator on a field cannot know its list index.**
`Validator#validate(object, context, value)` is handed the argument *definition*
(`validated`, shared by every element), the value, and a context whose
`current_path` is the **response** path — graphql-ruby coerces a list with a plain
`map` and keeps no index (measured against 2.6.10). Install the validator above on
a `qty` inside `lines: [LineInput!]!` and it writes `["input", "qty"]` for every
element alike, so a 200-line order can't say which line was wrong. Where the index
matters, install the validator on the **list argument** instead: `value` is then the
whole coerced Array, so you index it yourself and write
`["input", "lines", index, "qty"]`. Per-element validators run first, so by then
every element is fully coerced.

**One problem per call.** `#input_errors` is plural, but neither side collects the
way `ActiveModel::Errors` does: `coerce` raises on the first field whose value
won't convert, and graphql-ruby aborts variable validation at the first
`GraphQL::ExecutionError` a `validates:` rule raises, across the whole input tree.
The two cases the client does gather are the ones it can see without walking
further — **unknown keys** and **absent required fields** are listed in full in the
message (`missing required key(s) for AdoptionInput: name, species`), though
`#path` names only the first, because a path that points at two fields points at
neither. So build the form expecting to iterate. The exception is a graphql-ruby
**coercion** failure, which carries a `problems` array and really does report
several fields at once.

## Extending TransportError

What counts as a `TransportError` is an **extensible set** — each transport seeds
its own network exceptions (`Errno::*`, `SocketError`, timeouts, TLS; the Faraday
transport adds its own), and you can register more so a custom adapter's or
connection pool's failure gets the same treatment:

```ruby
GraphWeaver.register_transport_error(ConnectionPool::TimeoutError)
GraphWeaver.transport_errors << MyAdapter::ResetError   # it's just a Set
```

## Programmatic surfacing

Every error is dual-surface: `#message` for humans, `#to_h` for machines — a
JSON-ready hash (error class, per-error `path`/`code`/`locations`/`extensions`) you
can nest straight into a log line or an API response.

Field-level tooling lives on both `Response` and `QueryError`:

```ruby
response.errors_at("person.email")      # errors touching a path (prefix match)
response.each_error do |field, errors|  # grouped by index-stripped field
  form.add_error(field, errors.map(&:message))
end

response.report
# { "person.pets.name" => {
#     "messages" => ["name hidden"], "codes" => ["PRIVATE"],
#     "entity_ids" => ["7", "9"],    # resolved by walking paths through partial data
#     "errors" => [ ...full to_h detail... ] },
#   nil => { "codes" => ["DOWN"], ... } }   # global errors under nil
```

`GraphQLError#field` strips list indices (`people.3.email` → `people.email`) — the
stable grouping key; the raw `#path` keeps indices for exact location.

`Response#to_h` decomposes the envelope the same way, with each error as its
JSON-ready hash. `data` stays the typed struct, deliberately: `T::Struct#serialize`
would give snake_case keys where the wire is camelCase, drop null fields, and leave
a registered scalar as the Ruby object its codec built — output that would look
like the server's response without being one.

## Stale schemas

GraphQL has no schema-version signal, so a schema change surfaces as the server
rejecting your query's shape. `response.schema_stale?` / `QueryError#schema_stale?`
detect validation-shaped rejections (Apollo's `GRAPHQL_VALIDATION_FAILED` code, or
the message patterns graphql-ruby and GitHub use), and the raised message says what
to do: regenerate modules and/or refresh the schema cache.

## Cast failures

When wire data disagrees with the types the schema promised at generation time (a
nil where non-null was declared, a malformed scalar, an unknown enum value),
casting raises `GraphWeaver::CastError` naming the failing generated struct, with
the original exception as `#cause`.

A cast's own complaint is about the value and nothing else — "invalid date" locates
nothing on a struct holding four of them — so a casting leaf also carries **its
response key**, and three failures that keep happening say whose bug it is rather
than leaving you sorbet's words:

| what came back | what the message adds |
|---|---|
| an `ID` the server sent unquoted | GraphQL serializes `ID` as a JSON string, so this is the server out of spec — plus how to take it anyway (`register_scalar("ID", "T.untyped")`) |
| an enum value the generated enum doesn't hold | the values it does hold, and that drift is the likely cause: regenerate, or `register_enum(fallback:)` to absorb them |
| a field the server nulled **with a reason** | the server's own explanation, rather than only sorbet's nil complaint |

Simulate one in tests with
`GraphWeaver::Testing::FakeClient.new(schema:, corrupt: "Person.birthday")` — see
[testing](testing.md).
