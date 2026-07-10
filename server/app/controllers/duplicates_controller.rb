# Komga-style duplicate handling. Exact duplicates (same sha256) never
# enter the library twice — the scanner and uploads skip them — so what's
# left are different editions of the same work: same normalized
# title+author, different files. This page surfaces those groups and lets
# them be merged onto one book.
class DuplicatesController < ApplicationController
  def index
    tuples = Book.pluck(:id, :title, :author)
    grouped = tuples.group_by { |_, title, author| [ normalize(title), normalize(author) ] }
                    .values
                    .select { |rows| rows.size > 1 }

    books = Book.includes(:book_files).where(id: grouped.flatten(1).map(&:first)).index_by(&:id)
    @groups = grouped.map { |rows| rows.map { |id, _, _| books[id] }.compact.sort_by(&:created_at) }
                     .select { |group| group.size > 1 }
                     .sort_by { |group| normalize(group.first.title) }
  end

  def merge
    target = Book.find(params[:target_id])
    sources = Book.where(id: Array(params[:source_ids])).where.not(id: target.id)
    merged = sources.map { |source| Library::MergeBooks.call(source, target) }

    redirect_to duplicates_path,
                notice: "Merged #{helpers.pluralize(merged.size, 'book')} into “#{target.title}”."
  end

  private

  def normalize(value)
    value.to_s.strip.downcase.squeeze(" ")
  end
end
