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

Generation is deterministic, so the diff is exactly what the new version emits
differently and nothing else — worth reading rather than rubber-stamping.

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

`GraphWeaver.reset_registrations!` is the clean slate between tests. The four
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
| `register_scalar(…, coerce: :to_s)` | `coerce: true`, or a `cast:`/`serialize:` pair |
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
