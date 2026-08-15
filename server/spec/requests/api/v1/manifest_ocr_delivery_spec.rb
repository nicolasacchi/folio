require "rails_helper"

RSpec.describe "API v1 device delivery of an OCR'd scanned pdf", type: :request do
  let!(:device) { create(:device) }
  let(:headers) { { "X-Api-Token" => device.raw_token } }
  let!(:book) { create(:book, title: "Scanned") }
  let!(:pdf) do
    create(:book_file, book: book, format: "pdf").tap do |file|
      FileUtils.mkdir_p(file.absolute_path.dirname)
      File.write(file.absolute_path, "raw scanned pdf bytes")
      file.update!(size: File.size(file.absolute_path), sha256: Library.sha256(file.absolute_path))
    end
  end
  let!(:delivery) { create(:delivery, book: book, device: device) }

  # Mirrors what OcrBookJob actually writes (ocr_path/ocr_sha256/ocr_size/
  # ocr_source_sha256 together) rather than the partial updates other specs
  # use to exercise #ocr_fresh? alone.
  let(:ocr_bytes) { "ocr'd pdf bytes with a text layer" }
  let(:ocr_relative_path) { "ocr/#{pdf.id}.ocr.pdf" }

  before do
    ocr_absolute_path = Library.base_root.join(ocr_relative_path)
    FileUtils.mkdir_p(ocr_absolute_path.dirname)
    File.write(ocr_absolute_path, ocr_bytes)
    pdf.update!(
      ocr_path: ocr_relative_path,
      ocr_sha256: Digest::SHA256.hexdigest(ocr_bytes),
      ocr_size: ocr_bytes.bytesize,
      ocr_source_sha256: pdf.sha256
    )
  end

  it "reports the OCR companion's sha256/size/format in the manifest, matching what BookFilesController#show streams" do
    get "/api/v1/manifest", headers: headers

    item = response.parsed_body.fetch("items").first
    expect(item).to include(
      "id" => book.public_id,
      "format" => "pdf", # the OCR companion is still a pdf, unlike a prepared conversion
      "filename" => pdf.delivery_filename,
      "sha256" => Digest::SHA256.hexdigest(ocr_bytes),
      "size" => ocr_bytes.bytesize
    )

    get "/api/v1/books/#{book.public_id}/file", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(ocr_bytes.b)
    expect(response.headers["Content-Disposition"]).to include(pdf.delivery_filename)
  end

  context "when this device's delivery requests the raw variant (Delivery#raw)" do
    before { delivery.update!(raw: true) }

    it "reports the raw file's sha256/size in the manifest and streams its bytes, even though the OCR companion is fresh" do
      get "/api/v1/manifest", headers: headers

      item = response.parsed_body.fetch("items").first
      expect(item).to include(
        "sha256" => pdf.sha256,
        "size" => pdf.size
      )

      get "/api/v1/books/#{book.public_id}/file", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq("raw scanned pdf bytes".b)
      expect(response.headers["Content-Disposition"]).to include(pdf.delivery_filename)
    end
  end

  context "when the OCR companion goes stale (ocr_source_sha256 no longer matches sha256)" do
    before { pdf.update!(ocr_source_sha256: "no-longer-matches") }

    it "falls back to the raw file's sha256/size/bytes in both the manifest and BookFilesController#show" do
      get "/api/v1/manifest", headers: headers

      item = response.parsed_body.fetch("items").first
      expect(item).to include(
        "sha256" => pdf.sha256,
        "size" => pdf.size
      )

      get "/api/v1/books/#{book.public_id}/file", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.body.b).to eq("raw scanned pdf bytes".b)
      expect(response.headers["Content-Disposition"]).to include(pdf.delivery_filename)
    end
  end
end
