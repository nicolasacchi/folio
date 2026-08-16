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

  describe "original (raw) variant links" do
    let!(:book) { create(:book) }
    let!(:pdf_file) { create(:book_file, book: book, format: "pdf") }

    def make_ocr_fresh!
      ocr_path = "ocr/#{pdf_file.id}.ocr.pdf"
      FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
      File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
      pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_file.sha256)
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

    describe "the per-device Kindle send original link" do
      let!(:device) { create(:device, name: "My Kindle") }

      it "is hidden with no fresh OCR companion" do
        get book_path(book)

        expect(response.body).not_to include(CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, raw: 1)))
      end

      it "appears next to an unqueued device's Send pill once BookFile#ocr_fresh? is true" do
        make_ocr_fresh!

        get book_path(book)

        expect(response.body).to include(CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, raw: 1)))
      end

      it "appears next to an already-delivered device's pill (switching post-delivery needs no extra plumbing)" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current)

        get book_path(book)

        expect(response.body).to include("On #{device.name}")
        expect(response.body).to include(CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, raw: 1)))
      end

      it "appears next to a still-queued (not yet delivered) device's pill" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device)

        get book_path(book)

        expect(response.body).to include("Queued #{device.name}")
        expect(response.body).to include(CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, raw: 1)))
      end

      it "is hidden once that device's delivery is already raw (nothing left to switch to)" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, raw: true)

        get book_path(book)

        expect(response.body).to include("On #{device.name}")
        expect(response.body).not_to include(CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, raw: 1)))
      end

      it "is hidden while an eviction is queued (the Keep action already covers that state)" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current).request_eviction!("test")

        get book_path(book)

        expect(response.body).to include("Keep on #{device.name}")
        expect(response.body).not_to include(CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, raw: 1)))
      end
    end

    describe "the per-device Kindle send 'text layer' switch-back link (mirrors the original link once a delivery is raw)" do
      let!(:device) { create(:device, name: "My Kindle") }

      it "appears next to an already-delivered device's raw pill" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, raw: true)

        get book_path(book)

        expect(response.body).to include("On #{device.name}")
        expect(response.body).to include(CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, raw: 0)))
        # ">text layer<" alone would also match the unrelated Files-section
        # stamp (rendered by the same make_ocr_fresh! setup) — the title is
        # what's actually unique to this switch-back button.
        expect(response.body).to include("Re-send #{device.name}&#39;s copy with the OCR text layer")
      end

      it "appears next to a still-queued device's raw pill" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, raw: true)

        get book_path(book)

        expect(response.body).to include("Queued #{device.name}")
        expect(response.body).to include(CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, raw: 0)))
        expect(response.body).to include("Switch #{device.name}&#39;s queued send back to the OCR text layer")
      end

      it "is absent (in favor of the 'original' link) once that delivery is not raw" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, raw: false)

        get book_path(book)

        expect(response.body).not_to include(CGI.escapeHTML(deliveries_path(book_id: book.id, device_id: device.id, raw: 0)))
      end
    end

    describe "the per-device current-variant stamp" do
      let!(:device) { create(:device, name: "My Kindle") }

      # Scopes to the specific device's own action-row rather than the
      # whole page — the Files section renders its own "text layer" stamp
      # (from the same make_ocr_fresh! pdf_file) regardless of delivery
      # state, so an unscoped text search would false-positive.
      def device_row(doc)
        doc.css(".action-row").find { |row| row.text.include?(device.name) }
      end

      it "shows 'text layer' next to an already-delivered non-raw delivery" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, raw: false)

        get book_path(book)

        expect(device_row(Nokogiri::HTML5.parse(response.body)).css("span.stamp").map(&:text)).to include("text layer")
      end

      it "shows 'original scan' next to an already-delivered raw delivery" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, raw: true)

        get book_path(book)

        expect(device_row(Nokogiri::HTML5.parse(response.body)).css("span.stamp").map(&:text)).to include("original scan")
      end

      it "shows the stamp next to a still-queued (not yet delivered) delivery too" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, raw: true)

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

      it "is absent when the kindle file has no fresh OCR companion" do
        create(:delivery, book: book, device: device, delivered_at: Time.current)

        get book_path(book)

        expect(device_row(Nokogiri::HTML5.parse(response.body)).css("span.stamp")).to be_empty
      end
    end

    describe "device row switch-link labels" do
      let!(:device) { create(:device, name: "My Kindle") }

      def button_text_for(doc, raw:)
        form = doc.at_css(%(form[action="#{deliveries_path(book_id: book.id, device_id: device.id, raw: raw)}"]))
        form&.at_css("button")&.text&.strip
      end

      it "labels the first-send raw option 'send original scan'" do
        make_ocr_fresh!

        get book_path(book)

        expect(button_text_for(Nokogiri::HTML5.parse(response.body), raw: 1)).to eq("send original scan")
      end

      it "labels the switch link 'switch to original scan' on a non-raw, already-queued/delivered device" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, raw: false)

        get book_path(book)

        expect(button_text_for(Nokogiri::HTML5.parse(response.body), raw: 1)).to eq("switch to original scan")
      end

      it "labels the switch link 'switch to text layer' on a raw, already-queued/delivered device" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, raw: true)

        get book_path(book)

        expect(button_text_for(Nokogiri::HTML5.parse(response.body), raw: 0)).to eq("switch to text layer")
      end
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
