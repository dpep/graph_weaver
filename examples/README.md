# Examples

Four runnable scripts, smallest first. Each is the smallest thing that shows
its idea; run them straight from a checkout.

| | shows | needs |
|---|---|---|
| [`countries.rb`](countries.rb) | the whole loop in 30 lines: a client, `parse`, a typed result, a one-shot `run!` | network |
| [`rick_and_morty.rb`](rick_and_morty.rb) | filtering, pagination, an aliased field, a block-built type helper | network |
| [`federation.rb`](federation.rb) | a federated graph planned and stitched in-process, with the fetch trace and a refusal | nothing |
| [`github/`](github) | the production path: auth, a custom scalar, checked-in generated modules | a token |

```sh
bundle exec examples/countries.rb JP BR
bundle exec examples/rick_and_morty.rb morty
bundle exec examples/federation.rb
bundle exec examples/github/run.rb        # gh auth login, or GITHUB_TOKEN=...
```

**`federation.rb` is the one with no network at all** — three real subgraphs,
a boundary-crossing query through a generated module, the trace of the fetches
it took, and a refusal it declines to plan. `spec/examples_spec.rb` runs it on
every build.

**`github/` is the only one with committed generated code**, so it's the one
that looks like an app:

- [`setup.rb`](github/setup.rb) — the shared wiring an initializer would hold:
  auth, `register_scalar("DateTime", Time)`, the client.
- [`queries/`](github/queries) → [`generate.rb`](github/generate.rb) →
  [`generated/`](github/generated) — the build loop `rake graph_weaver:generate`
  runs in a Rails app.
- [`run.rb`](github/run.rb) — stars this repo ⭐ and introduces you to your
  fellow stargazers.

Regeneration introspects GitHub's schema (a few seconds, cached to a gitignored
`github/schema.json`); `run.rb` alone never introspects, because the generated
modules already carry their types.
