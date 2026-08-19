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
  # from running with this session's cookies. `wasm_unsafe_eval` below only
  # permits compiling/instantiating WebAssembly modules (needed by the
  # vendored pdf.js's image codecs); unlike `unsafe_eval` it does not permit
  # `eval`/`Function()`/string-to-JS, so this guarantee still holds. This
  # does not fully close the gap (the iframe is still same-origin, so
  # anything that doesn't need script — e.g. reading the DOM — is
  # unaffected); serving book content from a separate origin remains the
  # complete fix and is out of scope here. `style_src` keeps `unsafe_inline`
  # because foliate-js injects
  # per-theme <style> tags straight into each section's document
  # (renderer.setStyles) with no way for us to nonce vendored code.
  content_security_policy do |policy|
    policy.default_src :self
    # `wasm-unsafe-eval` (not the much broader `unsafe-eval`) is required by
    # Chrome/strict-CSP browsers for `WebAssembly.instantiate` itself — the
    # vendored pdf.js decodes JPXDecode/JBIG2Decode page images via wasm
    # modules (see vendor/pdfjs/wasm/), which silently fail to even
    # instantiate without this even though the module bytes fetch fine.
    policy.script_src  :self, :wasm_unsafe_eval
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
      # Threaded into the file URL the reader shell fetches (see
      # reader/show.html.erb) so #file resolves the same variant.
      @raw = params[:raw].present?
      # ?text=1 asks for the plain-text reflow companion (see
      # Library::TextCompanion, TextCompanionJob) — silently ignored
      # (falls through to the ordinary ocr/raw/none resolution below)
      # unless it's actually fresh for this exact readable_file. That
      # covers both a stale/never-finished-building link and a book
      # whose readable_file isn't even the text-companion source (a
      # richer preferred format — see Book#text_companion_source_file):
      # #file has to make the identical call so the two never disagree.
      text_requested = params[:text].present? && @file.text_fresh?
      # "none" | "ocr" | "raw" | "text" — mirrors
      # BookFile#read_source_path/#ocr_fresh?/#text_fresh? so the badge
      # the view renders always names what #file actually serves. text
      # wins over raw when both are requested and the companion is
      # fresh; no OCR companion at all means there's nothing to switch
      # between there, regardless of ?raw=.
      @variant = if text_requested
        "text"
      elsif @file.ocr_fresh?
        @raw ? "raw" : "ocr"
      else
        "none"
      end
      # The .txt companion's own basename — NOT the source book_file's
      # filename — is what actually gets fetched/opened for the text
      # variant (see #file below); foliate-js picks its txt engine off
      # this filename's extension (view.js), so a mismatch here would
      # make it try to parse plain text as whatever the source format was.
      @reader_filename = @variant == "text" ? File.basename(@file.text_path) : @file.filename
      @reader_format = @variant == "text" ? "txt" : @file.format
      # Which reader_positions row (see ReaderPosition, D9) this session
      # reads/writes — "text" and every other variant never share
      # pagination (a different underlying file, incompatible cfis).
      @position_variant = @variant == "text" ? "text" : ""
      @initial_position = position_for_variant(@position_variant)
      @text_length = mobi_text_length
    else
      ensure_epub_conversion
      @preparing_conversion = @book.conversions.active.where(target_format: "epub").order(:created_at).first
    end
  end

  def file
    @file = @book.readable_file
    return head :not_found if @file.nil?

    # ?text=1 — the plain-text reflow companion — is its own branch: a
    # wholly separate underlying path/sha/mime type from the source
    # book_file, not just another #read_source_path candidate. Falls
    # through to the ordinary ocr/raw resolution below (rather than
    # 404ing) when the companion isn't actually fresh, exactly like
    # #show's @variant resolution — the two must never disagree about
    # what a given URL serves.
    return file_text_companion if params[:text].present? && @file.text_fresh?

    # The OCR/original choice lives entirely in the URL (?raw=1) rather
    # than session state, so the two variants are already distinct browser
    # cache keys. Existence check, fresh_when and send_file all read this
    # same chosen path so nothing downstream can pick a different variant
    # than what was validated.
    raw = params[:raw].present?
    path = raw ? @file.absolute_path : @file.read_source_path
    return head :not_found unless File.exist?(path)

    # This app runs with strict_freshness (Rails 8.1 default): once a
    # request carries If-None-Match, the ETag alone decides freshness —
    # Last-Modified is never consulted as a fallback. So the ETag has to
    # carry the STORED hash of the bytes actually being served, not just
    # the path: an OCR re-run rewrites this same storage/ocr/<public_id>
    # .ocr.pdf in place, and a library rescan can rewrite a changed
    # external file's bytes at its unchanged path (see
    # Library::Scan#refresh_changed_file) — in both cases the path never
    # changes even though the served bytes do. ocr_sha256 and sha256 are
    # exactly the columns OcrBookJob and Library::Scan update every time
    # those bytes are regenerated, which is what makes them the right
    # etag ingredient: a stale cached copy correctly misses instead of
    # 304ing forever. `serving_ocr` mirrors #read_source_path's own
    # ocr_fresh? check so the sha picked always matches the path actually
    # being served in both the raw=1 and default branches. Path stays in
    # the etag array too, for raw/OCR variant separation.
    serving_ocr = !raw && @file.ocr_fresh?
    content_sha = serving_ocr ? @file.ocr_sha256 : @file.sha256
    fresh_when etag: [ path.to_s, content_sha ], last_modified: File.mtime(path)
    return if request.fresh?(response)

    send_file path,
      type: MIME_TYPES.fetch(@file.format, "application/octet-stream"),
      disposition: "inline"
  end

  def update_position
    position = find_or_update_position!
    render json: { writeback: writeback_decision(position) }
  end

  def state
    # variant: "" specifically — this endpoint compares web progress
    # against the physical Kindle's own state (see #kindle_state_json),
    # and a "text" position has no equivalent on the device (same reason
    # KindleWritebackJob picks "" explicitly rather than an unordered
    # find_by over what's now a multi-row-per-book-per-user table).
    position = @book.reader_positions.find_by(user: Current.user, variant: "")
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

  # -- text-companion file serving (used by #file) -----------------------

  # Same ETag/freshness shape as the main branch of #file (see its own
  # comment): text_sha256 is the column TextCompanionJob rewrites on
  # every regeneration, so a stale cached copy correctly misses instead
  # of 304ing forever against bytes that changed at the same path.
  def file_text_companion
    path = @file.text_absolute_path
    return head :not_found unless File.exist?(path)

    fresh_when etag: [ path.to_s, @file.text_sha256 ], last_modified: File.mtime(path)
    return if request.fresh?(response)

    send_file path, type: "text/plain", disposition: "inline"
  end

  # find_or_initialize_by + save! races two tabs/windows opening the same
  # never-before-read book: both see no existing row, and the loser's
  # save! hits ReaderPosition's user_id/book_id/variant uniqueness
  # validation instead of a normal update. On this app's SQLite backend
  # that surfaces as RecordInvalid (the losing save's own
  # uniqueness-validation SELECT already observes the winner's committed
  # insert); RecordNotUnique is rescued too for portability to backends
  # where the raw unique index wins the race instead. One retry against
  # the now-existing row (which the winner just created) is always enough.
  def find_or_update_position!
    variant = requested_position_variant
    position = ReaderPosition.find_or_initialize_by(book: @book, user: Current.user, variant: variant)
    assign_position_attributes(position)
    position.save!
    position
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
    position = ReaderPosition.find_by!(book: @book, user: Current.user, variant: variant)
    assign_position_attributes(position)
    position.save!
    position
  end

  # Which reader_positions row (see ReaderPosition, D9) this save
  # targets. The client always sends its own positionVariantValue
  # (reader_controller.js), but an unrecognized/missing value falls back
  # to the shared "" row rather than raising.
  def requested_position_variant
    variant = params[:variant].to_s
    ReaderPosition::VARIANTS.include?(variant) ? variant : ""
  end

  def assign_position_attributes(position)
    position.assign_attributes(
      cfi: params[:cfi].presence,
      fraction: params[:fraction].presence&.to_f,
      percent: params[:percent].presence&.to_f,
      context: parsed_context
    )
  end

  # The row for `variant` if one already exists; else, when the OTHER
  # variant has a row, a fresh (unsaved) position carrying just that
  # row's #fraction — never its #cfi, which is meaningless across a
  # variant change (a different underlying file with its own,
  # incompatible cfis — see ReaderPosition). nil when neither row exists
  # yet, same as a brand-new book.
  def position_for_variant(variant)
    primary = @book.reader_positions.find_by(user: Current.user, variant: variant)
    return primary if primary

    other_variant = variant == "text" ? "" : "text"
    other = @book.reader_positions.find_by(user: Current.user, variant: other_variant)
    return nil unless other

    ReaderPosition.new(book: @book, user: Current.user, variant: variant, fraction: other.fraction)
  end

  # -- write-back decision (used by #update_position) ------------------

  # One of "disabled" | "not_applicable" | "no_context" |
  # "skipped_backward" | "enqueued". See
  # app/services/reader/kindle_writeback.rb for the actual bundle
  # rewrite, which KindleWritebackJob drives.
  def writeback_decision(position)
    return "disabled" unless writeback_enabled?
    # A "text"-variant position has nothing to anchor into on the
    # physical Kindle: Reader::Anchor only understands the book's own
    # MOBI/AZW3 text stream (ANCHOR_FORMATS above), never the separate
    # text-companion .txt (see Library::TextCompanion) — and
    # KindleWritebackJob only ever reads the "" row anyway (see its own
    # comment there). Never worth an enqueue.
    return "not_applicable" if position.variant == "text"
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
