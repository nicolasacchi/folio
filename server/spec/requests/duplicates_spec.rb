require "rails_helper"

RSpec.describe "Duplicates", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  # Alpha: two editions, no overlapping formats — a clean merge.
  let!(:alpha_epub) { create(:book, title: "Alpha", author: "Writer", created_at: 2.days.ago) }
  let!(:alpha_azw3) { create(:book, title: "Alpha", author: "Writer", created_at: 1.day.ago) }
  # Beta: three editions, two of which share the epub format — a conflict,
  # and the larger group (3 books vs Alpha's 2).
  let!(:beta_1) { create(:book, title: "Beta", author: "Writer", created_at: 3.days.ago) }
  let!(:beta_2) { create(:book, title: "Beta", author: "Writer", created_at: 2.days.ago) }
  let!(:beta_3) { create(:book, title: "Beta", author: "Writer", created_at: 1.day.ago) }

  before do
    create(:book_file, book: alpha_epub, format: "epub")
    create(:book_file, book: alpha_azw3, format: "azw3", path: "#{SecureRandom.hex(4)}/a.azw3")
    create(:book_file, book: beta_1, format: "epub")
    create(:book_file, book: beta_2, format: "epub", path: "#{SecureRandom.hex(4)}/b2.epub")
    create(:book_file, book: beta_3, format: "mobi", path: "#{SecureRandom.hex(4)}/b3.mobi")
  end

  describe "GET /duplicates" do
    it "sorts groups by title by default" do
      get "/duplicates"

      expect(response.body.index("Alpha")).to be < response.body.index("Beta")
    end

    it "sorts groups by size when requested" do
      get "/duplicates", params: { sort: "size" }

      expect(response.body.index("Beta")).to be < response.body.index("Alpha")
    end

    it "filters down to groups with a format conflict" do
      get "/duplicates", params: { conflicts: "1" }

      expect(response.body).to include("Beta")
      expect(response.body).not_to include("Alpha")
    end

    it "offers a way back when the filter matches nothing" do
      Book.where(id: [ beta_1.id, beta_2.id, beta_3.id ]).destroy_all

      get "/duplicates", params: { conflicts: "1" }

      expect(response.body).to include("No groups match this filter")
      expect(response.body).to include("Clear filter")
    end

    it "still finds the catalog's duplicates without the filter" do
      Book.where(id: [ beta_1.id, beta_2.id, beta_3.id ]).destroy_all

      get "/duplicates"

      expect(response.body).not_to include("No duplicate editions found")
      expect(response.body).to include("Alpha")
    end

    it "previews the merged result's formats on the merge control" do
      get "/duplicates"

      expect(response.body).to include("Result: AZW3, EPUB.")
    end

    it "calls out a format that would collide instead of merging silently" do
      get "/duplicates"

      expect(response.body).to include("Result: EPUB, MOBI.")
      expect(response.body).to include("EPUB is on more than one edition — the extra copy stays put.")
    end
  end
end
