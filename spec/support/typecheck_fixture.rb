# typed: false — a block-form extend_type's body reads the including struct's
# fields, which srb tc can't see; false rather than ignore so specs can name it
# frozen_string_literal: true

require "tmpdir"

# The one generated pair the repo's own `srb tc` reads that carries a block-form
# extend_type: the .rbi declaring the module the block minted, and the module
# whose struct includes it. Every such include used to fail an app's typecheck,
# and nothing here noticed — spec/generated carries no extend_type registration,
# because most of the suite resets the registry between examples.
#
# It lives in spec/typecheck rather than spec/generated so nothing loads it:
# the include resolves at runtime only while the registration stands, which is
# exactly what the .rbi does NOT paper over. `bin/generate` refreshes it, and
# codegen_spec verifies it, like every other checked-in artifact.
module TypecheckFixture
  QUERY = "query PetShout { person(id: 1) { pets { name } } }"
  OUTPUT = File.expand_path("../typecheck", __dir__)

  # Write the pair (or check it is current, for verify_generated!'s own answer).
  def self.generate!(verify: false)
    GraphWeaver.extend_type("Pet") { def shout = "#{name}!" }
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "pet_shout.graphql"), QUERY)
      args = { schema: Demo::Schema, queries: dir, output: OUTPUT }
      verify ? GraphWeaver.verify_generated!(**args) : GraphWeaver.generate!(**args)
    end
  ensure
    GraphWeaver::Codegen.reset_type_helpers!
  end
end
