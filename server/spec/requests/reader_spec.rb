require "rails_helper"

RSpec.describe "In-browser reader", type: :request do
  let!(:user) { create(:user) }
  let!(:book) { create(:book, title: "Fixture Book") }

  def sign_in(user, password: "password")
    post session_path, params: { email_address: user.email_address, password: password }
  end

  describe "GET /books/:id/read" do
    it "requires authentication" do
      get read_book_path(book)
      expect(response).to redirect_to(new_session_path)
    end

    context "with a readable file" do
      let!(:epub_file) { create(:book_file, :epub_fixture, book: book) }

      it "renders the reader for a signed-in user" do
        sign_in(user)
        get read_book_path(book)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("data-controller=\"reader\"")
        expect(response.body).to include(read_book_file_path(book))
      end

      it "threads ?raw=1 into the file URL the reader shell fetches" do
        sign_in(user)
        get read_book_path(book, raw: 1)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(CGI.escapeHTML(read_book_file_path(book, raw: 1)))
      end

      it "renders the page-mode toggle and the zoom-mode overlay controls" do
        sign_in(user)
        get read_book_path(book)

        expect(response.body).to include('data-reader-target="pageModeRow"')
        expect(response.body).to include('data-reader-page-mode-param="fit"')
        expect(response.body).to include('data-reader-page-mode-param="zoom"')
        expect(response.body).to include('class="reader-fxl-controls"')
        expect(response.body).to include("click->reader#fxlPrevPage")
        expect(response.body).to include("click->reader#fxlNextPage")
        expect(response.body).to include("click->reader#fxlZoomIn")
        expect(response.body).to include("click->reader#fxlZoomOut")
      end

      it "declares variant 'none' and renders no variant badge without an OCR companion" do
        sign_in(user)
        get read_book_path(book)

        expect(response.body).to include('data-reader-variant-value="none"')
        expect(response.body).not_to include("reader-variant-badge")
      end

      it "scopes a restrictive script-src Content-Security-Policy to the reader page only" do
        sign_in(user)

        get read_book_path(book)
        csp = response.headers["Content-Security-Policy"]
        expect(csp).to be_present
        # wasm-unsafe-eval permits only Wasm compile/instantiate (pdf.js image
        # codecs), not eval/Function() — still no unsafe-inline/unsafe-eval.
        expect(csp).to match(/script-src 'self' 'wasm-unsafe-eval' 'nonce-[^']+'/)
        expect(csp).to include("object-src 'none'")
        expect(response.body).to include('type="importmap"') # importmap tag still renders (and is nonced)

        get book_path(book) # an unrelated controller is left completely unaffected
        expect(response.headers["Content-Security-Policy"]).to be_nil
      end
    end

    context "with no readable file but a convertible source" do
      let!(:docx_file) { create(:book_file, book: book, format: "docx") }

      it "queues an epub conversion and shows a preparing state" do
        sign_in(user)

        expect {
          get read_book_path(book)
        }.to change(Conversion, :count).by(1)
          .and have_enqueued_job(ConvertBookJob)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Preparing a readable copy")
        # The spinner/timeout affordance (see reader_preparing_controller.js):
        # a server timestamp the client counts elapsed time from, plus a
        # fallback panel that only appears once that timeout fires.
        expect(response.body).to include("data-reader-preparing-started-at-value")
        expect(response.body).to include(%(data-reader-preparing-timeout-value="#{ReaderController::PREPARING_TIMEOUT_MS}"))
        expect(response.body).to include("Still preparing")

        conversion = Conversion.last
        expect(conversion).to have_attributes(book: book, book_file: docx_file, target_format: "epub", status: "pending")
      end

      it "does not double-queue an already-active conversion" do
        sign_in(user)
        get read_book_path(book)

        expect {
          get read_book_path(book)
        }.not_to change(Conversion, :count)
      end
    end

    context "with no book files at all" do
      it "shows a no-readable-file state without queuing anything" do
        sign_in(user)

        expect { get read_book_path(book) }.not_to change(Conversion, :count)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("No readable file")
      end
    end
  end

  describe "GET /books/:id/read/file" do
    let!(:epub_file) { create(:book_file, :epub_fixture, book: book) }

    before { sign_in(user) }

    it "streams the file inline with the epub MIME type" do
      get read_book_file_path(book)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/epub+zip")
      expect(response.headers["Content-Disposition"]).to include("inline")
      expect(response.body.b).to eq(File.binread(epub_file.absolute_path))
    end

    it "supports If-Modified-Since revalidation" do
      get read_book_file_path(book)
      expect(response).to have_http_status(:ok)

      get read_book_file_path(book), headers: { "If-Modified-Since" => response.headers["Last-Modified"] }
      expect(response).to have_http_status(:not_modified)
    end

    it "404s when the book has no readable file" do
      epub_file.destroy!
      get read_book_file_path(book)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /books/:id/read/file with an OCR'd scanned PDF" do
    let!(:pdf_file) do
      create(:book_file, book: book, format: "pdf").tap do |file|
        FileUtils.mkdir_p(file.absolute_path.dirname)
        File.write(file.absolute_path, "raw scanned pdf bytes")
        file.update!(size: File.size(file.absolute_path), sha256: Library.sha256(file.absolute_path))
      end
    end

    before { sign_in(user) }

    it "serves the fresh OCR text-layer companion instead of the raw scan" do
      ocr_path = "ocr/#{pdf_file.id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
      pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_file.sha256)

      get read_book_file_path(book)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.body.b).to eq("ocr'd pdf bytes with a text layer")
    end

    it "falls back to the raw file when there is no fresh OCR companion" do
      get read_book_file_path(book)

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq("raw scanned pdf bytes")
    end
  end

  describe "GET /books/:id/read/file?raw=1 alongside the default OCR companion" do
    let!(:pdf_file) do
      create(:book_file, book: book, format: "pdf").tap do |file|
        FileUtils.mkdir_p(file.absolute_path.dirname)
        File.write(file.absolute_path, "raw scanned pdf bytes")
        file.update!(size: File.size(file.absolute_path), sha256: Library.sha256(file.absolute_path))
      end
    end

    let(:ocr_path) { "ocr/#{pdf_file.id}.ocr.pdf" }

    before do
      sign_in(user)
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
      pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_file.sha256)
    end

    it "serves the OCR companion by default and the untouched original with raw=1" do
      get read_book_file_path(book)
      expect(response.body.b).to eq("ocr'd pdf bytes with a text layer")

      get read_book_file_path(book, raw: 1)
      expect(response.body.b).to eq("raw scanned pdf bytes")
    end

    it "gives the two variants distinct ETags" do
      get read_book_file_path(book)
      ocr_etag = response.headers["ETag"]

      get read_book_file_path(book, raw: 1)
      raw_etag = response.headers["ETag"]

      expect(ocr_etag).to be_present
      expect(raw_etag).to be_present
      expect(ocr_etag).not_to eq(raw_etag)
    end

    # The regression this guards: Last-Modified alone has one-second
    # resolution, and the raw file predates the OCR companion made from
    # it — so a naive `fresh_when last_modified:` with no ETag could
    # legitimately 304 a raw=1 request against the OCR file's (newer)
    # Last-Modified. Presenting the OCR variant's own validators to the
    # raw URL (as a client that had it cached from a prior visit would)
    # must not 304 — that would leave the client showing its old OCR
    # bytes under a URL that's actually supposed to be the raw scan.
    it "never lets one variant's conditional GET validators freshen the other variant's response" do
      get read_book_file_path(book)
      ocr_etag = response.headers["ETag"]
      ocr_last_modified = response.headers["Last-Modified"]

      get read_book_file_path(book, raw: 1),
        headers: { "If-None-Match" => ocr_etag, "If-Modified-Since" => ocr_last_modified }

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq("raw scanned pdf bytes")
    end

    it "still 304s each variant's own URL against its own prior validators" do
      get read_book_file_path(book, raw: 1)
      raw_etag = response.headers["ETag"]
      raw_last_modified = response.headers["Last-Modified"]

      get read_book_file_path(book, raw: 1),
        headers: { "If-None-Match" => raw_etag, "If-Modified-Since" => raw_last_modified }

      expect(response).to have_http_status(:not_modified)
    end

    # The regression this guards: with only `etag: path` (the path string
    # never changes when an OCR re-run rewrites the same
    # storage/ocr/<public_id>.ocr.pdf in place), strict_freshness means an
    # If-None-Match from before the rewrite would 304 forever against the
    # now-stale cached copy. Folding ocr_sha256 into the etag (updated by
    # OcrBookJob on every regeneration, mirrored here) fixes that.
    it "does not 304 a stale ETag once the OCR companion is regenerated with different bytes at the same path" do
      get read_book_file_path(book)
      stale_etag = response.headers["ETag"]

      new_bytes = "re-ocr'd pdf bytes, a different text layer"
      File.write(Library.base_root.join(ocr_path), new_bytes)
      pdf_file.update!(ocr_sha256: Library.sha256(Library.base_root.join(ocr_path)))

      get read_book_file_path(book), headers: { "If-None-Match" => stale_etag }

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq(new_bytes.b)
    end

    it "still 304s the OCR variant against its own current validators once content is unchanged" do
      get read_book_file_path(book)
      etag = response.headers["ETag"]
      last_modified = response.headers["Last-Modified"]

      get read_book_file_path(book), headers: { "If-None-Match" => etag, "If-Modified-Since" => last_modified }

      expect(response).to have_http_status(:not_modified)
    end
  end

  describe "GET /books/:id/read — OCR/raw variant badge" do
    let!(:pdf_file) do
      create(:book_file, book: book, format: "pdf").tap do |file|
        FileUtils.mkdir_p(file.absolute_path.dirname)
        File.write(file.absolute_path, "raw scanned pdf bytes")
        file.update!(size: File.size(file.absolute_path), sha256: Library.sha256(file.absolute_path))
      end
    end

    let(:ocr_path) { "ocr/#{pdf_file.id}.ocr.pdf" }

    before do
      sign_in(user)
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
      pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_file.sha256)
    end

    it "defaults to the ocr variant, with a 'text layer' badge linking to the raw scan" do
      get read_book_path(book)

      expect(response.body).to include('data-reader-variant-value="ocr"')
      expect(response.body).to include(%(href="#{read_book_path(book, raw: 1)}"))
      expect(response.body).to include(%(title="Switch to the original scan"))
      expect(response.body).to include(">text layer<")
    end

    it "switches to the raw variant on ?raw=1, with an 'original scan' badge linking back to the ocr text layer" do
      get read_book_path(book, raw: 1)

      expect(response.body).to include('data-reader-variant-value="raw"')
      expect(response.body).to include(%(href="#{read_book_path(book)}"))
      expect(response.body).to include(%(title="Switch to the OCR text-layer version"))
      expect(response.body).to include(">original scan<")
    end
  end

  describe "GET /books/:id/read for a plain-text (.txt) book" do
    let!(:txt_file) do
      create(:book_file, book: book, format: "txt").tap do |file|
        FileUtils.mkdir_p(file.absolute_path.dirname)
        File.write(file.absolute_path, "Chapter One.\n\nIt was a dark and stormy night.")
        file.update!(size: File.size(file.absolute_path), sha256: Library.sha256(file.absolute_path))
      end
    end

    before { sign_in(user) }

    it "renders the reader shell for the txt format and serves the file as text/plain" do
      get read_book_path(book)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-reader-format-value="txt"')

      get read_book_file_path(book)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/plain")
      expect(response.body).to eq("Chapter One.\n\nIt was a dark and stormy night.")
    end
  end

  describe "the text-only companion (see Library::TextCompanion, TextCompanionJob)" do
    let!(:pdf_file) do
      create(:book_file, book: book, format: "pdf").tap do |file|
        FileUtils.mkdir_p(file.absolute_path.dirname)
        File.write(file.absolute_path, "raw scanned pdf bytes")
        file.update!(size: File.size(file.absolute_path), sha256: Library.sha256(file.absolute_path))
      end
    end

    def make_text_fresh!
      relative = "text/#{book.public_id}.txt"
      FileUtils.mkdir_p(Library.base_root.join(relative).dirname)
      File.write(Library.base_root.join(relative), "plain text companion body")
      # #text_source_content_sha256 (not the raw #sha256) — compares
      # against the OCR companion's sha once one is fresh (see
      # BookFile#text_fresh?), so this has to be read fresh each call
      # rather than hardcoded, for specs that make the OCR companion
      # fresh first.
      pdf_file.update!(text_path: relative, text_sha256: Library.sha256(Library.base_root.join(relative)),
        text_source_sha256: pdf_file.reload.text_source_content_sha256)
    end

    before { sign_in(user) }

    describe "GET /books/:id/read" do
      it "declares variant 'text' and swaps the filename/format to the companion's own when ?text=1 is fresh" do
        make_text_fresh!

        get read_book_path(book, text: 1)

        expect(response.body).to include('data-reader-variant-value="text"')
        expect(response.body).to include(%(data-reader-filename-value="#{book.public_id}.txt"))
        expect(response.body).to include('data-reader-format-value="txt"')
        expect(response.body).to include(CGI.escapeHTML(read_book_file_path(book, text: 1)))
      end

      it "falls back to the default variant when ?text=1 is requested but the companion isn't fresh" do
        get read_book_path(book, text: 1)

        expect(response.body).to include('data-reader-variant-value="none"')
        expect(response.body).to include(%(data-reader-filename-value="#{pdf_file.filename}"))
      end

      it "shows a 'text only' badge with a switch link back to the default variant" do
        make_text_fresh!

        get read_book_path(book, text: 1)

        expect(response.body).to include(">text only<")
        expect(response.body).to include(%(href="#{read_book_path(book)}"))
        expect(response.body).to include(%(title="Switch to the original file"))
      end

      it "offers a 'text only' switch link from the default variant once the companion is fresh" do
        make_text_fresh!

        get read_book_path(book)

        expect(response.body).to include('data-reader-variant-value="none"')
        expect(response.body).to include(%(href="#{read_book_path(book, text: 1)}"))
        expect(response.body).to include(">text only<")
      end

      it "offers both the OCR and text switch links together once both companions are fresh" do
        ocr_path = "ocr/#{pdf_file.id}.ocr.pdf"
        FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
        File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
        pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_file.sha256)
        make_text_fresh!

        get read_book_path(book)

        expect(response.body).to include('data-reader-variant-value="ocr"')
        expect(response.body).to include(%(href="#{read_book_path(book, raw: 1)}"))
        expect(response.body).to include(%(href="#{read_book_path(book, text: 1)}"))
      end
    end

    describe "GET /books/:id/read/file" do
      it "serves the text companion as text/plain when ?text=1 is fresh" do
        make_text_fresh!

        get read_book_file_path(book, text: 1)

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/plain")
        expect(response.body).to eq("plain text companion body")
      end

      it "falls back to the raw/ocr resolution when the companion isn't fresh" do
        get read_book_file_path(book, text: 1)

        expect(response).to have_http_status(:ok)
        expect(response.body.b).to eq("raw scanned pdf bytes")
      end

      it "gives the text variant its own ETag, distinct from the default variant's" do
        make_text_fresh!

        get read_book_file_path(book)
        default_etag = response.headers["ETag"]

        get read_book_file_path(book, text: 1)
        text_etag = response.headers["ETag"]

        expect(text_etag).to be_present
        expect(text_etag).not_to eq(default_etag)
      end

      it "does not 304 a stale ETag once the companion is regenerated with different bytes at the same path" do
        make_text_fresh!
        get read_book_file_path(book, text: 1)
        stale_etag = response.headers["ETag"]

        new_bytes = "re-extracted text, a different companion"
        File.write(Library.base_root.join(pdf_file.text_path), new_bytes)
        pdf_file.update!(text_sha256: Library.sha256(Library.base_root.join(pdf_file.text_path)))

        get read_book_file_path(book, text: 1), headers: { "If-None-Match" => stale_etag }

        expect(response).to have_http_status(:ok)
        expect(response.body.b).to eq(new_bytes.b)
      end

      it "still 304s the text variant against its own current validators once content is unchanged" do
        make_text_fresh!
        get read_book_file_path(book, text: 1)
        etag = response.headers["ETag"]
        last_modified = response.headers["Last-Modified"]

        get read_book_file_path(book, text: 1), headers: { "If-None-Match" => etag, "If-Modified-Since" => last_modified }

        expect(response).to have_http_status(:not_modified)
      end
    end

    describe "fraction-only seeding across variants" do
      it "seeds the text variant's initial fraction from the plain variant's saved position, without its cfi" do
        make_text_fresh!
        create(:reader_position, book: book, user: user, variant: "", cfi: "epubcfi(/6/2!/4)", fraction: 0.5, percent: 50.0)

        get read_book_path(book, text: 1)

        expect(response.body).to include('data-reader-fraction-value="0.5"')
        expect(response.body).not_to include("epubcfi(/6/2!/4)")
      end

      it "seeds the plain variant from a saved text position's fraction, without its cfi" do
        make_text_fresh!
        create(:reader_position, book: book, user: user, variant: "text", cfi: "epubcfi(text/9)", fraction: 0.75, percent: 75.0)

        get read_book_path(book)

        expect(response.body).to include('data-reader-fraction-value="0.75"')
        expect(response.body).not_to include("epubcfi(text/9)")
      end

      it "prefers an existing row for the requested variant over cross-variant seeding" do
        make_text_fresh!
        create(:reader_position, book: book, user: user, variant: "", cfi: "epubcfi(/6/2!/4)", fraction: 0.1, percent: 10.0)
        create(:reader_position, book: book, user: user, variant: "text", cfi: "epubcfi(text/1)", fraction: 0.9, percent: 90.0)

        get read_book_path(book, text: 1)

        expect(response.body).to include('data-reader-cfi-value="epubcfi(text/1)"')
        expect(response.body).to include('data-reader-fraction-value="0.9"')
      end

      it "renders no initial position at all when neither variant has one yet" do
        make_text_fresh!

        get read_book_path(book, text: 1)

        expect(response.body).to include('data-reader-cfi-value=""')
      end
    end

    describe "PUT /books/:id/read/position with variant: 'text'" do
      before { make_text_fresh! }

      it "renders data-reader-position-variant-value=\"text\" on the reader shell" do
        get read_book_path(book, text: 1)

        expect(response.body).to include('data-reader-position-variant-value="text"')
      end

      it "renders data-reader-position-variant-value=\"\" for every other variant" do
        get read_book_path(book)

        expect(response.body).to include('data-reader-position-variant-value=""')
      end

      it "creates a separate row for variant: 'text', without touching the shared '' row" do
        put read_book_position_path(book), params: { cfi: "epubcfi(/6/2!/4)", fraction: 0.1, percent: 10 }

        expect {
          put read_book_position_path(book),
            params: { cfi: "epubcfi(text/1)", fraction: 0.4, percent: 40, variant: "text" }
        }.to change(ReaderPosition, :count).by(1)

        plain = ReaderPosition.find_by(book: book, user: user, variant: "")
        text = ReaderPosition.find_by(book: book, user: user, variant: "text")
        expect(plain).to have_attributes(cfi: "epubcfi(/6/2!/4)", fraction: 0.1)
        expect(text).to have_attributes(cfi: "epubcfi(text/1)", fraction: 0.4)
      end

      it "falls back to the shared '' row for an unrecognized variant value" do
        put read_book_position_path(book),
          params: { cfi: "epubcfi(/6/2!/4)", fraction: 0.1, percent: 10, variant: "bogus" }

        expect(ReaderPosition.count).to eq(1)
        expect(ReaderPosition.find_by(book: book, user: user, variant: "")).to be_present
      end

      it "reports a 'not_applicable' write-back decision for a text-variant position, even with context present" do
        create(:device, kind: "kindle", reader_writeback: true)

        expect {
          put read_book_position_path(book),
            params: { percent: 40, context: { exact: "anchor text" }, variant: "text" }
        }.not_to have_enqueued_job(KindleWritebackJob)

        expect(JSON.parse(response.body)).to eq("writeback" => "not_applicable")
      end
    end

    describe "GET /books/:id/read/state" do
      it "ignores a 'text'-variant position and reports a nil web position when only that exists" do
        create(:reader_position, book: book, user: user, variant: "text",
          cfi: "epubcfi(text/1)", fraction: 0.5, percent: 50.0)

        get read_book_state_path(book)

        expect(JSON.parse(response.body)["web"]).to be_nil
      end
    end
  end

  describe "PUT /books/:id/read/position" do
    it "requires authentication" do
      expect {
        put read_book_position_path(book), params: { cfi: "epubcfi(/6/2!/4)", fraction: 0.1, percent: 10 }
      }.not_to change(ReaderPosition, :count)
      expect(response).to redirect_to(new_session_path)
    end

    context "when signed in" do
      before { sign_in(user) }

      it "creates a position from nested params" do
        expect {
          put read_book_position_path(book),
            params: { cfi: "epubcfi(/6/2!/4)", fraction: 0.25, percent: 25, context: { toc: "ch1" } }
        }.to change(ReaderPosition, :count).by(1)

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)).to eq("writeback" => "disabled")
        position = ReaderPosition.find_by(book: book, user: user)
        expect(position).to have_attributes(cfi: "epubcfi(/6/2!/4)", fraction: 0.25, percent: 25.0)
        expect(position.context).to eq("toc" => "ch1")
      end

      it "updates the existing row rather than creating a new one" do
        put read_book_position_path(book), params: { cfi: "epubcfi(/6/2!/4)", fraction: 0.1, percent: 10 }

        expect {
          put read_book_position_path(book), params: { cfi: "epubcfi(/6/4!/2)", fraction: 0.5, percent: 50 }
        }.not_to change(ReaderPosition, :count)

        position = ReaderPosition.find_by(book: book, user: user)
        expect(position).to have_attributes(cfi: "epubcfi(/6/4!/2)", fraction: 0.5, percent: 50.0)
      end

      it "retries once when two tabs race to create the first position for a book" do
        # Simulates the loser of the race: find_or_initialize_by ran before
        # the winner's row landed, so it still hands back a brand-new,
        # unsaved record; by the time save! actually runs, `existing` (the
        # winner's row) is already committed, so the uniqueness validation
        # fails save! with RecordInvalid instead of a normal update.
        existing = create(:reader_position, book: book, user: user,
          cfi: "epubcfi(/6/2!/4)", fraction: 0.1, percent: 10)
        allow(ReaderPosition).to receive(:find_or_initialize_by).and_return(ReaderPosition.new(book: book, user: user))

        put read_book_position_path(book), params: { cfi: "epubcfi(/6/4!/2)", fraction: 0.5, percent: 50 }

        expect(response).to have_http_status(:ok)
        expect(ReaderPosition.count).to eq(1)
        expect(existing.reload).to have_attributes(cfi: "epubcfi(/6/4!/2)", fraction: 0.5, percent: 50.0)
      end

      it "accepts context as a JSON string (as a JS fetch body would send it)" do
        put read_book_position_path(book),
          params: { cfi: "epubcfi(/6/2!/4)", fraction: 0.1, percent: 10, context: '{"toc":"ch2"}' }

        expect(ReaderPosition.find_by(book: book, user: user).context).to eq("toc" => "ch2")
      end

      it "caps oversized exact/before/after context fields rather than persisting them unbounded" do
        huge = "a" * (ReaderController::CONTEXT_FIELD_MAX_CHARS + 500)
        put read_book_position_path(book),
          params: { cfi: "epubcfi(/6/2!/4)", fraction: 0.1, percent: 10,
                    context: { exact: huge, before: huge, after: huge, toc: "ch1" } }

        context = ReaderPosition.find_by(book: book, user: user).context
        expect(context["exact"].length).to eq(ReaderController::CONTEXT_FIELD_MAX_CHARS)
        expect(context["before"].length).to eq(ReaderController::CONTEXT_FIELD_MAX_CHARS)
        expect(context["after"].length).to eq(ReaderController::CONTEXT_FIELD_MAX_CHARS)
        expect(context["toc"]).to eq("ch1") # untouched, opaque field
      end

      describe "write-back decision" do
        it "is disabled when no physical device has opted in" do
          put read_book_position_path(book), params: { percent: 10, context: { exact: "some anchor text" } }

          expect(JSON.parse(response.body)).to eq("writeback" => "disabled")
        end

        context "with a physical device opted into write-back" do
          let!(:kindle) { create(:device, kind: "kindle", reader_writeback: true) }

          it "is no_context when nothing was sent as context" do
            expect {
              put read_book_position_path(book), params: { percent: 10 }
            }.not_to have_enqueued_job(KindleWritebackJob)

            expect(JSON.parse(response.body)).to eq("writeback" => "no_context")
          end

          it "is no_context when context is present but exact is blank" do
            put read_book_position_path(book), params: { percent: 10, context: { toc: "ch1" } }

            expect(JSON.parse(response.body)).to eq("writeback" => "no_context")
          end

          it "enqueues the write-back job when there's no conflicting physical progress" do
            expect {
              put read_book_position_path(book), params: { percent: 40, context: { exact: "anchor text" } }
            }.to have_enqueued_job(KindleWritebackJob).with(book.id, user.id)

            expect(JSON.parse(response.body)).to eq("writeback" => "enqueued")
          end

          context "when the new position trails the Kindle's last-known progress" do
            before { create(:reading_state, book: book, device: kindle, progress_percent: 60.0, content_mtime: 1.hour.ago) }

            it "skips and asks for confirmation" do
              expect {
                put read_book_position_path(book), params: { percent: 10, context: { exact: "anchor text" } }
              }.not_to have_enqueued_job(KindleWritebackJob)

              expect(JSON.parse(response.body)).to eq("writeback" => "skipped_backward")
            end

            it "enqueues anyway once confirm_backward is set" do
              expect {
                put read_book_position_path(book),
                  params: { percent: 10, context: { exact: "anchor text" }, confirm_backward: true }
              }.to have_enqueued_job(KindleWritebackJob).with(book.id, user.id)

              expect(JSON.parse(response.body)).to eq("writeback" => "enqueued")
            end

            it "still enqueues when the drop is within the small-slack tolerance" do
              expect {
                put read_book_position_path(book), params: { percent: 59.6, context: { exact: "anchor text" } }
              }.to have_enqueued_job(KindleWritebackJob)

              expect(JSON.parse(response.body)).to eq("writeback" => "enqueued")
            end
          end
        end
      end
    end
  end

  describe "GET /books/:id/read/state" do
    before { sign_in(user) }

    it "returns nulls when there is no saved position and no physical device" do
      get read_book_state_path(book)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to eq("web" => nil, "kindle" => nil, "writeback_enabled" => false)
    end

    it "returns the saved web position, and a nil kindle state when nothing has synced from hardware" do
      create(:reader_position, book: book, user: user, cfi: "epubcfi(/6/2!/4)", fraction: 0.3, percent: 30.0)

      get read_book_state_path(book)

      body = JSON.parse(response.body)
      expect(body["kindle"]).to be_nil
      expect(body["web"]).to include("cfi" => "epubcfi(/6/2!/4)", "fraction" => 0.3, "percent" => 30.0)
      expect(body["web"]).to have_key("updated_at")
    end

    it "reports writeback_enabled once a physical device opts in" do
      create(:device, kind: "kindle", reader_writeback: true)

      get read_book_state_path(book)

      expect(JSON.parse(response.body)["writeback_enabled"]).to be true
    end

    context "with a physical device's synced reading state" do
      let!(:kindle) { create(:device, kind: "kindle", name: "Paperwhite") }
      let(:mbs) { File.binread(Rails.root.join("spec/fixtures/sidecars/krds.mbs")) }

      # Real KRDS fixture (see spec/services/reader/kindle_writeback_spec.rb)
      # carries fpr/lpr position 31740 — tar.gz's it into a real bundle at
      # kindle's reading_state path, exactly like device sync would.
      def sync_bundle(content_mtime:)
        tar_io = StringIO.new
        Gem::Package::TarWriter.new(tar_io) do |tar|
          tar.add_file_simple("Book.sdr/Book.mbs", 0o644, mbs.bytesize) { |io| io.write(mbs) }
        end
        gz_io = StringIO.new
        gz = Zlib::GzipWriter.new(gz_io)
        gz.write(tar_io.string)
        gz.close
        bytes = gz_io.string

        path = Library.reading_state_path(book, kindle)
        FileUtils.mkdir_p(path.dirname)
        File.binwrite(path, bytes)

        create(:reading_state, book: book, device: kindle,
          path: path.relative_path_from(Library.reading_states_root).to_s,
          content_mtime: content_mtime, size: bytes.bytesize, sha256: Digest::SHA256.hexdigest(bytes))
      end

      it "resolves a text snippet from the book's azw3 file at the synced position" do
        marker = "This is the current Kindle reading position marker."
        # A space (not another run of "p"/"s") on both sides of the marker
        # so word-boundary trimming in Reader::Anchor::EXACT_LENGTH's
        # window doesn't fold it into one giant unbroken "word".
        text = ("p" * 31_740) + marker + " " + ("s" * 2_000)
        azw3 = create(:book_file, book: book, format: "azw3", path: "#{SecureRandom.hex(4)}/state.azw3")
        MobiFixture.write_with_text(azw3.absolute_path, compression: Library::Mobi::COMPRESSION_NONE,
          text_length: text.b.bytesize, text_records: [ text.b ])
        # Content-address the cache key on the real bytes just written —
        # the factory's default sha256 is an arbitrary sequence value that
        # could collide with another spec's cached Reader::Anchor entry.
        azw3.update!(sha256: Library.sha256(azw3.absolute_path), size: File.size(azw3.absolute_path))

        state = sync_bundle(content_mtime: 2.hours.ago)
        ParseSidecarJob.perform_now(state.id)

        get read_book_state_path(book)

        body = JSON.parse(response.body)
        expect(body["kindle"]).to include("device_name" => "Paperwhite", "position" => 31_740)
        expect(body["kindle"]["snippet"]["exact"]).to start_with(marker)
      end

      it "returns a nil snippet for an epub-only book (no anchorable source)" do
        create(:book_file, :epub_fixture, book: book)
        state = sync_bundle(content_mtime: 2.hours.ago)
        ParseSidecarJob.perform_now(state.id)

        get read_book_state_path(book)

        body = JSON.parse(response.body)
        expect(body["kindle"]).to include("position" => 31_740)
        expect(body["kindle"]["snippet"]).to be_nil
      end
    end
  end
end
