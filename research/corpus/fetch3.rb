require_relative "/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib/graph_weaver"

DIR = "/tmp/claude/graph_weaver/corpus"

ENDPOINTS = {
  "saleor" => "https://demo.saleor.io/graphql",
  "hasura-poll" => "https://realtime-poll.hasura.app/v1/graphql",
  "hasura-chat" => "https://realtime-chat.hasura.app/v1/graphql",
  "hasura-todo" => "https://hasura-todo-app.hasura.app/v1/graphql",
  "hasura-backend" => "https://hasura.io/learn/graphql/graphiql",
  "anime-themes" => "https://api.mangadex.org/graphql",
  "gtfs-otp" => "https://api.digitransit.fi/routing/v1/routers/hsl/index/graphql",
  "openalex" => "https://api.openalex.org/graphql",
  "steamsets" => "https://api.steamsets.com/graphql",
  "yelp" => "https://api.graphql.jobs/",
  "rawg" => "https://api.rawg.io/graphql",
  "swop" => "https://swop.cx/graphql",
  "dgraph" => "https://play.dgraph.io/graphql",
  "github-mirror" => "https://api.github.com/graphql",
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
