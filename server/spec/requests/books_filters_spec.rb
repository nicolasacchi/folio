require 'rails_helper'

RSpec.describe "Library filters", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  let!(:old_italian) do
    create(:book, title: "Vecchio", language: "it", published_year: 1954,
      created_at: Time.zone.local(2026, 7, 1, 12))
  end
  let!(:new_english) do
    create(:book, title: "Fresh", language: "en", published_year: 2020,
      created_at: Time.zone.local(2026, 7, 10, 9))
  end

  it "filters by publication year" do
    get root_path(year: 1954)
    expect(response.body).to include("Vecchio")
    expect(response.body).not_to include("Fresh")
  end

  it "filters by language" do
    get root_path(language: "en")
    expect(response.body).to include("Fresh")
    expect(response.body).not_to include("Vecchio")
  end

  it "filters by the day a book was added" do
    get root_path(added: "2026-07-01")
    expect(response.body).to include("Vecchio")
    expect(response.body).not_to include("Fresh")
  end

  it "ignores an unparseable added date" do
    get root_path(added: "not-a-date")
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Vecchio").and include("Fresh")
  end

  describe "search modes" do
    before do
      BookSearch.index_book!(old_italian, fulltext: "the word fresh hides in the body")
      BookSearch.index_book!(new_english)
    end

    it "defaults to title/author matching" do
      get root_path(q: "fresh")
      expect(response.body).to include("Fresh")
      expect(response.body).not_to include("Vecchio")
    end

    it "searches inside books when mode=full" do
      get root_path(q: "fresh", mode: "full")
      expect(response.body).to include("Fresh").and include("Vecchio")
    end
  end
end
