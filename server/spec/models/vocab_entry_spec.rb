require "rails_helper"

RSpec.describe VocabEntry, type: :model do
  it "requires word, lemma and lang" do
    expect(build(:vocab_entry, word: "")).not_to be_valid
    expect(build(:vocab_entry, lemma: "")).not_to be_valid
    expect(build(:vocab_entry, lang: "")).not_to be_valid
  end

  it "only accepts languages Dictionary supports" do
    expect(build(:vocab_entry, lang: "en")).to be_valid
    expect(build(:vocab_entry, lang: "it")).to be_valid
    expect(build(:vocab_entry, lang: "fr")).not_to be_valid
  end

  it "enforces the (user, book, lemma, lang) dedupe key at the database level" do
    entry = create(:vocab_entry, lemma: "mouse", lang: "en")
    dup = build(:vocab_entry, user: entry.user, book: entry.book, lemma: "mouse", lang: "en", word: "mice")

    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows the same lemma+lang for a different user or a different book" do
    entry = create(:vocab_entry, lemma: "mouse", lang: "en")
    expect(build(:vocab_entry, book: entry.book, lemma: "mouse", lang: "en")).to be_valid
    expect(build(:vocab_entry, user: entry.user, lemma: "mouse", lang: "en")).to be_valid
  end

  describe ".upsert_lookup" do
    let(:user) { create(:user) }
    let(:book) { create(:book) }

    it "creates a new row on the first lookup" do
      expect {
        VocabEntry.upsert_lookup(user: user, word: "running", lemma: "run", lang: "en", book_id: book.id,
          context: "He kept running.", gloss: "to move fast on foot")
      }.to change(VocabEntry, :count).by(1)

      entry = VocabEntry.last
      expect(entry).to have_attributes(word: "running", lemma: "run", lang: "en", book_id: book.id,
        context: "He kept running.", gloss: "to move fast on foot")
    end

    it "updates the existing row instead of duplicating on a repeat lookup" do
      first = VocabEntry.upsert_lookup(user: user, word: "run", lemma: "run", lang: "en", book_id: book.id,
        context: "First context.", gloss: "first gloss")

      expect {
        second = VocabEntry.upsert_lookup(user: user, word: "running", lemma: "run", lang: "en", book_id: book.id,
          context: "Second context.", gloss: "second gloss")
        expect(second.id).to eq(first.id)
      }.not_to change(VocabEntry, :count)

      first.reload
      expect(first).to have_attributes(word: "running", context: "Second context.", gloss: "second gloss")
    end

    it "keeps the previous context/gloss when a repeat lookup doesn't supply new ones" do
      first = VocabEntry.upsert_lookup(user: user, word: "run", lemma: "run", lang: "en", book_id: book.id,
        context: "Has context.", gloss: "has gloss")

      VocabEntry.upsert_lookup(user: user, word: "run", lemma: "run", lang: "en", book_id: book.id)

      expect(first.reload).to have_attributes(context: "Has context.", gloss: "has gloss")
    end

    it "treats a nil book_id as its own bucket, independent of any book-scoped entry" do
      VocabEntry.upsert_lookup(user: user, word: "run", lemma: "run", lang: "en", book_id: book.id)

      expect {
        VocabEntry.upsert_lookup(user: user, word: "run", lemma: "run", lang: "en", book_id: nil)
      }.to change(VocabEntry, :count).by(1)
    end

    it "still dedupes a repeat nil-book_id lookup (find_or_initialize_by treats nil as IS NULL, not " \
       "the unique index — SQLite's NULL <> NULL means the index alone wouldn't catch this)" do
      VocabEntry.upsert_lookup(user: user, word: "run", lemma: "run", lang: "en", book_id: nil)

      expect {
        VocabEntry.upsert_lookup(user: user, word: "running", lemma: "run", lang: "en", book_id: nil)
      }.not_to change(VocabEntry, :count)
    end

    it "keeps a lang change (different dedupe key) as a distinct row" do
      VocabEntry.upsert_lookup(user: user, word: "libro", lemma: "libro", lang: "it", book_id: book.id)

      expect {
        VocabEntry.upsert_lookup(user: user, word: "libro", lemma: "libro", lang: "en", book_id: book.id)
      }.to change(VocabEntry, :count).by(1)
    end
  end
end
