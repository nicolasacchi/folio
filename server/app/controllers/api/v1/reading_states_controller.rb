# Reading-progress sync: the daemon uploads a tar.gz of the book's `.sdr`
# sidecar directory and downloads the newest bundle across devices
# (latest-modified-wins, as designed in the research notes).
class Api::V1::ReadingStatesController < Api::V1::BaseController
  MAX_BUNDLE_BYTES = 20.megabytes

  def show
    book = find_delivered_book! or return

    state = book.latest_reading_state
    if state.nil? || !File.exist?(state.absolute_path)
      return render json: { error: "no reading state" }, status: :not_found
    end

    response.headers["X-Sdr-Mtime"] = state.content_mtime.to_i.to_s
    response.headers["X-Sdr-Sha256"] = state.sha256
    response.headers["X-Sdr-Device-Id"] = state.device_id.to_s
    send_file state.absolute_path,
      filename: "#{book.public_id}.tar.gz",
      type: "application/gzip",
      disposition: "attachment"
  end

  def update
    book = find_delivered_book! or return

    mtime = request.headers["X-Sdr-Mtime"].to_i
    return render json: { error: "X-Sdr-Mtime header required" }, status: :unprocessable_content if mtime <= 0

    # Rewind in case a middleware (e.g. form parsing) already read the body.
    request.body.rewind if request.body.respond_to?(:rewind)
    body = request.body.read(MAX_BUNDLE_BYTES + 1) || "".b
    return render json: { error: "empty body" }, status: :unprocessable_content if body.empty?
    return render json: { error: "bundle too large" }, status: :content_too_large if body.bytesize > MAX_BUNDLE_BYTES

    path = Library.reading_state_path(book, current_device)
    FileUtils.mkdir_p(path.dirname)
    File.binwrite(path, body)

    state = book.reading_states.find_or_initialize_by(device: current_device)
    state.update!(
      path: path.relative_path_from(Library.reading_states_root).to_s,
      content_mtime: Time.zone.at(mtime),
      size: body.bytesize,
      sha256: Digest::SHA256.hexdigest(body)
    )
    ParseSidecarJob.perform_later(state.id)

    render json: { ok: true, mtime: state.content_mtime.to_i, sha256: state.sha256 }
  end
end
