require "rails_helper"
require "open3"
require "tmpdir"

RSpec.describe Dictionary do
  # Built once for the whole file by shelling out to the real ETL script
  # (exactly how it's meant to be run) against the small fixtures, into a
  # scratch DB pointed at via the ENV override — never the shared
  # storage/test_dictionary.sqlite3 that other spec files might touch.
  db_path = Rails.root.join("tmp", "dictionary_spec.sqlite3")
  script = Rails.root.join("script", "build_dictionary.rb")
  fixtures = Rails.root.join("spec", "fixtures", "dictionary")

  before(:context) do
    [ db_path, "#{db_path}-wal", "#{db_path}-shm" ].each { |f| FileUtils.rm_f(f) }

    %w[en it].each do |lang|
      output, status = Open3.capture2e(
        { "RAILS_ENV" => "test" },
        "ruby", script.to_s,
        "--lang", lang,
        "--input", fixtures.join("sample-#{lang}.jsonl").to_s,
        "--db", db_path.to_s
      )
      raise "build_dictionary.rb failed for #{lang}:\n#{output}" unless status.success?
    end

    ENV["DICTIONARY_DB"] = db_path.to_s
    Dictionary.reset!
  end

  after(:context) do
    ENV.delete("DICTIONARY_DB")
    Dictionary.reset!
    [ db_path, "#{db_path}-wal", "#{db_path}-shm" ].each { |f| FileUtils.rm_f(f) }
  end

  describe ".normalize_word" do
    it "downcases and strips punctuation, including Unicode quotes" do
      expect(described_class.normalize_word("“Mice,”")).to eq("mice")
      expect(described_class.normalize_word("MOUSE!")).to eq("mouse")
      expect(described_class.normalize_word("  quick ")).to eq("quick")
    end

    it "is empty for input with nothing but punctuation/whitespace, and tolerates nil" do
      expect(described_class.normalize_word("  !? ")).to eq("")
      expect(described_class.normalize_word(nil)).to eq("")
    end
  end

  describe ".lookup" do
    it "resolves an exact lemma match, capped at the 3 shortest glosses" do
      result = described_class.lookup("mouse")

      expect(result[:word]).to eq("mouse")
      expect(result[:lemma]).to eq("mouse")
      expect(result[:lang]).to eq("en")
      expect(result[:entries].size).to eq(1)
      expect(result[:entries].first[:pos]).to eq("noun")
      expect(result[:entries].first[:glosses]).to eq(
        [ "a shy person", "a computer pointing device", "a small rodent with a long tail" ]
      )
    end

    it "is case- and punctuation-insensitive while echoing the original word back" do
      result = described_class.lookup("“Mouse.”")
      expect(result[:word]).to eq("“Mouse.”")
      expect(result[:lemma]).to eq("mouse")
    end

    it "returns every part of speech for a multi-pos word" do
      result = described_class.lookup("run")
      expect(result[:entries].map { |e| e[:pos] }).to eq(%w[noun verb])
    end

    describe "lemma_forms resolution" do
      it "resolves a form_of entry to its target lemma (mice -> mouse)" do
        result = described_class.lookup("mice")
        expect(result[:lemma]).to eq("mouse")
        expect(result[:entries].first[:pos]).to eq("noun")
      end

      it "resolves an irregular plural expanded from forms[] (leaves -> leaf)" do
        expect(described_class.lookup("leaves")[:lemma]).to eq("leaf")
      end

      it "resolves an explicit form_of entry (children -> child)" do
        expect(described_class.lookup("children")[:lemma]).to eq("child")
      end

      it "resolves irregular verb forms expanded from forms[] (went/gone -> go)" do
        expect(described_class.lookup("went")[:lemma]).to eq("go")
        expect(described_class.lookup("gone")[:lemma]).to eq("go")
      end

      it "does not create a lemma_forms row for a form tagged 'table' or a multi-word form of a single-word headword" do
        expect(described_class.lookup("runnenings")).to be_nil
        expect(described_class.lookup("run down")).to be_nil
      end
    end

    describe "English suffix fallback" do
      it "strips a plain -s" do
        expect(described_class.lookup("cats")[:lemma]).to eq("cat")
      end

      it "strips -es" do
        expect(described_class.lookup("boxes")[:lemma]).to eq("box")
      end

      it "turns -ies into -y" do
        expect(described_class.lookup("flies")[:lemma]).to eq("fly")
      end

      it "strips -ly" do
        expect(described_class.lookup("quickly")[:lemma]).to eq("quick")
      end

      it "strips plain -ing / -ed" do
        expect(described_class.lookup("jumping")[:lemma]).to eq("jump")
        expect(described_class.lookup("jumped")[:lemma]).to eq("jump")
      end

      it "undoubles the consonant for -ing / -ed (running -> run, stopped -> stop)" do
        expect(described_class.lookup("running")[:lemma]).to eq("run")
        expect(described_class.lookup("stopping")[:lemma]).to eq("stop")
        expect(described_class.lookup("stopped")[:lemma]).to eq("stop")
      end

      it "restores a dropped trailing e for -ing / -ed (loving/loved -> love)" do
        expect(described_class.lookup("loving")[:lemma]).to eq("love")
        expect(described_class.lookup("loved")[:lemma]).to eq("love")
      end
    end

    describe "Italian suffix fallback" do
      it "turns -i into -o" do
        expect(described_class.lookup("libri", lang: "it")[:lemma]).to eq("libro")
        expect(described_class.lookup("gatti", lang: "it")[:lemma]).to eq("gatto")
      end

      it "turns -e into -a" do
        expect(described_class.lookup("case", lang: "it")[:lemma]).to eq("casa")
      end

      it "turns -chi into -co" do
        expect(described_class.lookup("fuochi", lang: "it")[:lemma]).to eq("fuoco")
      end
    end

    describe "Italian lemma_forms resolution" do
      it "resolves an irregular plural form_of entry (uova -> uovo)" do
        expect(described_class.lookup("uova", lang: "it")[:lemma]).to eq("uovo")
      end

      it "resolves a form expanded from forms[] (mangiato -> mangiare)" do
        expect(described_class.lookup("mangiato", lang: "it")[:lemma]).to eq("mangiare")
      end

      it "matches a plain word directly" do
        expect(described_class.lookup("gratis", lang: "it")[:lemma]).to eq("gratis")
      end
    end

    it "is scoped by language: an Italian word doesn't resolve under lang: en and vice versa" do
      expect(described_class.lookup("libro", lang: "en")).to be_nil
      expect(described_class.lookup("mouse", lang: "it")).to be_nil
    end

    it "returns nil for a word not in the dictionary" do
      expect(described_class.lookup("notaword")).to be_nil
    end

    it "returns nil for a blank word without raising" do
      expect(described_class.lookup("")).to be_nil
      expect(described_class.lookup("   ")).to be_nil
      expect(described_class.lookup(nil)).to be_nil
    end

    it "never inserted a lemmas row for a pure form-of entry (mice has no gloss of its own)" do
      # mice's only sense is form_of mouse — its entries must come from mouse.
      expect(described_class.lookup("mice")[:entries]).to eq(described_class.lookup("mouse")[:entries])
    end
  end

  describe ".available?" do
    it "is true for a language the built dictionary has rows for" do
      expect(described_class.available?("en")).to be true
      expect(described_class.available?("it")).to be true
    end

    it "is false for a language with no rows" do
      expect(described_class.available?("fr")).to be false
    end
  end

  describe ".stats" do
    it "returns lemma row counts per language" do
      stats = described_class.stats
      expect(stats["en"]).to be > 0
      expect(stats["it"]).to be > 0
      expect(stats["fr"]).to be_nil
    end
  end

  describe "when the database doesn't exist yet" do
    around do |example|
      original = ENV["DICTIONARY_DB"]
      Dir.mktmpdir do |dir|
        ENV["DICTIONARY_DB"] = File.join(dir, "not_built_yet.sqlite3")
        Dictionary.reset!
        example.run
      end
      ENV["DICTIONARY_DB"] = original
      Dictionary.reset!
    end

    it "lookup returns nil rather than raising" do
      expect(described_class.lookup("mouse")).to be_nil
    end

    it "available? is false and stats is empty" do
      expect(described_class.available?("en")).to be false
      expect(described_class.stats).to eq({})
    end
  end

  describe "when the underlying file can't be opened at all" do
    around do |example|
      original = ENV["DICTIONARY_DB"]
      Dir.mktmpdir do |dir|
        # A directory is never a valid SQLite file — forces a real
        # SQLite3::Exception instead of the "just creates an empty db" path.
        ENV["DICTIONARY_DB"] = dir
        Dictionary.reset!
        example.run
      end
      ENV["DICTIONARY_DB"] = original
      Dictionary.reset!
    end

    it "degrades to nil/false/empty instead of raising" do
      expect { described_class.lookup("mouse") }.not_to raise_error
      expect(described_class.lookup("mouse")).to be_nil
      expect(described_class.available?("en")).to be false
      expect(described_class.stats).to eq({})
    end
  end
end
