# Dictionary/Wiktionary-style word lookup for the in-browser reader
# (session auth). Response shape is load-bearing for the reader popup UI:
# { word:, lemma:, lang:, entries: [{ pos:, glosses: [] }] } on 200.
class LookupsController < ApplicationController
  def show
    word = params[:word].to_s.strip
    return render json: { error: "word required" }, status: :unprocessable_content if word.blank?

    lang = Dictionary::SUPPORTED_LANGS.include?(params[:lang]) ? params[:lang] : "en"
    result = Dictionary.lookup(word, lang: lang)
    return render json: { error: "not_found", word: word }, status: :not_found if result.nil?

    render json: result
  end
end
