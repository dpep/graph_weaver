# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

require_relative "errors"

module GraphWeaver
  # The envelope every generated #execute returns: the typed data (nil on a
  # total failure), the top-level GraphQL errors, and top-level extensions
  # (cost/throttle metadata). Generic over the query's Result type so
  # response.data stays fully typed — the generated code instantiates it as
  # GraphWeaver::Response[SomeQuery::Result]. #data! is the strict accessor:
  # the result, or a raised QueryError.
  class Response
    extend T::Sig
    extend T::Generic
    include ErrorFiltering

    Data = type_member

    sig { override.returns(T.nilable(Data)) }
    attr_reader :data

    sig { override.returns(T::Array[GraphWeaver::GraphQLError]) }
    attr_reader :errors

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :extensions

    sig do
      params(
        data: T.nilable(Data),
        errors: T::Array[GraphWeaver::GraphQLError],
        extensions: T::Hash[String, T.untyped],
      ).void
    end
    def initialize(data:, errors: [], extensions: {})
      @data = data
      @errors = errors
      @extensions = extensions
    end

    sig { returns(T::Boolean) }
    def errors? = !errors.empty?

    # The same question the other way round — people reach for the positive,
    # and a NoMethodError is a poor answer. Spelled `success?` after
    # Process::Status and Faraday::Response; `ok?` would read as HTTP 200,
    # which a GraphQL response carrying errors also is.
    sig { returns(T::Boolean) }
    def success? = errors.empty?

    # The envelope decomposed, string-keyed like the error classes' #to_h:
    # errors become JSON-ready hashes, extensions pass through, and data
    # stays the typed struct.
    #
    # Data is NOT re-serialized: T::Struct#serialize is the wrong inverse
    # here — props are snake_case where the wire is camelCase, nil fields
    # drop out, and a registered scalar keeps whatever Ruby object its codec
    # built. The result would look like the server's response and not be one.
    # Serialize the typed data yourself, or keep the raw hash and hand it to
    # .from_response when you need both.
    sig { returns(T::Hash[String, T.untyped]) }
    def to_h
      { "data" => data, "errors" => errors.map(&:to_h), "extensions" => extensions }
    end

    # The typed result, or raise QueryError if the response carried top-level
    # errors (partial data and extensions ride along on the error).
    sig { returns(Data) }
    def data!
      raise GraphWeaver::QueryError.new(errors, data: data, extensions: extensions) unless errors.empty?

      # a well-formed GraphQL response always pairs null data with errors; a
      # server (or an errors-stripping proxy) that returns neither is broken —
      # brand it rather than leaking a bare `T.must` TypeError
      data || raise(GraphWeaver::QueryError.new(
        [GraphWeaver::GraphQLError.new(message: "response carried neither data nor errors")],
        extensions: extensions,
      ))
    end
  end
end
