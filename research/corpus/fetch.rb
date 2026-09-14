# Fetch public GraphQL schemas into the corpus dir, via GraphWeaver's own
# transport + SchemaLoader.introspect (so the loader is exercised too).
require_relative "/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib/graph_weaver"

DIR = "/tmp/claude/graph_weaver/corpus"

ENDPOINTS = {
  "rickandmorty" => "https://rickandmortyapi.com/graphql",
  "anilist" => "https://graphql.anilist.co",
  "swapi" => "https://swapi-graphql.netlify.app/.netlify/functions/index",
  "spacex" => "https://spacex-production.up.railway.app/",
  "gitlab" => "https://gitlab.com/api/graphql",
  "everbase" => "https://api.everbase.co/graphql",
  "barcelona" => "https://barcelona-urban-mobility-graphql-api.netlify.app/graphql",
  "artsy" => "https://metaphysics-production.artsy.net/v2",
  "fruits" => "https://fruits-api.netlify.app/graphql",
  "universe" => "https://www.universe.com/graphql",
  "hivdb" => "https://hivdb.stanford.edu/graphql",
  "wordpress" => "https://wpgraphqldemo.com/graphql",
  "digitransit" => "https://api.digitransit.fi/routing/v2/hsl/gtfs/v1",
  "tmdb" => "https://tmdb.apps.quintero.io/",
  "ghibli" => "https://ghibli.dev/graphql",
  "react-finland" => "https://api.react-finland.fi/graphql",
  "camara" => "https://graphql.camara.leg.br/",
  "kitsu" => "https://kitsu.io/api/graphql",
  "contentful" => "https://graphql.contentful.com/content/v1/spaces/f8bqpb4ltp4z/",
}

target = ARGV[0]
ENDPOINTS.each do |name, url|
  next if target && name != target
  path = File.join(DIR, "#{name}.json")
  next puts("#{name}: cached") if File.exist?(path) && File.size(path) > 1000

  started = Time.now
  begin
    transport = GraphWeaver::Transport::HTTP.new(url, read_timeout: 120, open_timeout: 20)
    GraphWeaver::SchemaLoader.introspect(transport, cache: path, ttl: 10**9)
    puts format("%-16s OK   %7.1fs  %s bytes", name, Time.now - started, File.size(path))
  rescue StandardError => e
    File.delete(path) if File.exist?(path) && File.size(path) < 1000
    puts format("%-16s FAIL %7.1fs  %s: %s", name, Time.now - started, e.class, e.message.to_s[0, 200])
  end
end
