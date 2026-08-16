require 'rails_helper'

RSpec.describe "Deliveries", type: :request do
  let!(:user) { create(:user) }
  let!(:book) { create(:book) }
  let!(:device) { create(:device) }

  before do
    post "/session", params: { email_address: user.email_address, password: "password" }
  end

  describe "POST /deliveries" do
    it "queues the book for the device" do
      expect {
        post "/deliveries", params: { book_id: book.id, device_id: device.id }
      }.to change(Delivery, :count).by(1)

      expect(Delivery.last).to have_attributes(book: book, device: device, delivered_at: nil)
    end

    it "falls back to the user's preferred Kindle when device_id is blank" do
      user.update!(preferred_device: device)

      expect {
        post "/deliveries", params: { book_id: book.id }
      }.to change(Delivery, :count).by(1)

      expect(Delivery.last.device).to eq(device)
    end

    it "redirects with an alert when neither device_id nor preferred Kindle is set" do
      expect {
        post "/deliveries", params: { book_id: book.id }
      }.not_to change(Delivery, :count)

      expect(response).to redirect_to(book_path(book))
      follow_redirect!
      expect(response.body).to match(/No Kindle selected|preferred Kindle/i)
    end

    it "is idempotent for an already-queued book" do
      create(:delivery, book: book, device: device)

      expect {
        post "/deliveries", params: { book_id: book.id, device_id: device.id }
      }.not_to change(Delivery, :count)
    end

    it "queues a Kindle-format conversion when the book has none" do
      expect {
        post "/deliveries", params: { book_id: book.id, device_id: device.id }
      }.to have_enqueued_job(EnsureKindleFormatJob).with(book.id)
    end

    it "skips conversion when a Kindle-ready file exists" do
      create(:book_file, book: book, format: "azw3")

      expect {
        post "/deliveries", params: { book_id: book.id, device_id: device.id }
      }.not_to have_enqueued_job(EnsureKindleFormatJob)
    end

    describe "?raw=1 (the untouched-original variant)" do
      it "defaults a fresh delivery to raw: false" do
        post "/deliveries", params: { book_id: book.id, device_id: device.id }

        expect(Delivery.last.raw).to be(false)
      end

      it "persists raw: true on a fresh delivery" do
        post "/deliveries", params: { book_id: book.id, device_id: device.id, raw: 1 }

        expect(Delivery.last.raw).to be(true)
      end

      it "flips an existing delivery's raw on re-send, without creating a second row" do
        delivery = create(:delivery, book: book, device: device, raw: false)

        expect {
          post "/deliveries", params: { book_id: book.id, device_id: device.id, raw: 1 }
        }.not_to change(Delivery, :count)

        expect(delivery.reload.raw).to be(true)
      end

      it "leaves an already-raw delivery's raw untouched on a plain re-send (no raw param at all)" do
        delivery = create(:delivery, book: book, device: device, raw: true)

        post "/deliveries", params: { book_id: book.id, device_id: device.id }

        expect(delivery.reload.raw).to be(true)
      end

      it "flips an already-raw delivery back with an explicit raw=0" do
        delivery = create(:delivery, book: book, device: device, raw: true)

        post "/deliveries", params: { book_id: book.id, device_id: device.id, raw: 0 }

        expect(delivery.reload.raw).to be(false)
      end
    end

    describe "flash message naming the OCR/raw variant" do
      let!(:pdf_file) { create(:book_file, book: book, format: "pdf") }

      def make_ocr_fresh!
        ocr_path = "ocr/#{pdf_file.id}.ocr.pdf"
        FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
        File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
        pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_file.sha256)
      end

      it "names the text-layer variant when a fresh send defaults to it" do
        make_ocr_fresh!

        post "/deliveries", params: { book_id: book.id, device_id: device.id }
        follow_redirect!

        expect(response.body).to include("Queued for #{device.name} (text layer).")
      end

      it "names the original-scan variant when a fresh send asks for it" do
        make_ocr_fresh!

        post "/deliveries", params: { book_id: book.id, device_id: device.id, raw: 1 }
        follow_redirect!

        expect(response.body).to include("Queued for #{device.name} (original scan).")
      end

      it "says so explicitly when flipping an existing delivery to the original scan" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, raw: false)

        post "/deliveries", params: { book_id: book.id, device_id: device.id, raw: 1 }
        follow_redirect!

        expect(response.body).to include("Switched #{device.name} to the original scan — it will re-deliver.")
      end

      it "says so explicitly when flipping an existing delivery back to the text layer" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, raw: true)

        post "/deliveries", params: { book_id: book.id, device_id: device.id, raw: 0 }
        follow_redirect!

        expect(response.body).to include("Switched #{device.name} to the text layer — it will re-deliver.")
      end

      it "says 'Queued', not 'Switched', when re-sending a previously removed delivery with a different variant" do
        make_ocr_fresh!
        delivery = create(:delivery, book: book, device: device, delivered_at: Time.current, raw: false)
        delivery.mark_removed!

        post "/deliveries", params: { book_id: book.id, device_id: device.id, raw: 1 }
        follow_redirect!

        expect(response.body).to include("Queued for #{device.name} (original scan).")
        expect(response.body).not_to include("Switched")
      end

      it "keeps the plain 'Already queued' message when nothing about the variant changes" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, raw: false)

        post "/deliveries", params: { book_id: book.id, device_id: device.id }
        follow_redirect!

        expect(response.body).to include("Already queued for #{device.name}.")
        expect(response.body).not_to include("Switched")
      end

      it "keeps today's plain messages verbatim for a book with no OCR companion" do
        plain_book = create(:book)
        create(:book_file, book: plain_book, format: "azw3")

        post "/deliveries", params: { book_id: plain_book.id, device_id: device.id }
        follow_redirect!

        expect(response.body).to include("Queued for #{device.name}.")
        expect(response.body).not_to include("(text layer)")
        expect(response.body).not_to include("(original scan)")
      end
    end
  end

  describe "DELETE /deliveries/:id" do
    let!(:delivery) { create(:delivery, book: book, device: device) }

    it "removes the book from the device queue" do
      expect {
        delete "/deliveries/#{delivery.id}"
      }.to change(Delivery, :count).by(-1)
    end
  end

  describe "queue state in the UI" do
    let!(:azw3) { create(:book_file, book: book, format: "azw3") }

    it "offers a send button for an unqueued device" do
      get "/books/#{book.id}"

      expect(response.body).to include("Send to #{device.name}")
    end

    it "shows queued state and per-device counts once queued" do
      create(:delivery, book: book, device: device)

      get "/books/#{book.id}"
      expect(response.body).to include("Queued #{device.name}")

      get "/devices"
      expect(response.body).to include("0 books on device, 1 queued")
    end
  end
end
