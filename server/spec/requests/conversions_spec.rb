require 'rails_helper'

RSpec.describe "Conversions", type: :request do
  let!(:user) { create(:user) }
  let!(:book) { create(:book) }

  before do
    post "/session", params: { email_address: user.email_address, password: "password" }
  end

  describe "POST /books/:book_id/conversions (kind defaults to calibre, existing behavior)" do
    let!(:source) { create(:book_file, book: book, format: "epub") }

    it "queues a Calibre conversion exactly as before" do
      expect {
        post "/books/#{book.id}/conversions", params: { target_format: "azw3" }
      }.to change(Conversion, :count).by(1)
        .and have_enqueued_job(ConvertBookJob)

      conversion = Conversion.last
      expect(conversion.kind).to eq("calibre")
      expect(conversion.target_format).to eq("azw3")
      expect(response).to redirect_to(book_path(book))
    end

    it "still falls back to calibre for an unrecognized kind value" do
      expect {
        post "/books/#{book.id}/conversions", params: { target_format: "azw3", kind: "bogus" }
      }.to change(Conversion, :count).by(1)
        .and have_enqueued_job(ConvertBookJob)

      expect(Conversion.last.kind).to eq("calibre")
    end

    it "rejects an unsupported target format" do
      expect {
        post "/books/#{book.id}/conversions", params: { target_format: "exe" }
      }.not_to change(Conversion, :count)

      expect(response).to redirect_to(book_path(book))
      follow_redirect!
      expect(response.body).to include("Unsupported target format")
    end

    # txt stays in Conversion::TARGET_FORMATS (existing rows/validations
    # still work) but is no longer an offered "Convert to" target — see
    # Conversion::OFFERED_TARGET_FORMATS. ebook-convert can't reliably
    # reflow a scanned/OCR'd pdf to txt (see ConvertBookJob::MIN_OUTPUT_SIZE
    # and the book 39589 / Conversion #7941 incident); the supported reflow
    # path is Library::TextCompanion (BooksController#build_text).
    it "rejects a user-submitted txt target the same way it rejects other un-offered targets" do
      expect {
        post "/books/#{book.id}/conversions", params: { target_format: "txt" }
      }.not_to change(Conversion, :count)

      expect(response).to redirect_to(book_path(book))
      follow_redirect!
      expect(response.body).to include("Unsupported target format")
    end
  end

  describe "POST /books/:book_id/conversions with kind=ocr" do
    it "queues an OCR conversion for a book with a scanned pdf" do
      pdf = create(:book_file, book: book, format: "pdf")

      expect {
        post "/books/#{book.id}/conversions", params: { kind: "ocr" }
      }.to change(Conversion, :count).by(1)
        .and have_enqueued_job(OcrBookJob)

      conversion = Conversion.last
      expect(conversion.kind).to eq("ocr")
      expect(conversion.target_format).to eq("pdf")
      expect(conversion.book_file).to eq(pdf)
      expect(response).to redirect_to(book_path(book))
    end

    it "does not enqueue ConvertBookJob for an ocr request" do
      create(:book_file, book: book, format: "pdf")

      expect {
        post "/books/#{book.id}/conversions", params: { kind: "ocr" }
      }.not_to have_enqueued_job(ConvertBookJob)
    end

    it "redirects with an alert when the book has no scanned pdf" do
      create(:book_file, book: book, format: "epub")

      expect {
        post "/books/#{book.id}/conversions", params: { kind: "ocr" }
      }.not_to change(Conversion, :count)

      expect(response).to redirect_to(book_path(book))
      follow_redirect!
      expect(response.body).to include("No scanned PDF to OCR")
    end

    it "redirects with an alert when the pdf file is unavailable" do
      create(:book_file, book: book, format: "pdf", available: false)

      expect {
        post "/books/#{book.id}/conversions", params: { kind: "ocr" }
      }.not_to change(Conversion, :count)

      expect(response).to redirect_to(book_path(book))
      follow_redirect!
      expect(response.body).to include("No scanned PDF to OCR")
    end

    it "no-ops instead of raising when an OCR conversion is already queued for the book" do
      pdf = create(:book_file, book: book, format: "pdf")
      create(:conversion, :ocr, book: book, book_file: pdf, status: "pending")

      expect {
        post "/books/#{book.id}/conversions", params: { kind: "ocr" }
      }.not_to change(Conversion, :count)

      expect(response).to redirect_to(book_path(book))
      follow_redirect!
      expect(response.body).to match(/already queued/i)
    end

    it "allows a fresh OCR request once the previous one is no longer active" do
      pdf = create(:book_file, book: book, format: "pdf")
      create(:conversion, :ocr, book: book, book_file: pdf, status: "completed")

      expect {
        post "/books/#{book.id}/conversions", params: { kind: "ocr" }
      }.to change(Conversion, :count).by(1)
    end
  end
end
