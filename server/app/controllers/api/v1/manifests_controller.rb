class Api::V1::ManifestsController < Api::V1::BaseController
  # The device manifest lists one deliverable (Kindle-ready) file per book
  # queued for this device (see Delivery), plus enough reading-state info
  # for the daemon to sync sidecars without extra round-trips.
  #
  # v3 additions (all ignored by older daemons):
  #   items[].thumbnail — Library cover for /mnt/us/system/thumbnails
  #   removals[]        — evictions the daemon should perform and ack
  #   status_url        — where to POST device telemetry after each pass
  def show
    deliveries = current_device.deliveries.active.where(evict_requested_at: nil)
      .includes(book: [ :book_files, :reading_states ])
    books = deliveries.map(&:book).sort_by { |book| book.title.to_s.downcase }
    deliveries_by_book = deliveries.index_by(&:book_id)

    items = books.filter_map do |book|
      file = book.kindle_file
      next unless file

      # A missing/stale delivery copy heals itself: serve the raw file now,
      # rebuild in the background; the sha change re-delivers next poll.
      PrepareKindleFileJob.perform_later(book.id) if file.needs_preparation?

      # This device's own variant choice (Delivery#variant) — passed into
      # delivery_format/filename/size/sha256 so a variant switch alone
      # changes the sha and re-triggers a re-fetch next poll.
      variant = deliveries_by_book.fetch(book.id).variant

      {
        id: book.public_id,
        title: book.title,
        author: book.author,
        series: book.series,
        format: file.delivery_format(variant: variant),
        filename: file.delivery_filename(variant: variant),
        size: file.delivery_size(variant: variant),
        sha256: file.delivery_sha256(variant: variant),
        url: api_v1_book_file_path(public_id: book.public_id, fmt: file.format),
        thumbnail: thumbnail_summary(book, file),
        reading_state: reading_state_summary(book)
      }
    end

    render json: {
      version: 3,
      generated_at: Time.current.to_i,
      items: items,
      removals: removals,
      status_url: api_v1_device_status_path,
      clippings_url: api_v1_clippings_path,
      device_settings: current_device.manifest_settings
    }
  end

  private

  def reading_state_summary(book)
    state = book.reading_states.max_by(&:content_mtime)
    return nil unless state

    {
      mtime: state.content_mtime.to_i,
      sha256: state.sha256,
      size: state.size,
      device_id: state.device_id,
      url: api_v1_book_reading_state_path(public_id: book.public_id)
    }
  end

  # Firmware only shows Library covers for sideloaded EBOK files when a
  # thumbnail named after the file's EXTH ASIN sits in the thumbnail cache
  # (it never auto-generates them for EBOK like it does for PDOC). PDOC
  # thumbnails are named after a device-local uuid we can't know, so those
  # rely on the firmware's own generation.
  def thumbnail_summary(book, file)
    return nil unless book.cover?

    identity = file.cde_identity
    return nil if identity[:asin].blank? || identity[:cde_type] != "EBOK"

    filename = Library::Thumbnails.kindle_filename(identity[:asin], identity[:cde_type])
    return nil unless filename

    { url: api_v1_book_thumbnail_path(public_id: book.public_id), filename: filename }
  end

  def removals
    current_device.deliveries.evict_requested.includes(book: :book_files).filter_map do |delivery|
      book = delivery.book
      file = book.kindle_file
      next unless file

      identity = file.cde_identity
      thumbnail = identity[:asin].present? ? Library::Thumbnails.kindle_filename(identity[:asin], identity[:cde_type]) : nil
      {
        id: book.public_id,
        delivery_id: delivery.id,
        filename: file.delivery_filename(variant: delivery.variant),
        thumbnail_filename: thumbnail,
        reason: delivery.evict_reason,
        ack_url: api_v1_ack_removal_path(delivery)
      }
    end
  end
end
