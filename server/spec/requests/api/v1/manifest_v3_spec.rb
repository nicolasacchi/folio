require 'rails_helper'

RSpec.describe "API v1 manifest (v3 fields)", type: :request do
  let!(:device) { create(:device) }
  let(:headers) { { "X-Api-Token" => device.token } }
  let!(:book) { create(:book, title: "Ready") }
  let!(:azw3) { create(:book_file, :on_disk, book: book, format: "azw3") }
  let!(:delivery) { create(:delivery, book: book, device: device) }

  def manifest
    get "/api/v1/manifest", headers: headers
    response.parsed_body
  end

  it "announces version 3 with status and clippings urls" do
    body = manifest
    expect(body["version"]).to eq(3)
    expect(body["status_url"]).to eq("/api/v1/device/status")
    expect(body["clippings_url"]).to eq("/api/v1/clippings")
    expect(body["removals"]).to eq([])
  end

  describe "thumbnails" do
    before do
      FileUtils.mkdir_p(Library.covers_root)
      File.binwrite(Library.cover_path(book), "\xFF\xD8fakejpeg")
    end

    it "includes the EXTH-derived thumbnail for EBOK files with a cover" do
      MobiFixture.write(azw3.absolute_path, exth: { 113 => "0a37-uuid", 501 => "EBOK" })

      item = manifest["items"].first
      expect(item["thumbnail"]).to eq(
        "url" => "/api/v1/books/#{book.public_id}/thumbnail",
        "filename" => "thumbnail_0a37-uuid_EBOK_portrait.jpg"
      )
    end

    it "omits the thumbnail for PDOC files (firmware generates those)" do
      MobiFixture.write(azw3.absolute_path, exth: { 113 => "0a37-uuid", 501 => "PDOC" })

      expect(manifest["items"].first["thumbnail"]).to be_nil
    end

    it "omits the thumbnail without a cover" do
      FileUtils.rm_f(Library.cover_path(book))
      MobiFixture.write(azw3.absolute_path, exth: { 113 => "0a37-uuid", 501 => "EBOK" })

      expect(manifest["items"].first["thumbnail"]).to be_nil
    end

    it "omits the thumbnail when the file has no ASIN" do
      MobiFixture.write(azw3.absolute_path, exth: { 501 => "EBOK" })

      expect(manifest["items"].first["thumbnail"]).to be_nil
    end
  end

  describe "removals" do
    before { delivery.update!(delivered_at: 1.day.ago) }

    it "lists evict-requested deliveries and drops them from items" do
      delivery.request_eviction!("finished")

      body = manifest
      expect(body["items"]).to eq([])
      removal = body["removals"].sole
      expect(removal).to include(
        "id" => book.public_id,
        "delivery_id" => delivery.id,
        "filename" => azw3.delivery_filename,
        "reason" => "finished",
        "ack_url" => "/api/v1/removals/#{delivery.id}/ack"
      )
    end

    it "omits already-removed deliveries entirely" do
      delivery.request_eviction!("finished")
      delivery.mark_removed!

      body = manifest
      expect(body["items"]).to eq([])
      expect(body["removals"]).to eq([])
    end
  end
end
