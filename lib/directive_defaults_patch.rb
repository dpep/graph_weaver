# typed: false — monkeypatch; `self.class` resolves against the prepended host
# frozen_string_literal: true

require "graphql"

# graphql-ruby's SDL builder (BuildFromDefinition#prepare_directives)
# passes only the directive arguments present at the usage site, but
# Directive#initialize validates ALL defined arguments — so a defaulted
# non-null argument (`extension: Boolean! = false`) raises
# InvalidArgumentError when omitted, even though the SDL spec makes it
# optional. Real Apollo supergraph SDL (join v0.3) hits this on every
# @join__type usage.
#
# Fill in the declared defaults before validation. This is what upstream
# should do; present in graphql 2.6.3 (latest at time of writing).
module DirectiveDefaultsPatch
  def initialize(owner, **arguments)
    self.class.all_argument_definitions.each do |arg_defn|
      if !arguments.key?(arg_defn.keyword) && arg_defn.default_value?
        arguments[arg_defn.keyword] = arg_defn.default_value
      end
    end

    super(owner, **arguments)
  end
end

GraphQL::Schema::Directive.prepend(DirectiveDefaultsPatch)
