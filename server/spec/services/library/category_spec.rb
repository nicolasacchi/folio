require 'rails_helper'

RSpec.describe Library::Category do
  let(:root) { Pathname.new("/books") }

  around do |example|
    original = ENV["CATEGORY_DEPTH"]
    example.run
  ensure
    ENV["CATEGORY_DEPTH"] = original
  end

  def category(relative, roots: [ root ], depth: nil)
    described_class.from_path(root.join(relative).to_s, roots: roots, depth: depth || described_class.default_depth)
  end

  describe ".from_path" do
    it "reads the rules-table matrix from the design doc" do
      examples = {
        "fiction/sf/Asimov/Foundation.epub" => "fiction/sf",
        "fiction/literary/Saramago/Blindness.epub" => "fiction/literary",
        "classics/italian/Dante/Inferno.epub" => "classics/italian",
        "_inbox/Harari/Nexus.epub" => "_inbox"
      }

      examples.each do |relative, expected|
        expect(category(relative)).to eq(expected), "expected #{relative.inspect} => #{expected.inspect}"
      end
    end

    it "returns nil for a _quarantine path (not scanned)" do
      expect(category("_quarantine/dump/Some Book.epub")).to be_nil
    end

    it "returns nil for a dot-prefixed top dir" do
      expect(category(".hidden/Author/Book.epub")).to be_nil
    end

    it "returns nil for a file directly under the root" do
      expect(category("loose.epub")).to be_nil
    end

    it "returns nil for a path outside all configured roots" do
      outside = Pathname.new("/elsewhere/fiction/sf/Author/Book.epub")
      expect(described_class.from_path(outside.to_s, roots: [ root ])).to be_nil
    end

    it "drops a Calibre 'Title (id)' leaf dir below the author" do
      expect(category("fiction/sf/Isaac Asimov/Foundation (42)/metadata.opf")).to eq("fiction/sf")
      expect(category("fiction/sf/Isaac Asimov/Foundation (42)/Foundation.epub")).to eq("fiction/sf")
    end

    it "still resolves a loose file directly under the category segments" do
      expect(category("fiction/sf/Foundation.epub")).to eq("fiction/sf")
    end

    it "resolves a single-segment category when there is no subcategory dir at all" do
      expect(category("fiction/Foundation.epub")).to eq("fiction")
    end

    it "treats a depth-deep dir tuple as category segments even without a further author dir below (design doc's own algorithm makes no distinction here)" do
      expect(category("fiction/Author/Foundation.epub")).to eq("fiction/Author")
    end

    it "clamps depth below 1 up to 1" do
      expect(category("fiction/sf/Author/Book.epub", depth: 0)).to eq("fiction")
    end

    it "clamps depth above 2 down to 2" do
      expect(category("fiction/sf/Author/Book.epub", depth: 5)).to eq("fiction/sf")
    end

    it "honors CATEGORY_DEPTH=1 from the environment" do
      ENV["CATEGORY_DEPTH"] = "1"
      expect(category("fiction/sf/Author/Book.epub")).to eq("fiction")
    end

    it "defaults to depth 2 when CATEGORY_DEPTH is unset" do
      ENV.delete("CATEGORY_DEPTH")
      expect(category("fiction/sf/Author/Book.epub")).to eq("fiction/sf")
    end

    it "matches against multiple roots" do
      other_root = Pathname.new("/other")
      path = other_root.join("nonfiction/history/Author/Book.epub").to_s
      expect(described_class.from_path(path, roots: [ root, other_root ])).to eq("nonfiction/history")
    end
  end
end
