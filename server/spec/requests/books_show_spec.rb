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

  describe "annotation location labels" do
    it "explains the Kindle-location abbreviation" do
      book = create(:book)
      create(:annotation, book: book, device: create(:device), location_start: 100, location_end: 120)

      get book_path(book)

      expect(response.body).to include(%(<abbr title="Kindle location, not a page number">loc.</abbr>))
    end
  end
end
