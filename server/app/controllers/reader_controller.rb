# In-browser reader (session auth). Serves the book file to foliate-js,
# tracks per-user reading position, and (for books with no directly
# readable format) kicks off an epub conversion so the page has something
# to open once it lands.
class ReaderController < ApplicationController
  before_action :set_book

  layout "reader"

  # foliate-js opens each book section in an iframe with
  # sandbox="allow-same-origin allow-scripts" (needed for in-section
  # scripting/events — see the vendored paginator.js), whose `blob:`
  # document is consequently same-origin with this app and runs whatever
  # script the book itself contains, completely unsanitized. Per the CSP
  # spec, a `blob:` document with no opener of its own inherits the CSP of
  # whoever created it — i.e. THIS page — so `script-src :self` here (no
  # `unsafe-inline`/`unsafe-eval`, and no nonce a book's own markup could
  # ever carry) is what actually stops a malicious book's inline <script>
  # from running with this session's cookies. This does not fully close the
  # gap (the iframe is still same-origin, so anything that doesn't need
  # script — e.g. reading the DOM — is unaffected); serving book content
  # from a separate origin remains the complete fix and is out of scope
  # here. `style_src` keeps `unsafe_inline` because foliate-js injects
  # per-theme <style> tags straight into each section's document
  # (renderer.setStyles) with no way for us to nonce vendored code.
  content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.style_src   :self, :unsafe_inline
    policy.img_src     :self, :data, :blob, "https://upload.wikimedia.org"
    policy.font_src    :self, :data
    policy.connect_src :self, "https://en.wikipedia.org", "https://it.wikipedia.org"
    policy.frame_src   :self, :blob
    policy.object_src  :none
    policy.base_uri    :none
    policy.form_action :self
  end

  MIME_TYPES = {
    "epub" => "application/epub+zip",
    "azw3" => "application/x-mobipocket-ebook",
    "azw"  => "application/x-mobipocket-ebook",
    "mobi" => "application/x-mobipocket-ebook",
    "prc"  => "application/x-mobipocket-ebook",
    "fb2"  => "application/xml",
    "cbz"  => "application/vnd.comicbook+zip",
    "txt"  => "text/plain",
    "pdf"  => "application/pdf"
  }.freeze

  # Formats Reader::Anchor can index (it shells out to Library::Mobi.raw_text,
  # a MOBI6-stream reader) — the subset of Book::KINDLE_FORMATS with an
  # actual text stream to anchor into (excludes kfx/txt/pdf).
  ANCHOR_FORMATS = %w[azw3 azw mobi prc].freeze

  # book.language is free text (Calibre metadata / OPF dc:language) — maps
  # the handful of forms we expect for the two Dictionary::SUPPORTED_LANGS
  # down to the lookup card's default lang; anything else (including blank)
  # falls back to English.
  LANG_ALIASES = { "en" => "en", "eng" => "en", "it" => "it", "ita" => "it" }.freeze

  # How far below the Kindle's last-known percent a new web position has
  # to fall before we treat it as "went backward" and ask for confirmation
  # rather than silently overwriting further-along physical progress.
  BACKWARD_SLACK_PERCENT = 0.5

  # The client's own CONTEXT_EXACT_CHARS/CONTEXT_BEFORE_CHARS/
  # CONTEXT_AFTER_CHARS (reader_controller.js) target 100-150 chars each;
  # this is a generous multiple of that, not a tight bound — just enough to
  # stop a buggy or adversarial client from handing
  # Reader::Anchor.fuzzy_locate's O(query_length x window_length)
  # Levenshtein DP (run inside the KindleWritebackJob background worker) an
  # effectively unbounded query. Truncates rather than rejects so an
  # oversized context still degrades to "worse anchoring", not a dropped
  # write-back.
  CONTEXT_FIELD_MAX_CHARS = 2000

  # How long the "preparing a readable copy" screen (reader/show.html.erb's
  # @preparing_conversion branch) spins before swapping to a stalled-
  # conversion fallback with retry/back actions — see
  # reader_preparing_controller.js, which does the actual client-side
  # countdown from the conversion's created_at (a server timestamp, so it
  # survives every poll-triggered frame reload rather than resetting). A
  # real conversion finishes in well under this; Conversion::STUCK_AFTER
  # (1 hour) is the server-side backstop that actually marks a dead
  # worker's row failed so a retry can requeue it.
  PREPARING_TIMEOUT_MS = 90_000

  def show
    @file = @book.readable_file
    @book_lang = normalized_book_lang
    @reader_preferences = Current.user.reader_preferences
    if @file
      @initial_position = @book.reader_positions.find_by(user: Current.user)
      @text_length = mobi_text_length
    else
      ensure_epub_conversion
      @preparing_conversion = @book.conversions.active.where(target_format: "epub").order(:created_at).first
    end
  end

  def file
    @file = @book.readable_file
    return head :not_found if @file.nil? || !File.exist?(@file.absolute_path)

    fresh_when last_modified: File.mtime(@file.absolute_path)
    return if request.fresh?(response)

    send_file @file.absolute_path,
      type: MIME_TYPES.fetch(@file.format, "application/octet-stream"),
      disposition: "inline"
  end

  def update_position
    position = find_or_update_position!
    render json: { writeback: writeback_decision(position) }
  end

  def state
    position = @book.reader_positions.find_by(user: Current.user)
    render json: {
      web: position && {
        cfi: position.cfi,
        fraction: position.fraction,
        percent: position.percent,
        updated_at: position.updated_at
      },
      kindle: kindle_state_json,
      writeback_enabled: writeback_enabled?
    }
  end

  private

  def set_book
    @book = Book.find(params[:id])
  end

  # Default lang for the reader's dictionary lookup card (GET /lookup?lang=).
  def normalized_book_lang
    LANG_ALIASES[@book.language.to_s.strip.downcase] || "en"
  end

  # find_or_initialize_by + save! races two tabs/windows opening the same
  # never-before-read book: both see no existing row, and the loser's
  # save! hits ReaderPosition's user_id/book_id uniqueness validation
  # instead of a normal update. On this app's SQLite backend that surfaces
  # as RecordInvalid (the losing save's own uniqueness-validation SELECT
  # already observes the winner's committed insert); RecordNotUnique is
  # rescued too for portability to backends where the raw unique index
  # wins the race instead. One retry against the now-existing row (which
  # the winner just created) is always enough.
  def find_or_update_position!
    position = ReaderPosition.find_or_initialize_by(book: @book, user: Current.user)
    assign_position_attributes(position)
    position.save!
    position
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    position = ReaderPosition.find_by!(book: @book, user: Current.user)
    assign_position_attributes(position)
    position.save!
    position
  end

  def assign_position_attributes(position)
    position.assign_attributes(
      cfi: params[:cfi].presence,
      fraction: params[:fraction].presence&.to_f,
      percent: params[:percent].presence&.to_f,
      context: parsed_context
    )
  end

  # -- write-back decision (used by #update_position) ------------------

  # One of "disabled" | "no_context" | "skipped_backward" | "enqueued".
  # See app/services/reader/kindle_writeback.rb for the actual bundle
  # rewrite, which KindleWritebackJob drives.
  def writeback_decision(position)
    return "disabled" unless writeback_enabled?
    return "no_context" if position.context.blank? || position.context["exact"].blank?
    return "skipped_backward" if backward_without_confirmation?(position)

    KindleWritebackJob.perform_later(@book.id, Current.user.id)
    "enqueued"
  end

  def backward_without_confirmation?(position)
    return false if confirm_backward?

    kindle_percent = Reader::KindleWriteback.latest_physical_state(@book, user: Current.user)&.progress_percent
    return false unless kindle_percent && position.percent

    position.percent < kindle_percent - BACKWARD_SLACK_PERCENT
  end

  def confirm_backward?
    ActiveModel::Type::Boolean.new.cast(params[:confirm_backward])
  end

  def writeback_enabled?
    Device.physical.where(reader_writeback: true).exists?
  end

  # -- kindle state (used by #state) ------------------------------------

  def kindle_state_json
    state = Reader::KindleWriteback.latest_physical_state(@book, user: Current.user)
    return nil unless state

    {
      device_name: state.device.name,
      content_mtime: state.content_mtime,
      position: state.last_position,
      percent: state.progress_percent,
      snippet: kindle_snippet(state.last_position)
    }
  end

  # Best-effort: any failure to locate a source file or decode its text
  # (including Library::Mobi::Unsupported for HUFF/KFX) just means no
  # snippet — never a 500 on the state endpoint.
  def kindle_snippet(position)
    return nil unless position

    source = anchor_source_file
    return nil unless source

    Reader::Anchor.snippet_at(source, position)
  rescue StandardError
    nil
  end

  def anchor_source_file
    ANCHOR_FORMATS.filter_map { |format| @book.file_for(format) }.find(&:available?)
  end

  # Mirrors ConversionsController#create's source-picking, minus the
  # already-queued/target-format checks that don't apply here (there's no
  # explicit target_format param — it's always epub).
  def ensure_epub_conversion
    return if @book.conversions.active.where(target_format: "epub").exists?

    by_format = @book.book_files.index_by(&:format)
    source = Conversion::SOURCE_PREFERENCE.filter_map { |format| format == "epub" ? nil : by_format[format] }.first
    return unless source

    conversion = @book.conversions.create!(book_file: source, target_format: "epub")
    ConvertBookJob.perform_later(conversion.id)
  end

  # Locations readout ("Loc 123 of 456") needs the book's uncompressed
  # text length, which only a MOBI/AZW3 source exposes cheaply (PalmDOC
  # header). EPUB has no equivalent measure, so this is nil for epub-only
  # books and the reader JS falls back to percent + chapter title.
  def mobi_text_length
    source = %w[azw3 mobi].filter_map { |format| @book.file_for(format) }.find(&:available?)
    return nil unless source

    Library::Mobi.text_length(source.absolute_path)
  end

  # The client sends `context` either as a JSON string (typical `fetch`
  # body) or as nested Rails params (a plain form post) — accept both.
  def parsed_context
    raw = params[:context]
    return {} if raw.blank?

    context = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : JSON.parse(raw.to_s)
    cap_context_fields(context)
  rescue JSON::ParserError
    {}
  end

  def cap_context_fields(context)
    %w[exact before after].each do |key|
      value = context[key]
      context[key] = value[0, CONTEXT_FIELD_MAX_CHARS] if value.is_a?(String) && value.length > CONTEXT_FIELD_MAX_CHARS
    end
    context
  end
end
