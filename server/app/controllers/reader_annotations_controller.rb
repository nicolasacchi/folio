# Highlights/notes/bookmarks for the in-browser reader (session auth).
#
# Every row lives in the shared `annotations` table alongside the ones
# `Library::Clippings` imports from a physical Kindle's "My Clippings.txt"
# (source "clippings"). This controller only ever creates/mutates rows with
# source "web", attributed to the single synthetic Device.web_reader! — see
# that method for why. Clippings-sourced rows are read-only here except for
# `locate`, which lets the frontend cache a client-resolved CFI onto them
# (clippings only carry Kindle locations/pages, not CFIs) without touching
# anything else about the row.
class ReaderAnnotationsController < ApplicationController
  before_action :set_book
  before_action :set_annotation, only: %i[update destroy locate]

  def index
    annotations = @book.annotations.readable.includes(:device)
      .order(Arel.sql("location_start IS NULL, location_start ASC, added_at ASC"))

    render json: annotations.map { |annotation| annotation_json(annotation) }
  end

  def create
    cfi = create_params[:cfi].presence
    if cfi.blank?
      return render json: { errors: [ "cfi can't be blank" ] }, status: :unprocessable_content
    end

    device = Device.web_reader!
    fingerprint = web_fingerprint(kind: create_params[:kind], cfi: cfi)

    existing = Annotation.find_by(device: device, fingerprint: fingerprint)
    return render json: annotation_json(existing), status: :ok if existing

    annotation = Annotation.new(
      book: @book,
      device: device,
      source: "web",
      kind: create_params[:kind],
      cfi: cfi,
      content: create_params[:content],
      note: create_params[:note],
      color: create_params[:color],
      added_at: Time.current,
      fingerprint: fingerprint,
      raw_title: @book.title,
      raw_author: @book.author
    )

    if annotation.save
      render json: annotation_json(annotation), status: :created
    else
      render json: { errors: annotation.errors.full_messages }, status: :unprocessable_content
    end
  rescue ActiveRecord::RecordNotUnique
    # Concurrent create of the same cfi+kind — someone else just won the
    # race to insert it; hand back the row that landed.
    render json: annotation_json(Annotation.find_by(device: device, fingerprint: fingerprint)), status: :ok
  end

  def update
    return head :forbidden unless @annotation.source == "web"

    if @annotation.update(update_params)
      render json: annotation_json(@annotation), status: :ok
    else
      render json: { errors: @annotation.errors.full_messages }, status: :unprocessable_content
    end
  end

  def destroy
    return head :forbidden unless @annotation.source == "web"

    @annotation.destroy!
    head :no_content
  end

  # Any source — this is how a Kindle clipping (no CFI of its own) picks up
  # a CFI the frontend resolved by locating the clipping's snippet in the
  # book text. Never overwrites an already-resolved CFI unless force=true.
  def locate
    cfi = locate_params[:cfi].presence
    force = ActiveModel::Type::Boolean.new.cast(params[:force])

    @annotation.update!(cfi: cfi) if cfi && (@annotation.cfi.blank? || force)

    render json: annotation_json(@annotation), status: :ok
  end

  private

  def set_book
    @book = Book.find(params[:id])
  end

  def set_annotation
    @annotation = @book.annotations.find(params[:annotation_id])
  end

  def create_params
    params.permit(:kind, :cfi, :content, :note, :color)
  end

  def update_params
    params.permit(:color, :note)
  end

  def locate_params
    params.permit(:cfi)
  end

  def web_fingerprint(kind:, cfi:)
    Digest::SHA256.hexdigest("web:#{@book.id}:#{kind}:#{cfi}")
  end

  def annotation_json(annotation)
    {
      id: annotation.id,
      kind: annotation.kind,
      source: annotation.source,
      content: annotation.content,
      note: annotation.note,
      color: annotation.color,
      cfi: annotation.cfi,
      location_start: annotation.location_start,
      location_end: annotation.location_end,
      page: annotation.page,
      device_name: annotation.device.name,
      added_at: annotation.added_at
    }
  end
end
