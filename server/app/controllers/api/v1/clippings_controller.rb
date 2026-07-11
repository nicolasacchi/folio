# Accepts the device's whole "My Clippings.txt" (the daemon uploads it
# whenever its hash changes). Kept raw on disk for reprocessing, parsed
# into Annotation rows synchronously (the file is small).
class Api::V1::ClippingsController < Api::V1::BaseController
  MAX_SIZE = 10.megabytes

  def update
    body = request.body.read(MAX_SIZE + 1) || ""
    return render json: { error: "clippings too large" }, status: :content_too_large if body.bytesize > MAX_SIZE

    persist_raw(body)
    stats = Library::Clippings.import(current_device, body)

    render json: { ok: true }.merge(stats)
  end

  private

  def persist_raw(body)
    dir = Library.base_root.join("clippings")
    FileUtils.mkdir_p(dir)
    File.binwrite(dir.join("device-#{current_device.id}.txt"), body)
  end
end
