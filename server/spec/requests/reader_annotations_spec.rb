require "rails_helper"

RSpec.describe "Reader annotations", type: :request do
  let!(:user) { create(:user) }
  let!(:book) { create(:book, title: "Fixture Book", author: "Fixture Author") }
  let!(:kindle_device) { create(:device, name: "kindle-1") }

  def sign_in(user, password: "password")
    post session_path, params: { email_address: user.email_address, password: password }
  end

  def annotations_path(book)
    "/books/#{book.id}/read/annotations"
  end

  def annotation_path(book, annotation)
    "/books/#{book.id}/read/annotations/#{annotation.id}"
  end

  def locate_path(book, annotation)
    "/books/#{book.id}/read/annotations/#{annotation.id}/locate"
  end

  describe "GET /books/:id/read/annotations" do
    it "requires authentication" do
      get annotations_path(book)
      expect(response).to redirect_to(new_session_path)
    end

    context "when signed in" do
      before { sign_in(user) }

      it "returns the book's annotations across sources, ordered by location then added_at, with the documented shape" do
        clipping = create(:annotation,
          book: book, device: kindle_device, source: "clippings", kind: "highlight",
          content: "In principio era il Verbo.", location_start: 680, location_end: 682,
          page: 45, added_at: Time.zone.local(2026, 7, 1))

        web_device = Device.web_reader!
        web = Annotation.create!(
          book: book, device: web_device, source: "web", kind: "highlight",
          cfi: "epubcfi(/6/2!/4)", content: "Selected passage.", color: "yellow",
          added_at: Time.zone.local(2026, 7, 2), fingerprint: "web-fp-1", raw_title: book.title
        )
        no_location = Annotation.create!(
          book: book, device: web_device, source: "web", kind: "note",
          cfi: "epubcfi(/6/4!/2)", note: "A note.",
          added_at: Time.zone.local(2026, 7, 3), fingerprint: "web-fp-2", raw_title: book.title
        )

        get annotations_path(book)

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body.map { |a| a["id"] }).to eq([ clipping.id, web.id, no_location.id ])

        clipping_json = body.first
        expect(clipping_json).to include(
          "id" => clipping.id, "kind" => "highlight", "source" => "clippings",
          "content" => "In principio era il Verbo.", "note" => nil, "color" => nil,
          "cfi" => nil, "location_start" => 680, "location_end" => 682, "page" => 45,
          "device_name" => kindle_device.name
        )
        expect(clipping_json).to have_key("added_at")

        web_json = body.second
        expect(web_json).to include(
          "id" => web.id, "kind" => "highlight", "source" => "web",
          "content" => "Selected passage.", "color" => "yellow",
          "cfi" => "epubcfi(/6/2!/4)", "device_name" => web_device.name
        )
      end

      it "does not include unreadable kinds even if present in the table" do
        annotation = create(:annotation, book: book, device: kindle_device, kind: "highlight")
        annotation.update_column(:kind, "garbage")

        get annotations_path(book)

        expect(JSON.parse(response.body)).to be_empty
      end
    end
  end

  describe "POST /books/:id/read/annotations" do
    it "requires authentication" do
      expect {
        post annotations_path(book), params: { kind: "highlight", cfi: "epubcfi(/6/2!/4)", color: "yellow" }
      }.not_to change(Annotation, :count)
      expect(response).to redirect_to(new_session_path)
    end

    context "when signed in" do
      before { sign_in(user) }

      it "creates a web-sourced annotation attributed to the synthetic web device" do
        expect {
          post annotations_path(book), params: {
            kind: "highlight", cfi: "epubcfi(/6/2!/4)", content: "Selected passage.", color: "yellow"
          }
        }.to change(Annotation, :count).by(1)

        expect(response).to have_http_status(:created)
        body = JSON.parse(response.body)
        expect(body).to include(
          "kind" => "highlight", "source" => "web", "content" => "Selected passage.",
          "color" => "yellow", "cfi" => "epubcfi(/6/2!/4)", "device_name" => "Folio Web"
        )

        annotation = Annotation.find(body["id"])
        expect(annotation.device).to eq(Device.web_reader!)
        expect(annotation.fingerprint).to eq(Digest::SHA256.hexdigest("web:#{book.id}:highlight:epubcfi(/6/2!/4)"))
        expect(annotation.raw_title).to eq(book.title)
        expect(annotation.added_at).to be_present
      end

      it "returns the existing row instead of raising on a duplicate cfi+kind" do
        post annotations_path(book), params: { kind: "highlight", cfi: "epubcfi(/6/2!/4)", color: "yellow" }
        first_id = JSON.parse(response.body)["id"]

        expect {
          post annotations_path(book), params: { kind: "highlight", cfi: "epubcfi(/6/2!/4)", color: "blue" }
        }.not_to change(Annotation, :count)

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["id"]).to eq(first_id)
        expect(body["color"]).to eq("yellow") # unchanged — the original row, not a re-create
      end

      it "allows the same cfi across different kinds and different books" do
        post annotations_path(book), params: { kind: "highlight", cfi: "epubcfi(/6/2!/4)", color: "yellow" }
        other_book = create(:book, title: "Other Book")

        expect {
          post annotations_path(book), params: { kind: "note", cfi: "epubcfi(/6/2!/4)", note: "hi" }
          post annotations_path(other_book), params: { kind: "highlight", cfi: "epubcfi(/6/2!/4)", color: "blue" }
        }.to change(Annotation, :count).by(2)
      end

      it "rejects a blank cfi" do
        expect {
          post annotations_path(book), params: { kind: "highlight", color: "yellow" }
        }.not_to change(Annotation, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects a kind outside the whitelist" do
        expect {
          post annotations_path(book), params: { kind: "underline", cfi: "epubcfi(/6/2!/4)" }
        }.not_to change(Annotation, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "requires a whitelisted color for highlights" do
        expect {
          post annotations_path(book), params: { kind: "highlight", cfi: "epubcfi(/6/2!/4)" }
        }.not_to change(Annotation, :count)
        expect(response).to have_http_status(:unprocessable_content)

        expect {
          post annotations_path(book), params: { kind: "highlight", cfi: "epubcfi(/6/2!/4)", color: "red" }
        }.not_to change(Annotation, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "allows a nil color for notes and bookmarks" do
        expect {
          post annotations_path(book), params: { kind: "note", cfi: "epubcfi(/6/2!/4)", note: "hi" }
        }.to change(Annotation, :count).by(1)
        expect(response).to have_http_status(:created)

        expect {
          post annotations_path(book), params: { kind: "bookmark", cfi: "epubcfi(/6/4!/2)" }
        }.to change(Annotation, :count).by(1)
        expect(response).to have_http_status(:created)
      end
    end
  end

  describe "PATCH /books/:id/read/annotations/:annotation_id" do
    before { sign_in(user) }

    it "updates color and note on a web-sourced row" do
      web = Annotation.create!(
        book: book, device: Device.web_reader!, source: "web", kind: "highlight",
        cfi: "epubcfi(/6/2!/4)", color: "yellow", added_at: Time.current,
        fingerprint: "web-fp-3", raw_title: book.title
      )

      patch annotation_path(book, web), params: { color: "pink", note: "reconsidered" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).to include("color" => "pink", "note" => "reconsidered")
      expect(web.reload.color).to eq("pink")
    end

    it "ignores a content param (not permitted)" do
      web = Annotation.create!(
        book: book, device: Device.web_reader!, source: "web", kind: "highlight",
        cfi: "epubcfi(/6/2!/4)", content: "original", color: "yellow", added_at: Time.current,
        fingerprint: "web-fp-4", raw_title: book.title
      )

      patch annotation_path(book, web), params: { content: "rewritten" }

      expect(web.reload.content).to eq("original")
    end

    it "returns 403 for a clippings-sourced row" do
      clipping = create(:annotation, book: book, device: kindle_device, source: "clippings")

      patch annotation_path(book, clipping), params: { color: "pink" }

      expect(response).to have_http_status(:forbidden)
      expect(clipping.reload.color).to be_nil
    end
  end

  describe "DELETE /books/:id/read/annotations/:annotation_id" do
    before { sign_in(user) }

    it "destroys a web-sourced row" do
      web = Annotation.create!(
        book: book, device: Device.web_reader!, source: "web", kind: "bookmark",
        cfi: "epubcfi(/6/2!/4)", added_at: Time.current, fingerprint: "web-fp-5", raw_title: book.title
      )

      expect { delete annotation_path(book, web) }.to change(Annotation, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "returns 403 for a clippings-sourced row and leaves it intact" do
      clipping = create(:annotation, book: book, device: kindle_device, source: "clippings")

      expect { delete annotation_path(book, clipping) }.not_to change(Annotation, :count)
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /books/:id/read/annotations/:annotation_id/locate" do
    before { sign_in(user) }

    it "sets the cfi on a clippings row that has none yet" do
      clipping = create(:annotation, book: book, device: kindle_device, source: "clippings", cfi: nil)

      patch locate_path(book, clipping), params: { cfi: "epubcfi(/6/8!/2)" }

      expect(response).to have_http_status(:ok)
      expect(clipping.reload.cfi).to eq("epubcfi(/6/8!/2)")
    end

    it "does not overwrite an already-resolved cfi without force" do
      clipping = create(:annotation, book: book, device: kindle_device, source: "clippings", cfi: "epubcfi(/6/2!/2)")

      patch locate_path(book, clipping), params: { cfi: "epubcfi(/6/8!/2)" }

      expect(response).to have_http_status(:ok)
      expect(clipping.reload.cfi).to eq("epubcfi(/6/2!/2)")
    end

    it "overwrites an already-resolved cfi when force=true" do
      clipping = create(:annotation, book: book, device: kindle_device, source: "clippings", cfi: "epubcfi(/6/2!/2)")

      patch locate_path(book, clipping), params: { cfi: "epubcfi(/6/8!/2)", force: true }

      expect(response).to have_http_status(:ok)
      expect(clipping.reload.cfi).to eq("epubcfi(/6/8!/2)")
    end

    it "works on web-sourced rows too" do
      web = Annotation.create!(
        book: book, device: Device.web_reader!, source: "web", kind: "highlight",
        cfi: nil, color: "yellow", added_at: Time.current, fingerprint: "web-fp-6", raw_title: book.title
      )

      patch locate_path(book, web), params: { cfi: "epubcfi(/6/8!/2)" }

      expect(response).to have_http_status(:ok)
      expect(web.reload.cfi).to eq("epubcfi(/6/8!/2)")
    end
  end
end
