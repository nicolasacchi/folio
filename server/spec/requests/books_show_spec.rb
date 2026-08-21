require "rails_helper"

RSpec.describe "Book detail page", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  describe "conversion error disclosure" do
    let!(:book) { create(:book) }
    let!(:source) { create(:book_file, book: book, format: "epub") }

    it "renders the full stored error for a failed conversion inside an expandable disclosure" do
      long_error = "calibre error: #{"x" * 200} END-OF-ERROR-MARKER"
      conversion = create(:conversion, book: book, book_file: source, target_format: "azw3", status: "pending")
      conversion.mark_failed!(long_error)

      get book_path(book)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("<details")
      expect(response.body).to include("conversion-error")
      # The row above only shows a 160-char truncated fragment — the
      # disclosure must carry the whole thing, including the tail.
      expect(response.body).to include("END-OF-ERROR-MARKER")
      expect(response.body).to include(conversion.error)
    end

    it "does not render a disclosure for a conversion that has not failed" do
      create(:conversion, book: book, book_file: source, target_format: "azw3", status: "completed")

      get book_path(book)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("conversion-error")
    end

    it "does not render a disclosure when there are no conversions" do
      get book_path(book)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("conversion-error")
    end
  end

  describe "action deck" do
    let!(:book) { create(:book) }
    let!(:epub_file) { create(:book_file, :epub_fixture, book: book) }

    it "renders Read in browser first, ahead of the per-device buttons" do
      device = create(:device, name: "My Kindle")

      get book_path(book)

      expect(response.body).to include('<div class="action-deck">')
      read_index = response.body.index("Read in browser")
      send_index = response.body.index("Send to #{device.name}")
      expect(read_index).to be_present
      expect(send_index).to be_present
      expect(read_index).to be < send_index
    end
  end

  describe "OCR text layer button" do
    # A pdf-only book (no epub let!() here, unlike "action deck" above) —
    # otherwise Book#readable_file would already prefer the epub and every
    # "shows" case below would accidentally be exercising the mixed-format
    # scenario instead.
    let!(:book) { create(:book) }
    let!(:pdf_file) { create(:book_file, book: book, format: "pdf") }

    # Asserts on the button's own form action (book_conversions_path with
    # kind=ocr) rather than the "OCR text layer" label text — the Files
    # section's "text layer" stamp (rendered once ocr_fresh?) carries a
    # title attribute ("OCR text layer present…") that contains the same
    # substring and would make a text-only assertion a false positive.
    it "shows for a scanned pdf with no fresh OCR companion" do
      get book_path(book)

      expect(response.body).to include(book_conversions_path(book, kind: "ocr"))
    end

    it "hides once BookFile#ocr_fresh? is true" do
      ocr_path = "ocr/#{pdf_file.id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
      pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_file.sha256)

      get book_path(book)

      expect(response.body).not_to include(book_conversions_path(book, kind: "ocr"))
    end

    # Book#readable_file (and IndexBookJob::TEXT_SOURCE_PREFERENCE) prefer
    # epub over pdf — on a mixed-format book, an OCR'd pdf companion would
    # be used by neither reading nor search, so the button shouldn't
    # promise it even though the pdf itself has no fresh companion yet.
    it "hides for a mixed-format book where a richer format is already preferred for reading" do
      create(:book_file, :epub_fixture, book: book)

      get book_path(book)

      expect(response.body).not_to include(book_conversions_path(book, kind: "ocr"))
    end
  end

  describe "Files section download links" do
    let!(:book) { create(:book) }
    let!(:pdf_file) { create(:book_file, book: book, format: "pdf") }

    it "offers only the plain download link with no fresh OCR companion" do
      get book_path(book)

      expect(response.body).to include(download_book_path(book, fmt: "pdf"))
      expect(response.body).not_to include(CGI.escapeHTML(download_book_path(book, fmt: "pdf", raw: 1)))
    end

    it "adds a secondary original-file link once BookFile#ocr_fresh? is true" do
      ocr_path = "ocr/#{pdf_file.id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
      pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_file.sha256)

      get book_path(book)

      expect(response.body).to include(download_book_path(book, fmt: "pdf"))
      expect(response.body).to include(CGI.escapeHTML(download_book_path(book, fmt: "pdf", raw: 1)))
      expect(response.body).to include(">original<")
    end
  end

  describe "delivery variant links" do
    let!(:book) { create(:book) }
    let!(:pdf_file) { create(:book_file, book: book, format: "pdf") }

    def make_ocr_fresh!
      ocr_path = "ocr/#{pdf_file.id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
      pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_file.sha256)
    end

    def make_text_fresh!
      text_relative = "text/#{book.public_id}.txt"
      FileUtils.mkdir_p(Library.base_root.join(text_relative).dirname)
      File.write(Library.base_root.join(text_relative), "plain text companion")
      pdf_file.update!(text_path: text_relative, text_source_sha256: pdf_file.sha256)
    end

    describe "the reader's 'Original scan' button" do
      it "is hidden with no fresh OCR companion" do
        get book_path(book)

        expect(response.body).not_to include(CGI.escapeHTML(read_book_path(book, raw: 1)))
      end

      it "appears as a visible secondary button (not a muted link) once BookFile#ocr_fresh? is true" do
        make_ocr_fresh!

        get book_path(book)

        doc = Nokogiri::HTML5.parse(response.body)
        link = doc.at_css(%(a[href="#{read_book_path(book, raw: 1)}"]))
        expect(link).to be_present
        expect(link["class"]).to eq("btn")
        expect(link.text).to include("Original scan")
        expect(link["title"]).to eq("Open the scanned original, without the OCR text layer")
      end
    end

    describe "the reader's 'Text only' / 'Build text version' read-row controls" do
      it "is absent for a book with no pdf at all" do
        other = create(:book)
        create(:book_file, book: other, format: "epub")

        get book_path(other)

        expect(response.body).not_to include("Build text version")
        expect(response.body).not_to include(">Text only<")
      end

      it "is absent for a mixed-format book where a richer format is already preferred for reading" do
        create(:book_file, :epub_fixture, book: book)

        get book_path(book)

        expect(response.body).not_to include("Build text version")
      end

      it "shows 'Build text version' when the companion doesn't exist yet and nothing is building" do
        get book_path(book)

        expect(response.body).to include("Build text version")
        expect(response.body).to include(build_text_book_path(book))
      end

      it "shows a pending stamp instead of the build button while a text conversion is active" do
        create(:conversion, :text, book: book, book_file: pdf_file, status: "running")

        get book_path(book)

        expect(response.body).to include("building text version…")
        expect(response.body).not_to include("Build text version")
      end

      it "shows 'Build text version' again once a previous attempt failed (no longer active)" do
        create(:conversion, :text, book: book, book_file: pdf_file, status: "failed")

        get book_path(book)

        expect(response.body).to include("Build text version")
      end

      it "shows the 'Text only' reading button once the companion is fresh" do
        make_text_fresh!

        get book_path(book)

        doc = Nokogiri::HTML5.parse(response.body)
        link = doc.at_css(%(a[href="#{read_book_path(book, text: 1)}"]))
        expect(link).to be_present
        expect(link.text).to include("Text only")
        expect(response.body).not_to include("Build text version")
      end
    end

    describe "the 'Deep re-OCR text' rebuild button" do
      it "is absent before any text companion exists (first build is always the fast path)" do
        get book_path(book)

        expect(response.body).not_to include("Deep re-OCR text")
      end

      it "is absent while a text build is still active" do
        create(:conversion, :text, book: book, book_file: pdf_file, status: "running")

        get book_path(book)

        expect(response.body).not_to include("Deep re-OCR text")
      end

      it "appears once the text companion is fresh, posting build_text with engine=deep and a turbo_confirm" do
        make_text_fresh!

        get book_path(book)

        doc = Nokogiri::HTML5.parse(response.body)
        form = doc.at_css(%(form[action="#{build_text_book_path(book, engine: "deep")}"]))
        expect(form).to be_present
        expect(form.text).to include("Deep re-OCR text")
        expect(form["data-turbo-confirm"]).to match(/original scan/i)
      end
    end

    describe "the 'deep OCR' badge on the Text only button" do
      # Scoped to span.stamp text (not a plain response.body substring
      # check) — the always-present "Deep re-OCR text" rebuild button's own
      # turbo_confirm text also says "deep OCR", which would otherwise
      # false-positive this on every fresh companion regardless of engine.
      it "is absent for a fresh companion built with the default 'layer' engine" do
        make_text_fresh!

        get book_path(book)

        doc = Nokogiri::HTML5.parse(response.body)
        expect(doc.css("span.stamp").map(&:text)).not_to include("deep OCR")
      end

      it "appears once the fresh companion was itself built via engine: 'deep'" do
        make_text_fresh!
        pdf_file.update!(text_engine: "deep")

        get book_path(book)

        doc = Nokogiri::HTML5.parse(response.body)
        expect(doc.css("span.stamp").map(&:text)).to include("deep OCR")
      end
    end

    describe "Files section text-only download link" do
      it "is absent with no fresh text companion" do
        get book_path(book)

        expect(response.body).not_to include(CGI.escapeHTML(download_book_path(book, fmt: "pdf", text: 1)))
      end

      it "adds a 'text only' download link and stamp once BookFile#text_fresh? is true" do
        make_text_fresh!

        get book_path(book)

        expect(response.body).to include(CGI.escapeHTML(download_book_path(book, fmt: "pdf", text: 1)))
        expect(response.body).to include(">text only<")
      end

      it "labels the stamp 'text only (deep OCR)' when the fresh companion was built via engine: 'deep'" do
        make_text_fresh!
        pdf_file.update!(text_engine: "deep")

        get book_path(book)

        expect(response.body).to include(">text only (deep OCR)<")
      end
    end

    describe "the per-device Kindle send original-scan link" do
      let!(:device) { create(:device, name: "My Kindle") }

      def original_link_href
        CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, variant: "original"))
      end

      it "is hidden with no fresh OCR companion" do
        get book_path(book)

        expect(response.body).not_to include(original_link_href)
      end

      it "appears next to an unqueued device's Send pill once BookFile#ocr_fresh? is true" do
        make_ocr_fresh!

        get book_path(book)

        expect(response.body).to include(original_link_href)
      end

      it "appears next to an already-delivered device's pill (switching post-delivery needs no extra plumbing)" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current)

        get book_path(book)

        expect(response.body).to include("On #{device.name}")
        expect(response.body).to include(original_link_href)
      end

      it "appears next to a still-queued (not yet delivered) device's pill" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device)

        get book_path(book)

        expect(response.body).to include("Queued #{device.name}")
        expect(response.body).to include(original_link_href)
      end

      it "is hidden once that device's delivery is already 'original' (nothing left to switch to)" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "original")

        get book_path(book)

        expect(response.body).to include("On #{device.name}")
        expect(response.body).not_to include(original_link_href)
      end

      it "is hidden while an eviction is queued (the Keep action already covers that state)" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current).request_eviction!("test")

        get book_path(book)

        expect(response.body).to include("Keep on #{device.name}")
        expect(response.body).not_to include(original_link_href)
      end
    end

    describe "the per-device Kindle send 'text layer' switch-back link (mirrors the original link once a delivery is 'original')" do
      let!(:device) { create(:device, name: "My Kindle") }

      def auto_link_href
        CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, variant: "auto"))
      end

      it "appears next to an already-delivered device's 'original' pill" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "original")

        get book_path(book)

        expect(response.body).to include("On #{device.name}")
        expect(response.body).to include(auto_link_href)
        # ">text layer<" alone would also match the unrelated Files-section
        # stamp (rendered by the same make_ocr_fresh! setup) — the title is
        # what's actually unique to this switch-back button.
        expect(response.body).to include("Re-send #{device.name}&#39;s copy with the OCR text layer")
      end

      it "appears next to a still-queued device's 'original' pill" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, variant: "original")

        get book_path(book)

        expect(response.body).to include("Queued #{device.name}")
        expect(response.body).to include(auto_link_href)
      end

      it "is absent (in favor of the 'original' link) once that delivery is 'auto'" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "auto")

        get book_path(book)

        expect(response.body).not_to include(auto_link_href)
      end
    end

    describe "the per-device Kindle send text-only link" do
      let!(:device) { create(:device, name: "My Kindle") }

      def text_link_href
        CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, variant: "text"))
      end

      it "is hidden when the kindle_file isn't a pdf" do
        create(:book_file, book: book, format: "azw3")

        get book_path(book)

        expect(response.body).not_to include(text_link_href)
      end

      it "appears next to an unqueued device's Send pill (the AZW3 doesn't have to exist yet)" do
        get book_path(book)

        expect(response.body).to include(text_link_href)
      end

      it "appears next to an already-delivered device's pill" do
        create(:delivery, book: book, device: device, delivered_at: Time.current)

        get book_path(book)

        expect(response.body).to include("On #{device.name}")
        expect(response.body).to include(text_link_href)
      end

      it "is hidden once that device's delivery is already 'text' (nothing left to switch to)" do
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "text")

        get book_path(book)

        expect(response.body).to include("On #{device.name}")
        expect(response.body).not_to include(text_link_href)
      end

      it "switches back to 'auto' with a plain label when there is no OCR companion to name it after" do
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "text")

        get book_path(book)

        expect(response.body).to include(CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, variant: "auto")))
        expect(response.body).to include(">switch to original file<")
      end
    end

    describe "the per-device current-variant stamp" do
      let!(:device) { create(:device, name: "My Kindle") }

      # Scopes to the specific device's own action-row rather than the
      # whole page — the Files section renders its own "text layer"/"text
      # only" stamps regardless of delivery state, so an unscoped text
      # search would false-positive.
      def device_row(doc)
        doc.css(".action-row").find { |row| row.text.include?(device.name) }
      end

      it "shows 'text layer' next to an already-delivered 'auto' delivery" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "auto")

        get book_path(book)

        expect(device_row(Nokogiri::HTML5.parse(response.body)).css("span.stamp").map(&:text)).to include("text layer")
      end

      it "shows 'original scan' next to an already-delivered 'original' delivery" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "original")

        get book_path(book)

        expect(device_row(Nokogiri::HTML5.parse(response.body)).css("span.stamp").map(&:text)).to include("original scan")
      end

      it "shows 'text only' next to a 'text' delivery, instead of the OCR stamp" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "text")

        get book_path(book)

        stamps = device_row(Nokogiri::HTML5.parse(response.body)).css("span.stamp").map(&:text)
        expect(stamps).to include("text only")
        expect(stamps).not_to include("text layer", "original scan")
      end

      it "shows the stamp next to a still-queued (not yet delivered) delivery too" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, variant: "original")

        get book_path(book)

        expect(device_row(Nokogiri::HTML5.parse(response.body)).css("span.stamp").map(&:text)).to include("original scan")
      end

      it "is absent while an eviction is queued (that state has no switch link either)" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current).request_eviction!("test")

        get book_path(book)

        expect(device_row(Nokogiri::HTML5.parse(response.body)).css("span.stamp")).to be_empty
      end

      it "is absent before anything is queued (first send)" do
        make_ocr_fresh!

        get book_path(book)

        expect(device_row(Nokogiri::HTML5.parse(response.body)).css("span.stamp")).to be_empty
      end

      it "is absent for a plain 'auto' delivery when the kindle file has no fresh OCR companion" do
        create(:delivery, book: book, device: device, delivered_at: Time.current)

        get book_path(book)

        expect(device_row(Nokogiri::HTML5.parse(response.body)).css("span.stamp")).to be_empty
      end
    end

    describe "device row switch-link labels" do
      let!(:device) { create(:device, name: "My Kindle") }

      def button_text_for(doc, variant:)
        form = doc.at_css(%(form[action="#{deliveries_path(book_id: book.id, device_id: device.id, variant: variant)}"]))
        form&.at_css("button")&.text&.strip
      end

      it "labels the first-send original-scan option 'send original scan'" do
        make_ocr_fresh!

        get book_path(book)

        expect(button_text_for(Nokogiri::HTML5.parse(response.body), variant: "original")).to eq("send original scan")
      end

      it "labels the switch link 'switch to original scan' on an 'auto', already-queued/delivered device" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "auto")

        get book_path(book)

        expect(button_text_for(Nokogiri::HTML5.parse(response.body), variant: "original")).to eq("switch to original scan")
      end

      it "labels the switch link 'switch to text layer' on an 'original', already-queued/delivered device" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "original")

        get book_path(book)

        expect(button_text_for(Nokogiri::HTML5.parse(response.body), variant: "auto")).to eq("switch to text layer")
      end

      it "labels the first-send text-only option 'send text only'" do
        get book_path(book)

        expect(button_text_for(Nokogiri::HTML5.parse(response.body), variant: "text")).to eq("send text only")
      end

      it "labels the switch link 'switch to text only' on a non-'text', already-queued/delivered device" do
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "auto")

        get book_path(book)

        expect(button_text_for(Nokogiri::HTML5.parse(response.body), variant: "text")).to eq("switch to text only")
      end

      # The partial promises "switch links to every OTHER variant" — on a
      # 'text' delivery with fresh OCR that's both "auto" (text layer) AND
      # "original", not just "auto" via an extra hop.
      it "offers a direct switch-to-original-scan link (not just auto) on a 'text' delivery with fresh OCR" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "text")

        get book_path(book)

        doc = Nokogiri::HTML5.parse(response.body)
        expect(button_text_for(doc, variant: "auto")).to eq("switch to text layer")
        expect(button_text_for(doc, variant: "original")).to eq("switch to original scan")
      end

      it "has no direct switch-to-original-scan link on a 'text' delivery without fresh OCR (nothing to switch to)" do
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "text")

        get book_path(book)

        expect(button_text_for(Nokogiri::HTML5.parse(response.body), variant: "original")).to be_nil
      end
    end
  end

  describe "Convert to buttons" do
    let!(:book) { create(:book) }
    let!(:pdf_file) { create(:book_file, book: book, format: "pdf") }

    # txt stays in Conversion::TARGET_FORMATS (existing conversion rows keep
    # validating) but is no longer offered as a "Convert to" button — see
    # Conversion::OFFERED_TARGET_FORMATS. ebook-convert can't reliably
    # reflow a scanned/OCR'd pdf to txt (see ConvertBookJob::MIN_OUTPUT_SIZE
    # and the book 39589 / Conversion #7941 incident); Library::TextCompanion
    # (BooksController#build_text, the "Build text version" button) is the
    # supported replacement.
    it "does not offer a TXT conversion button for a pdf-only book" do
      get book_path(book)

      expect(response.body).to include(book_conversions_path(book, target_format: "epub"))
      expect(response.body).not_to include(book_conversions_path(book, target_format: "txt"))
    end
  end

  describe "full-text index button" do
    let!(:book) { create(:book) }

    it "shows the opt-in button when fulltext is not enabled" do
      get book_path(book)

      expect(response.body).to include("Index full text")
      expect(response.body).to include(reindex_book_path(book))
      expect(response.body).not_to include("in search index")
      expect(response.body).not_to include("indexing pending")
    end

    it "shows an in-index stamp and a remove button once fulltext is enabled and indexed" do
      book.update!(fulltext_enabled: true, has_fulltext: true)

      get book_path(book)

      expect(response.body).to include("in search index")
      expect(response.body).to include("Remove from index")
      expect(response.body).to include(unindex_book_path(book))
      expect(response.body).not_to include("Index full text")
    end

    it "shows a pending stamp with re-run and remove buttons once enabled but not yet indexed" do
      book.update!(fulltext_enabled: true, has_fulltext: false)

      get book_path(book)

      expect(response.body).to include("indexing pending")
      expect(response.body).to include("Re-run")
      expect(response.body).to include("Remove from index")
      expect(response.body).to include(reindex_book_path(book))
      expect(response.body).to include(unindex_book_path(book))
    end

    # After "Remove from index" flips fulltext_enabled off, has_fulltext
    # stays true until the queued IndexBookJob clears the row — without this
    # state the opt-in button would render, implying the book is out of the
    # index while its text is actually still stored and searchable.
    it "shows a removal-pending stamp with a re-opt-in button once disabled but still indexed" do
      book.update!(fulltext_enabled: false, has_fulltext: true)

      get book_path(book)

      expect(response.body).to include("removal pending")
      expect(response.body).to include("Keep in index")
      expect(response.body).to include(reindex_book_path(book))
      expect(response.body).not_to include("Index full text")
      expect(response.body).not_to include("in search index")
      expect(response.body).not_to include("indexing pending")
    end
  end

  describe "annotation location labels" do
    it "explains the Kindle-location abbreviation" do
      book = create(:book)
      create(:annotation, book: book, device: create(:device), location_start: 100, location_end: 120)

      get book_path(book)

      expect(response.body).to include(%(<abbr title="Kindle location, not a page number">loc.</abbr>))
    end
  end
end
