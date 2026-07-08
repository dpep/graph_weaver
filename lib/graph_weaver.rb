require "graphql"
require "sorbet-runtime"

require_relative "graph_weaver/codegen"
require_relative "graph_weaver/http_executor"
require_relative "graph_weaver/schema_loader"
require_relative "graph_weaver/version"

# opt-in extras:
#   require "graph_weaver/faraday_executor"        # Faraday transport
#   require "graph_weaver/directive_defaults_patch" # fix graphql-ruby
#     dropping directive argument defaults when loading SDL (needed for
#     Apollo supergraph SDL until rmosolgo/graphql-ruby#5659 ships)
