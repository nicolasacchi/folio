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
    # Captured now, before any further save on `delivery` below — AR's
    # own previously_new_record? tracks only the *most recent* save, so
    # the update!/reactivate! calls further down would otherwise reset it
    # to false even for a delivery that was, in fact, just created here.
    fresh_delivery = delivery.previously_new_record?
    # ?raw=1 asks for the untouched scan instead of the OCR companion, ?raw=0
    # explicitly asks back for it (see BookFile#delivery_path) — the param
    # has to be genuinely absent (not just falsy) to leave an existing
    # delivery's own choice alone, or a plain re-send click (no raw param
    # at all) would quietly reset an already-raw delivery to false. A fresh
    # delivery already defaults to raw: false via the column default.
    # Re-sending a book that was previously removed (or queued for
    # removal) re-arms the existing row. Computed before the raw-handling
    # block below (and before `reactivate!` clears these columns), since
    # `raw_switched` needs to know whether this is really a fresh queue
    # rather than a change to something already in flight.
    requeued = delivery.removed? || delivery.evict_requested?
    raw_switched = false
    if params[:raw].present?
      requested_raw = ActiveModel::Type::Boolean.new.cast(params[:raw])
      if delivery.raw != requested_raw
        delivery.update!(raw: requested_raw)
        # Only a "switch" of an already-queued/delivered copy — a raw
        # choice made on the same request that created (or re-arms) the
        # row is just how that send was queued (see the flash message
        # below), not a change to something already in flight.
        raw_switched = !fresh_delivery && !requeued
      end
    end
    delivery.reactivate! if requeued
    # A queued book with no Kindle-readable file gets one converted now;
    # one with a file gets its delivery copy built (cover + PDOC identity).
    if book.kindle_file
      PrepareKindleFileJob.perform_later(book.id)
    else
      EnsureKindleFormatJob.perform_later(book.id)
    end

    redirect_back fallback_location: book_path(book),
      notice: delivery_notice(book, device, delivery, fresh_delivery || requeued, raw_switched)
  end

  def destroy
    delivery = Delivery.find(params[:id])
    delivery.destroy!
    redirect_back fallback_location: book_path(delivery.book),
      notice: "Removed from #{delivery.device.name}.", status: :see_other
  end

  private

  # Names the OCR/raw variant whenever there's actually one to name (see
  # BookFile#delivery_path) — books with no fresh OCR companion keep the
  # plain "Queued"/"Already queued" wording this always had.
  def delivery_notice(book, device, delivery, queued, raw_switched)
    ocr_original = book.kindle_file&.ocr_fresh?
    variant = delivery.raw ? "original scan" : "text layer"

    if raw_switched && ocr_original
      "Switched #{device.name} to the #{variant} — it will re-deliver."
    elsif queued
      ocr_original ? "Queued for #{device.name} (#{variant})." : "Queued for #{device.name}."
    else
      "Already queued for #{device.name}."
    end
  end

  def resolve_device
    if params[:device_id].present?
      Device.physical.find_by(id: params[:device_id])
    else
      Current.user.preferred_kindle
    end
  end
end
