# typed: ignore
require "prism"

# README.md and docs/ are the product's first surface, and nothing in the
# suite read them until this file: a sample that doesn't parse is a sample
# nobody ran, and a link that doesn't resolve is a reader stopped.
#
# **Samples are parsed, not executed, on purpose.** A sample is written for the
# reader's app — it names `MyApp::Schema`, an endpoint, a controller action —
# so running one means standing up a fixture world per sample, which is a
# second app to keep in step with the docs and the first thing to rot. Several
# samples are also deliberately partial (a rescue clause, one setting of a
# hash), so there is nothing to run. What execution would catch beyond parsing
# — a constant that moved, an argument that changed — the suite and
# `spec/public_surface_spec.rb` already catch, and `examples/` runs end to end.
# Parsing is the cheap half of the net and it holds for every sample at once.
module DocSamples
  ROOT = File.expand_path("..", __dir__)

  FILES = [
    "README.md",
    *Dir[File.join(ROOT, "docs/*.md")].sort.map { "docs/#{File.basename(_1)}" },
  ].freeze

  # A sample that is *meant* not to parse, keyed by a line out of it rather
  # than a line number, which drifts on the first paragraph added above. Two
  # kinds: `...` standing in for code, and an excerpt shown without the block
  # it sits in. Both are the author's deliberate choice — padding one to
  # please a parser would make the doc worse — so each entry says which.
  INCOMPLETE = {
    "docs/errors.md" => [
      ["rescue GraphWeaver::InputError => e", "a rescue clause, shown without its action"],
    ],
    "docs/federation.md" => [
      ['subgraphs: { "shipping" => :fake }   # any other absent', "one setting, shown without its constructor"],
    ],
    "docs/generated_modules.md" => [
      ['QUERY = "..."', "a sketch of generated source — bodiless defs, ... for what they emit"],
      ['alias: { tag: "meta.tag" }              # explicit', "the spellings `alias:` accepts, one per line"],
    ],
    "docs/i18n.md" => [
      ["# before the wire", "two call sites, each shown without the method around it"],
    ],
    "docs/transports.md" => [
      ["headers: { ... },", "... for the headers, and for the app default"],
      ["retry_if:", "... for the body of the predicate"],
      ["rescue GraphWeaver::ServerError => e", "a rescue clause, shown without its call"],
    ],
  }.freeze

  Sample = Struct.new(:file, :line, :source) do
    def to_s = "#{file}:#{line}"

    def result = @result ||= Prism.parse(source)

    def parses? = result.success?

    def why = result.errors.map(&:message).uniq.first(3).join("; ")

    def incomplete? = excerpts.any? { source.include?(_1) }

    def excerpts = INCOMPLETE.fetch(file, []).map(&:first)
  end

  # ```ruby … ```, at the start of a line. Nested fences don't occur here.
  def self.samples_in(file)
    lines = File.readlines(File.join(ROOT, file))
    lines.each_index.select { lines[_1].match?(/\A\s*```ruby\s*\z/) }.map do |open|
      close = (open + 1...lines.size).find { lines[_1].match?(/\A\s*```\s*\z/) } or
        raise "#{file}:#{open + 1} opens a ruby fence that is never closed"

      Sample.new(file, open + 2, lines[(open + 1)...close].join)
    end
  end

  SAMPLES = FILES.to_h { [_1, samples_in(_1)] }.freeze

  # GitHub's heading slug: downcase, drop all but word characters, spaces and
  # hyphens, spaces to hyphens, and -1/-2 on a repeat. Headings inside a fence
  # are code, not headings.
  def self.anchors_in(file)
    @anchors ||= {}
    @anchors[file] ||= slugs_in(file)
  end

  def self.slugs_in(file)
    seen = Hash.new(0)
    fenced = false
    File.readlines(File.join(ROOT, file)).filter_map do |line|
      fenced = !fenced if line.start_with?("```")
      next if fenced
      next unless (heading = line[/\A\#+\s+(.*?)\s*\z/, 1])

      slug = heading.downcase.delete("`").gsub(/[^\w\- ]/, "").strip.tr(" ", "-")
      seen[slug] += 1
      seen[slug] > 1 ? "#{slug}-#{seen[slug] - 1}" : slug
    end
  end

  # [text](target) — every link that isn't a url, as [file, fragment].
  def self.links_in(file)
    File.read(File.join(ROOT, file)).scan(/\]\(([^)\s]+)\)/).filter_map do |(link)|
      next if link.start_with?("http://", "https://", "mailto:", "#!")

      path, fragment = link.split("#", 2)
      target = path.to_s.empty? ? file : File.expand_path(path, File.dirname(File.join(ROOT, file)))
      [link, target.sub("#{ROOT}/", ""), fragment]
    end
  end
end


describe "the docs" do
  describe "ruby samples" do
    DocSamples::FILES.each do |file|
      DocSamples::SAMPLES.fetch(file).reject(&:incomplete?).each do |sample|
        it "parses #{sample}" do
          expect(sample.parses?).to be(true), "#{sample} is not Ruby: #{sample.why}"
        end
      end
    end

    it "finds the samples at all" do
      # every example above is generated, so a fence pattern that matched
      # nothing would leave this file green having checked nothing
      %w[README.md docs/getting_started.md docs/testing.md docs/transports.md].each do |file|
        expect(DocSamples::SAMPLES.fetch(file)).not_to be_empty, "no ```ruby fences found in #{file}"
      end
    end

    # Without this the list only grows: an entry whose sample was completed,
    # or deleted, would keep silently excusing nothing.
    describe "deliberately incomplete" do
      DocSamples::INCOMPLETE.each do |file, entries|
        entries.each do |excerpt, why|
          it "#{file} — #{why}" do
            matched = DocSamples::SAMPLES.fetch(file).select { _1.source.include?(excerpt) }

            expect(matched.size).to eq(1),
              "#{excerpt.inspect} matches #{matched.size} samples in #{file}, not 1"
            expect(matched.first.parses?).to be(false),
              "#{matched.first} parses now — drop this entry"
          end
        end
      end
    end
  end

  # A heading rename breaks every link into it silently, which is how
  # getting_started came to point at #2-what-the-generator-writes.
  describe "links" do
    DocSamples::FILES.each do |file|
      it "resolves every intra-repo link in #{file}" do
        broken = DocSamples.links_in(file).select do |_link, target, fragment|
          next true unless File.exist?(File.join(DocSamples::ROOT, target))
          next false if fragment.nil? || fragment.empty?

          !DocSamples.anchors_in(target).include?(fragment)
        end

        expect(broken.map(&:first)).to be_empty
      end
    end
  end
end
