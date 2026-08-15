# Web-side queue management: "Send to Kindle" buttons on the book page.
class DeliveriesController < ApplicationController
  def create
    book = Book.find(params[:book_id])
    device = resolve_device
    unless device
      return redirect_back fallback_location: book_path(book),
        alert: "No Kindle selected. Pick a device or set a preferred Kindle on the Devices page."
    end

    delivery = Delivery.find_or_create_by!(book: book, device: device)
    # ?raw=1 asks for the untouched scan instead of the OCR companion, ?raw=0
    # explicitly asks back for it (see BookFile#delivery_path) — the param
    # has to be genuinely absent (not just falsy) to leave an existing
    # delivery's own choice alone, or a plain re-send click (no raw param
    # at all) would quietly reset an already-raw delivery to false. A fresh
    # delivery already defaults to raw: false via the column default.
    if params[:raw].present?
      requested_raw = ActiveModel::Type::Boolean.new.cast(params[:raw])
      delivery.update!(raw: requested_raw) if delivery.raw != requested_raw
    end
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

  private

  def resolve_device
    if params[:device_id].present?
      Device.physical.find_by(id: params[:device_id])
    else
      Current.user.preferred_kindle
    end
  end
end
