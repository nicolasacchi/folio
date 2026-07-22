# The vocab notebook: dictionary lookups (see LookupsController#show)
# saved into a per-book, exportable study list. GET /lookup itself stays a
# pure read with no write side-effect; this is the dedicated write path —
# the reader auto-POSTs here, fire-and-forget, once a lookup resolves (see
# reader_controller.js's "Vocab notebook capture" section) — plus the
# browsable list, per-book filter, CSV/Anki export, and delete.
#
# Every query is scoped to Current.user: a signed-in user only ever sees
# (or exports, or deletes) their own captured words.
class VocabEntriesController < ApplicationController
  before_action :set_book, if: -> { params[:book_id].present? }, only: [ :index, :export ]
  before_action :set_entry, only: [ :destroy ]

  PER_PAGE = 100

  def index
    @lang = Dictionary::SUPPORTED_LANGS.include?(params[:lang]) ? params[:lang] : nil
    @filter_books = Book.joins(:vocab_entries)
      .where(vocab_entries: { user_id: Current.user.id })
      .distinct.order(:title)
    @lang_counts = scoped_entries.group(:lang).count
    @total_all = scoped_entries.count

    scope = filtered_entries
    @total = scope.count
    @page = [ params[:page].to_i, 1 ].max
    @vocab_entries = scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
  end

  # Session-auth JSON write the reader POSTs to right after a /lookup
  # resolves. `lang` must be one Dictionary actually supports (same
  # whitelist LookupsController applies) — anything else is rejected
  # rather than silently coerced, since there's no "current book language"
  # fallback to reach for here the way the reader's own JS has.
  def create
    lang = Dictionary::SUPPORTED_LANGS.include?(create_params[:lang]) ? create_params[:lang] : nil
    word = create_params[:word].to_s.strip
    lemma = create_params[:lemma].to_s.strip.presence || word

    if word.blank? || lang.nil?
      return render json: { errors: [ "word and a supported lang are required" ] }, status: :unprocessable_content
    end

    entry = VocabEntry.upsert_lookup(
      user: Current.user, word: word, lemma: lemma, lang: lang,
      book_id: resolve_book_id(create_params[:book_id]),
      context: create_params[:context].presence, gloss: create_params[:gloss].presence
    )

    render json: entry_json(entry), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_content
  end

  def destroy
    @entry.destroy!
    redirect_back fallback_location: vocab_entries_path, notice: "Removed from vocab notebook.", status: :see_other
  end

  def export
    @lang = Dictionary::SUPPORTED_LANGS.include?(params[:lang]) ? params[:lang] : nil
    scope = filtered_entries
    stamp = [ "vocab", @book&.title&.parameterize, Date.current.iso8601 ].compact_blank.join("-")

    case params[:format]
    when "anki"
      send_data VocabEntries::Export.anki_tsv(scope), filename: "#{stamp}.tsv",
        type: "text/tab-separated-values; charset=utf-8"
    else
      send_data VocabEntries::Export.csv(scope), filename: "#{stamp}.csv",
        type: "text/csv; charset=utf-8"
    end
  end

  private

  # Current.user's entries, book-filtered (@book) but not yet lang-filtered
  # — the base every list/count/export query in this controller narrows
  # from, kept separate from filtered_entries so the lang chip counts can
  # be computed across all langs without re-querying per chip.
  def scoped_entries
    scope = Current.user.vocab_entries
    scope = scope.where(book_id: @book.id) if @book
    scope
  end

  # scoped_entries plus the lang filter, eager-loading :book so rendering
  # a page of rows (each of which links to its book) never N+1s.
  def filtered_entries
    scope = scoped_entries.includes(:book).recent
    scope = scope.where(lang: @lang) if @lang
    scope
  end

  def set_book
    @book = Book.find(params[:book_id])
  end

  def set_entry
    @entry = Current.user.vocab_entries.find(params[:id])
  end

  def resolve_book_id(raw)
    return nil if raw.blank?

    Book.where(id: raw).pick(:id)
  end

  def create_params
    params.permit(:word, :lemma, :lang, :book_id, :context, :gloss)
  end

  def entry_json(entry)
    {
      id: entry.id, word: entry.word, lemma: entry.lemma, lang: entry.lang,
      book_id: entry.book_id, context: entry.context, gloss: entry.gloss,
      created_at: entry.created_at, updated_at: entry.updated_at
    }
  end
end
