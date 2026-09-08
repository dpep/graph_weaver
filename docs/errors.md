# Errors

Two generated names travel together, and they're close enough to trip on:

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

The envelope is a single generic `GraphWeaver::Response[Result]` — `response.data`
stays fully typed to *this* query's result, no per-query wrapper class.

Every `GraphQLError` exposes `#message`, `#locations`, `#path`, `#extensions`,
and `#code` (`extensions["code"]`) — match on the **code**, not the message
string (`response.errors.first.code == "THROTTLED"`).

Everything GraphWeaver *concludes* descends from `GraphWeaver::Error` — a
transport failure, a rejected query, a response that wouldn't cast, a plan the
[local router](federation.md) refused, a subgraph map that doesn't add up. The
subclass says where it failed:

| Class | When |
|-------|------|
| `TransportError` | never reached the server — DNS, connection refused, TLS, timeout |
| `ServerError` | reached it, non-2xx HTTP — `#status`, `#body`, `#headers`, `#retry_after`, `#throttled?` |
| `QueryError` | 200 body with top-level GraphQL errors — `#errors`, `#data`, `#extensions`, `#codes`, `#throttled?` |
| `TypeError` | the response wouldn't cast into the generated structs — `#struct`, `#cause` |
| `InputError` | the variables wouldn't build into the generated input structs — unknown/typo'd key, missing required field, out-of-range enum, wrong-typed field, wrong number of @oneOf fields — `#field`, `#struct` |
| `ValidationError` | build time: the query didn't validate against the schema |
| `Codegen::Aliases::UnknownSegment` | build time: an [`alias:`](generated_modules.md#flat-accessors-with-alias) path names a field no type here has — a typo, so `optional: true` won't skip it |
| `ConfigurationError` | setup judged against your schema — which Ruby schema serves which subgraph (`Testing::Router`, `federation:diff`) |
| `Testing::Unplannable` | the local test router won't plan this operation — `#category`, `#detail` |
| `Testing::MissingRecording` | a [cassette](cassettes.md) holds no entry for this request — the message prints the variables, and the ones it did record |

An argument that is wrong *on its face* raises a plain `ArgumentError` instead
(`pool_size: must be >= 1`, `cast: must be a Symbol, Proc, :itself, or nil`),
like any Ruby method — a bug at the call site, not a condition to rescue. The
line is whether the library had to read your schema to reach the verdict: it
did for `ConfigurationError`, which is why a spec helper can rescue that one.

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

`#throttled?` deliberately spells the same on both: an API may say "slow
down" with a 429 or with a `THROTTLED` error in a 200 body, and a caller
shouldn't have to know which. It recognizes the codes the big graphs
actually send (`GraphWeaver::GraphQLError::THROTTLE_CODES` — Shopify's
`THROTTLED`, GitHub's `RATE_LIMITED`, and friends); pass that constant to
`Retry`'s `retry_codes:` instead of hand-writing the strings.

Or skip the hand-rolling: [`Retry`](transports.md#retries) wraps any client and
already defaults to exactly the policy above — transport failures always,
`ServerError` on 5xx plus 408/429, and GraphQL error codes you name.

**Top-level scalar variables** fail like any Ruby method call, *outside* the
hierarchy on purpose — passing the wrong Ruby type for a scalar kwarg is a
programming bug, not caller input: a wrong-typed one raises sorbet-runtime's
`TypeError` ("Parameter 'page': Expected type T.nilable(Integer), got type
String"), a missing required one a plain `ArgumentError` ("missing keyword: :id").

**Input-object variables** are the caller-input case, so they're *inside* the
hierarchy. When you pass an input object as a hash (or struct) it's built
through the generated `coerce`, and anything wrong in there raises
`GraphWeaver::InputError` — one rescue point for turning invalid input into a
422:

```ruby
rescue GraphWeaver::InputError => e
  render json: e.to_h, status: :unprocessable_entity
  # { "error" => "GraphWeaver::InputError",
  #   "message" => "unknown key(s) for …Input: staus (did you mean 'status'?)",
  #   "field" => "staus", "struct" => "…Input" }
end
```

A nested filter reports the innermost input type, so the error points at the
input that actually held the bad field.

Business/validation failures returned *as data* (Shopify-style `userErrors { field
message code }`) aren't errors here — they're just fields you selected, so they
deserialize onto `response.data` like anything else and you inspect them there.

The one-shot `GraphWeaver.run` / `run!` mirror this: `run` returns
the envelope, `run!` the result-or-raise.

## Extending TransportError

What counts as a `TransportError` is an **extensible set** — each transport
seeds its own network exceptions (`Errno::*`, `SocketError`, timeouts, TLS; the
Faraday transport adds its own), and you can register more so a custom adapter's
or connection pool's failure gets the same treatment:

```ruby
GraphWeaver.register_transport_error(ConnectionPool::TimeoutError)
GraphWeaver.transport_errors << MyAdapter::ResetError   # it's just a Set
```


## Programmatic surfacing

Every error is dual-surface: `#message` for humans, `#to_h` for machines — a
JSON-ready hash (error class, per-error `path`/`code`/`locations`/`extensions`)
you can nest straight into a log line or an API response.

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

`GraphQLError#field` strips list indices (`people.3.email` → `people.email`) —
the stable grouping key; the raw `#path` keeps indices for exact location.

## Stale schemas

GraphQL has no schema-version signal, so a schema change surfaces as the
server rejecting your query's shape. `response.schema_stale?` /
`QueryError#schema_stale?` detect validation-shaped rejections (Apollo's
`GRAPHQL_VALIDATION_FAILED` code, or the message patterns graphql-ruby and
GitHub use), and the raised message says what to do: regenerate modules and/or
refresh the schema cache.

## Cast failures

When wire data disagrees with the types the schema promised at generation time
(a nil where non-null was declared, a malformed scalar, an unknown enum value),
casting raises `GraphWeaver::TypeError` naming the failing generated struct,
with the original exception as `#cause`. Simulate one in tests with
`GraphWeaver::Testing::FakeClient.new(schema:, corrupt: "Person.birthday")` — see
[testing](testing.md).
