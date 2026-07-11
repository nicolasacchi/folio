# Web-side queue management: "Send to Kindle" buttons on the book page.
class DeliveriesController < ApplicationController
  def create
    book = Book.find(params[:book_id])
    device = Device.find(params[:device_id])

    delivery = Delivery.find_or_create_by!(book: book, device: device)
    # Re-sending a book that was previously removed (or queued for
    # removal) re-arms the existing row.
    requeued = delivery.removed? || delivery.evict_requested?
    delivery.reactivate! if requeued
    # A queued book with no Kindle-readable file gets one converted now;
    # one with a file gets its delivery copy built (cover + PDOC identity).
    if book.kindle_file
      PrepareKindleFileJob.perform_later(book.id)
    else
      EnsureKindleFormatJob.perform_later(book.id)
    end

    redirect_back fallback_location: book_path(book),
      notice: delivery.previously_new_record? || requeued ? "Queued for #{device.name}." : "Already queued for #{device.name}."
  end

  def destroy
    delivery = Delivery.find(params[:id])
    delivery.destroy!
    redirect_back fallback_location: book_path(delivery.book),
      notice: "Removed from #{delivery.device.name}.", status: :see_other
  end
end
