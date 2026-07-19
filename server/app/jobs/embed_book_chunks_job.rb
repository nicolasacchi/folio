# (Re)embeds one book's chunk-level vectors (see Library::Embeddings) after
# its extracted fulltext changes. Chunking + embedding up to
# MAX_CHUNKS_PER_BOOK windows is much heavier than EmbedBookJob's single
# metadata vector (~20ms), so this runs on the same low-priority :indexing
# queue as Calibre text extraction rather than :default — a catalog-wide
# run must never compete with device-API-adjacent jobs.
class EmbedBookChunksJob < ApplicationJob
  queue_as :indexing

  def perform(book_id)
    return unless Library::Embeddings.available?

    book = Book.find_by(id: book_id)
    return unless book

    Library::Embeddings.index_book_chunks!(book)
  end
end
