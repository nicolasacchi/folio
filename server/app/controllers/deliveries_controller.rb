# Web-side queue management: "Send to Kindle" buttons on the book page.
class DeliveriesController < ApplicationController
  def create
    book = Book.find(params[:book_id])
    device = Device.find(params[:device_id])

    delivery = Delivery.find_or_create_by!(book: book, device: device)
    # A queued book with no Kindle-readable file gets one converted now.
    EnsureKindleFormatJob.perform_later(book.id) unless book.kindle_file

    redirect_back fallback_location: book_path(book),
      notice: delivery.previously_new_record? ? "Queued for #{device.name}." : "Already queued for #{device.name}."
  end

  def destroy
    delivery = Delivery.find(params[:id])
    delivery.destroy!
    redirect_back fallback_location: book_path(delivery.book),
      notice: "Removed from #{delivery.device.name}.", status: :see_other
  end
end
