# Upgrading

## Regenerate on every upgrade

**Any release can change what codegen emits.** Patch releases included — most of
them are fixes to a generated type, and a fix to a type is a change to the bytes.
0.5.1 was a patch and moved three of them.

So `rake graph_weaver:generate` is part of upgrading the gem, every time, and
`rake graph_weaver:verify` is the detector: it fails when the checked-in Ruby
isn't what this version would write. Nothing beyond that is promised — there is
no "generated output is stable within a minor" rule to lean on. What each release
changed, and whether it needs a regenerate, is in the changelog.

A generated file's header names the release that wrote it, so the first `verify`
after an upgrade reports the tree as stale whether or not codegen actually
moved. That's the reminder working, not a false alarm.

Generation is deterministic, so the diff is exactly what the new version emits
differently and nothing else — worth reading rather than rubber-stamping.

## Upgrading from 0.5.1

Much smaller than 0.5.0, and mostly mechanical. Three commands find most of it:

```sh
rake graph_weaver:generate   # 1. what codegen emits moved in several places
srb tc                       # 2. kwargs that got narrower are call-site errors
bundle exec rspec            # 3. every deleted knob raises where it's still set
```

The rest of this section is what those three don't catch.

### Loose input coerces, so `coerce:` and `auto_coerce` are gone

`execute(first: params[:first])` converts the String to an `Integer` — for every
variable and every input-object field, with nothing to switch on. The old way of
buying that was `GraphWeaver.auto_coerce` or `register_scalar(…, coerce: true)`,
and both paid for it by **widening the emitted kwarg**, which switched off the
static check at every call site. Delete them:

```ruby
GraphWeaver.auto_coerce = true                             # gone
GraphWeaver.register_scalar("Money", Money, coerce: true)  # drop the coerce:
```

Behavior is unchanged; the kwarg is not. It is now typed exactly as the schema
types it, so a call site passing a **literal** of the wrong type is a new
`srb tc` error — which is the point, since a literal is one you can just spell
right:

```ruby
StargazersQuery.execute(first: "10")            # srb tc error now
StargazersQuery.execute(first: params[:first])  # fine, and "10" becomes 10
```

`cast:` is what a loose value converts through, so a custom scalar needs nothing
beyond the registration it already has. Bad input raises
`GraphWeaver::InputError` naming the variable, the operation and the value.

Two conversions got **stricter** at the same time, and either can bite an app
that was passing. A numeric string is now read as a wire format rather than as
Ruby source, so `"010"` is ten rather than eight and `"0x1f"` and `"1_0"` are
refused. And a `Boolean` refuses a String outright — every rule for `"0"` and
`"off"` is somebody's convention, so convert at the call site.

### `nil` sends `null`

A variable passed `nil` now sends an explicit `null`; one left out is still left
out. That's what lets a mutation clear a field — and it changes what a kwarg fed
a possibly-missing value means:

```ruby
UpdateProfile.execute!(bio: params[:bio])   # a missing param used to omit; now it clears the bio
```

**Grep for kwargs fed straight from `params` or an optional attribute**, and
pass the keyword only when you mean it:

```ruby
UpdateProfile.execute!(**(params[:bio] ? { bio: params[:bio] } : {}))
```

Non-null variables are unaffected: they can't carry `null`, so `nil` there still
omits and the schema default applies. Input objects get the distinction only
where a Hash can express it — `coerce({nickname: nil})` sends null, `coerce({})`
omits, and a struct built with `.new` can't tell the two apart, so `nil` there
still means omit.

### Renames

| before | after |
|---|---|
| `Retry.new(tries: n)`, `retries: { tries: n }` | `retries: n - 1` — one word everywhere, counting the attempts *after* the first, so `retries: 0` is one attempt and `GraphWeaver.new(url, retries: 3)` is four |
| `GraphWeaver.new(url, retries: { retries: 5, retry_codes: […] })` | `GraphWeaver.new(url, retries: 5, retry_codes: […])` — the other retry options sit beside the count; the Hash form read as a key nested in itself |
| `Retry.new(t, on: […])` | `Retry.new(t, retry_on: […])` |
| `Retry.new(t, base: 0.5, max: 30)` | `Retry.new(t, base_delay: 0.5, max_delay: 30)` — beside a count, `max: 30` read as a second, larger attempt count |
| `Codegen.generate(module_name:)` | `name:` — the spelling `GraphWeaver.parse` already used; `module_name:` now raises, naming its replacement |
| `Testing.config.null_chance = 0.3` | `graphql_fake(null_chance: 0.3)`, on the example that wants it |
| `Testing.config.mode = :literal` | `graphql_fake(values: :literal)`, likewise |
| `Testing::MODES` | `Testing::VALUE_STYLES` |
| `SchemaLoader.stale?(path)` | `SchemaLoader.diff(path).empty?` — and `diff` also names what moved |

The two `Testing.config` deletions are the ones worth a sentence. A suite-wide
`null_chance` answers a per-example question, so it nils an unrelated field one
run in ten, on a seed the failure doesn't name; move it onto the examples that
are *about* an empty state. (`config.default_mode` and the `graphql: :fake` tag
are untouched — the per-fake `mode:` became `values:` so the two can't be
confused for each other.) Every retry misspelling raises rather than being
ignored: the Hash form names its flat replacement, and a retry option passed
without `retries:` says so.

### The internals moved behind `Internal`

The public surface is now what the docs name, what generated code calls, and the
`execute` slot; everything else sits under `GraphWeaver::Internal` or went
`private`, and a spec diffs the two so the next accidental promotion fails CI.
Nothing documented moved — skip this section unless `srb tc` or a
`NoMethodError` says otherwise.

What a suite might plausibly have reached for: the federation query planner and
its IR (`Internal::Planner`), the fake-value engine (`Internal::Values`), the
selection walk (`Internal::Selection` — so `FakeClient` no longer answers
`each_field` or `gather`), the cassette matching rules (`Internal::RequestKey`),
subgraph detection (was `Testing::Subgraphs`), `GraphWeaver.log` /
`.instrument` / `.filter_variables` (`Internal::Log` — `logger=`,
`instrumenter=` and `filter_parameters=` are unchanged), and
`Transport.operation_name` / `.mutation?` / `.log_tag`, which left the class you
subclass for `Internal::Wire`.

Two smaller edges. `SchemaDiff::Change`, `Cassette::Check`, `Coverage::Result`
and `InputStruct::Field` are `Data` now rather than `Struct`, so they hand out
no writers — read one, build a new one to change a field. And generated modules
keep their own plumbing to themselves: `DEFAULT_CLIENT`, `FIELDS` and `ONE_OF`
are emitted `private_constant`, so **regenerate**.

### Behavior that changed under you

- **A mutation is no longer retried.** A timeout doesn't say whether the server
  applied it, and a second `charge` is worse than a failed one. Pass
  `retry_mutations: true` for an API whose mutations are idempotent.
- **A registration this schema can't match warns instead of failing
  generation.** One registry serves a whole federated graph, so a name the
  schema in hand doesn't declare may belong to the subgraph next door — see
  [federation](federation.md#generating-for-a-federated-graph). Your typo is now
  in the list `rake graph_weaver:generate` prints after the files, so read it.
- **`verify_generated!` fails when it finds no query documents.** A mistyped
  `queries_paths` used to leave a CI gate green forever.
- **The local router refuses a `@fromContext` argument** rather than fetching
  the field with it unset. Federation 2.8's `@context` machinery was on the
  routing table's known list, so the argument was read and dropped. Per query,
  like `@interfaceObject`: a subtree one subgraph answers whole still runs.
- **A `#trace` assertion may see one entry fewer.** Two `@requires` field sets
  crossing into the same subgraph on the same `@key` now ride one entity fetch,
  the way Apollo's do.
- **Fabricating a custom scalar registered as a class of your own needs a pin
  for the type** — `Testing.config.overrides = { "Money" => "12.00" }`, or the
  same key on one example's `graphql_fake`. Without one, `FakeClient` and
  cassette anonymization refuse rather than feeding your cast a `"Money-1"`
  placeholder. Scalars registered as `Time`, `Date`, `Integer`, `Float`,
  `String` or `T::Boolean` need nothing.
- **Re-run `rake graph_weaver:cassettes:anonymize`** on any committed cassette
  holding a registered custom scalar: the anonymizer used to write a value the
  generated codec couldn't read back.
- **Generation refuses four more things**, each naming its fix — a
  `register_scalar` whose Ruby type nothing can build out of JSON (`BigDecimal`,
  classically: give it a `cast:`), a result key that would shadow a constant the
  file uses, an enum value that camelizes to nothing, and a narrowed fragment
  whose `__typename` sits behind `@skip`/`@include`.

## Upgrading to 0.5.0

0.5.0 is one large breaking release. Almost all of it is caught mechanically,
in this order:

```sh
# 1. rename the path settings first — generate won't load without them
#    (queries_path -> queries_paths, generated_path -> generated_paths,
#     fragments_path -> fragments_paths; see "Path settings are lists" below)

bundle exec tapioca gem graph_weaver   # 2. regenerate the RBI
rake graph_weaver:generate             # 3. the emitted call shape changed
srb tc                                 # 4. every call site that moved is an error
rake graph_weaver:verify               # 5. fails until the tree is regenerated
```

**Step 2 is not optional.** Against the 0.4.6 RBI, `srb tc` reports errors
pointing into your `generated/` directory — `QueryModule`, `client_for`,
`check_envelope!` — which read as though codegen emitted broken Ruby. It
didn't; sorbet is checking new generated code against the old gem's types.
Regenerate the RBI and what remains is only your own call sites.

Generated code is `# typed: strict`, so step 4 finds those for you. The rest of
this page is what a typechecker can't see.

### `execute` means one thing now

Every client answers the same call — `execute(query, variables:, operation_name:)`,
returning the raw response hash. `Client` used to spell something else under
that name, which is why `Retry.new(client)` and `Sequence.new(client, fake)`
raised `ArgumentError`. They work now.

The one-shot sugar moved to `run`:

```ruby
client.execute!("query { … }", id: "1")   # before
client.run!("query { … }", id: "1")       # after   (and #run for the envelope)

GraphWeaver.execute(source, query, **vars)   # before
GraphWeaver.run(source, query, **vars)       # after
```

**This one is worth grepping for.** `Client#execute` still exists, so a stale
call fails at runtime rather than at typecheck — as do `GraphWeaver.execute`
and `GraphWeaver.reset_scalars!`, which are simply gone and will not be flagged
until the RBI is regenerated (step 2): `rg '\.execute!?\(' --type ruby`
and check each hit is passing `variables:` rather than loose kwargs.

A generated module takes its per-call client as a **keyword**:

```ruby
PersonQuery.execute(some_client, id: "1")          # before
PersonQuery.execute(client: some_client, id: "1")  # after
```

`GraphWeaver.resolve_transport` is gone; nothing needs unwrapping any more.

### Path settings are lists

`queries_paths`, `generated_paths`, `fragments_paths` — every entry is read.
Assigning a String still works, so the change is the name:

```ruby
GraphWeaver.queries_path = "app/graphql/queries"    # before
GraphWeaver.queries_paths = "app/graphql/queries"   # after
```

`schema_path` stays singular: one run reads one schema.

### One reset

`GraphWeaver.reset_registrations!` is the clean slate between tests, or between
generations for different schemas. The four
narrow ones moved to where they live:

```ruby
GraphWeaver.reset_scalars!            # before
GraphWeaver::Codegen.reset_scalars!   # after   (also reset_enums!, clear_scalars!,
                                      #          reset_type_helpers!)
```

### Generated names come from the response key, not the type

Nested structs used to be named for the GraphQL *type* they were cast from;
they are now named for the **response key that selects them**, camelized, and
the constant path reads like the query. The typechecker finds the call sites in
a `# typed: true` file (an unresolved constant is an `srb tc` error); in a
`# typed: false` file it is `uninitialized constant` at runtime, so grep for
`::Result::` there.

| selection | before (type) | after (key) |
|---|---|---|
| `person { pets { name } }` | `PersonQuery::Result::Person::Pet` | `PersonQuery::Result::Person::Pets` |
| `payrollRisk { score }` | `…::Result::RiskAssessment` | `…::Result::PayrollRisk` |
| `_entities(…) { ... on Product { … } }` | `…::Result::Product` | `…::Result::Entities::Product` |

The key is used verbatim — no pluralization, so a list field `pets` is `Pets`.
To pick the name yourself, alias the field: `pet: pets { name }` generates
`Pet`. Union and interface members keep their type-condition names, nested in
the container the field names. The payoff is that adding, removing or
reordering an unrelated selection can never rename a struct you reference.

**Enums moved out of the result tree.** Every schema enum a query touches is one
Ruby type in the shared module, `GraphQLTypes::Species`, so a value read from
one query hands straight into another's variable. A query module aliases the
enums its *variables* use (`AddPetMutation::Species` still works); an enum
reached only through a result is no longer nested under the struct that
carries it — `SearchQuery::Result::Search::Species` is `GraphQLTypes::Species`.

### Smaller renames

| before | after |
|---|---|
| `Testing.config.auto_fake = true` | `Testing.config.default_mode = :fake` |
| a mutation's `…Query` module | `…Mutation` |
| `graphql: :none` (rspec tag) | `graphql: false` |

**The shared types module was three, and is now one.** `GraphQLInputs`,
`GraphQLEnums` and `GraphQLUnions` are all `GraphQLTypes`, and the files move
with them — `generated/inputs/` becomes `generated/types/`. The three settings
that named them (`inputs_module=`, `enums_module=`, `unions_module=`) are one
`types_module=`. Regenerating writes the new tree; delete the old directory,
which pruning leaves behind empty.

If your specs run one schema class in-process while your client points at a
different API, name it — per example, since a federated suite runs more than
one:

```ruby
graphql_in_process(MySchema)                     # in the example
GraphWeaver::Testing.config.schema = MySchema    # or once, for the whole suite
```

### Registering from Rails

A registration naming one of your own constants belongs in a `to_prepare` block
— the same place the in-process client goes, and for the same reason:
autoloading is set up after `config/initializers` run.

```ruby
Rails.application.config.to_prepare do
  GraphWeaver.register_enum("Species", PetKind, fallback: PetKind::Unknown)
  GraphWeaver.extend_type("Pet", PetHelpers)
end
```

Generation depends on `:environment`, which runs `to_prepare` too, so the
registration is in place before it emits — and at boot the generated files
load from a `to_prepare` block of their own, after yours.

### If you use the federation router

Detection only sees *loaded* schema classes, and Rails does not eager load for
rake or in the default test environment. Both are one line:

```ruby
config.eager_load = true        # config/environments/test.rb
config.rake_eager_load = true   # config/application.rb
```

Without them the `federation:*` tasks silently see nothing — and
`federation:diff` now **fails** rather than reporting a green "matches" over
zero subgraphs.
