require "rails_helper"

RSpec.describe "Smart shelves", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  describe "GET /smart_shelves" do
    it "lists saved shelves" do
      create(:smart_shelf, name: "Asimov SF")

      get smart_shelves_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Asimov SF")
    end

    it "shows an empty state with no shelves" do
      get smart_shelves_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No smart shelves yet")
    end
  end

  describe "GET /smart_shelves/new" do
    it "renders the condition-row form" do
      get new_smart_shelf_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Add condition")
      expect(response.body).to include("condition_field")
    end
  end

  describe "GET /smart_shelves/:id/edit" do
    it "renders the form pre-filled with the shelf's saved conditions" do
      shelf = create(:smart_shelf, name: "Prefilled", rules: {
        "conditions" => [ { "field" => "author", "op" => "equals", "value" => "Isaac Asimov" } ]
      })

      get edit_smart_shelf_path(shelf)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(%(value="author"))
      expect(response.body).to include("Isaac Asimov")
    end
  end

  describe "POST /smart_shelves" do
    it "creates a shelf from field/op/value rows and redirects" do
      post smart_shelves_path, params: {
        smart_shelf: {
          name: "Asimov SF",
          match: "all",
          condition_field: [ "author", "category" ],
          condition_op: [ "equals", "under" ],
          condition_value: [ "Isaac Asimov", "fiction" ]
        }
      }

      expect(response).to redirect_to(smart_shelves_path)
      shelf = SmartShelf.find_by(name: "Asimov SF")
      expect(shelf).to be_present
      expect(shelf.conditions.size).to eq(2)
    end

    it "drops a blank row (no field chosen) instead of erroring" do
      post smart_shelves_path, params: {
        smart_shelf: {
          name: "Partial",
          condition_field: [ "author", "" ],
          condition_op: [ "equals", "" ],
          condition_value: [ "Isaac Asimov", "" ]
        }
      }

      expect(response).to redirect_to(smart_shelves_path)
      expect(SmartShelf.find_by(name: "Partial").conditions.size).to eq(1)
    end

    it "re-renders the form with errors on invalid rules (unknown field)" do
      expect {
        post smart_shelves_path, params: {
          smart_shelf: {
            name: "Bad shelf",
            condition_field: [ "not_a_real_field" ],
            condition_op: [ "equals" ],
            condition_value: [ "x" ]
          }
        }
      }.not_to change { SmartShelf.count }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("unknown field")
    end

    it "re-renders the form with errors when the name is blank" do
      expect {
        post smart_shelves_path, params: { smart_shelf: { name: "" } }
      }.not_to change { SmartShelf.count }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET /smart_shelves/:id" do
    it "renders matching books and excludes non-matching ones, via the shared shelf grid" do
      asimov = create(:book, title: "Foundation", author: "Isaac Asimov")
      create(:book, title: "Cooking for Two", author: "Julia Child")

      shelf = create(:smart_shelf, name: "Asimov", rules: {
        "conditions" => [ { "field" => "author", "op" => "equals", "value" => "Isaac Asimov" } ]
      })

      get smart_shelf_path(shelf)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Foundation")
      expect(response.body).not_to include("Cooking for Two")
      expect(response.body).to include("shelf-item")
    end

    it "paginates like the main library shelf" do
      shelf = create(:smart_shelf, name: "Everything by A", rules: {
        "conditions" => [ { "field" => "author", "op" => "equals", "value" => "A" } ]
      })
      (BooksController::PER_PAGE + 5).times { |n| create(:book, title: "Book #{n}", author: "A") }

      get smart_shelf_path(shelf)
      expect(response.body).to include("page 1 of 2")

      get smart_shelf_path(shelf, page: 2)
      expect(response.body).to include("page 2 of 2")
    end

    it "shows a graceful empty state for a shelf that matches nothing" do
      shelf = create(:smart_shelf, name: "Nothing matches", rules: {
        "conditions" => [ { "field" => "author", "op" => "equals", "value" => "Nobody Real" } ]
      })

      get smart_shelf_path(shelf)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No books match this shelf")
    end

    it "shows a graceful empty state for a shelf with no conditions at all" do
      shelf = create(:smart_shelf, name: "Blank", rules: {})
      create(:book)

      get smart_shelf_path(shelf)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("No books match this shelf")
    end

    it "does not N+1 as the number of matching books grows" do
      shelf = create(:smart_shelf, name: "All A", rules: {
        "conditions" => [ { "field" => "author", "op" => "equals", "value" => "A" } ]
      })
      make_book = -> { create(:book, author: "A").tap { |b| create(:book_file, book: b, format: "epub") } }

      make_book.call
      queries_for_one = count_sql_queries { get smart_shelf_path(shelf) }
      expect(response).to have_http_status(:ok)

      4.times { make_book.call }
      queries_for_five = count_sql_queries { get smart_shelf_path(shelf) }
      expect(response).to have_http_status(:ok)

      expect(queries_for_five).to be <= queries_for_one + 2
    end
  end

  describe "PATCH /smart_shelves/:id" do
    it "updates the rules" do
      shelf = create(:smart_shelf, name: "Mutable", rules: {
        "conditions" => [ { "field" => "author", "op" => "equals", "value" => "Old Author" } ]
      })

      patch smart_shelf_path(shelf), params: {
        smart_shelf: {
          name: "Mutable",
          condition_field: [ "author" ],
          condition_op: [ "equals" ],
          condition_value: [ "New Author" ]
        }
      }

      expect(response).to redirect_to(smart_shelves_path)
      shelf.reload
      expect(shelf.conditions.first["value"]).to eq("New Author")
    end

    it "re-renders with errors on an invalid update" do
      shelf = create(:smart_shelf, name: "Mutable")

      patch smart_shelf_path(shelf), params: {
        smart_shelf: { name: "Mutable", condition_field: [ "author" ], condition_op: [ "bogus_op" ], condition_value: [ "x" ] }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("unknown operator")
    end
  end

  describe "DELETE /smart_shelves/:id" do
    it "removes the shelf without touching its books" do
      book = create(:book, title: "Untouched", author: "Isaac Asimov")
      shelf = create(:smart_shelf, name: "Doomed", rules: {
        "conditions" => [ { "field" => "author", "op" => "equals", "value" => "Isaac Asimov" } ]
      })

      delete smart_shelf_path(shelf)

      expect(response).to redirect_to(smart_shelves_path)
      expect(SmartShelf.exists?(shelf.id)).to be false
      expect(Book.exists?(book.id)).to be true
    end
  end

  def count_sql_queries
    count = 0
    callback = lambda do |*, payload|
      count += 1 unless payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
  end
end
