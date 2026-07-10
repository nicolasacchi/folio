# (Re)embeds one book's semantic vector after its metadata changes.
# Embedding is ~20ms of local CPU, so the default queue is fine.
class EmbedBookJob < ApplicationJob
  queue_as :default

  def perform(book_id)
    return unless Library::Embeddings.available?

    book = Book.find_by(id: book_id)
    return unless book

    Library::Embeddings.index_book!(book)
  end
end
