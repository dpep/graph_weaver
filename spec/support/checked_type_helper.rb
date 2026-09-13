# typed: strict
# frozen_string_literal: true

# The shape docs/generated_modules.md recommends for an extend_type mixin that
# wants sigs srb tc can check: declare the fields it leans on as abstract sigs
# — in the module's own scope, which is the only scope srb tc reads it in — and
# let the generated struct's `const` satisfy them. This file being strict is
# the assertion; registry_spec mixes it into a real struct for the other half.
module PetShoutingChecked
  extend T::Sig
  extend T::Helpers
  abstract!

  sig { abstract.returns(String) }
  def name; end

  sig { returns(String) }
  def shout = "#{name}!"
end
