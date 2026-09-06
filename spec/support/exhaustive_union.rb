# typed: strict
# frozen_string_literal: true

require_relative "../generated/named_query"

# The exhaustiveness promise docs/generated_modules.md makes, held to `srb tc`:
# a `case` over every generated member — the catch-all included — exhausts the
# union's T.any, so T.absurd compiles. Change what a dispatch emits and this
# stops typechecking, which is the point.
module ExhaustiveUnion
  extend T::Sig

  sig { params(named: NamedQuery::Result::Named::Type).returns(String) }
  def self.label(named)
    case named
    when NamedQuery::Result::Named::Pet then named.species.serialize
    when NamedQuery::Result::Named::Other then named.name
    else T.absurd(named)
    end
  end
end
