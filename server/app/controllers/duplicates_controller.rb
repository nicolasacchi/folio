# Komga-style duplicate handling. Exact duplicates (same sha256) never
# enter the library twice — the scanner and uploads skip them — so what's
# left are different editions of the same work: same normalized
# title+author, different files. This page surfaces those groups and lets
# them be merged onto one book.
class DuplicatesController < ApplicationController
  PER_PAGE = 40
  SORTS = %w[title size].freeze

  def index
    @sort = SORTS.include?(params[:sort]) ? params[:sort] : "title"
    @conflicts_only = params[:conflicts] == "1"

    tuples = Library::DuplicateGroups.tuples
    # Loaded once for every duplicate book (never the whole catalog — see
    # Library::DuplicateGroups.tuples), so sorting/filtering below never
    # N+1s even though it looks at every group, not just the current page.
    books = Book.includes(:book_files).where(id: tuples.flatten(1).map(&:first)).index_by(&:id)
    groups = tuples.map { |rows| rows.map { |id, _, _| books[id] }.compact }
                   .select { |group| group.size > 1 }

    # Whether the catalog has any duplicate groups at all, regardless of
    # the filter below — distinguishes "nothing to merge" from "nothing
    # matches this filter" in the view.
    @has_duplicates = groups.any?

    groups = groups.select { |group| format_conflict?(group) } if @conflicts_only
    groups = groups.sort_by { |group| -group.size } if @sort == "size"
    # Default order is already by title (Library::DuplicateGroups.tuples).

    @total_groups = groups.size
    @page = [ params[:page].to_i, 1 ].max
    @last_page = [ (@total_groups / PER_PAGE.to_f).ceil, 1 ].max
    @page = @last_page if @page > @last_page
    @groups = (groups[(@page - 1) * PER_PAGE, PER_PAGE] || []).map { |group| group.sort_by(&:created_at) }
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
    Library::DuplicateGroups.normalize(value)
  end

  # A group "conflicts" when some format shows up on more than one of its
  # editions — those copies won't move during a merge (Library::MergeBooks
  # leaves them where they are rather than overwriting or deleting a
  # managed file), so this is the set worth reviewing by hand first.
  # Reads off the group's already-preloaded book_files, never queries.
  def format_conflict?(group)
    formats = group.flat_map { |book| book.book_files.map(&:format) }
    formats.uniq.size != formats.size
  end
end
