require "rails_helper"

RSpec.describe "Vocab notebook", type: :request do
  let!(:user) { create(:user) }
  let!(:book) { create(:book, title: "Fixture Book") }

  def sign_in(user, password: "password")
    post session_path, params: { email_address: user.email_address, password: password }
  end

  describe "authentication" do
    it "redirects an unauthenticated GET /vocab" do
      get vocab_entries_path
      expect(response).to redirect_to(new_session_path)
    end

    it "redirects an unauthenticated POST /vocab" do
      post vocab_entries_path, params: { word: "mouse", lemma: "mouse", lang: "en" }
      expect(response).to redirect_to(new_session_path)
    end
  end

  context "when signed in" do
    before { sign_in(user) }

    describe "POST /vocab" do
      it "creates a vocab entry from a resolved lookup" do
        expect {
          post vocab_entries_path, params: {
            word: "running", lemma: "run", lang: "en", book_id: book.id,
            context: "He kept running down the street.", gloss: "to move fast on foot"
          }
        }.to change(VocabEntry, :count).by(1)

        expect(response).to have_http_status(:created)
        entry = VocabEntry.last
        expect(entry).to have_attributes(
          user_id: user.id, book_id: book.id, word: "running", lemma: "run", lang: "en",
          context: "He kept running down the street.", gloss: "to move fast on foot"
        )
      end

      it "updates the existing row instead of duplicating on a second identical POST" do
        post vocab_entries_path, params: { word: "run", lemma: "run", lang: "en", book_id: book.id, context: "First." }

        expect {
          post vocab_entries_path, params: { word: "running", lemma: "run", lang: "en", book_id: book.id, context: "Second." }
        }.not_to change(VocabEntry, :count)

        expect(response).to have_http_status(:created)
        entry = VocabEntry.last
        expect(entry).to have_attributes(word: "running", context: "Second.")
      end

      it "defaults lemma to word when lemma is blank" do
        post vocab_entries_path, params: { word: "cats", lang: "en" }
        expect(VocabEntry.last.lemma).to eq("cats")
      end

      it "saves without a book when book_id is absent" do
        post vocab_entries_path, params: { word: "mouse", lemma: "mouse", lang: "en" }
        expect(VocabEntry.last.book_id).to be_nil
      end

      it "rejects a blank word" do
        expect {
          post vocab_entries_path, params: { word: "  ", lemma: "x", lang: "en" }
        }.not_to change(VocabEntry, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects an unsupported language" do
        expect {
          post vocab_entries_path, params: { word: "chat", lemma: "chat", lang: "fr" }
        }.not_to change(VocabEntry, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    describe "GET /vocab" do
      it "only lists the current user's entries" do
        mine = create(:vocab_entry, user: user, book: book, word: "mine", lemma: "mine")
        other_user = create(:user, email_address: "other@example.com")
        create(:vocab_entry, user: other_user, book: book, word: "theirs", lemma: "theirs")

        get vocab_entries_path

        expect(response.body).to include(mine.word)
        expect(response.body).not_to include("theirs")
      end

      it "filters by book" do
        other_book = create(:book, title: "Other Book")
        create(:vocab_entry, user: user, book: book, word: "inbook", lemma: "inbook")
        create(:vocab_entry, user: user, book: other_book, word: "otherbook", lemma: "otherbook")

        get vocab_entries_path(book_id: book.id)

        expect(response.body).to include("inbook")
        expect(response.body).not_to include("otherbook")
      end

      it "filters by lang" do
        create(:vocab_entry, user: user, book: book, word: "libro", lemma: "libro", lang: "it")
        create(:vocab_entry, user: user, book: book, word: "mouse", lemma: "mouse", lang: "en")

        get vocab_entries_path(lang: "it")

        expect(response.body).to include("libro")
        expect(response.body).not_to include("mouse")
      end

      it "does not N+1 the book association as the number of entries on the page grows" do
        create(:vocab_entry, user: user, book: book)
        queries_for_one = count_sql_queries { get vocab_entries_path }
        expect(response).to have_http_status(:ok)

        4.times { create(:vocab_entry, user: user, book: book) }
        queries_for_five = count_sql_queries { get vocab_entries_path }
        expect(response).to have_http_status(:ok)

        # Going from 1 to 5 entries should add ~0 queries (:book is
        # eager-loaded per page via .includes, not per row) — a little
        # slack for incidental variance either way.
        expect(queries_for_five).to be <= queries_for_one + 2
      end
    end

    describe "per-book vocab section on the book page" do
      it "shows only that book's words for the current user" do
        create(:vocab_entry, user: user, book: book, word: "keepme", lemma: "keepme")
        other_book = create(:book, title: "Other Book")
        create(:vocab_entry, user: user, book: other_book, word: "dropme", lemma: "dropme")

        get book_path(book)

        expect(response.body).to include("keepme")
        expect(response.body).not_to include("dropme")
      end
    end

    describe "DELETE /vocab/:id" do
      it "removes the entry" do
        entry = create(:vocab_entry, user: user, book: book)

        expect { delete vocab_entry_path(entry) }.to change(VocabEntry, :count).by(-1)
        expect(response).to redirect_to(vocab_entries_path)
      end

      it "does not allow deleting another user's entry" do
        other_user = create(:user, email_address: "other@example.com")
        entry = create(:vocab_entry, user: other_user, book: book)

        expect { delete vocab_entry_path(entry) }.not_to change(VocabEntry, :count)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "GET /vocab/export" do
      it "returns a CSV with the expected rows" do
        create(:vocab_entry, user: user, book: book, word: "mouse", lemma: "mouse", lang: "en",
          gloss: "a small rodent", context: "A mouse ran by.")

        get export_vocab_entries_path(format: "csv")

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/csv")
        expect(response.headers["Content-Disposition"]).to include(".csv")

        rows = CSV.parse(response.body, headers: true)
        expect(rows.headers).to eq(%w[Word Lemma Lang Book Context Gloss Date])
        row = rows.first
        expect(row["Word"]).to eq("mouse")
        expect(row["Lemma"]).to eq("mouse")
        expect(row["Book"]).to eq("Fixture Book")
        expect(row["Gloss"]).to eq("a small rodent")
      end

      it "returns an Anki-friendly TSV with front/back columns" do
        create(:vocab_entry, user: user, book: book, word: "running", lemma: "run", lang: "en",
          gloss: "to move fast on foot", context: "He kept running.")

        get export_vocab_entries_path(format: "anki")

        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/tab-separated-values")

        front, back = response.body.strip.split("\t")
        expect(front).to eq("running (run)")
        expect(back).to eq("to move fast on foot<br>He kept running.")
      end

      it "only exports the current user's entries" do
        create(:vocab_entry, user: user, book: book, word: "mine", lemma: "mine")
        other_user = create(:user, email_address: "other@example.com")
        create(:vocab_entry, user: other_user, book: book, word: "theirs", lemma: "theirs")

        get export_vocab_entries_path(format: "csv")

        expect(response.body).to include("mine")
        expect(response.body).not_to include("theirs")
      end
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
