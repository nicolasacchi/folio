module BooksHelper
  # Stable hue for a book's generated cover, derived from its public id.
  def cover_hue(book)
    book.public_id.to_i(16) % 360
  end

  def conversion_stamp_class(conversion)
    case conversion.status
    when "completed" then "stamp stamp--ready"
    when "failed" then "stamp stamp--failed"
    else "stamp stamp--pending"
    end
  end

  def format_size(bytes)
    number_to_human_size(bytes, precision: 2)
  end
end
