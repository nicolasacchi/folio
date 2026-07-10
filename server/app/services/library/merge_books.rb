# Folds one book into another (duplicate resolution). Non-conflicting
# formats move over — managed files are physically moved under the target's
# directory, external (scanned) ones just re-point — and the source book is
# destroyed once nothing is left on it.
class Library::MergeBooks
  def self.call(source, target)
    raise ArgumentError, "cannot merge a book into itself" if source.id == target.id

    moved = []
    source.book_files.each do |file|
      next if target.file_for(file.format)

      if file.external?
        file.update!(book_id: target.id)
      else
        destination = Library.file_path(target, file.format)
        FileUtils.mkdir_p(destination.dirname)
        FileUtils.mv(file.absolute_path, destination)
        file.update!(book_id: target.id, path: destination.relative_path_from(Library.root).to_s)
      end
      moved << file.format
    end

    if !target.cover? && source.cover?
      FileUtils.mkdir_p(Library.covers_root)
      FileUtils.cp(source.cover_path, target.cover_path)
    end

    source.reload
    source.destroy! if source.book_files.none?
    BookSearch.index_book!(target)
    moved
  end
end
