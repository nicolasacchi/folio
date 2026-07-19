module Kosync
  class SyncsController < Kosync::BaseController
    # PUT /kosync/syncs/progress — unconditional last-write-wins upsert of
    # the single progress row for (credential, document). Stamps the
    # server's own clock as `synced_at`; the client never sends a
    # timestamp on PUT, so there's nothing to compare against (see
    # KosyncProgress for why this never does compare-and-swap).
    def update
      document = params[:document].to_s
      progress = params[:progress]
      percentage = params[:percentage]
      device = params[:device]

      return render_kosync_error(:forbidden, 2004, "Field 'document' not provided.") if document.blank?
      if progress.blank? || percentage.blank? || device.blank?
        return render_kosync_error(:forbidden, 2003, "Invalid request")
      end

      record = current_kosync_credential.kosync_progresses.find_or_initialize_by(document: document)
      record.assign_attributes(
        progress: progress.to_s,
        percentage: percentage,
        device: device,
        device_id: params[:device_id],
        metadata: params[:metadata]
      )
      record.synced_at = Time.now.to_i

      if record.save
        render json: { document: record.document, timestamp: record.synced_at }
      else
        render_kosync_error(:forbidden, 2003, "Invalid request")
      end
    end

    # GET /kosync/syncs/progress/:document — `{}` (HTTP 200, not 404) when
    # this credential has never synced this document: KOReader's client
    # treats a response body missing `percentage` as "no progress found"
    # (main.lua getProgress), so a 404 here would just be a wire-format
    # KOReader doesn't expect and can't parse the same way.
    def show
      document = params[:document].to_s
      return render_kosync_error(:forbidden, 2004, "Field 'document' not provided.") if document.blank?

      record = current_kosync_credential.kosync_progresses.find_by(document: document)
      return render json: {} unless record

      render json: {
        document: record.document,
        percentage: record.percentage,
        progress: record.progress,
        device: record.device,
        device_id: record.device_id,
        timestamp: record.synced_at
      }
    end
  end
end
