# typed: true
# frozen_string_literal: true

require_relative "../graph_weaver"

# faker is optional — semantic values (name/email/age/price/...) when
# present, type-based values when not
begin
  require "faker"
rescue LoadError
  # fall back to type-based generation
end

# Opt-in test tooling: require "graph_weaver/testing" from your spec
# helper (never from production code). Nothing here needs configuring —
# what a mode runs against is derived (see CLIENT_MODES). Configure to
# override a derivation, or to tune fabricated values:
#
#      GraphWeaver::Testing.configure do |config|
#        config.schema = MySchema                  # overrides the derived schema
#        config.router = { supergraph: "supergraph.graphql" }  # when it isn't the dump
#        config.context = { current_user: }        # baseline GraphQL context
#        config.default_mode = :fake               # untagged examples (graph_weaver/rspec)
#        config.seed = 42                          # reproducible fakes
#        config.mode = :faker                      # or :literal; nil = auto
#        config.overrides = { "Person.name" => "Daniel" }
#        config.list_size = 2..4
#        config.null_chance = 0.1                  # nullable fields go nil sometimes
#        config.cassette_dir = "spec/cassettes"
#      end
#
# mode picks how values are fabricated:
#      :faker   — semantic, field-name matched (requires the faker gem)
#      :literal — plain type-derived values ("name-1", seeded numbers)
#      nil      — auto: :faker when the gem is loaded, else :literal
#
# rspec users: require "graph_weaver/rspec" instead — it hooks the suite
# (seed from rspec, a client per example from its `graphql:` tag).
module GraphWeaver
  module Testing
    MODES = [:faker, :literal].freeze

    # What an example can run against, named by the rspec tag that selects
    # it — `it "…", graphql: :in_process` (see graph_weaver/rspec):
    #
    #      :fake        fabricated, schema-correct data; no resolvers run
    #      :in_process  your resolvers, one live schema class, in-process
    #      :router      your resolvers, across a federated graph
    CLIENT_MODES = %i[fake in_process router].freeze

    class Config
      attr_accessor :overrides, :seed, :list_size, :null_chance, :cassette_dir, :context,
        :record, :anonymize
      attr_writer :schema
      attr_reader :mode, :router, :default_mode

      def initialize
        @overrides = {}
        @seed = nil
        @list_size = 1..3
        @null_chance = 0.0
        @mode = nil # auto
        @schema = nil
        @located = nil # the committed dump, once located
        # not under spec/fixtures: `fixtures :all` globs that path for
        # `{**,*}/*.yml` and would try to load cassettes as ActiveRecord
        # fixtures, a subdirectory included
        @cassette_dir = "spec/cassettes"
        # what an example with no `graphql:` tag runs against. nil leaves
        # GraphWeaver.client alone: swapping every example onto something
        # else is too surprising to be a default.
        @default_mode = nil
        # the GraphQL context every :in_process / :router example starts
        # from; graphql_context merges onto it
        @context = {}
        # Router arguments, when the composed supergraph isn't the
        # conventional dump — { supergraph:, subgraphs: }, subgraphs optional
        @router = nil
        # GRAPHWEAVER_RECORD=1 rspec ...  -> Testing.cassette re-records
        @record = !ENV["GRAPHWEAVER_RECORD"].to_s.empty?
        # anonymize responses as they're recorded (needs config.schema)
        @anonymize = false
      end

      # the explicitly configured schema, else the conventional dump
      # (SchemaLoader.locate at GraphWeaver.schema_path) — nil when
      # neither exists
      def schema
        # the dump memoizes separately: explicit_schema has to stay honest
        # about whether anyone set one, since :in_process won't run a dump's
        # resolver-less types as if they were the live class
        @schema || (@located ||= GraphWeaver::SchemaLoader.locate)
      end

      # What's been set, without falling back to the dump — so validating
      # overrides at configure time doesn't force a schema load on a suite
      # that never asks for one.
      def explicit_schema = @schema

      def mode=(mode)
        unless mode.nil? || MODES.include?(mode)
          raise ArgumentError, "mode: must be one of #{MODES.inspect} (or nil for auto), got #{mode.inspect}"
        end

        @mode = mode
      end

      def default_mode=(mode)
        unless mode.nil? || CLIENT_MODES.include?(mode)
          raise ArgumentError,
            "default_mode: must be one of #{CLIENT_MODES.inspect} (or nil to leave " \
            "GraphWeaver.client alone), got #{mode.inspect}"
        end

        @default_mode = mode
      end

      # the pre-tag spelling of default_mode = :fake
      def auto_fake = @default_mode == :fake
      def auto_fake=(on)
        self.default_mode = (on ? :fake : nil)
      end

      # Router arguments, for a supergraph derivation can't find: `{
      # supergraph: "supergraph.graphql" }` is enough — subgraphs are
      # derived from what each loaded schema defines. Naming one is for
      # what derivation can't settle, or for `"reviews" => :fake`, which
      # fabricates a subgraph this process doesn't serve.
      def router=(arguments)
        unless arguments.nil? || (arguments.is_a?(Hash) && arguments[:supergraph])
          raise ArgumentError,
            "router: must be the arguments to build one, e.g. { supergraph: \"supergraph.graphql\" }"
        end
        if arguments&.key?(:context)
          # the rspec hook resets the router's context from config.context
          # every example, so one set here would silently never be read
          raise ArgumentError, "router: context: is set as config.context — the baseline every " \
            ":in_process and :router example starts from"
        end
        unknown = (arguments&.keys || []) - %i[supergraph subgraphs]
        raise ArgumentError, "router: doesn't take #{unknown.join(", ")}" if unknown.any?

        @router = arguments
        @built_router = nil
      end

      # Built once: parsing the supergraph is setup, not per-example work.
      # #context is settable, so an example that runs as someone else sets
      # that rather than rebuilding — the rspec hook resets it each time.
      def built_router
        @built_router ||= Router.new(supergraph: supergraph!, subgraphs: @router && @router[:subgraphs])
      end

      # The composed supergraph :router plans against — named, or the
      # conventional dump when that's what it is. A client can't supply
      # one: its schema is the API schema a router serves, with the
      # @join__* routing table stripped out.
      def supergraph!
        return @router[:supergraph] if @router

        path = GraphWeaver::SchemaLoader.locate_path
        return path if path && supergraph?(path)

        raise GraphWeaver::Error, ":router needs the composed supergraph SDL — a client's schema " \
          "is the API schema the router serves, with the @join__* routing table stripped out, so " \
          "the supergraph has to be named. #{path ? "#{path} carries no @join__* markers" : "Nothing on disk at #{GraphWeaver.schema_path}"}. " \
          "Set GraphWeaver::Testing.config.router = { supergraph: \"supergraph.graphql\" }."
      end

      # The live schema class :in_process runs against: the one you named,
      # the one the client already runs in-process, else derived from what
      # the loaded schema classes define (LiveSchema).
      def live_schema
        @live_schema ||= @schema || GraphWeaver.live_schema || LiveSchema.detect(reference_schema!)
      end

      # The schema everything else derives from: the one you set, else the
      # committed dump, else the schema the app's client talks to.
      def reference_schema!
        found = schema || (GraphWeaver.client.schema if GraphWeaver.client.respond_to?(:schema))
        return found if found

        raise GraphWeaver::Error, "no schema to run against — GraphWeaver.client isn't set, " \
          "there's no schema dump at #{GraphWeaver.schema_path}, and " \
          "GraphWeaver::Testing.config.schema is unset. Set any one of them."
      end

      private

      def supergraph?(source)
        GraphWeaver::SchemaLoader.routing_table(source)
        true
      rescue GraphWeaver::Error
        false
      end
    end

    class << self
      def config
        @config ||= Config.new
      end

      def configure
        yield config
        # a typo'd override key pins nothing and the test still passes, so
        # catch it here — while the block that set it is still on the stack
        validate_overrides!(config.explicit_schema, config.overrides) if config.explicit_schema
        config
      end

      # Override keys name schema coordinates: "Type.field", or a bare field
      # name matching that field on any type. Anything else is a typo that
      # would silently fabricate random data instead of pinning a value.
      def validate_overrides!(schema, overrides)
        overrides.each_key { |key| validate_override_key!(schema, key.to_s) }
      end

      # back to defaults — between tests, or to undo an experiment
      def reset!
        @config = nil
      end

      # resolve a cassette name ("github") against cassette_dir; paths
      # with separators or extensions pass through
      def cassette_path(name)
        return name if name.include?("/") || name.end_with?(".yml", ".yaml")

        File.join(cassette_dir, "#{name}.yml")
      end

      # The configured directory, against Rails.root when there is one — a rake
      # task runs from wherever it runs from; the cassettes don't move.
      # const_get rather than a bare Rails: sorbet can't resolve a constant the
      # gem doesn't depend on.
      def cassette_dir
        dir = config.cassette_dir
        root = (Object.const_get(:Rails).root if Object.const_defined?(:Rails))
        root ? File.join(root.to_s, dir) : dir
      rescue NoMethodError
        dir # something else named Rails
      end

      private

      def validate_override_key!(schema, key)
        type_name, field_name = key.split(".", 2)
        # introspection fields (__typename) are real but absent from #fields
        return if (field_name || type_name).start_with?("__")

        if field_name.nil?
          known = field_names(schema)
          return if known.include?(type_name)

          bad_override!(key, "matches no field in this schema", known, type_name)
        end

        type = schema.get_type(type_name)
        unless type.respond_to?(:fields)
          bad_override!(key, "names no object type in this schema", schema.types.keys, type_name)
        end
        return if type.fields.key?(field_name)

        bad_override!(key, "is not a field of #{type_name}", type.fields.keys, field_name)
      end

      def bad_override!(key, problem, dictionary, term)
        suggestion = GraphWeaver.did_you_mean(dictionary, term)
        hint = suggestion ? " — did you mean '#{suggestion}'?" : ""
        raise GraphWeaver::Error, "override key #{key.inspect} #{problem}#{hint}"
      end

      # Every output field name in the schema — walked only when a bare key
      # asks for it.
      def field_names(schema)
        schema.types.each_value.flat_map { |type| type.respond_to?(:fields) ? type.fields.keys : [] }.uniq
      end
    end
  end
end

require_relative "testing/values"
require_relative "testing/fake_client"
require_relative "testing/fake_subgraph"
require_relative "testing/failure"
require_relative "testing/cassette"
require_relative "testing/router"
require_relative "testing/live_schema"
require_relative "testing/coverage"
