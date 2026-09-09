# typed: false
require "open3"

# The gem's public surface, locked. Everything reachable from GraphWeaver
# without a private_constant or a `private` in the way is a promise someone
# can build on, and the expensive kind of accident is the one nobody
# decided: a helper that goes public because a second file needed it.
#
# The list is produced by bin/public-surface in its own process — see the
# comment there for why.
describe "public surface" do
  let(:list) { File.expand_path("support/public_surface.txt", __dir__) }
  let(:tool) { File.expand_path("../bin/public-surface", __dir__) }

  it "matches the checked-in list" do
    out, err, status = Open3.capture3(RbConfig.ruby, tool)
    expect(status).to be_success, "bin/public-surface failed:\n#{err}"

    actual = out.lines(chomp: true)
    expected = File.readlines(list, chomp: true)

    added = actual - expected
    removed = expected - actual

    expect(added).to be_empty, <<~MSG
      New public names:

      #{added.join("\n")}

      Add them to spec/support/public_surface.txt if they are meant to be public
      (bin/public-surface --update), or make them private — `private`,
      `private_class_method`, `private_constant`, or move them under
      GraphWeaver::Internal, which this list skips.
    MSG

    expect(removed).to be_empty, <<~MSG
      Public names that disappeared:

      #{removed.join("\n")}

      A removed public name is a breaking change. If that's the intent, run
      bin/public-surface --update and say so in the changelog.
    MSG
  end
end
