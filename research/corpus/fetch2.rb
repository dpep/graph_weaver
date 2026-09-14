require_relative "/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib/graph_weaver"

DIR = "/tmp/claude/graph_weaver/corpus"

ENDPOINTS = {
  "swapi" => "https://swapi-graphql.netlify.app/graphql",
  "saleor" => "https://demo.saleor.io/graphql/",
  "graphqlzero" => "https://graphqlzero.almansi.me/api",
  "apisguru" => "https://api.apis.guru/v2/graphql",
  "tcgdex" => "https://api.tcgdex.net/v2/graphql",
  "wpgraphql" => "https://www.wpgraphql.com/graphql",
  "wpcontent" => "https://content.wpgraphql.com/graphql",
  "ehri" => "https://portal.ehri-project.eu/api/graphql",
  "trygql-basic" => "https://trygql.formidable.dev/graphql/basic-pokedex",
  "trygql-web" => "https://trygql.formidable.dev/graphql/web-collections",
  "countries" => "https://countries.trevorblades.com/graphql",
  "gdom" => "https://api.hashnode.com/",
  "mocki" => "https://api.mocki.io/v2/c6d5a8a0/graphql",
  "nautilus" => "https://api.fabricjs.com/graphql",
  "spotify-demo" => "https://spotify-demo-api-fe224840fc96.herokuapp.com/v1/graphql",
  "kiwi" => "https://api.skypicker.com/umbrella/v2/graphql",
  "bitquery" => "https://graphql.bitquery.io/",
  "opentargets" => "https://api.platform.opentargets.org/api/v4/graphql",
  "pokeapi-beta" => "https://beta.pokeapi.co/graphql/v1beta",
  "monday" => "https://api.monday.com/v2",
  "gitpod" => "https://api.dotcms.com/api/v1/graphql",
  "dbpedia" => "https://directions-api.com/graphql",
}

target = ARGV[0]
ENDPOINTS.each do |name, url|
  next if target && name != target
  path = File.join(DIR, "#{name}.json")
  next puts("#{name}: cached") if File.exist?(path) && File.size(path) > 1000

  started = Time.now
  begin
    transport = GraphWeaver::Transport::HTTP.new(url, read_timeout: 120, open_timeout: 15)
    GraphWeaver::SchemaLoader.introspect(transport, cache: path, ttl: 10**9)
    puts format("%-16s OK   %7.1fs  %s bytes", name, Time.now - started, File.size(path))
  rescue StandardError => e
    File.delete(path) if File.exist?(path) && File.size(path) < 1000
    puts format("%-16s FAIL %7.1fs  %s: %s", name, Time.now - started, e.class, e.message.to_s[0, 160])
  end
end
