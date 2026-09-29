# Lane: where does loading a large supergraph spend its time — and what is structural

Read research/briefs/brief-common.md first (gate, commit rules, traps), then CLAUDE.md's
design section, then `lib/graph_weaver/schema_loader.rb` — `load`, `build_sdl`,
`strip_federation` (`link_namespaces`, `remove_inaccessible`, `federation_definition?`,
`strip_federation_directives`), `routing_table` / `RoutingTable`, and `Graph#schema` in
`lib/graph_weaver/graph.rb` plus `Client#schema` in `client.rb` for who calls `load` when.

## Stance

You are the performance engineer who refuses to optimize on a hunch. The owner says
loading a large supergraph "can get a little slow". Your first deliverable is the
number: where the time goes, by stage, on inputs big enough to matter. Your second is
whichever changes the profile supports — and none it doesn't. Structural wins first
(doing a thing once instead of twice, not doing it at all on a path that doesn't need
it, skipping a round trip through text); algorithmic ones only where the profile points
at a loop. Behaviour must not change: same schema, same routing table, byte-identical
generated code. If a candidate below turns out not to pay, say so with the measurement
and skip it.

## Step 1 — the measuring tool (commit it; it outlives this lane)

`bin/bench-load` (or `research/corpus/bench_load.rb` if it shouldn't ship — decide by
whether a maintainer would run it again; lean: `bin/`, beside `bin/round-trip`):
- synthesizes a composed supergraph SDL at a size (`-t 500`, `2000`, `8000` object
  types, ~8 fields each, a fair share of `@join__type`/`@join__field` applications, a
  few `@inaccessible` types and fields, three subgraphs, one `@link` header) — the
  repo's fixture supergraph is 6 KB, far too small to time; also accepts a real
  supergraph path;
- times, separately and with a warm-up: `GraphQL.parse`, `link_namespaces`,
  `remove_inaccessible`, the definition/directive strip, `to_query_string`,
  `GraphQL::Schema.from_definition` on the result, `SchemaLoader.load` end to end, and
  `SchemaLoader.routing_table` end to end; prints a table, ms rounded to what three
  runs support (say the variance);
- `--profile` runs stackprof (it's a dev dependency? check; add it if not) over `load`
  and prints the top frames.
Report the table for all three sizes BEFORE any change, and name the dominant stage.

## Step 2 — candidates, in the order the lead expects them to pay

1. **Does runtime need the schema at all?** `GraphWeaver.new("supergraph.graphql")`
   at app boot: is the schema loaded eagerly, or only when something asks (codegen,
   `check_query`, a test mode, `schema:diff`)? A generated module's `execute` needs no
   schema. If a dump-built client loads on construction, make it lazy — the biggest
   possible win is not parsing at all in a production boot. Prove with a scratch
   boot that never touches the file (an `strace`-shaped check: stub `File.read` and
   assert it isn't called).
2. **Parse once.** `load` and `routing_table` each read and parse the same file; a
   graph asks for both. Share the AST (a per-process memo keyed by resolved path +
   mtime + size, holding the parsed document and/or the built schema and table),
   invalidated when the file changes — `schema:refresh` writes it and then reads it.
   Say what a stale-memo bug would look like and why the key prevents it.
3. **Build from the document, not from text.** graphql-ruby's public
   `from_definition` takes a string, but `from_definition` itself parses and calls
   `GraphQL::Schema::BuildFromDefinition.from_document(document, ...)`. Check the
   signature on the gem's floor and ceiling versions (Gemfile.lock and the gemspec's
   constraint); if it's stable across them, build from the filtered AST and skip
   `to_query_string` + the second parse. If it's private/unstable across versions,
   say so and skip — a monkeypatch-shaped dependency is worse than a reprint.
4. **The fixpoint and the per-node walks.** `remove_inaccessible` re-maps every
   definition per iteration and the strip walks every node's directives; measure
   whether either registers at 8000 types. If they don't, leave them alone and say so.
5. Anything the profile shows that isn't listed.

## Step 3 — proof that nothing changed

For each change: `bin/generate` clean; `bin/round-trip -c 2000` and `-q
spec/support/federation/queries`; `bin/federation-diff`; AND a byte-identity check —
generate the fixture queries and the corpus dumps' queries before and after (the
`research/corpus` scripts and the hunt-7 objnode harness under
`research/logs/hunt7-report.md` describe how) and diff the output. `RoutingTable`
equality before/after on the synthesized supergraph (`to_h` or a field-by-field
comparison). Two random seeds. Numbers after, same table.

## Ownership

`lib/graph_weaver/schema_loader.rb`, `lib/graph_weaver/graph.rb`,
`lib/graph_weaver/client.rb` (laziness only), `bin/bench-load`, `Gemfile`/gemspec for
stackprof as a dev dependency if needed, specs, one CHANGELOG block under
`## Unreleased` (create it; 0.7.7 is cut) — measurements in the bullet only where
they change what a user does. No other lane is running. Base off origin/main at the
current head.

## Report

The before table (three sizes), the dominant stage, each candidate with pay/skip and
the number that decided it, the after table, the byte-identity evidence, shas.
