require "rails_helper"

RSpec.describe "Book category — show breadcrumb and edit", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  describe "GET /books/:id (breadcrumb)" do
    it "links the root segment to category_root and the full path to category" do
      book = create(:book, category: "fiction/sf")

      get book_path(book)

      expect(response.body).to include(Library::Taxonomy.label_for("fiction"))
      expect(response.body).to include(Library::Taxonomy.sub_label_for("fiction", "sf"))
      expect(response.body).to include(root_path(category_root: "fiction"))
      expect(response.body).to include(root_path(category: "fiction/sf"))
    end

    it "shows just the root when the category has no subcategory" do
      book = create(:book, category: "classics")

      get book_path(book)

      expect(response.body).to include(root_path(category_root: "classics"))
      expect(response.body).not_to include(root_path(category: "classics"))
    end

    it "renders no breadcrumb when the book has no category" do
      book = create(:book, category: nil)

      get book_path(book)

      expect(response.body).not_to include("breadcrumb")
    end
  end

  describe "GET /books/:id/edit" do
    it "offers taxonomy categories as select options, grouped by root" do
      book = create(:book, category: "fiction/sf")

      get edit_book_path(book)

      expect(response.body).to include('<option selected="selected" value="fiction/sf">')
      expect(response.body).to include("<optgroup label=\"#{ERB::Util.html_escape(Library::Taxonomy.label_for('classics'))}\"")
    end

    it "keeps an out-of-taxonomy current value selectable instead of dropping it" do
      book = create(:book, category: "old_shelf/gone")

      get edit_book_path(book)

      expect(response.body).to include('value="old_shelf/gone"')
    end
  end

  describe "PATCH /books/:id" do
    it "updates the category" do
      book = create(:book, category: "fiction/literary")

      patch book_path(book), params: { book: { category: "fiction/sf" } }

      expect(book.reload.category).to eq("fiction/sf")
    end

    it "clears the category via the blank option" do
      book = create(:book, category: "fiction/sf")

      patch book_path(book), params: { book: { category: "" } }

      expect(book.reload.category).to be_nil.or eq("")
    end
  end
end
