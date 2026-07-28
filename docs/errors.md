# Errors

`execute` returns a typed **`Response` envelope** rather than raising on GraphQL
errors — so partial data and top-level `extensions` (cost, throttle) survive.
`execute!` is the shortcut when you just want the result:

```ruby
PersonQuery.execute!(id: "1")   # => Result, or raises QueryError  (== execute(...).data!)

response = PersonQuery.execute(id: "1")   # => GraphWeaver::Response[Result]
response.data           # T.nilable(Result) — typed, present even on partial success
response.errors         # Array[GraphWeaver::GraphQLError]
response.errors?        # any top-level errors?
response.extensions     # { "cost" => … } — rides on success too
response.data!          # the Result, or raise GraphWeaver::QueryError
```

The envelope is a single generic `GraphWeaver::Response[Result]` — `response.data`
stays fully typed to *this* query's result, no per-query wrapper class.

Every `GraphQLError` exposes `#message`, `#locations`, `#path`, `#extensions`,
and `#code` (`extensions["code"]`) — match on the **code**, not the message
string (`response.errors.first.code == "THROTTLED"`).

Everything GraphWeaver raises descends from `GraphWeaver::Error`, split by where
it failed:

| Class | When |
|-------|------|
| `TransportError` | never reached the server — DNS, connection refused, TLS, timeout |
| `ServerError` | reached it, non-2xx HTTP — `#status`, `#body` |
| `QueryError` | 200 body with top-level GraphQL errors — `#errors`, `#data`, `#extensions`, `#codes` |
| `TypeError` | the response wouldn't cast into the generated structs — `#struct`, `#cause` |
| `InputError` | the variables wouldn't build into the generated input structs — unknown/typo'd key, missing required field, out-of-range enum, wrong-typed field — `#field`, `#struct` |
| `ValidationError` | build time: the query didn't validate against the schema |

```ruby
begin
  person = PersonQuery.execute!(id: "1").person
rescue GraphWeaver::TransportError
  retry                                   # network blip
rescue GraphWeaver::ServerError => e
  e.status >= 500 ? backoff : raise       # retry 5xx; a 4xx is our bug
rescue GraphWeaver::QueryError => e
  e.codes.include?("THROTTLED") ? backoff : raise
end
```

Or skip the hand-rolling — `Retry` wraps any transport with
configurable retries:

```ruby
transport = GraphWeaver::Retry.new(
  GraphWeaver::Transport::HTTP.new(url),
  tries: 5,                        # total attempts
  backoff: :exponential,           # or :linear, or ->(attempt) { seconds }
  base: 0.5, max: 30,              # seconds, clamped at max:
  jitter: true,                    # randomize each delay by 50-100%
  retry_codes: ["THROTTLED"],      # also retry GraphQL errors by code
)
```

Defaults match the rescue block above: transport failures always retry,
`ServerError` only on 5xx (a 4xx is your bug — retrying won't fix it;
override with `retry_if:`), and GraphQL-level codes only when listed in
`retry_codes:`. Exhausting `tries:` re-raises the last error.

**Top-level scalar variables** fail like any Ruby method call, *outside* the
hierarchy on purpose — passing the wrong Ruby type for a scalar kwarg is a
programming bug, not caller input: a wrong-typed one raises sorbet-runtime's
`TypeError` ("Parameter 'page': Expected type T.nilable(Integer), got type
String"), a missing required one a plain `ArgumentError` ("missing keyword: :id").

**Input-object variables** are the caller-input case, so they're *inside* the
hierarchy. When you pass an input object as a hash (or struct) it's built
through the generated `coerce`, and any problem there — an unknown/typo'd key, a
missing required field, an out-of-range enum, a wrong-typed field — raises
`GraphWeaver::InputError`. That's one rescue point for turning invalid input
into a 422:

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

The one-shot `GraphWeaver.execute` / `execute!` mirror this: `execute` returns
the envelope, `execute!` the result-or-raise.

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
