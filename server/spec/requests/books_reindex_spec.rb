require "rails_helper"

RSpec.describe "Book full-text opt-in", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  describe "POST /books/:id/reindex" do
    it "opts the book in and queues IndexBookJob" do
      book = create(:book, fulltext_enabled: false)

      expect { post reindex_book_path(book) }
        .to have_enqueued_job(IndexBookJob).with(book.id)

      expect(book.reload.fulltext_enabled).to be(true)
      expect(response).to redirect_to(book_path(book))
    end
  end

  describe "POST /books/:id/unindex" do
    it "opts the book out and queues IndexBookJob so it clears the stored fulltext" do
      book = create(:book, fulltext_enabled: true, has_fulltext: true)

      expect { post unindex_book_path(book) }
        .to have_enqueued_job(IndexBookJob).with(book.id)

      expect(book.reload.fulltext_enabled).to be(false)
      expect(response).to redirect_to(book_path(book))
    end
  end
end
