# Kindle Library thumbnail for a book, rendered from its cover. The
# daemon drops it into /mnt/us/system/thumbnails under the EXTH-derived
# filename from the manifest.
class Api::V1::ThumbnailsController < Api::V1::BaseController
  def show
    book = find_delivered_book! or return

    thumb = Library::Thumbnails.ensure(book)
    return render json: { error: "no cover" }, status: :not_found unless thumb

    send_file thumb, type: "image/jpeg", disposition: "inline"
  end
end
