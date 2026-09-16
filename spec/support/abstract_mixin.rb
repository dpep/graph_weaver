# typed: strict
# frozen_string_literal: true

# The shape generation emits when a mixin declares a field it leans on abstract
# — the recommendation in docs/generated_modules.md. Sorbet demands that
# whatever satisfies an abstract sig declare the override, and a `const` has no
# sig to write `override.` into, so the emitter says it both ways: `override:
# true` on the prop, `override.` in an alias delegator's sig. This file being
# strict is the assertion; abstract_mixin_spec.rb checks the emitter writes it.
module AbstractMixin
  module PetFields
    extend T::Sig
    extend T::Helpers
    abstract!

    sig { abstract.returns(String) }
    def name; end

    sig { abstract.returns(T.nilable(String)) }
    def tag; end

    sig { returns(String) }
    def shout = "#{name}!#{tag}"
  end

  # what the emitter writes for a selected `name` and an alias: { tag: ... }
  class Pet < T::Struct
    extend T::Sig
    include PetFields

    const :name, String, override: true

    sig { override.returns(T.nilable(String)) }
    def tag = name[0]
  end
end
