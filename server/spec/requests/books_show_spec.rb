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

  describe "annotation location labels" do
    it "explains the Kindle-location abbreviation" do
      book = create(:book)
      create(:annotation, book: book, device: create(:device), location_start: 100, location_end: 120)

      get book_path(book)

      expect(response.body).to include(%(<abbr title="Kindle location, not a page number">loc.</abbr>))
    end
  end
end
