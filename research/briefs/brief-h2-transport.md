# Lane: transport and generator — A7, A8, C6, D6

Read /tmp/claude/graph_weaver/brief-hunt2-common.md first.

You are the production engineer who owns the wire and the install generator.

- **A7**: the generator's `.rubocop.yml` append guards with a textual `AllCops:` match, but RuboCop *replaces* `Exclude` arrays on merge rather than unioning — so whenever `AllCops:` isn't literally in that one file (defaults, or an `inherit_from:`), the appended block wipes the effective exclude list, RuboCop's own `vendor`/`node_modules`/`tmp` included. The report verified the fix: append with `inherit_mode: merge: [Exclude]` scoped to the block, so it unions. Spec against the report's `t5_rubocop_merge.rb` shape (real rubocop config resolution if the gem is available in a scratch GEM_HOME; otherwise assert the YAML shape and document the reason). Also D6's multi-document `.rubocop.yml`: detect a second `---` and print the lines instead of appending.
- **A8**: `Transport::Faraday#url` encodes params with `URI.encode_www_form`, not Faraday's encoder, so Array/Hash params (`a: [1,2]`, `a: {b: "c"}`) are misreported — and `:wire` stubs the wrong url. Use `connection.build_exclusive_url(nil, connection.params)`, byte-identical to the wire. Spec over the report's cases plus the two `spec/faraday_spec.rb` already pins.
- **C6**: a non-String header value (`"X-Int" => 5`) escapes as net/http's bare `NoMethodError: undefined method 'strip'`. `to_s` it, or refuse naming the header — pick the one-rule answer (procs already resolve; nil already drops; so `to_s` for everything else is the consistent third rule).
- **D6**: a prebuilt `Faraday::Connection` never gets graph_weaver's `User-Agent` because Faraday pre-fills one and `||=` never fires. Decide whether the "a prebuilt connection owns its headers" comment or the UA's stated purpose wins; make the code and the comment agree.

Ownership: `lib/graph_weaver/transport.rb`, `lib/graph_weaver/transport/**`, `lib/generators/**`, `spec/http_spec.rb`, `spec/faraday_spec.rb`, `spec/install_generator_spec.rb`, new specs, `docs/transports.md`. Not yours: everything else.
