# GraphWeaver senior-engineer evaluation — session M (the skeptic)

Evaluator stance: senior Ruby engineer, skeptic, migrating a Rails app with
fifteen hand-handled custom scalars off graphql-client. Read
brief-senior4-common.md + brief-senior-M.md. Nearest prior sessions skimmed:
senior-log-D.md (scalars at the seams — nested inputs, modes, precision,
outward serialization, federation @key/@requires) and senior-log-G.md
(scalars across two graphs, srb tc coverage, misuse probes). Not repeating
their findings; noting where this session reconfirms one.

Working dir: /tmp/claude/graph_weaver/senior-app-M. Gem via `path:`, never
edited. Toolchain: `~/.rvm/wrappers/ruby-3.4.9/bundle exec ...`.

### ~08:20-08:50 — read docs/scalars.md, docs/alternatives.md, README.md,
docs/getting_started.md (the `unused` lint's serializer-excuse section, since
D flagged it) in full. Skimmed senior-log-D.md and senior-log-G.md in full
for their ranked findings (scalars at the seams / across graphs) so this
session doesn't repeat them. Confirmed senior D's HIGH `to_json` finding is
fixed on main (`ResultStruct#to_json` now goes through a real `as_json`,
CHANGELOG 246-258) and its URL-unicode / list-scalar-InputError / null-scalar
findings are now documented in scalars.md verbatim. ~30 min (over the
brief's per-door budget, but this is shared setup, not one door).

### ~08:50-09:40 — the scalar zoo at scale. Plain Ruby, no Rails, in-process
graphql-ruby schema (`lib/app/schema.rb`), matching senior A/D/G's own
approach. Fifteen scalars from the brief's list, registered per
docs/scalars.md's own recipes, one initializer (`lib/init.rb`, 59 lines
including the 3 comment banners and 1 extra registration for a
`[[Decimal!]!]` corner case not in the 15):

| # | scalar | Ruby type | registration door | needed cast:/serialize:? |
|---|---|---|---|---|
| 1 | Upload | — | deliberately unregistered (no Ruby class the client side can name for "a file about to be sent") | n/a |
| 2 | JSON | T.untyped | already registered by graphql-ruby default | no |
| 3 | Cursor | String | class alone — String is a "wire class", already the right Ruby type | no |
| 4 | Base64 | String | class + explicit cast/serialize | **yes**, both directions (`Base64.decode64`/`strict_encode64`) |
| 5 | GeoJSON | `T::Hash[String, T.untyped]` | type-string (JSON-narrowing recipe) | no |
| 6 | Timezone | VO::Timezone | class alone (`.parse`/`to_s` inferred) | no |
| 7 | Locale | VO::Locale | class alone | no |
| 8 | Color | VO::Color | class alone | no |
| 9 | Email | VO::Email | class alone | no |
| 10 | PhoneNumber | VO::PhoneNumber | class alone | no |
| 11 | Percentage | Float | class alone (stdlib table entry) | no |
| 12 | GID (`gid://app/User/1`) | VO::GlobalId | class alone (`.parse`/`to_s`) | no |
| 13 | CurrencyCode | VO::CurrencyCode | class alone | no |
| 14 | Bytes | Integer | class alone — Integer is also a "wire class" | no |
| 15 | UUID | VO::UUID | class alone | no |

**13 of 15 needed nothing but a class name; only 1 (Base64) needed an
explicit cast:/serialize: pair; 1 (GeoJSON) used the type-string door
instead of a class; 1 (Upload) has no client-side registration at all.**
Writing all fifteen plus the seven small value-object classes
(`lib/app/value_objects.rb`, ~100 lines, each with `eql?`/`hash` per the
docs' own recommendation) took **~35 minutes wall time** — most of it was me
inventing plausible value objects, not fighting the registration API. Two
false starts along the way, both mine, not the gem's: `field :tasks, ...,
connection: true`-shaped naming (`TaskConnection`) tripped graphql-ruby's own
implicit Relay-connection field detection (`GraphQL::Schema::DuplicateNamesError`
on the auto-added `after`/`first` args) — fixed with `connection: false`, a
graphql-ruby quirk, not graph_weaver's; and a union query missing
`__typename` was refused by generation with a precise, actionable message
(quoted below). `rake graph_weaver:generate`: **clean, 13 files, one line**:
```
1 unregistered custom scalar → T.untyped: Upload (register with GraphWeaver.register_scalar)
```
`bundle exec srb tc` (full tapioca-generated RBIs for graphql/money/graph_weaver):
**No errors! Great job.** — every one of the 14 registered scalars (Upload
aside) typechecks cleanly through every generated struct, including the
value objects with no built-in Sorbet RBI at all.

### ~09:40 — miss three on purpose (Email, GID, UUID commented out of
`lib/init.rb`), no regenerate yet.

`rake graph_weaver:verify` **before regenerating** correctly named every
file that actually uses one of the three, and nothing else:
```
stale generated queries — regenerate (rake graph_weaver:generate):
app/graphql/generated/types/search_filter_input.rb,
app/graphql/generated/contacts_query.rb,
app/graphql/generated/profile_query.rb,
app/graphql/generated/search_query.rb
```
`rake graph_weaver:generate` then touched exactly those four, left the other
nine alone, and named the damage precisely:
```
9 already up to date
4 unregistered custom scalars → T.untyped: Email, GID, UUID, Upload
(register with GraphWeaver.register_scalar)
```
No crash, no ambiguity — `verify`/`generate` are exactly as precise "missing
three" as senior D found them for "missing one". **Runtime, though, is
silent**: after regenerating with the three missing, `ProfileQuery.execute!`
against a live in-process schema returns `result.profile.email` as a plain
`String` (`"ada@example.com"`) and `result.profile.id` as a plain `String`
(`"gid://app/User/1"`) — no exception, no warning at the call site, nothing
short of rereading the generate-time advisory tells you `GlobalId#type` is
gone. Confirmed and reset back to all fifteen; `verify` green again with the
one Upload line. This generalizes senior G's finding #4 (advisory merges
scalar names) from a slightly different angle: the **generation-time**
signal is excellent, but there is no **runtime** signal at all — a
regression that ships (someone reverts a registration, or a scalar
registration accidentally gets removed in a merge) degrades silently to
"the field is a string now" rather than failing loudly anywhere a test would
catch it structurally, unless a test asserts the concrete class.

### ~09:55 — Upload / multipart.

docs/alternatives.md already says plainly, under "Where graph_weaver loses":
**"No `@defer`, no file uploads, no persisted queries, no batching"** — so
the headline claim isn't in question. What I drove is the *shape* of the
failure a migrating team actually hits.

`Types::Upload` (a plain `GraphQL::Schema::Scalar`) on a mutation argument,
left unregistered (there's no Ruby class a client-side registration could
sensibly name for "a file about to be sent" — registering `Upload` as
`String`, say, would just move the corruption below one layer). Generation:
clean, one advisory line (`Upload` in the unregistered-scalars report,
already shown above).

Then the real question — what happens when a real `File` is passed as the
variable, over the real HTTP transport (`GraphWeaver::Transport::HTTP`,
webmock intercepting)? **`GraphWeaver.new`'s duck-typed client slot correctly
refused my first attempt** — wrapping a transport in another `GraphWeaver.new`
gets a precise, actionable error (`GraphWeaver::Transport::HTTP is a client,
not a schema source — pass ... this as its transport: GraphWeaver.new(schema,
transport: client)`), so I passed the transport directly as `client:`, which
generated modules accept. The request **did not raise**, returned HTTP 200,
and the actual JSON body sent to the wire was:
```json
{"query":"mutation UploadAvatarMutation($file: Upload!) { ... }",
 "variables":{"file":"#<File:0x0000000125dcd6d0>"},
 "operationName":"UploadAvatarMutation"}
```
**Finding (HIGH, and worse than a raised exception): a `File`/`IO`/`Tempfile`
given as an unregistered scalar's variable is silently `Object#to_json`'d
into a garbage string carrying a live memory address, and posted as ordinary
`application/json` — never as `multipart/form-data` per the [GraphQL
multipart request
spec](https://github.com/jaydenseric/graphql-multipart-request-spec) — with
no exception anywhere in graph_weaver.** Root cause: `Transport#perform`
builds the whole request body with one `GraphWeaver::Internal::Wire.json(request)`
(`JSON.generate`) call over the raw `variables` hash; an unregistered
scalar's kwarg is `T.untyped` with `.checked(:never)`, so nothing coerces or
even inspects the value before it reaches `JSON.generate`, and `File` has no
`#to_json` of its own so it falls through to `Object#to_json`'s `to_s.to_json`
— the exact same fallback senior D found (and this repo since fixed) for
*inbound* `ResultStruct#to_json`, but here on the **outbound** variable path,
which nothing in this codebase touches. **Not fixable by registering a
`cast:`/`serialize:` for `Upload`** — `register_scalar`'s contract converts
one JSON value into one Ruby value and back; multipart needs to *restructure
the whole HTTP request* (JSON body carries `null` placeholders keyed by an
`operations`/`map` convention, the file rides a separate form part) which is
a transport-level feature, not a scalar-level one. Additive fix, in order of
value: (1) the cheap one — `Transport#perform` refuses a variable value
`JSON.generate` can't render honestly (a `File`/`IO`/anything without a real
JSON form) with a message naming the variable, rather than silently
serializing its `#to_s`, the same discipline `Wire.json`'s `rescue
JSON::GeneratorError` already extends to `NaN`/`Infinity`; (2) real multipart
support, which is the actual feature gap alternatives.md already owns up to.
(1) is a five-line, purely-defensive change; (2) is roadmap-sized. I'd ship
(1) regardless of (2)'s timeline — right now the failure mode for *any*
non-JSON-native variable value (not just files) is silent wire corruption,
which is exactly the "silent wrong answer" this codebase's own CLAUDE.md
calls the most expensive outcome the library can produce.

### ~10:10 — scalars in the corners (spec/corners_spec.rb, `graphql: :in_process`,
7 examples, **all green on the first try**, no findings):

| corner | outcome |
|---|---|
| scalar field on a union member (`Task.completion`) and on an interface field selected through fragments (`... on Themed { themeColor }`) | both cast correctly; union dispatch via `__typename` works once selected (generation refuses a union with no `__typename`, quoted below) |
| list of lists of a scalar (`[[Decimal!]!]`) | `[[BigDecimal("1.1"), BigDecimal("2.2")], [BigDecimal("3.3")]]` — nesting depth handled, matches senior D's "does serialize: run at every depth" confirmation, generalized to reads |
| a scalar argument with a schema default the query doesn't pass (`threshold: Percentage = 0.5`) | the server's default applies untouched — `0.5 + 0.1 == 0.6` |
| a scalar-typed field behind `@skip(if:)` driven by a Boolean variable | works both ways; the custom-scalar field and the directive coexist with no special-casing needed |
| a scalar inside a `@oneOf` input | both branches (`byEmail`/`byPhone`) cast correctly; giving both or neither is refused with a precise message (quoted below) |
| a nullable scalar list with null elements | `[Color.parse("#111111"), nil, Color.parse("#222222")]` — null elements pass through untouched, non-null ones cast |
| the same scalar name registered globally and inside a `GraphWeaver.graph` block (separate app, `senior-app-M-graphs`) | **graph-block wins for that graph only** — `:alt`'s `register_scalar "Color", String` generates `T.nilable(T::Array[T.nilable(String)])` with no cast, while `:app`'s untouched global registration still generates `T.nilable(T::Array[T.nilable(VO::Color)])` with `.parse`/`.to_s`, in the same process, same run. Reconfirms senior G's "per-graph `.dup` — no leakage" finding from the opposite direction (global vs. one graph, rather than two named graphs) |

Two messages worth quoting exactly, both clean refusals:
```
select __typename on SearchResult so the union can dispatch — unaliased and
not under @skip/@include, since from_h reads it on every response — or
narrow to a single `... on Type` condition (no dispatch needed)
```
```
$filter of ContactsQuery: GraphQLTypes::SearchFilterInput is @oneOf — supply
exactly one field, non-null, got byEmail, byPhone
```
(and `got none` for the empty case). Also worth noting since it directly
contradicts senior G's LOW finding #6: **`rake graph_weaver:graphs` now
prints per-graph registered-scalar lists** (`scalars: Base64, Bytes, Color,
...`) and the unregistered-scalar advisory is now **per-graph labeled**
(`graph :app: Upload`) — both G findings #4 and #6, fixed on main, confirmed
directly rather than taken on faith.

### ~10:30 — the migration itself: three real graphql-client call sites,
ported.

Wrote real graphql-client code (`lib/app/gc_client.rb`) against the *same*
`App::Schema`, in-process (`GraphQL::Client.new(schema:, execute: App::Schema)`
— confirmed this seam is exactly as good as alternatives.md says: point it at
a live schema class and it runs with no socket) — a plain query with
variables (`ProfileQuery`), a fragment-heavy one (a named `ThemedFragment`
spread into a union query), and a mutation with an input object
(`CreateTaskMutation`, a plain Hash for `input:`). Their graph_weaver
equivalents already existed from the scalar-zoo door
(`ProfileQuery`/`SearchQuery`/`CreateTaskMutation`), so the "port" is the
diff between what I had to write for each.

**What changed, concretely:**
- graphql-client's fragment reference isn't a GraphQL-level `...FragmentName`
  in the document — it's **Ruby string interpolation of the parsed
  constant**: `"...#{ThemedFragment::ThemedFragment}"` (and the nested
  `::ThemedFragment` is real, not a typo — a file with one fragment in it
  still nests the definition a level, since a file could hold more than
  one). graph_weaver's `... on Themed { themeColor }` is bare GraphQL, no
  Ruby-level indirection, no module to name.
- graphql-client's `Client.parse` validates **at require time** (a bad field
  raises `GraphQL::Client::ValidationError` the moment the file loads);
  graph_weaver validates at **generate time** (`rake graph_weaver:generate`
  / `queries:check`), a separate step from booting the app. Load-time
  validation is a real property graph_weaver's model doesn't have — it needs
  the schema live and loaded before any query file can even be required,
  which is also why graphql-client's docs call dump-based scalar
  deserialization "the path its own README recommends" and then don't fully
  support it (alternatives.md already cites this).
- **What the generated code let me delete:** every hand-written cast.
  graphql-client's readers return raw wire values — `r.data.profile.uuid`
  is the bare string `"550e8400-..."`, `r.data.create_task.completion` is a
  bare `Float` — so a hand-maintained app with 15 custom scalars is, in
  graphql-client, 15 places in application code doing `VO::UUID.parse(...)`
  after every call (or worse, 15 places where someone forgot to). That
  per-call-site conversion is exactly what graph_weaver's registration
  moves to one place, confirmed directly: `result.profile.uuid` is already
  a `VO::UUID`.
- **What I lost, confirmed by trying to use it:** graphql-client's Relay-style
  fragment masking is real and I hit it live, not just read about it.
  `s.themeColor` (selected only via `...ThemedFragment` on the `Themed`
  interface) raises:
  ```
  NoMethodError: undefined method 'themeColor' for an instance of
  #<Module:0x00000001237b2e50>::Task
  ```
  **even though `s.to_h` has it right there** — `{"__typename"=>"Task",
  "themeColor"=>"#ff0000", "id"=>"1", ...}`. Confirms alternatives.md's
  graphql-client callout ("a field another fragment fetched raises even
  though the value is right there in the response") hands-on, not on faith.
  graph_weaver has no masking at all — `task.theme_color` just works,
  selected via any fragment shape — which is a straightforward win for a
  migrating team's day-to-day code, and the tradeoff getting_started.md
  names for it (`rake graph_weaver:unused`, a lint rather than a runtime
  guarantee, catching "50-67% of genuinely unread selections" by the docs'
  own honest number) is the right thing to have flagged rather than assumed
  clean.
  Also lost: `#to_h`'s untyped-Hash escape hatch for genuinely dynamic code
  (rare, but real) and the load-time validation above.
- **A typo, confirmed both ways.** `r.data.profile.emial` (graphql-client):
  `GraphQL::Client::UnimplementedFieldError: undefined field 'emial' on
  Profile type.` — a real, clean, well-named runtime error. `result.profile&.emial`
  (graph_weaver, `srb tc`): `Method 'emial' does not exist on
  'ProfileQuery::Result::Profile' ... Did you mean 'email'? Use -a to
  autocorrect` — verbatim, including the autocorrect suggestion, exactly as
  README's own worked example shows. Both are honest, well-designed errors;
  the difference is *when* — a red build here, a request in production
  there.

**My alternatives.md row, written before re-reading the gem's own, then
diffed:** *"A result is: graphql-client — an anonymous class, readers per
selected field, masked by fragment boundary; graph_weaver — a checked-in
struct, no masking, typed all the way down." "A typo is caught: at the
request (graphql-client) vs. at the build (graph_weaver)."* Diffed against
the gem's own table: **matches on substance** ("an anonymous class, readers
per selected field" / "a checked-in nested T::Struct"; "at runtime, on the
request" / "at srb tc, before you run it") — the gem's table doesn't call
out data masking specifically in the table itself (it's in the
graphql-client prose section, which I'd read before writing my own row, so
this isn't independent confirmation of that one point — but the *table's*
two rows I could check blind both held up).

### ~11:00 — steelman three claims, try to falsify each in ~5 minutes.

1. **"Generation is deterministic — same schema and queries, byte-identical
   files"** (README). Steelman: this is the property that makes `verify`
   trustworthy in CI at all — without it, "regenerate" would show diff noise
   unrelated to a real change, and nobody would trust the gate. Falsification
   attempt: `rm -rf app/graphql/generated` (not just `generate` over an
   existing tree — a full cold rebuild, so caching can't be doing the work)
   and regenerate from the same 15-scalar registry and the same 10 query
   files. **Did not falsify**: `diff -rq` against the prior generated tree
   was empty, byte for byte, across all 13 files.
2. **README's worked example — "a typo is a typecheck error rather than a
   NoMethodError in production," down to the literal "Did you mean `name`?"
   Sorbet output shown in the README.** Steelman: this is the entire pitch
   of the library in one code block, so if it's exaggerated even slightly
   (say, if `-a` autocorrect weren't actually offered, or the message were
   generic rather than naming the struct), that's a credibility problem for
   the README's very first screen. Falsification attempt: the exact
   scenario, on a real generated struct (`result.profile&.emial`, sig-typed
   `ProfileQuery::Result`), run through the real `srb tc`. **Did not
   falsify**: verbatim match, including `Did you mean 'email'? Use -a to
   autocorrect` and the `Defined here` pointer to the generated `const`
   line.
3. **scalars.md's "What the wire carries" table — "generated code takes
   every JSON spelling a spec-compliant server may write, and refuses the
   rest," with two named exceptions carrying advice (an unquoted `ID`, a
   registration with no cast).** Steelman: this is the load-bearing safety
   claim for the whole "wire in the corners" section of the brief — if any
   cell in that table were wrong, a real production server that happens to
   write one of the "refused" spellings would silently corrupt data instead
   of failing loudly. Falsification attempt: fed `from_h` an unquoted `ID`
   (`"taskId" => 1` instead of `"1"`) and a `Boolean` field given the string
   `"true"` instead of the JSON boolean. **Did not falsify**: both refused,
   exactly as documented — the unquoted-`ID` case with the exact advice
   sentence quoted in the docs (*"the server sent `"taskId"` unquoted;
   GraphQL serializes ID and String as JSON strings, so that is the server
   being out of spec... To take it anyway, register the scalar loosely:
   `GraphWeaver.register_scalar("ID", "T.untyped")`"*), the Boolean case with
   a plain, correctly-typed `CastError` and no false hint.

**None of the three claims broke.** For a skeptic, that's itself the finding
worth stating plainly rather than manufacturing doubt to look busy: this
session's confidence in "generation is deterministic," "the README's typo
example is real," and "the wire table is accurate" moved from *documented
claim* to *independently verified*, on the actual generated code, not a toy
example. The one place a genuinely new, unrelated bug surfaced (Upload/
multipart, above) came from *driving a real scenario the docs already admit
is unsupported*, not from doubting a claim the docs make confidently.

### Final state

`bundle exec rspec`: **7/7 green** (spec/corners_spec.rb; the scalar-zoo,
miss-three, Upload, and migration doors were driven from one-off scripts and
quoted verbatim above rather than kept as specs, since they're
process/generation-time behaviors — `verify`/`generate` output, `srb tc`
output, a raw transport POST body — not example-level behavior). `bundle
exec srb tc`: **No errors!** across the whole app, including the
graphql-client comparison file (`# typed: ignore`, correctly excluded from
the checked contract — it's dynamic metaprogramming by design, not this
session's code). `bundle exec rake graph_weaver:verify`: green, one
Upload advisory line, stable across the whole session.

Second app, `senior-app-M-graphs` (a copy of the above with two
`GraphWeaver.graph` blocks added), used only for the global-vs-graph-block
scalar-scoping corner case — not otherwise touched.

## Doors named in the brief, not separately reproduced

Every bullet has a concrete repro above. Two things reasoned about rather
than independently re-driven, both time-boxed: a real GraphQL multipart
request spec client speaking to graph_weaver's transport (the finding above
is about what graph_weaver's *own* transport does with a file, which fully
answers the brief's question — "what the client does" — without needing a
second real implementation of the multipart spec to compare against); and
JSON/i18n-flavored scalars (`Locale`) beyond registering and casting them —
i18n proper is senior E's door.
