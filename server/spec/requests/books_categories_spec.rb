require "rails_helper"

RSpec.describe "Library category filters", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  let!(:sf) { create(:book, title: "Foundation", author: "Isaac Asimov", category: "fiction/sf") }
  let!(:literary) { create(:book, title: "Blindness", author: "Jose Saramago", category: "fiction/literary") }
  let!(:history) { create(:book, title: "Sapiens", author: "Yuval Harari", category: "nonfiction/history") }
  let!(:inbox) { create(:book, title: "Loose Import", category: "_inbox") }
  let!(:uncategorized) { create(:book, title: "No Shelf Yet", category: nil) }

  describe "GET / with category" do
    it "filters to an exact category/subcategory" do
      get root_path(category: "fiction/sf")

      expect(response.body).to include("Foundation")
      expect(response.body).not_to include("Blindness")
      expect(response.body).not_to include("Sapiens")
    end

    it "filters to _inbox like any other category value" do
      get root_path(category: "_inbox")

      expect(response.body).to include("Loose Import")
      expect(response.body).not_to include("Foundation")
    end

    it "filters to uncategorized books via the sentinel value" do
      get root_path(category: BooksController::UNCATEGORIZED)

      expect(response.body).to include("No Shelf Yet")
      expect(response.body).not_to include("Foundation")
      expect(response.body).not_to include("Loose Import")
    end
  end

  describe "GET / with category_root" do
    it "filters to every book under a root" do
      get root_path(category_root: "fiction")

      expect(response.body).to include("Foundation").and include("Blindness")
      expect(response.body).not_to include("Sapiens")
    end
  end

  it "lets an exact category win when both category and category_root are given" do
    get root_path(category: "fiction/sf", category_root: "nonfiction")

    expect(response.body).to include("Foundation")
    expect(response.body).not_to include("Blindness")
    expect(response.body).not_to include("Sapiens")
  end

  it "composes a category filter with author and format filters (AND)" do
    create(:book_file, book: sf, format: "epub")
    create(:book_file, book: literary, format: "epub")

    get root_path(category_root: "fiction", author: "Isaac Asimov", format: "epub")

    expect(response.body).to include("Foundation")
    expect(response.body).not_to include("Blindness")
  end

  it "returns no results (not an error) when the category and format filters can't both hold" do
    create(:book_file, book: sf, format: "epub")

    get root_path(category: "fiction/sf", format: "azw3")

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Foundation")
  end

  describe "the keep-reading guard" do
    let!(:reading_state) do
      device = create(:device)
      create(:reading_state, book: sf, device: device, content_mtime: Time.current, progress_percent: 40)
    end

    it "shows the keep-reading shelf on the unfiltered front page" do
      get root_path
      expect(response.body).to include("Keep reading")
    end

    it "suppresses the keep-reading shelf once a category filter is applied" do
      get root_path(category: "fiction/sf")
      expect(response.body).not_to include("Keep reading")
    end

    it "suppresses the keep-reading shelf once a category_root filter is applied" do
      get root_path(category_root: "fiction")
      expect(response.body).not_to include("Keep reading")
    end
  end

  describe "shelf counts" do
    it "exposes root and subcategory counts for the Shelves nav" do
      get root_path

      expect(response.body).to include("Shelves")
      expect(response.body).to include(Library::Taxonomy.label_for("fiction"))
      expect(response.body).to include(Library::Taxonomy.sub_label_for("fiction", "sf"))
      expect(response.body).to include(Library::Taxonomy.sub_label_for("nonfiction", "history"))
      expect(response.body).to include("Inbox")
      expect(response.body).to include("Uncategorized")
    end

    it "does not render a shelf row for a category with zero books" do
      get root_path
      expect(response.body).not_to include(Library::Taxonomy.label_for("comics"))
    end
  end
end
