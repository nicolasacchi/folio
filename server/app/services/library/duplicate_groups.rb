# Groups books that look like different editions of the same work: same
# normalized title + author, different files (exact copies are already
# blocked at ingest by sha256). Shared by the Duplicates page and the
# merge-all catalog operation.
module Library::DuplicateGroups
  module_function

  def normalize(value)
    value.to_s.strip.downcase.squeeze(" ")
  end

  # Returns arrays of [id, title, author] tuples, one array per group,
  # sorted by normalized title.
  def tuples
    Book.pluck(:id, :title, :author)
        .group_by { |_, title, author| [ normalize(title), normalize(author) ] }
        .values
        .select { |rows| rows.size > 1 }
        .sort_by { |rows| normalize(rows.first[1]) }
  end

  def count
    tuples.size
  end

  # The edition all others in the group merge into: most formats first,
  # then having a cover, then the earliest-added (stable ids win ties).
  def merge_target(books)
    books.min_by { |book| [ -book.book_files.size, book.cover? ? 0 : 1, book.created_at, book.id ] }
  end
end
