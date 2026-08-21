require "rails_helper"

RSpec.describe "Book text-only companion build", type: :request do
  let!(:user) { create(:user) }

  before do
    post session_path, params: { email_address: user.email_address, password: "password" }
  end

  describe "POST /books/:id/build_text" do
    it "queues TextCompanionJob for a book whose kindle_file is a pdf" do
      book = create(:book)
      create(:book_file, book: book, format: "pdf")

      expect { post build_text_book_path(book) }.to have_enqueued_job(TextCompanionJob)

      expect(response).to redirect_to(book_path(book))
      expect(flash[:notice]).to match(/Building/i)
      expect(book.conversions.where(kind: "text")).to be_exists
    end

    it "does not duplicate an already-active build" do
      book = create(:book)
      pdf = create(:book_file, book: book, format: "pdf")
      create(:conversion, :text, book: book, book_file: pdf, status: "running")

      expect { post build_text_book_path(book) }.not_to have_enqueued_job(TextCompanionJob)
      expect(response).to redirect_to(book_path(book))
    end

    it "alerts instead of queueing when the book has no pdf to build from" do
      book = create(:book)
      create(:book_file, book: book, format: "epub")

      expect { post build_text_book_path(book) }.not_to have_enqueued_job(TextCompanionJob)

      expect(response).to redirect_to(book_path(book))
      expect(flash[:alert]).to match(/No scanned PDF/i)
    end

    it "alerts when a richer Kindle format already exists (pdf isn't the kindle_file)" do
      book = create(:book)
      create(:book_file, book: book, format: "pdf")
      create(:book_file, book: book, format: "azw3")

      expect { post build_text_book_path(book) }.not_to have_enqueued_job(TextCompanionJob)
      expect(flash[:alert]).to match(/No scanned PDF/i)
    end

    it "notices (rather than claiming a build just started) when the text companion is already usable" do
      book = create(:book)
      pdf = create(:book_file, book: book, format: "pdf")

      text_relative = "text/#{book.public_id}.txt"
      FileUtils.mkdir_p(Library.base_root.join(text_relative).dirname)
      File.write(Library.base_root.join(text_relative), "plain text companion")

      kindle_relative = "text/#{book.public_id}.azw3"
      FileUtils.mkdir_p(Library.base_root.join(kindle_relative).dirname)
      File.write(Library.base_root.join(kindle_relative), "azw3 bytes")

      pdf.update!(
        text_path: text_relative, text_source_sha256: pdf.sha256,
        text_kindle_path: kindle_relative
      )
      expect(pdf).to be_text_kindle_usable

      expect { post build_text_book_path(book) }.not_to have_enqueued_job(TextCompanionJob)

      expect(response).to redirect_to(book_path(book))
      expect(flash[:notice]).to match(/already built/i)
    end
  end

  describe "POST /books/:id/build_text?engine=deep" do
    it "queues a deep-OCR rebuild even when the text-companion AZW3 is already usable" do
      book = create(:book)
      pdf = create(:book_file, :on_disk, book: book, format: "pdf")

      text_relative = "text/#{book.public_id}.txt"
      FileUtils.mkdir_p(Library.base_root.join(text_relative).dirname)
      File.write(Library.base_root.join(text_relative), "plain text companion")

      kindle_relative = "text/#{book.public_id}.azw3"
      FileUtils.mkdir_p(Library.base_root.join(kindle_relative).dirname)
      File.write(Library.base_root.join(kindle_relative), "azw3 bytes")

      pdf.update!(
        text_path: text_relative, text_source_sha256: pdf.sha256,
        text_kindle_path: kindle_relative
      )
      expect(pdf).to be_text_kindle_usable

      expect { post build_text_book_path(book), params: { engine: "deep" } }
        .to have_enqueued_job(TextCompanionJob).with { |_id, engine| engine == "deep" }

      expect(response).to redirect_to(book_path(book))
      expect(flash[:notice]).to match(/deep OCR/i)
      expect(flash[:notice]).to match(/original scan/i)
    end

    it "notices that a build is already running instead of claiming a fresh rebuild just started" do
      book = create(:book)
      pdf = create(:book_file, book: book, format: "pdf")
      create(:conversion, :text, book: book, book_file: pdf, status: "running")

      expect { post build_text_book_path(book), params: { engine: "deep" } }
        .not_to have_enqueued_job(TextCompanionJob)

      expect(response).to redirect_to(book_path(book))
      expect(flash[:notice]).to match(/already running/i)
    end

    it "alerts (never queues) when the book has no pdf to build from, same as the layer path" do
      book = create(:book)
      create(:book_file, book: book, format: "epub")

      expect { post build_text_book_path(book), params: { engine: "deep" } }
        .not_to have_enqueued_job(TextCompanionJob)

      expect(flash[:alert]).to match(/No scanned PDF/i)
    end

    it "treats an unrecognized engine value as the default 'layer' path" do
      book = create(:book)
      create(:book_file, book: book, format: "pdf")

      expect { post build_text_book_path(book), params: { engine: "bogus" } }
        .to have_enqueued_job(TextCompanionJob).with { |_id, engine| engine == "layer" }

      expect(flash[:notice]).to match(/Building/i)
    end
  end
end
