# A word a reader looked up in the in-browser dictionary (see
# LookupsController#show), captured into a per-book/per-user "vocab
# notebook" — see VocabEntriesController. GET /lookup itself never writes
# one of these; the reader auto-POSTs to VocabEntriesController#create
# once a lookup actually resolves (reader_controller.js's "Vocab notebook
# capture" section).
#
# book_id is nullable — a lookup need not happen from inside a book's
# reader session — but (user, book, lemma, lang) is still the dedupe key
# (see .upsert_lookup): looking the same word up again in the same book
# refreshes the existing row instead of creating a duplicate.
class VocabEntry < ApplicationRecord
  belongs_to :user
  belongs_to :book, optional: true

  validates :word, presence: true
  validates :lemma, presence: true
  validates :lang, presence: true, inclusion: { in: Dictionary::SUPPORTED_LANGS }

  scope :recent, -> { order(updated_at: :desc, id: :desc) }

  # Upserts by the (user, book, lemma, lang) dedupe key: a repeat lookup of
  # a word already in the notebook refreshes word/context/gloss/updated_at
  # in place rather than creating a duplicate row (context/gloss are only
  # overwritten when the new lookup actually supplied one, so a later
  # lookup that couldn't capture context doesn't blank out a good one from
  # an earlier save).
  def self.upsert_lookup(user:, word:, lemma:, lang:, book_id: nil, context: nil, gloss: nil)
    entry = find_or_initialize_by(user_id: user.id, book_id: book_id, lemma: lemma, lang: lang)
    entry.word = word
    entry.context = context if context.present?
    entry.gloss = gloss if gloss.present?
    entry.save!
    entry
  rescue ActiveRecord::RecordNotUnique
    # Lost a create race against a concurrent identical lookup — the row
    # that won already carries the same dedupe key, so just hand it back.
    find_by!(user_id: user.id, book_id: book_id, lemma: lemma, lang: lang)
  end
end
