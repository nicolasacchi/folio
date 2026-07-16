require "rails_helper"

RSpec.describe Library::Taxonomy do
  describe ".categories" do
    it "loads the frozen taxonomy in file order" do
      expect(described_class.categories.keys).to eq(%w[fiction nonfiction practical classics comics])
    end
  end

  describe ".subs_for" do
    it "lists a root's subcategory keys in taxonomy order" do
      expect(described_class.subs_for("classics").keys).to eq(%w[italian world])
    end

    it "returns an empty hash for an unknown root instead of raising" do
      expect(described_class.subs_for("nope")).to eq({})
    end
  end

  describe ".known?" do
    it "is true for a known category/subcategory pair" do
      expect(described_class.known?("fiction/sf")).to be true
    end

    it "is true for a known root with no subcategory" do
      expect(described_class.known?("classics")).to be true
    end

    it "is false for a known root with an unknown subcategory" do
      expect(described_class.known?("fiction/nope")).to be false
    end

    it "is false for an unknown root" do
      expect(described_class.known?("nope")).to be false
    end

    it "is false for blank input" do
      expect(described_class.known?(nil)).to be false
      expect(described_class.known?("")).to be false
    end
  end

  describe ".label_for" do
    it "returns nil for blank input" do
      expect(described_class.label_for(nil)).to be_nil
      expect(described_class.label_for("")).to be_nil
    end

    it "prefers label_en at the root when present" do
      expect(described_class.label_for("classics")).to eq("Classics")
    end

    it "falls back to label when a root has no label_en" do
      expect(described_class.label_for("comics")).to eq("Fumetti e graphic")
    end

    it "joins root and sub labels for a category/subcategory pair" do
      expect(described_class.label_for("fiction/sf")).to eq("Fiction / Fantascienza")
    end

    it "humanizes an unknown root instead of raising" do
      expect(described_class.label_for("some_new_shelf")).to eq("Some new shelf")
    end

    it "humanizes an unknown subcategory under a known root instead of raising" do
      expect(described_class.label_for("fiction/some_new_sub")).to eq("Fiction / Some new sub")
    end

    it "humanizes both segments of a fully unknown category/subcategory pair" do
      expect(described_class.label_for("unknown_root/unknown_sub")).to eq("Unknown root / Unknown sub")
    end
  end
end
