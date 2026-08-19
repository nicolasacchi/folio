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
      expect(flash[:alert]).to match(/No Kindle selected|preferred Kindle/i)
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

    describe "variant selection (?variant=, plus legacy ?raw= mapping)" do
      it "defaults a fresh delivery to variant: 'auto'" do
        post "/deliveries", params: { book_id: book.id, device_id: device.id }

        expect(Delivery.last.variant).to eq("auto")
      end

      it "persists variant: 'original' on a fresh delivery" do
        post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "original" }

        expect(Delivery.last.variant).to eq("original")
      end

      it "flips an existing delivery's variant on re-send, without creating a second row" do
        delivery = create(:delivery, book: book, device: device, variant: "auto")

        expect {
          post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "original" }
        }.not_to change(Delivery, :count)

        expect(delivery.reload.variant).to eq("original")
      end

      it "leaves an already-'original' delivery's variant untouched on a plain re-send (no variant param at all)" do
        delivery = create(:delivery, book: book, device: device, variant: "original")

        post "/deliveries", params: { book_id: book.id, device_id: device.id }

        expect(delivery.reload.variant).to eq("original")
      end

      it "flips an already-'original' delivery back with an explicit variant=auto" do
        delivery = create(:delivery, book: book, device: device, variant: "original")

        post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "auto" }

        expect(delivery.reload.variant).to eq("auto")
      end

      it "ignores an unrecognized variant value (leaves the delivery's variant alone)" do
        delivery = create(:delivery, book: book, device: device, variant: "auto")

        post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "bogus" }

        expect(delivery.reload.variant).to eq("auto")
      end

      describe "legacy ?raw= param" do
        it "maps raw=1 onto variant: 'original'" do
          post "/deliveries", params: { book_id: book.id, device_id: device.id, raw: 1 }

          expect(Delivery.last.variant).to eq("original")
        end

        it "maps raw=0 onto variant: 'auto'" do
          delivery = create(:delivery, book: book, device: device, variant: "original")

          post "/deliveries", params: { book_id: book.id, device_id: device.id, raw: 0 }

          expect(delivery.reload.variant).to eq("auto")
        end

        it "is ignored once an explicit variant= is also given" do
          post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "text", raw: 1 }

          expect(Delivery.last.variant).to eq("text")
        end
      end
    end

    describe "variant=text" do
      it "queues TextCompanionJob when the kindle_file is a pdf and the companion isn't usable yet" do
        create(:book_file, book: book, format: "pdf")

        expect {
          post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "text" }
        }.to have_enqueued_job(TextCompanionJob)

        expect(Delivery.last.variant).to eq("text")
      end

      it "does not queue TextCompanionJob when the kindle_file isn't a pdf" do
        create(:book_file, book: book, format: "azw3")

        expect {
          post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "text" }
        }.not_to have_enqueued_job(TextCompanionJob)
      end

      it "does not queue TextCompanionJob once the text-companion AZW3 is already usable" do
        pdf = create(:book_file, :on_disk, book: book, format: "pdf")
        relative = "text/#{book.public_id}.azw3"
        FileUtils.mkdir_p(Library.base_root.join(relative).dirname)
        File.write(Library.base_root.join(relative), "azw3 bytes")
        text_relative = "text/#{book.public_id}.txt"
        FileUtils.mkdir_p(Library.base_root.join(text_relative).dirname)
        File.write(Library.base_root.join(text_relative), "text")
        pdf.update!(text_path: text_relative, text_source_sha256: pdf.sha256, text_kindle_path: relative)

        expect {
          post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "text" }
        }.not_to have_enqueued_job(TextCompanionJob)
      end
    end

    describe "flash message naming the variant" do
      let!(:pdf_file) { create(:book_file, book: book, format: "pdf") }

      def make_ocr_fresh!
        ocr_path = "ocr/#{pdf_file.id}.ocr.pdf"
        FileUtils.mkdir_p(Library.base_root.join(ocr_path).dirname)
        File.write(Library.base_root.join(ocr_path), "ocr'd pdf bytes with a text layer")
        pdf_file.update!(ocr_path: ocr_path, ocr_source_sha256: pdf_file.sha256)
      end

      it "names the text-layer variant when a fresh send defaults to auto" do
        make_ocr_fresh!

        post "/deliveries", params: { book_id: book.id, device_id: device.id }

        expect(flash[:notice]).to eq("Queued for #{device.name} (text layer).")
      end

      it "names the original-scan variant when a fresh send asks for it" do
        make_ocr_fresh!

        post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "original" }

        expect(flash[:notice]).to eq("Queued for #{device.name} (original scan).")
      end

      it "says so explicitly when flipping an existing delivery to the original scan" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "auto")

        post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "original" }

        expect(flash[:notice]).to eq("Switched #{device.name} to the original scan — it will re-deliver.")
      end

      it "says so explicitly when flipping an existing delivery back to the text layer" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "original")

        post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "auto" }

        expect(flash[:notice]).to eq("Switched #{device.name} to the text layer — it will re-deliver.")
      end

      it "names the text-only variant on a fresh send, even without a fresh OCR companion" do
        post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "text" }

        expect(flash[:notice]).to eq("Queued for #{device.name} (text only).")
      end

      it "says so explicitly (in its own wording) when flipping an existing delivery to the text-only version" do
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "auto")

        post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "text" }

        expect(flash[:notice]).to eq("Switched #{device.name} to the text-only version — it will re-deliver.")
      end

      it "says 'Queued', not 'Switched', when re-sending a previously removed delivery with a different variant" do
        make_ocr_fresh!
        delivery = create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "auto")
        delivery.mark_removed!

        post "/deliveries", params: { book_id: book.id, device_id: device.id, variant: "original" }

        expect(flash[:notice]).to eq("Queued for #{device.name} (original scan).")
      end

      it "keeps the plain 'Already queued' message when nothing about the variant changes" do
        make_ocr_fresh!
        create(:delivery, book: book, device: device, delivered_at: Time.current, variant: "auto")

        post "/deliveries", params: { book_id: book.id, device_id: device.id }

        expect(flash[:notice]).to eq("Already queued for #{device.name}.")
      end

      it "keeps today's plain messages verbatim for a book with no OCR companion and no variant requested" do
        plain_book = create(:book)
        create(:book_file, book: plain_book, format: "azw3")

        post "/deliveries", params: { book_id: plain_book.id, device_id: device.id }

        expect(flash[:notice]).to eq("Queued for #{device.name}.")
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
