require "rails_helper"

RSpec.describe "Series index", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  it "renders a cover thumbnail for each series, reusing the shelf grid" do
    create(:book, title: "Dune", series: "Dune Saga", series_index: 1)

    get series_index_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Dune Saga")
    expect(response.body).to include("shelf-item")
    expect(response.body).to include("cover")
  end

  it "does not N+1 as the number of series on the page grows" do
    make_series = ->(n) { create(:book, title: "Book #{n}", series: "Series #{n}", series_index: 1) }

    make_series.call(1)
    queries_for_one = count_sql_queries { get series_index_path }
    expect(response).to have_http_status(:ok)

    2.upto(6) { |n| make_series.call(n) }
    queries_for_six = count_sql_queries { get series_index_path }
    expect(response).to have_http_status(:ok)

    # One book per series, so the representative-cover lookup (two queries
    # total — see SeriesController#index) shouldn't grow with series count.
    expect(queries_for_six).to be <= queries_for_one + 2
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
