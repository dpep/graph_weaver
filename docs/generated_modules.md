# Generated modules

`GraphWeaver::Codegen` turns one GraphQL operation into one `# typed: strict`
Ruby module. Everything `srb tc` knows about your query results comes from that
file — there is no runtime schema, no lazy wrapper, no reflection.

Read this when you want to predict the output, or when a generated name isn't
the one you expected:

- **[Anatomy](#anatomy)** — what a module holds, and what a `Result` can do
- **[Naming](#naming)** — how the module and every nested struct get their names
- **[Variables](#variables-become-typed-kwargs)** — kwargs, input objects, coercion
- **[Enums](#enums-one-graphql-enum-one-ruby-type)** and **[selections](#selections)** — fragments, aliases, unions and interfaces
- **[Type helpers](#type-helpers)** — your own methods on a generated struct
- **[Clients](#clients)**, **[`from_response`](#deserializing-a-response-from-another-client)**, and the **[build](#generating)** itself

The setup around it is assembled step by step in
[getting started](getting_started.md), including
[what Sorbet does and doesn't require](getting_started.md#sorbet-with-or-without).
For consoles and dev there's [dynamic mode](#dynamic-mode); for one-off scripts,
`client.run!` skips modules entirely.

## Anatomy

```ruby
module PersonQuery
  QUERY = "..."                  # the operation, verbatim
  OPERATION_NAME = "PersonQuery"  # its name — the module's, when the file's is anonymous

  class Result < T::Struct       # the response shape, exactly as selected
    class Person < T::Struct
      const :name, String        # non-null in the schema
      const :birthday, T.nilable(Date)

      def self.from_h(data) ...  # generated casting — no reflection
    end

    const :person, T.nilable(Person)
  end

  extend GraphWeaver::QueryModule # client (see below)
  def self.execute(id:, client: nil)    # -> GraphWeaver::Response[Result]
  def self.execute!(id:, client: nil)   # -> Result, or raises QueryError

  def self.from_response(response)      # deserialize a raw hash -> Response[Result]
  def self.from_response!(response)     # -> Result, or raises QueryError
end
```

`execute` returns the **envelope** — `GraphWeaver::Response[Result]` with
`#data`, `#data!`, `#errors`, `#extensions` — so partial data and cost/throttle
metadata survive. `execute!` is the shortcut: the typed **result**, or a raised
`GraphWeaver::QueryError`. See [errors](errors.md).
[`from_response`](#deserializing-a-response-from-another-client) is the
network-free half of the pair.

`OPERATION_NAME` rides along on every request as the spec's `operationName`, so
Apollo Studio, Hasura and your APM key traces, rate limits and slow-query reports
on the operation instead of lumping every request together. **You don't have to
name your operations**: an anonymous document is named after the module in the
emitted `QUERY` *and* in `OPERATION_NAME` — both, since a server rejects an
`operationName` its document doesn't declare.

A `Result` is an **ordinary Ruby object**: value `==` (with `eql?` and `hash`,
so a result works as a hash key), `deconstruct_keys` for pattern matching,
`#to_h`, and `#to_json`/`#as_json`. All of them go the whole way down a nested
result. It is immutable as far as its props go, like `Struct` or `Data` — and no
further: the `String` or `Hash` a leaf holds is the one the response carried, so
`result.name << "!"` changes the result, and its `hash` with it.

```ruby
case PersonQuery.execute!(id: "1")
in { person: { name:, pets: [{ name: first_pet }, *] } } then "#{name} and #{first_pet}"
in { person: { name: } } then "#{name}, petless"
in { person: nil } then "nobody"
end
```

**`#to_h` is the Ruby shape; `#to_json` is the wire shape.** `to_h` gives
snake_case prop names as Symbols, nils kept, enums as their `T::Enum` members,
and a registered scalar as whatever object its codec built — a view, for Ruby to
read. `#to_json` — and `#as_json`, which `render json:` goes through — writes
the response keys instead, every leaf back through its scalar registration's
`serialize:`, so a result's JSON is the inverse of `from_h`
(`Result.from_h(JSON.parse(result.to_json)) == result`), which is what a cache
entry, a log line or a JSON API response wants. The split is deliberate: a
Symbol-keyed Ruby hash can't be mistaken for a server's response, and a JSON
string can, so the JSON is the one that has to be true. (An **input** struct's
`to_h` is already the wire hash it sends, so there its JSON and its `to_h`
agree.) The trip is exactly as faithful as each scalar's own `cast:`/`serialize:`
pair: a `Time` goes back out with
[the microseconds its registration writes](scalars.md#going-out--what-a-variable-kwarg-accepts),
and a `register_scalar` with a `cast:` and no `serialize:` has no wire spelling
at all, so its value reaches the encoder as it is.

**Cache a result with `Marshal` or JSON, not YAML.** A `T::Enum` member is a
singleton that sorbet compares by identity, and Psych allocates an object before
filling it in, so YAML has no way to hand back the canonical one: after a round
trip `pet.species == Species::Dog` is false and the result no longer equals
itself.

## Naming

**A module is named after its file**, suffixed with the operation the file
defines — `person.graphql` → `PersonQuery` in `person_query.rb`,
`save_list_entry.graphql` → `SaveListEntryMutation` in
`save_list_entry_mutation.rb`. The operation name written *inside* the file never
names the module (it goes on the wire as `operationName`); leave it off and the
module's name is written into the document instead. The same rule runs at all
three doors: `generate!`, `GraphWeaver.parse(path)`, and `client.load_queries!`.

**Every run of non-alphanumerics in the file name is a word boundary**, after a
trailing `.query`/`.mutation`/`.subscription` extension naming the document's own
operation is dropped — so `get-hello.graphql` is `GetHelloQuery` in
`get_hello_query.rb`, and `hello.query.graphql` is `HelloQuery`, not
`HelloQueryQuery`. Only that extension is dropped: `user.profile.graphql` is
`UserProfileQuery`, keeping the `profile`. A file whose extension names a kind it
doesn't hold (`hello.query.graphql` defining a mutation) is refused, naming both
halves. What is left still has to spell a constant — `01_home.graphql` is
refused, since `01HomeQuery` isn't one.

Subdirectories are yours to organize with — `queries/admin/pets.graphql` is
found, but the module name still comes from the file name alone, so it is
`PetsQuery`. Two files that name the same module are refused at generation,
naming both, rather than one silently overwriting the other; so is a file holding
two operations, since one file can't name two modules. Change a file's `query` to
`mutation` and its constant changes with it; the next `generate!` prunes the old
file, and `verify` fails until you regenerate.

**A graph's `namespace:` nests what it generates**, and is the answer when two
schemas in one app each have a `person.graphql`: `namespace: "Billing"` makes
that one `Billing::PersonQuery` in the same `person_query.rb`, and its shared
types module `Billing::GraphQLTypes`. Nothing else about the rule changes. See
[getting started](getting_started.md#more-than-one-schema).

Parsing a raw query *string* has no file to name it after, so it uses the
operation name (`query GetPerson` → `GetPerson`); dynamic `parse` falls back to
`Query` for an anonymous one (its constants are container-scoped, so collisions
are impossible) while `Codegen.generate` insists on a deliberate name. Override
with `name:` on either. Assign a parsed module to a constant and every nested
struct upgrades to that real path, so a cast failure names it rather than a hex
object address.

**Every nested type is named for the response key that selects it**, camelized
(`stargazers` → `Stargazers`, `nameWithOwner` → `NameWithOwner`, `_entities` →
`Entities`). Structs nest the way the selection does, so the constant path reads
like the query:

```graphql
query { repository { stargazers { edges { node { login } } } } }
```

```ruby
StargazersQuery::Result::Repository::Stargazers::Edges::Node
```

The name is a function of that field's own position and nothing else, which is
the property that matters when generated code is checked in and referenced from
app code: **adding, removing, or reordering an unrelated selection can never
rename a struct you already use.**
[`spec/naming_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/naming_spec.rb) asserts each of those three
edits leaves the name alone.

The key is used verbatim — no pluralization heuristics, so a list field `pets`
generates `Pets`, not `Pet`. To choose the name yourself, alias the field in the
query: `pet: pets { name }` generates `Pet` (and a `.pet` accessor).

**Union and interface members** are the one name that doesn't come from a key:
they take the type condition that produces them (`... on Book` → `Book`) inside
the container named for the field, plus the catch-all `Other`; a union hoisted
out of a shared fragment is named for the fragment; and several fields sharing
one collapsed union type take the first of their keys alphabetically. Still
position-determined, all of it.

Two collisions are handled rather than left to surprise you. A name that would
shadow the struct it nests in (`pet { pet { ... } }`) takes a numeric suffix
(`Pet2`), since a bare `Pet` inside `class Pet` would resolve to the child. And a
name that would shadow a constant the file *uses* is refused — a key `date`
beside a `Date` scalar prop turns `Date.iso8601` into a `NoMethodError` in a file
that typechecks. The message names both; alias either one in the query.

## Variables become typed kwargs

```graphql
mutation($name: String!, $species: Species!, $note: String) { ... }
```

```ruby
AddPetMutation.execute!(name: "Rex", species: AddPetMutation::Species::Dog)
```

- required vs optional falls out of nullability and defaults: nullable or
  defaulted variables become optional kwargs
- **absent and `null` are different things, and the kwarg says which.** Leaving a
  keyword out omits the variable, so the server's default applies; passing `nil`
  sends `null`, which is how a mutation clears a field. `bio: params[:bio]`
  therefore sends `null` when the param is missing — pass the keyword only when
  you mean to. A non-null variable can't carry `null`, so `nil` there still means
  omit.
- enum variables accept the enum or its wire value (`species: Species::Dog` or
  `species: "DOG"`)
- custom scalars serialize through the [scalar registry](scalars.md)
- one kwarg per declared variable, always — so adding a variable to a query adds
  a kwarg and leaves every existing call site alone. Two names are refused at
  generation, `$client` and `$variables`: the generated `execute` body already
  owns them. Rename the variable in the query.

**The kwarg is typed exactly as the schema types it, and the value is coerced
anyway.** Those aren't in tension, because they answer different questions:

```ruby
StargazersQuery.execute(first: 10)              # typechecks
StargazersQuery.execute(first: "10")            # srb tc error — you know it's a literal
StargazersQuery.execute(first: params[:first])  # typechecks, and "10" becomes 10
```

`first:` is `Integer`, never `T.any(Integer, String)`, so `srb tc` still catches
a call site that has the wrong thing. But a Rails param is `T.untyped` — sorbet
lets it through, and `execute` converts it in its body from what the scalar
already knows ([the table is in scalars.md](scalars.md#going-out--what-a-variable-kwarg-accepts)).
A value that won't convert raises `GraphWeaver::InputError` naming the variable,
the operation and the value.

That is why the emitted sig carries `.checked(:never)`: sorbet-runtime would
otherwise reject the String before the body could read it. Coercion stands in its
place for the arguments — stricter, and with a better message — and the `Result`
it returns is a `T::Struct`, so its props are still checked one by one.
(`T::Configuration.default_checked_level = :never` buys nothing back: that knob
governs `sig` dispatch, which the emitted sigs already opt out of, and `from_h`
allocates and costs the same either way.)

**Input objects** take the generated `T::Struct` or a plain hash — `.coerce`
normalizes underscored Symbol/String keys, enums accept wire values, nested
inputs accept hashes, and an unknown key raises with a spellchecked hint rather
than silently dropping:

```ruby
AdoptMutation.execute!(input: { name: "Rex", species: "DOG", nickname: "Rexy" })

# the struct form is the one srb tc checks field by field
AdoptMutation.execute!(input: AdoptMutation::AdoptionInput.new(name: "Rex", species: Species::Dog))
```

A struct is typed consts plus a compact per-field `FIELDS` table the
`GraphWeaver::InputStruct` runtime drives — `serialize` (aliased `to_h`) builds
the wire hash, `coerce` builds from a plain hash. `coerce` remembers which keys
the hash had, so `{nickname: nil}` sends `null` and `{}` omits the field. A
struct built with `.new` can't tell the two apart — every unset prop is nil
either way — so `nil` there means omit; reach for `coerce` to send an explicit
null. Nested inputs work, including recursive ones: a self-referential filter
generates cleanly, with `_and:`/`_not:` typed as the struct itself.

In the `generate!` workflow input types are emitted **once per schema**, one file
per type under `generated/types/` with `types.rb` as the manifest. Query modules
alias what they touch, so `AdoptMutation::AdoptionInput` still works and a shared
type keeps one identity across modules; a query module aliases only its *variable
root* types, so a deeply nested one is reached as `GraphQLTypes::<Type>`. Per-type
files keep drift reviewable: a schema migration diffs exactly the types it
touched, and types the schema drops are pruned on regeneration (`verify` flags
strays). Dynamic `parse` stays self-contained.

### An input object generates its whole closure

A result type is generated per selection set, because a selection set *is* the
question. An input object has no selection set, so the only static answer to
"what can `$where` hold" is every input type it can transitively reach — and
codegen emits a file for each. On a hand-written schema that closure is usually
the one type and nothing else. On a generated one (Hasura, Gatsby), where every
`_bool_exp` references every other, one `$where` reaches a thousand of them.

The escape is to stop making the filter a variable. Write it as a literal in the
query with a variable per leaf, and codegen has ordinary scalars to generate
instead of the closure — on the query that emitted ~1,200 files, exactly one:

```graphql
query($name: String!, $minHeight: Int!) {
  pokemon(where: { name: { _ilike: $name }, height: { _gte: $minHeight } }) {
    name
  }
}
```

`srb tc` gets *more* out of that, not less. `name: String`, `min_height: Integer`
are types it checks at every call site, where the variable form is
`T.any(PokemonBoolExp, T::Hash[T.untyped, T.untyped])` — and a hash built from
`params`, which is how a filter is really assembled, takes the untyped branch.
Refusals land on the leaf too, so `path` is the form field rather than the
comparison operator under it. Two shapes can't be inlined, and codegen says which
when a prop collision forces the question: a key chosen at runtime (the sort
column in `order_by: { <column>: asc }`), since GraphQL has no dynamic object
keys, and a list whose length only the runtime knows.

## Enums: one GraphQL enum, one Ruby type

Every schema enum a query touches — as a variable, in a result, or both —
becomes exactly one Ruby type in the shared module, named for the enum
(`GraphQLTypes::Species`), and every query module aliases it:

```ruby
species = SearchQuery.execute!(term: "Shelby").search.first.species
AddPetMutation.execute!(name: "Rex", species:)     # same class, no conversion
```

So a value read out of one query hands straight back into another's variable,
`case`/`T.absurd` is exhaustive across your app, and the class a field gets
doesn't depend on what else the query happened to reference. An enum value that
camelizes to nothing — `_` and `__` are both legal GraphQL — is refused at
generation: there is no constant to name it. Map the enum onto one of yours
instead.

`register_enum` replaces the generated `T::Enum` with your own app enum — see
[scalars.md](scalars.md#enums-map-onto-your-own-tenum). Dynamic `parse` emits the
enums into the query module itself; there's no cross-query set to share against,
but one enum is still one class within that module.

**The one misuse nothing catches** is comparing against the wire spelling:

```ruby
pet.species == "CAT"                    # => false, always, and silently
pet.species == GraphQLTypes::Species::Cat
```

A generated enum is a plain `T::Enum`, so `==` against a String is `false` —
`srb tc` allows it (`==` takes `BasicObject`) and nothing raises. sorbet-runtime
owns this question and ships the switch: turn on
`T::Configuration.enable_legacy_t_enum_migration_mode` in dev and test, and route
`soft_assert_handler` wherever your other soft assertions go. It covers your own
`T::Enum`s too, which is why it belongs there rather than in the generated
classes. Careful reading it: in that mode the comparison answers **true** (it
serializes first), so the handler, not the return value, is the signal.

## Selections

- **Fragments** — inline fragments and named spreads flatten into the selection;
  type conditions match exact names or interfaces/unions the type belongs to.
- **`@skip` / `@include`** — a directive-conditional field may be absent from the
  response regardless of schema nullability, so its generated type is always
  nilable.
- **Aliases** — result keys follow aliases; props are the underscored alias.

Props are always snake_case (`nameWithOwner` → `name_with_owner`). Reaching for
the wire name is a classic stumble, so it fails helpfully at both layers: `srb
tc` flags it statically, and at runtime (consoles, dynamic mode) the struct
raises a NoMethodError naming the prop that does exist — `use 'name_with_owner'`
for the exact wire name, `did you mean ...?` for a near-miss typo in either
casing.

A name that would shadow a method every struct answers — `class`, `hash`,
`display`, `to_json`, and `supplied` on an input — takes a trailing underscore
instead: `class` → `class_`, in results and input types alike, and the generated
source says so on the line above the prop. Only the Ruby name moves. It is the
one Ruby name for the field, so `.new`, `.coerce`, a result's `#to_h` and pattern
matching, and an `InputError`'s `#path` all use `class_` (an input error's
`#coordinate` still names the schema's `Tricky.class`) — while the wire keeps the
schema's spelling in both directions, so the query, the request, the response,
and `#as_json`/`#to_json` are untouched and `render json: result` never leaks a
trailing underscore.

### Abstract types

An abstract field emits **one struct per type condition the selection names**,
plus a catch-all `Other`, wrapped in a module with
`Type = T.type_alias { T.any(...) }` and a `from_h` that dispatches on
`__typename`. Generation therefore *requires* `__typename` in such a selection,
unaliased and unconditional — the wire response carries no type tag unless you
ask, and `from_h` reads it on every response. One `__typename` inside each
`... on Type` does **not** substitute, however many of them there are: the
dispatch runs before any member's selection applies, and a member the query never
named would carry none at all.

Size follows the query, not the schema: two `... on` conditions against GitHub's
`Node` — an interface with a few hundred implementations — emit three structs,
not a few hundred. Anything the query didn't name — a member you have no fragment
on, or one the schema grew *after* you generated — deserializes into `Other`,
carrying what the abstract type itself guarantees (an interface's selected
interface-level fields; for a union, `__typename`). Adding a union member
upstream is a non-breaking change, and it stays one here.

Two selections have nothing to dispatch between, so they skip the module and
become the struct directly: **no conditions at all** (interface-level fields
only) → one shared struct; **exactly one condition and nothing else** → that
type's struct, always nilable, since a non-matching runtime type comes back as
`nil` — so narrowing doubles as filtering. "Nothing else" is what keeps the miss
legible: a field every member answers — spelled bare, or inside a fragment on the
abstract type itself, which is the same selection — puts the field back on the
dispatch path, so the other members keep what they sent. Narrowing reads the match
off `__typename` when the selection carries one unaliased and unguarded, and off
"the object came back empty" when it doesn't — so an all-`@skip`/`@include`
narrowed fragment, or one whose `__typename` is itself guarded, is refused: a
match would be indistinguishable from a miss.

When a whole union field is selected as one named *shared* fragment
(`{ ...FeedItemFields }`), that type is hoisted once into `GraphQLTypes` — named
for the fragment — and each query aliases it, so the same union is one Ruby type
family across queries, not a fresh dispatch module per query. Like shared inputs,
it's a `generate!`-directory concern; dynamic `parse` inlines.

### Consuming a union — dispatch on the class, not `__typename`

`from_h` already reads `__typename` off the wire and builds the right member
struct, so what you hold is a real `Book` or `Disc`, not a tag. Branch on the
class and let Sorbet do the rest:

```ruby
items.each do |item|          # item : T.any(Result::Item::Book, Result::Item::Disc, Result::Item::Other)
  case item
  when Result::Item::Book then item.title     # narrowed to Book — .title is available
  when Result::Item::Disc then item.runtime   # narrowed to Disc — .runtime is available
  when Result::Item::Other then item.__typename # something this query names no fields on
  else T.absurd(item)
  end
end
```

Two things a `case` on the `__typename` string can't give you. `when Book`
*narrows*: inside the branch `item` is statically a `Book`, so its fields
typecheck and a `Disc` field is a compile error. And after every branch the
`T.any` is exhausted, so `T.absurd` asserts the `else` is unreachable — **write a
fragment for another member, regenerate, and the `T.absurd` stops compiling until
you handle it.** It is exhaustive over the members *this query asked about*, plus
`Other` — deliberately not "every type in the schema", which is what keeps a
`case` you wrote today compiling when upstream adds a member.

`__typename` is still there as a plain `String`, with one use the class can't
cover: two *differently-selected* occurrences of the same union are distinct type
families (`Result::Item::Book` is not `Result::FeaturedItem::Book`), so a `case`
written for one won't span the other. Select the union through a shared fragment
to hold it as one type across queries ([above](#abstract-types)); if all you have
is the bare tag, `__typename` is the common denominator, unchecked.

## Type helpers

Derived values (display names, emoji, predicates) belong next to the data but not
*in* it — rewriting wire values on the way in destroys the raw truth. Register a
plain module and every struct generated from that GraphQL type includes it,
whatever query it appears in:

```ruby
module PetHelpers
  def adult? = birthday && birthday < Date.today << 24
  def display_name = adult? ? "#{name} 🦴" : "#{name} 🐶"
end

GraphWeaver.extend_type("Pet", PetHelpers)

pet.display_name   # => "Shelby 🦴"
pet.name           # => "Shelby" — the wire value stays honest
```

The methods live on the struct, so they see its wire fields at runtime and
fakes/cassettes get the behavior automatically; registrations are additive
(repeated ones stack). The mixin is one of your own constants, so in Rails the
registration goes in a `to_prepare` block like `register_enum` does, and for the
same reason — [getting started](getting_started.md#2-run-the-generator) has the
rule and the boot order behind it. Editing the *mixin* in development needs a
restart, unlike a `.graphql` edit: a reload hands the constant a new module
object, and the `include` that took the old one doesn't run again.

For quick decoration, build the mixin inline — the block is `module_eval`'d into
a fresh module auto-named under `GraphWeaver::TypeHelpers`:

```ruby
GraphWeaver.extend_type("Pet") do
  def display_name = "#{name} 🐶"
end
```

The name is where the block is written and what it extends:
`GraphWeaver::TypeHelpers::Pet` at the top level,
`GraphWeaver::TypeHelpers::Billing::Pet` inside `GraphWeaver.graph :billing`.
Generated code spells it, so it depends on your source and nothing else — two
graphs can extend the same type name, and the name a `generate` bakes in is the
one a boot creates. The module is minted at registration, so no file declares
it; generation writes a `type_helpers.rbi` beside the modules that does, which
is what lets your `srb tc` resolve the `include`. Ruby never loads an `.rbi`, so
dropping the registration still fails loudly at require rather than quietly
handing the struct an empty module.

**Neither form has its method bodies statically checked**, for the same reason:
`srb tc` checks a mixin's method bodies in the module's own scope, not the
including struct's, so a helper reading a wire field (`name`, `birthday`) fails
with "method does not exist on the module" — and the block form has no source on
disk for `srb tc` to read at all. A *named* module can carry real sigs, though, by
declaring the fields it leans on: `abstract!` plus a
`sig { abstract.returns(String) }; def name; end` is how a mixin says "whatever
includes me has these", and the struct's `const`s satisfy them — generation
declares the override Sorbet demands there (`const :name, String, override:
true`, and `sig { override.returns(...) }` on an `alias:` accessor), which is
the one thing you couldn't add by hand: a `const` has no sig to put it in.
`T.unsafe(self).name` also silences it, at the cost of checking nothing. Either
beats `# typed: false` for a helper you want checked.

### Flat accessors with `alias:`

The one derivation the generator can type for you is a plain projection — a
selected field, possibly nested, exposed under a flat accessor. `alias:` emits a
sig'd delegator *into the struct body*, where the field is in scope, so it's
fully checked (the thing a mixin can't be):

```ruby
GraphWeaver.extend_type("Widget", alias: { tag: "meta.tag" })

# generated on the Widget struct:
#   sig { returns(T.nilable(String)) }
#   def tag = meta&.tag
```

Forms:

```ruby
alias: { tag: "meta.tag" }              # explicit accessor name
alias: "meta.tag"                       # accessor named after the last segment (`tag`)
alias: ["meta.tag", "meta.color"]       # several at once
alias: { label: "name", tag: "meta.tag" }
```

The path is the **Ruby** accessor chain, so its segments are snake_case props
(`name_with_owner.tag`), not wire names. It's typed from the selection: any
nullable hop makes the accessor nilable and inserts `&.`; the leaf can be a
scalar, enum, or nested struct. It's validated against each query at generation —
an unselected or misspelled segment (`did you mean 'tag'?`), a selector on a
non-list, or a name that collides with a real field all fail with a pointed
error. Registrations stack, like the mixin forms.

A segment can also be `first` or `last` to pick one element out of a list hop —
always nilable, since the list may be empty. This is what turns an
`_entities`-style "array that logically holds one thing" into a clean accessor:

```ruby
GraphWeaver.extend_type("Query", alias: { entity: "_entities.first" }, optional: true)

#   sig { returns(T.nilable(Widget)) }        # concrete, when the selection is one `... on Widget`
#   def entity = _entities&.first             # (a multi-fragment selection types it as the union)
```

`optional: true` makes the aliases *lenient*: a query whose selection doesn't fit
the path just omits the accessor instead of failing generation. Reach for it when
the alias lives on a universal type like `Query` — where a strict alias would
force *every* query to select the path — or when it only fits some selections. It
excuses a field the query didn't select, not a segment the schema doesn't have: a
typo or a wire-cased name (`findPets` for `find_pets`) still raises, since no
selection could ever satisfy it.

**One call does both halves.** `alias:` and a block are independent parts of the
same registration — the accessor is emitted into the struct body, the block
becomes a mixin the struct includes — so a block method can call an accessor the
same call declared:

```ruby
GraphWeaver.extend_type("Widget", alias: { tag: "meta.tag" }) do
  def shout = tag&.upcase
end
```

The block can't spell the `alias` half itself: `alias` is a Ruby keyword and the
block is `module_eval`'d Ruby, so writing it there would define a method alias
rather than a projection. It stays a keyword on the call.

For anything beyond a passthrough projection — real logic, still typed — reopen
the generated struct in your own file and add sig'd methods; Sorbet merges the
bodies. Every form above, and every error it raises, is a named example in
[`spec/aliases_spec.rb`](https://github.com/dpep/graph_weaver/blob/main/spec/aliases_spec.rb).

## Clients

A client is anything satisfying the [execute contract](transports.md) — a
`GraphWeaver::Client`, a transport, a `Retry`, a live schema class, a fake.
A module knows which graph it belongs to, and the graph knows how to reach it:
resolution is per call (`client:`) → a test mode's stand-in → the client its
[graph](getting_started.md#more-than-one-schema) names → `GraphWeaver.client`;
the canonical list is in [transports](transports.md#client-resolution). There is
no setter — `MyQuery.client` reads back what the module would execute through,
and a [parsed](#dynamic-mode) module, which has no graph, runs
against whatever parsed it. A graph naming its own client is no reason a module
escapes [testing's `graphql:` tag](testing.md), which is exactly the instruction
to replace it; what the *example* says still wins.

`client` lives in the gem (`GraphWeaver::QueryModule`, extended by every
generated module). A generated file says nothing about transport — only a private
`GRAPH` naming its graph, which is also how `graphql: :fake` fabricates each
module's own schema with two graphs in play, and the
`:graph` on every [instrumentation event](logging.md#the-payload) the module's
`execute` produces.

## Deserializing a response from another client

`execute` is two steps: make the request, then cast the JSON into the typed
structs. Only the second step is GraphWeaver-specific, and it's exposed on its
own — so you can fetch with any GraphQL client (Apollo, a raw `Net::HTTP` post, a
batching layer, a recorded fixture) and hand the result over:

```ruby
raw = my_graphql_client.post(PersonQuery::QUERY, id: "1")
# => {"data" => {"person" => {...}}, "errors" => [...], "extensions" => {...}}

response = PersonQuery.from_response(raw)   # GraphWeaver::Response[Result]
person   = response.data!.person            # typed, no network

person = PersonQuery.from_response!(raw).person   # or skip the envelope
```

`execute` *is* `from_response(client.execute(...))`, so the envelope is identical.
The one requirement: pass the response **verbatim** — a hash (or anything with
`#to_h`) with the standard GraphQL shape and **wire-cased string keys**
(`"person"`, `"nameWithOwner"`), the top-level `"data"` / `"errors"` /
`"extensions"` keys included. Don't symbolize or snake_case it first. Which is
checked, since symbolizing is the likeliest thing to go wrong at this seam: a
hash carrying neither `"data"` nor `"errors"` raises a `GraphWeaver::CastError`
naming the keys it *did* find, rather than handing back an envelope that reports
success with no data. `nil` and a bare String are refused the same way.

## Generating

Queries live as `.graphql` files (the source of truth), generation writes the
Ruby, and verification fails when the two drift. The conventional layout
(configurable via `GraphWeaver.queries_paths` / `generated_paths` /
`schema_path`):

```text
app/graphql/
  schema.json        # introspection dump (or schema.graphql SDL)
  queries/           # *.graphql / *.gql, nested — hand-written, reviewed
  fragments/         # shared fragments, spread by name from any query
  generated/
    types.rb         # manifest: requires + forward declarations, in load order
    types/           # one file per shared type
    type_helpers.rbi # only with a block-form extend_type — declares its module
    *_query.rb       # one module per query — generated, checked in, never edited
    *_mutation.rb    # ...and per mutation
```

```sh
rake graph_weaver:generate    # queries_paths -> generated_paths.first
rake graph_weaver:verify      # fail if anything is stale — run in CI
```

The tasks self-register in Rails; elsewhere add `require "graph_weaver/tasks"` to
your Rakefile. Scalar/enum/type registrations are baked into generated source, so
they must run first — in Rails they do, since the tasks depend on `:environment`.
Or call the same APIs directly:

```ruby
schema = GraphWeaver::SchemaLoader.load(GraphWeaver.schema_path)
GraphWeaver.generate!(schema:)            # write the modules
GraphWeaver.verify_generated!(schema:)    # the freshness guard, one line in a spec
```

**`verify_generated!` costs what `generate!` costs**, minus the writes — it
recomputes the whole plan whether nothing is stale or everything is. So it
belongs in *one* example per suite run, not in a `before` or an assertion per
example, where it reads like a cheap check and isn't.

`generate!` returns every file the plan produces, but rewrites only the ones whose
bytes changed; `GraphWeaver.changed_files` is that subset. So
`rake graph_weaver:generate` prints `wrote` for what moved and `N already up to
date` for the rest, and a watching dev server has one module to reload instead of
all of them. The unregistered-scalar report is the rake task's `puts`, so off rake
read `GraphWeaver.untyped_scalars` for the unioned list — or set
[`GraphWeaver.logger`](logging.md), which `generate!` names them on at `info` as
it goes. The schema dump is step 0: codegen reads it, never a live endpoint, and
generating without one fails pointing at exactly that.

**A type shared across query modules lives in `GraphQLTypes` and is aliased in.**
Input types, schema enums, and unions hoisted from shared fragments are all one
kind of thing — a type that would otherwise be copied into every query that
touches it — so they live in one module, one file each, and a query module that
uses any of them opens with `require_relative "types"`. Rename the constant
(`GraphWeaver.types_module=`, or `generate!(types_module:)`) when one app
generates against two schemas. One module is one namespace, so a shared fragment
whose name is already a schema type in that module is refused at generation,
naming both.

**Generation prunes.** Rename or delete a `.graphql` and the module it used to
produce is deleted on the next `generate!` — which says so, since a deletion you
didn't expect is the one worth reading; `verify` flags it as stale until you
regenerate. Only files carrying GraphWeaver's header
(`# Generated by GraphWeaver <version> — do not edit.`) are ever deleted, so
hand-written files in the output directory are safe. A run that finds **no**
queries says where it looked rather than exiting 0 in silence, and
`verify_generated!` fails outright.

**A refusal writes nothing at all** — not even the files that planned cleanly —
so a failed run leaves the tree exactly as it was, and it reports *every* query it
refused rather than the first.

**Generation is deterministic.** The same schema and queries produce
byte-identical files, on any machine, in any order — everything with a
non-obvious order (schema members, enum values, requires, hoisted names) is
sorted, and a spec asserts it both across calls and against the checked-in
fixtures. So regenerating a file you didn't change produces no diff,
`verify_generated!` never fails spuriously, and a generated file is worth
reviewing line by line.

Regenerate when: a query changes, the schema changes, a registration changes, or
GraphWeaver itself upgrades — **any release can change what codegen emits**, patch
releases included, and `verify_generated!` is what catches it. The rake tasks that
spot a *schema* change for you — `schema:diff`, `schema:refresh`, `queries:check`
— are in [getting started](getting_started.md#5-verify-in-ci); a
[`schema_stale?`](errors.md) error in production is the late signal.

### Loading what it wrote

In Rails, loading is automatic — the Railtie requires every generated file at
the end of boot, after your initializers and after any registrations of your own
in a `to_prepare` block, and again after each development reload. Elsewhere it's
explicit, factory_bot-style:
`GraphWeaver.load_generated!` requires every file under `generated_paths`.

**Outside Rails, four things have to agree**, and nothing wires them together for
you — a script that generates its own modules sets all four:

1. `queries_paths` — where `generate!` reads `.graphql` files.
2. `generated_paths` — where it writes, and where `load_generated!` reads. Point
   them at the same directory or generation is invisible.
3. the call above, before the first `execute` — nothing else requires the files.
4. `GraphWeaver.client =` — a module belonging to no declared graph has no
   other [client](#clients) to reach for.

Miss (3) and the script gets a `NameError` for its own module; miss (4) and it
gets `PersonQuery: client must respond to #execute(query, variables:), got
NilClass` from a module that otherwise looks fine.

Every directory setting is a list — `queries_paths`, `generated_paths`,
`fragments_paths` — and every entry is read (entries may be globs; the generated
default includes `app/graphql/*/generated`, so per-schema layouts load too).
Assigning a String wraps it, so pointing at one directory stays a one-liner.
`generate!` writes into the first `generated_paths` entry — one run, one output
directory. `schema_path` is the one singular setting: a run reads one schema, so a
list would name a dump nothing ever opens. A relative path resolves against
`GraphWeaver.root` — `Rails.root` in a Rails app, the working directory otherwise
— so where you started the process doesn't change which files it reads.

Plain requires, not Zeitwerk: Zeitwerk would expect `Generated::PersonQuery` from
`generated/person_query.rb`. In development a query edit regenerates and reloads
before the next request; everywhere else generated code changes only on
regeneration — restart, like a schema migration, or call
`GraphWeaver.reload_generated!` after regenerating in another terminal.

## Dynamic mode

`GraphWeaver.parse` generates + evals in one step (no build artifact, evaled into
an anonymous container — no global constants leak). Same runtime semantics;
invisible to `srb tc`, so prefer the build step where static checking matters.
`GraphWeaver.run(source, query, **variables)` — or `client.run` — is the one-shot
form: parse and execute in one call, no module kept. In development
`client.load_queries!` parses every query file into modules with the same names
generation would use.

A parsed module **runs against whatever parsed it** — `client.parse(query)` and
`load_queries!` bind the client they came from, and `GraphWeaver.parse(client:)`
says it outright. That is a property of parsing, not a slot you can set later:
it generates no file, so it has no graph to read a client off, and a per-call
`client:` still wins over it.

In an app with [more than one graph](getting_started.md#more-than-one-schema), a
parsed module belongs to one of them — that is what a `graphql:` tag runs it
against and whose `client` it reaches for, the same thing generation writes into
a file. It is read off the schema
you parsed against when a graph runs that class in-process; say it outright
otherwise:

```ruby
PersonQuery = GraphWeaver.parse(schema: BILLING, query: "…", graph: :billing)
```

Generated source is eval'd, so inputs are validated: module names must be
constant names, and query heredocs can't be terminated early. Still: queries are
code — don't feed untrusted strings to parse.
