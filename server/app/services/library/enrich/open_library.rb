# Open Library lookup: search by title/author, then fetch the work record
# for its description. No API key; their guidance is ~1 req/s for bulk
# use, which the single-threaded enrichment queue enforces.
module Library::Enrich::OpenLibrary
  SEARCH_URL = "https://openlibrary.org/search.json"

  module_function

  def key = "openlibrary"

  def lookup(title:, author:)
    query = { title: title.to_s, limit: 5, fields: "title,author_name,first_publish_year,cover_i,key" }
    query[:author] = author if author.present?
    body = Library::Enrich.get("#{SEARCH_URL}?#{URI.encode_www_form(query)}")
    return nil if body.nil?

    docs = JSON.parse(body)["docs"].to_a
    doc = docs.find do |candidate|
      Library::Enrich.plausible_match?(book_title: title, book_author: author,
                                       found_title: candidate["title"].to_s,
                                       found_authors: Array(candidate["author_name"]))
    end
    return nil unless doc

    {
      description: work_description(doc["key"]),
      published_year: doc["first_publish_year"],
      cover_url: doc["cover_i"] ? "https://covers.openlibrary.org/b/id/#{doc['cover_i']}-L.jpg" : nil
    }.compact.presence
  rescue JSON::ParserError
    nil
  end

  def work_description(work_key)
    return nil unless work_key.to_s.start_with?("/works/")

    body = Library::Enrich.get("https://openlibrary.org#{work_key}.json")
    return nil if body.nil?

    description = JSON.parse(body)["description"]
    text = description.is_a?(Hash) ? description["value"] : description
    text.to_s.strip.presence
  rescue JSON::ParserError
    nil
  end
end
