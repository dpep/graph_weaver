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

    Data = type_member

    sig { returns(T.nilable(Data)) }
    attr_reader :data

    sig { returns(T::Array[GraphWeaver::GraphQLError]) }
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

    # The typed result, or raise QueryError if the response carried top-level
    # errors (partial data and extensions ride along on the error).
    sig { returns(Data) }
    def data!
      raise GraphWeaver::QueryError.new(errors, data: data, extensions: extensions) unless errors.empty?
      T.must(data)
    end
  end
end
