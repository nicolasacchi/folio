require "rails_helper"

RSpec.describe Library::Krds do
  # Real device captures, firmware 5.19.2 — see the file header comment
  # in app/services/library/krds.rb for exactly what the byte layout is.
  let(:mbp1) { File.binread(Rails.root.join("spec/fixtures/sidecars/krds.mbp1")) }
  let(:mbs) { File.binread(Rails.root.join("spec/fixtures/sidecars/krds.mbs")) }

  describe ".krds?" do
    it "is true for both real fixtures" do
      expect(described_class.krds?(mbp1)).to be true
      expect(described_class.krds?(mbs)).to be true
    end

    it "is false for unrelated bytes" do
      expect(described_class.krds?("BPARMOBI".b)).to be false
      expect(described_class.krds?("")).to be false
    end
  end

  describe "parse/serialize round trip" do
    it "reproduces the mbp1 fixture byte-for-byte" do
      expect(described_class.serialize(described_class.parse(mbp1))).to eq(mbp1)
    end

    it "reproduces the mbs fixture byte-for-byte" do
      expect(described_class.serialize(described_class.parse(mbs))).to eq(mbs)
    end
  end

  describe "parsed tree shape" do
    it "reads the mbp1 objects, including an empty explicit-length string and an empty object" do
      document = described_class.parse(mbp1)

      expect(document.version).to eq(1)
      expect(document.objects.map(&:name)).to eq(
        %w[sync_lpr next.in.series.info.data annotation.cache.object ReaderMetrics]
      )

      sync_lpr = document.objects.find { |o| o.name == "sync_lpr" }
      expect(sync_lpr.children).to eq([ Library::Krds::Node.new(type: :bool, value: true) ])

      series_info = document.objects.find { |o| o.name == "next.in.series.info.data" }
      expect(series_info.children.first.type).to eq(:string)
      expect(series_info.children.first.value).to eq("")
      expect(series_info.children.first.short_empty).to eq(false) # flag=0, explicit u16 length=0

      annotation_cache = document.objects.find { |o| o.name == "annotation.cache.object" }
      expect(annotation_cache.children).to eq([])
    end

    it "reads nested objects and the -1 sentinel int64 fields in mbs" do
      document = described_class.parse(mbs)

      timer_model = document.objects.find { |o| o.name == "timer.model" }
      nested = timer_model.children.find { |c| c.object? }
      expect(nested.name).to eq("timer.average.calculator")
      expect(nested.children.map(&:value)).to eq([ 0, 0, 0, 0 ])

      fpr = document.objects.find { |o| o.name == "fpr" }
      expect(fpr.children[0]).to have_attributes(type: :string, value: "31740")
      expect(fpr.children[1]).to have_attributes(type: :int64, value: -1)
      expect(fpr.children[3]).to have_attributes(type: :string, value: "", short_empty: true) # flag=1 shortcut

      lpr = document.objects.find { |o| o.name == "lpr" }
      expect(lpr.children[0]).to have_attributes(type: :byte, value: 2)
      expect(lpr.children[1].value).to start_with("31739:31739:15:")
      expect(lpr.children[2]).to have_attributes(type: :int64, value: 1_783_778_405_632)
    end
  end

  describe ".update_positions" do
    it "returns nil when the blob has no rewritable position (mbp1's sync_lpr is boolean-only)" do
      expect(described_class.update_positions(mbp1, 12_345)).to be_nil
    end

    it "returns nil for bytes that aren't a valid KRDS blob" do
      expect(described_class.update_positions("not krds".b, 1)).to be_nil
    end

    it "whole-replaces an all-digits position (fpr) and updates its time field" do
      at = Time.at(1_700_000_000)
      result = described_class.update_positions(mbs, 99_999, at: at)

      fpr = described_class.parse(result).objects.find { |o| o.name == "fpr" }
      expect(fpr.children[0].value).to eq("99999")
      expect(fpr.children[1].value).to eq(1_700_000_000_000)
      # the ambiguous third field (-1 sentinel) is left alone — only the
      # field immediately after the position string is treated as "time"
      expect(fpr.children[2].value).to eq(-1)
    end

    it "rewrites the leading INT:INT: segments of a compound lpr position and preserves the opaque tail" do
      at = Time.at(1_700_000_000)
      result = described_class.update_positions(mbs, 5_000, at: at)

      lpr = described_class.parse(result).objects.find { |o| o.name == "lpr" }
      expect(lpr.children[1].value).to eq(
        "5000:5000:15:REFUQQAAAHRFQkFSAAAAAQAAAABFQlZTAAAABI2FoH4AAAABAAAACP////8AAAAAAAAAEAAAe/sA\n" \
        "AAADAAAAAAECHwAAAAAKAAMAAgAAAAAAAwACAAcAHwAAdt7//wA2AAAAAP//ADcQAAABAAcAHwAA\n" \
        "AAAAAAAAAAD96g=="
      )
      expect(lpr.children[2].value).to eq(1_700_000_000_000)
    end

    it "leaves a non-numeric-leading position value (and its time field) untouched" do
      opaque = Library::Krds::Document.new(version: 1, objects: [
        Library::Krds::Node.new(type: :object, name: "lpr", short_empty: false, children: [
          Library::Krds::Node.new(type: :string, value: "not-a-position", short_empty: false),
          Library::Krds::Node.new(type: :int64, value: 123)
        ])
      ])
      bytes = described_class.serialize(opaque)

      expect(described_class.update_positions(bytes, 42)).to be_nil
    end

    it "leaves every non-position object byte-identical" do
      result = described_class.update_positions(mbs, 99_999, at: Time.now)

      original_objects = described_class.parse(mbs).objects.reject { |o| %w[lpr fpr].include?(o.name) }
      rewritten_objects = described_class.parse(result).objects.reject { |o| %w[lpr fpr].include?(o.name) }

      original_objects.zip(rewritten_objects).each do |original, rewritten|
        wrap = ->(object) { described_class.serialize(Library::Krds::Document.new(version: 1, objects: [ object ])) }
        expect(wrap.call(rewritten)).to eq(wrap.call(original))
      end
    end
  end

  describe "object nesting depth" do
    # Builds `depth` levels of nested (empty-named) objects, innermost first.
    def nested_document(depth)
      node = Library::Krds::Node.new(type: :object, name: "n", short_empty: false, children: [])
      (depth - 1).times do
        node = Library::Krds::Node.new(type: :object, name: "n", short_empty: false, children: [ node ])
      end
      Library::Krds::Document.new(version: 1, objects: [ node ])
    end

    it "raises Error (not SystemStackError) for a blob nested deeper than MAX_NESTING_DEPTH" do
      bytes = described_class.serialize(nested_document(Library::Krds::MAX_NESTING_DEPTH + 1))

      expect { described_class.parse(bytes) }.to raise_error(Library::Krds::Error, /nesting/)
    end

    it "still parses a blob nested right up to MAX_NESTING_DEPTH" do
      bytes = described_class.serialize(nested_document(Library::Krds::MAX_NESTING_DEPTH))

      expect { described_class.parse(bytes) }.not_to raise_error
    end

    it "update_positions degrades to nil (not an unrescued crash) for an over-deep blob" do
      bytes = described_class.serialize(nested_document(Library::Krds::MAX_NESTING_DEPTH + 1))

      expect(described_class.update_positions(bytes, 1)).to be_nil
    end
  end
end
