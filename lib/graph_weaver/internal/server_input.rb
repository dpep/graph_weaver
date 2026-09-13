# typed: true
# frozen_string_literal: true

module GraphWeaver
  module Internal
    # A server's rejection of the input, read back into InputError values —
    # the same value object the client-side refusal is, so an app renders one
    # form the same way whichever side said no.
    #
    # Four shapes, most specific first: the `extensions.input` convention
    # (docs/errors.md), graphql-ruby's variable-coercion `problems` array, a
    # recognized `extensions.code`, and Hasura's argument path. Everything
    # else is nobody's input error and stays out — and an explanation with no
    # table entry becomes `:refused` carrying the server's own sentence,
    # because a wrong `kind` is worse than no kind: the app will have
    # translated it into a confident sentence.
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

      # Hasura states no input code — it stamps one code on a whole class of
      # rejections and says what the error is about in `extensions.path`, a
      # dotted string rather than an array. So the path is the test, not the
      # code: only one that reaches a field's arguments is about the input.
      # "$", "$.query" and "$.selectionSet.<field>" are the query itself — a
      # .graphql file that doesn't parse, or names an argument the schema
      # hasn't got, is nothing a form can highlight.
      HASURA_CODES = %w[validation-failed parse-failed].freeze
      # lazily, so an argument of its own named `args` doesn't win the split
      HASURA_ARGUMENT = /\A\$\.selectionSet\..+?\.args\.(.+)\z/
      HASURA_SEGMENT = /\A([_A-Za-z]\w*)((?:\[\d+\])*)\z/

      # The explanations Hasura writes that name a kind on their own (measured
      # against Hasura v2, one curl per entry — spec/input_errors_spec.rb
      # holds the verbatim JSON). Its scalar family, "expected <description>
      # for type 'T', but found <json type>", is deliberately absent: one
      # sentence covers both `limit: -5` (out of range) and `limit: "lots"`
      # (wrong type), and telling them apart means parsing the English
      # description rather than reading a table.
      HASURA_NOT_A_MEMBER = /\Aexpected one of the values \[(.*)\] for type '[^']*', but found /
      HASURA_NOT_DEFINED = /\Afield '([^']*)' not found in type: '([^']*)'\z/
      HASURA_NULL = /\Aunexpected null value for type '[^']*'\z/
      QUOTED = /'([^']*)'/

      # InputError::DETAILS closes the key set; this closes the types, because
      # a right key with the wrong type under it is the same smuggling. An app
      # is entitled to errors.rb's promise that members stays an Array —
      # details[:members].join(", ") must not raise on what a server sent.
      # (spec/input_errors_spec.rb holds these keys to DETAILS.)
      DETAIL_TYPES = {
        "type" => String, "members" => Array, "min" => Numeric,
        "max" => Numeric, "format" => String, "suggestion" => String,
      }.freeze

      private_constant :VARIABLE, :COERCE, :NOT_A_MEMBER, :NOT_NULL, :NOT_DEFINED,
        :HASURA_CODES, :HASURA_ARGUMENT, :HASURA_SEGMENT, :QUOTED,
        :HASURA_NOT_A_MEMBER, :HASURA_NOT_DEFINED, :HASURA_NULL

      class << self
        def read(error)
          extensions = error.extensions
          stated = extensions["input"]
          return [convention(error.message, stated, error.path || [], nil)] if stated.is_a?(Hash)
          return problems(error, extensions) if extensions["problems"].is_a?(Array)

          kind = GraphWeaver::GraphQLError::INPUT_CODES[error.code.to_s]
          return [coded(error, kind)] if kind

          hasura(error, extensions)
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
            details: details_of(stated),
          )
        end

        # the details a server stated that a kind can actually mean, both key
        # and type — anything else is dropped rather than passed through
        def details_of(stated)
          DETAIL_TYPES.each_with_object({}) do |(key, type), out|
            value = stated[key]
            out[key.to_sym] = value if value.is_a?(type)
          end
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

            explained(message, path, value, within)
          end
        end

        def explained(message, path, value, within)
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
            # can give a coordinate — but only from the problem's OWN path.
            # #path is the variable plus that, so its last segment is the
            # variable name when the problem states none, and "RangeInput.range"
            # is a slot the schema doesn't have.
            type = $1
            field = within.last
            build(message, kind: :unknown, path:, value:,
              coordinate: ("#{type}.#{field}" if field.is_a?(String)))
          else
            build(message, kind: :refused, path:, value:)
          end
        end

        # Hasura: the argument is in extensions.path or this is not about the
        # input. No value either — Hasura never echoes back what it rejected.
        def hasura(error, extensions)
          return [] unless HASURA_CODES.include?(error.code.to_s)

          stated = extensions["path"]
          match = stated.is_a?(String) ? stated.match(HASURA_ARGUMENT) : nil
          path = hasura_path(match[1]) if match
          path ? [hasura_explained(error.message, path)] : []
        end

        # "order_by[0].name" => ["order_by", 0, "name"]. nil rather than a
        # partial read: a path this can't spell points a form at a field the
        # server never named.
        def hasura_path(stated)
          stated.split(".").flat_map do |segment|
            match = segment.match(HASURA_SEGMENT) or return nil
            [match[1], *match[2].scan(/\d+/).map(&:to_i)]
          end
        end

        def hasura_explained(message, path)
          case message
          when HASURA_NOT_A_MEMBER
            build(message, kind: :not_a_member, path:, details: { members: $1.scan(QUOTED).flatten })
          when HASURA_NOT_DEFINED
            build(message, kind: :unknown, path:, coordinate: "#{$2}.#{$1}")
          when HASURA_NULL
            # :missing is "wasn't supplied, or was null" (docs/i18n.md)
            build(message, kind: :missing, path:)
          else
            build(message, kind: :refused, path:)
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
        #
        # The message goes through the same filter the client side puts its own
        # messages through: a server quotes the value it rejected as a matter of
        # course ('Could not coerce value "hunter2" to Int'), so redacting only
        # #value would leave half the promise kept.
        def build(message, kind:, path:, value: nil, coordinate: nil, details: {})
          redact = GraphWeaver::Internal::Redact
          GraphWeaver::InputError.new(
            redact.detail(path.last, message), kind:, path:, coordinate:, details:, raised: false,
            value: redact.value(path.last, value),
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
