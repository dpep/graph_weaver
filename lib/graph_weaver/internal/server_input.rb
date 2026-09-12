# typed: true
# frozen_string_literal: true

module GraphWeaver
  module Internal
    # A server's rejection of the input, read back into InputError values —
    # the same value object the client-side refusal is, so an app renders one
    # form the same way whichever side said no.
    #
    # Three shapes, most specific first: the `extensions.input` convention
    # (docs/errors.md), graphql-ruby's variable-coercion `problems` array, and
    # a recognized `extensions.code`. Everything else is nobody's input error
    # and stays out — and an explanation with no table entry becomes
    # `:refused` carrying the server's own sentence, because a wrong `kind` is
    # worse than no kind: the app will have translated it into a confident
    # sentence.
    module ServerInput
      # graphql-ruby names the variable only in the error's message; the
      # problems underneath are relative to it (measured against 2.6.10).
      VARIABLE = /\AVariable \$([A-Za-z_]\w*) /

      # The explanations graphql-ruby writes for a variable that wouldn't
      # coerce. A closed table, not a parser: anything else is :refused.
      COERCE = /\ACould not coerce value .* to (\S+)\z/
      NOT_A_MEMBER = /\AExpected .* to be one of: (.*)\z/
      NOT_NULL = /\AExpected value to not be null\z/
      NOT_DEFINED = /\AField is not defined on (\S+)\z/

      DETAIL_KEYS = GraphWeaver::InputError::DETAILS.map(&:to_s).freeze

      private_constant :VARIABLE, :COERCE, :NOT_A_MEMBER, :NOT_NULL, :NOT_DEFINED, :DETAIL_KEYS

      class << self
        def read(error)
          extensions = error.extensions
          stated = extensions["input"]
          return [convention(error.message, stated, error.path || [], nil)] if stated.is_a?(Hash)
          return problems(error, extensions) if extensions["problems"].is_a?(Array)

          kind = GraphWeaver::GraphQLError::INPUT_CODES[error.code.to_s]
          kind ? [coded(error, kind)] : []
        end

        private

        # The convention: taken verbatim, after checking `kind` is one this
        # version knows and `details` carries only keys a kind can mean.
        def convention(message, stated, path, value)
          kind = stated["kind"].to_s.to_sym
          kind = :refused unless GraphWeaver::InputError::KINDS.include?(kind)
          coordinate = stated["coordinate"]

          build(
            message,
            kind:,
            path: stated["path"].is_a?(Array) ? stated["path"] : path,
            coordinate: (coordinate if coordinate.is_a?(String)),
            value: stated.key?("value") ? stated["value"] : value,
            details: stated.slice(*DETAIL_KEYS).transform_keys(&:to_sym),
          )
        end

        # One InputError per problem — a single coercion error routinely
        # carries several, and they are about different fields.
        def problems(error, extensions)
          root = (match = error.message.match(VARIABLE)) ? [match[1]] : []

          extensions["problems"].filter_map do |problem|
            next unless problem.is_a?(Hash)

            within = Array(problem["path"])
            path = root + within
            value = dig(extensions["value"], within)
            message = problem["explanation"].to_s
            stated = problem.dig("extensions", "input")
            next convention(message, stated, path, value) if stated.is_a?(Hash)

            explained(message, path, value)
          end
        end

        def explained(message, path, value)
          case message
          when COERCE
            # text that didn't parse, vs a thing that was never that type
            build(message, kind: value.is_a?(String) ? :unparseable : :type_mismatch,
              path:, value:, details: { type: $1 })
          when NOT_A_MEMBER
            build(message, kind: :not_a_member, path:, value:, details: { members: $1.split(", ") })
          when NOT_NULL
            build(message, kind: :missing, path:, value:)
          when NOT_DEFINED
            # the one explanation that names the input type, so the one that
            # can give a coordinate
            type = $1
            build(message, kind: :unknown, path:, value:,
              coordinate: ("#{type}.#{path.last}" if path.last.is_a?(String)))
          else
            build(message, kind: :refused, path:, value:)
          end
        end

        # A recognized validation code. `argumentName` is the input coordinate;
        # the error's own `path` is a QUERY path ("query", "rangeThing", …), so
        # it is only the floor for a code that names no argument.
        def coded(error, kind)
          extensions = error.extensions
          argument = extensions["argumentName"]
          # inputObjectType is stated outright; argumentNotAccepted says which
          # kind of thing `name` is instead. A field argument has no schema
          # coordinate here — nothing names the field's parent type.
          type = extensions["inputObjectType"] ||
            (extensions["name"] if extensions["typeName"] == "InputObject")

          build(
            error.message,
            kind:,
            path: argument.is_a?(String) ? [argument] : (error.path || []),
            coordinate: ("#{type}.#{argument}" if type.is_a?(String) && argument.is_a?(String)),
            value: extensions["value"],
          )
        end

        # raised: false — this is a value read off a response, and the warn
        # line Error#initialize writes would claim a raise that never happened.
        def build(message, kind:, path:, value: nil, coordinate: nil, details: {})
          GraphWeaver::InputError.new(
            message, kind:, path:, coordinate:, details:, raised: false,
            value: GraphWeaver::Internal::Redact.value(path.last, value),
          )
        end

        # the problem's path walked into the variable the server echoed back
        def dig(value, path)
          path.reduce(value) do |node, segment|
            case node
            when Hash then node[segment.to_s]
            when Array then segment.is_a?(Integer) ? node[segment] : nil
            else return nil
            end
          end
        end
      end
    end
  end
end
