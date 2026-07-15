require "rails_helper"
require "open3"

RSpec.describe "Word lookup", type: :request do
  db_path = Rails.root.join("tmp", "lookups_spec_dictionary.sqlite3")
  script = Rails.root.join("script", "build_dictionary.rb")
  fixtures = Rails.root.join("spec", "fixtures", "dictionary")

  before(:context) do
    [ db_path, "#{db_path}-wal", "#{db_path}-shm" ].each { |f| FileUtils.rm_f(f) }

    %w[en it].each do |lang|
      output, status = Open3.capture2e(
        { "RAILS_ENV" => "test" },
        "ruby", script.to_s,
        "--lang", lang,
        "--input", fixtures.join("sample-#{lang}.jsonl").to_s,
        "--db", db_path.to_s
      )
      raise "build_dictionary.rb failed for #{lang}:\n#{output}" unless status.success?
    end

    ENV["DICTIONARY_DB"] = db_path.to_s
    Dictionary.reset!
  end

  after(:context) do
    ENV.delete("DICTIONARY_DB")
    Dictionary.reset!
    [ db_path, "#{db_path}-wal", "#{db_path}-shm" ].each { |f| FileUtils.rm_f(f) }
  end

  it "redirects unauthenticated requests to sign in" do
    get lookup_path(word: "mouse")
    expect(response).to redirect_to(new_session_path)
  end

  context "signed in" do
    let!(:user) { create(:user) }

    before { post session_path, params: { email_address: user.email_address, password: "password" } }

    it "returns the exact response shape on a hit" do
      get lookup_path(word: "mouse")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "word" => "mouse",
        "lemma" => "mouse",
        "lang" => "en",
        "entries" => [
          { "pos" => "noun", "glosses" => [ "a shy person", "a computer pointing device", "a small rodent with a long tail" ] }
        ]
      )
    end

    it "resolves through the suffix fallback chain like the model does" do
      get lookup_path(word: "running")
      expect(response.parsed_body["lemma"]).to eq("run")
    end

    it "defaults to English" do
      get lookup_path(word: "mouse")
      expect(response.parsed_body["lang"]).to eq("en")
    end

    it "looks up Italian when lang=it" do
      get lookup_path(word: "libri", lang: "it")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["lang"]).to eq("it")
      expect(response.parsed_body["lemma"]).to eq("libro")
    end

    it "falls back to English for an unsupported lang instead of raising" do
      get lookup_path(word: "mouse", lang: "fr")

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["lang"]).to eq("en")
    end

    it "returns 404 with the word echoed back when nothing resolves" do
      get lookup_path(word: "notaword")

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("error" => "not_found", "word" => "notaword")
    end

    it "returns 422 for a blank word" do
      get lookup_path(word: "   ")
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 422 when word is missing entirely" do
      get lookup_path
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
