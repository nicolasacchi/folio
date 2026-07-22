require "rails_helper"

RSpec.describe VocabEntries::Export do
  let(:user) { create(:user) }
  let(:book) { create(:book, title: "Fixture Book") }

  describe ".csv" do
    it "renders a header row and one row per entry" do
      create(:vocab_entry, user: user, book: book, word: "mouse", lemma: "mouse", lang: "en",
        gloss: "a small rodent", context: "A mouse ran by.")

      rows = CSV.parse(described_class.csv(VocabEntry.all), headers: true)

      expect(rows.headers).to eq(%w[Word Lemma Lang Book Context Gloss Date])
      expect(rows.first.to_h).to include(
        "Word" => "mouse", "Lemma" => "mouse", "Lang" => "en", "Book" => "Fixture Book",
        "Context" => "A mouse ran by.", "Gloss" => "a small rodent"
      )
    end

    it "leaves the Book column blank for an entry with no book" do
      create(:vocab_entry, user: user, book: nil, word: "solo", lemma: "solo")

      rows = CSV.parse(described_class.csv(VocabEntry.all), headers: true)

      expect(rows.first["Book"]).to be_nil
    end
  end

  describe ".anki_tsv" do
    it "puts word+lemma on the front and gloss+context on the back" do
      create(:vocab_entry, user: user, book: book, word: "running", lemma: "run", lang: "en",
        gloss: "to move fast on foot", context: "He kept running.")

      front, back = described_class.anki_tsv(VocabEntry.all).split("\t")

      expect(front).to eq("running (run)")
      expect(back).to eq("to move fast on foot<br>He kept running.")
    end

    it "omits the lemma parenthetical when lemma equals word" do
      create(:vocab_entry, user: user, book: book, word: "mouse", lemma: "mouse")

      front, = described_class.anki_tsv(VocabEntry.all).split("\t")

      expect(front).to eq("mouse")
    end

    it "omits a missing gloss or context rather than leaving a stray separator" do
      create(:vocab_entry, user: user, book: book, word: "mouse", lemma: "mouse", gloss: "a rodent", context: nil)

      _, back = described_class.anki_tsv(VocabEntry.all).split("\t")

      expect(back).to eq("a rodent")
    end

    it "collapses embedded tabs/newlines so a stray character can't corrupt the import" do
      create(:vocab_entry, user: user, book: book, word: "mouse", lemma: "mouse",
        context: "Line one.\nLine\ttwo.")

      _, back = described_class.anki_tsv(VocabEntry.all).split("\t", 2)

      expect(back).not_to include("\n")
      expect(back).not_to include("\t")
    end

    it "joins multiple entries as one line each" do
      create(:vocab_entry, user: user, book: book, word: "one", lemma: "one")
      create(:vocab_entry, user: user, book: book, word: "two", lemma: "two")

      lines = described_class.anki_tsv(VocabEntry.recent).lines(chomp: true)

      expect(lines.size).to eq(2)
    end
  end
end
