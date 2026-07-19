require "rails_helper"

RSpec.describe "Library shelf — conversion-failure badge", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  it "flags a book that failed a conversion and has no Kindle-ready file" do
    book = create(:book, title: "Broken Book")
    source = create(:book_file, book: book, format: "epub")
    conversion = create(:conversion, book: book, book_file: source, target_format: "azw3", status: "pending")
    conversion.mark_failed!("calibre blew up")

    get root_path

    expect(response.body).to include("Broken Book")
    expect(response.body).to include("cover-badge")
  end

  it "does not flag a book whose failed conversion is offset by a good Kindle-ready file" do
    book = create(:book, title: "Recovered Book")
    source = create(:book_file, book: book, format: "epub")
    conversion = create(:conversion, book: book, book_file: source, target_format: "mobi", status: "pending")
    conversion.mark_failed!("first attempt failed")
    create(:book_file, book: book, format: "azw3") # a later attempt/target succeeded

    get root_path

    expect(response.body).to include("Recovered Book")
    expect(response.body).not_to include("cover-badge")
  end

  it "does not flag a healthy book with no conversion history" do
    create(:book, title: "Healthy Book")

    get root_path

    expect(response.body).to include("Healthy Book")
    expect(response.body).not_to include("cover-badge")
  end

  it "does not N+1 as the number of flagged books on the page grows" do
    make_flagged_book = lambda do
      book = create(:book)
      source = create(:book_file, book: book, format: "epub")
      conversion = create(:conversion, book: book, book_file: source, target_format: "azw3", status: "pending")
      conversion.mark_failed!("boom")
      book
    end

    make_flagged_book.call
    queries_for_one = count_sql_queries { get root_path }
    expect(response).to have_http_status(:ok)

    4.times { make_flagged_book.call }
    queries_for_five = count_sql_queries { get root_path }
    expect(response).to have_http_status(:ok)

    # Going from 1 to 5 flagged books should add ~0 queries (both
    # book_files and conversions are eager-loaded per page, not per book —
    # see BooksController#index's .includes(:book_files, :conversions)),
    # not the ~4-8 an N+1 over conversion_failed_without_deliverable?
    # would add. A little slack for incidental variance either way.
    expect(queries_for_five).to be <= queries_for_one + 2
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
