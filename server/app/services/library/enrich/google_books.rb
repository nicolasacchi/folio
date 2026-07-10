# Google Books lookup (anonymous — throttled by Google per IP, so it runs
# as the fallback provider; Open Library takes the bulk).
module Library::Enrich::GoogleBooks
  SEARCH_URL = "https://www.googleapis.com/books/v1/volumes"

  module_function

  def key = "googlebooks"

  def lookup(title:, author:)
    terms = [ %(intitle:"#{title}") ]
    terms << %(inauthor:"#{author}") if author.present?
    body = Library::Enrich.get("#{SEARCH_URL}?#{URI.encode_www_form(q: terms.join(" "), maxResults: 5)}")
    return nil if body.nil?

    items = JSON.parse(body)["items"].to_a
    info = items.filter_map { |item| item["volumeInfo"] }.find do |candidate|
      Library::Enrich.plausible_match?(book_title: title, book_author: author,
                                       found_title: candidate["title"].to_s,
                                       found_authors: Array(candidate["authors"]))
    end
    return nil unless info

    year = info["publishedDate"].to_s[/\A\d{4}/]&.to_i
    cover = info.dig("imageLinks", "thumbnail")&.sub(/\Ahttp:/, "https:")
    {
      description: info["description"].to_s.strip.presence,
      published_year: year,
      cover_url: cover
    }.compact.presence
  rescue JSON::ParserError
    nil
  end
end
