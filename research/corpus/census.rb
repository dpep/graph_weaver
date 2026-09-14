require_relative "/Users/dpepper/code/lib/ruby/graph_weaver/.claude/worktrees/agent-acd01563ae166f51e/lib/graph_weaver"

paths = ARGV
rows = paths.map do |path|
  name = File.basename(path)
  started = Time.now
  begin
    schema = GraphWeaver::SchemaLoader.load(path)
    kinds = Hash.new(0)
    schema.types.each_value { |t| kinds[t.kind.name] += 1 }
    [name, "OK", format("%.1fs", Time.now - started), kinds["OBJECT"], kinds["INPUT_OBJECT"],
      kinds["INTERFACE"], kinds["UNION"], kinds["ENUM"], kinds["SCALAR"],
      schema.types.size]
  rescue StandardError => e
    [name, "LOAD FAIL: #{e.class}: #{e.message.to_s[0, 160]}", format("%.1fs", Time.now - started)]
  end
end

puts format("%-28s %-6s %6s %7s %7s %6s %6s %6s %7s %7s",
  "schema", "load", "secs", "objects", "inputs", "ifaces", "unions", "enums", "scalars", "total")
rows.each do |row|
  if row[1] == "OK"
    puts format("%-28s %-6s %6s %7d %7d %6d %6d %6d %7d %7d", *row)
  else
    puts format("%-28s %s", row[0], row[1])
  end
end
