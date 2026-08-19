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
    # ?variant=original/text/auto (or legacy ?raw=1/0) picks this
    # delivery's variant (see BookFile#delivery_path) — the param has to
    # be genuinely absent (not just falsy/unrecognized) to leave an
    # existing delivery's own choice alone, or a plain re-send click (no
    # variant param at all) would quietly reset it back to "auto". A
    # fresh delivery already defaults to "auto" via the column default.
    # Re-sending a book that was previously removed (or queued for
    # removal) re-arms the existing row. Computed before the variant-
    # handling block below (and before `reactivate!` clears these
    # columns), since `variant_switched` needs to know whether this is
    # really a fresh queue rather than a change to something already in
    # flight.
    requeued = delivery.removed? || delivery.evict_requested?
    variant_switched = false
    requested = requested_variant
    if requested && delivery.variant != requested
      delivery.update!(variant: requested)
      # Only a "switch" of an already-queued/delivered copy — a variant
      # choice made on the same request that created (or re-arms) the row
      # is just how that send was queued (see the flash message below),
      # not a change to something already in flight.
      variant_switched = !fresh_delivery && !requeued
    end
    delivery.reactivate! if requeued
    # variant "text" needs its own build: the AZW3 companion isn't a real
    # book_files row a normal conversion produces (see
    # Book#queue_text_companion!) — a no-op once it's already usable or a
    # build is already queued.
    book.queue_text_companion! if delivery.variant == "text"
    # A queued book with no Kindle-readable file gets one converted now;
    # one with a file gets its delivery copy built (cover + PDOC identity).
    if book.kindle_file
      PrepareKindleFileJob.perform_later(book.id)
    else
      EnsureKindleFormatJob.perform_later(book.id)
    end

    redirect_back fallback_location: book_path(book),
      notice: delivery_notice(book, device, delivery, fresh_delivery || requeued, variant_switched)
  end

  def destroy
    delivery = Delivery.find(params[:id])
    delivery.destroy!
    redirect_back fallback_location: book_path(delivery.book),
      notice: "Removed from #{delivery.device.name}.", status: :see_other
  end

  private

  # params[:variant] (one of Delivery::VARIANTS) wins when present; else
  # the legacy ?raw=1/0 the "original"/"text layer" toggle used before
  # variants existed maps onto "original"/"auto". nil means "leave this
  # delivery's variant alone" (see the caller).
  def requested_variant
    return params[:variant] if Delivery::VARIANTS.include?(params[:variant].to_s)
    return nil unless params[:raw].present?

    ActiveModel::Type::Boolean.new.cast(params[:raw]) ? "original" : "auto"
  end

  # Names the variant whenever there's actually one worth naming (see
  # BookFile#delivery_path): "text" always is (it's a distinct feature);
  # "original" vs "auto" ("text layer") only differ from each other once
  # the book actually has a fresh OCR companion to bypass — with no
  # companion, every variant delivers the same file, so books with no OCR
  # companion keep the plain "Queued"/"Already queued" wording this
  # always had.
  def delivery_notice(book, device, delivery, queued, variant_switched)
    ocr_original = book.kindle_file&.ocr_fresh?
    variant = delivery.variant
    labeled = variant == "text" || ocr_original

    if variant_switched && labeled
      "Switched #{device.name} to the #{variant_label(variant, switched: true)} — it will re-deliver."
    elsif queued
      labeled ? "Queued for #{device.name} (#{variant_label(variant, switched: false)})." : "Queued for #{device.name}."
    else
      "Already queued for #{device.name}."
    end
  end

  def variant_label(variant, switched:)
    case variant
    when "text" then switched ? "text-only version" : "text only"
    when "original" then "original scan"
    else "text layer"
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
