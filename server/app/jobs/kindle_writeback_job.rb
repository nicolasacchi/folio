# Carries a web-reader ReaderPosition back onto the newest physical
# Kindle's .sdr bundle. Enqueued by ReaderController#update_position once
# it's decided write-back applies (see writeback_decision there); all the
# actual bundle rewriting lives in Reader::KindleWriteback.
#
# The position is anchored via Reader::Anchor: the saved `exact` snippet
# (plus its before/after context) is searched for in the book's own text
# stream to recover a raw byte offset Library::Krds can write as lpr/fpr.
class KindleWritebackJob < ApplicationJob
  queue_as :default

  # book/user rows can vanish between enqueue and perform (book deleted,
  # user removed) — nothing left to write back, just drop the job.
  discard_on ActiveRecord::RecordNotFound

  # Same source-format preference as ReaderController::ANCHOR_FORMATS —
  # only formats Reader::Anchor (via Library::Mobi.raw_text) can index.
  ANCHOR_FORMATS = %w[azw3 azw mobi prc].freeze

  def perform(book_id, user_id)
    book = Book.find(book_id)
    user = User.find(user_id)

    position = ReaderPosition.find_by(book: book, user: user)
    return if position.nil? || position.context.blank?

    exact = position.context["exact"]
    return if exact.blank?

    source = ANCHOR_FORMATS.filter_map { |format| book.file_for(format) }.find(&:available?)
    return log("no anchorable source file for book #{book.id}") unless source

    offset = locate(source, exact, position.context)
    return log("could not locate anchor for book #{book.id}") if offset.nil?
    return if unchanged?(book, offset)

    result = write_back(book, offset, user: user)
    log("book #{book.id} written=#{result.written} reason=#{result.reason || "ok"}")
  end

  private

  def locate(source, exact, context)
    Reader::Anchor.locate(source, exact, before: context["before"], after: context["after"])
  rescue Library::Mobi::Unsupported
    nil
  rescue StandardError => e
    # Belt-and-braces alongside Library::Mobi::Unsupported: a corrupt or
    # adversarial source file reaching this deep into the MOBI/PalmDOC/KRDS
    # parsers should degrade to "could not anchor" like every other
    # unparseable-book case here, not fail the background job outright —
    # mirrors ReaderController#kindle_snippet's rescue StandardError for the
    # same source-reading path on the request side.
    Rails.logger.warn("[reader-writeback] anchor failed for #{source.absolute_path}: #{e.class}: #{e.message}")
    nil
  end

  # Nothing to do if the web device's own last-written position already
  # matches — avoids rewriting the bundle (and bumping content_mtime) for
  # a position update that resolved to the same raw offset.
  def unchanged?(book, offset)
    web_state = ReadingState.find_by(book: book, device: Device.web_reader!)
    web_state&.last_position == offset
  end

  # basis_state pins the write to the physical state we're actually
  # rewriting from; if another sync landed a newer one while we were
  # locating the anchor, Reader::KindleWriteback reports :stale — refetch
  # and retry once against the now-current bundle rather than clobbering it.
  def write_back(book, offset, user: nil)
    basis = Reader::KindleWriteback.latest_physical_state(book, user: user)
    result = Reader::KindleWriteback.call(book: book, offset: offset, basis_state: basis, user: user)
    return result unless result.reason == :stale

    basis = Reader::KindleWriteback.latest_physical_state(book, user: user)
    Reader::KindleWriteback.call(book: book, offset: offset, basis_state: basis, user: user)
  end

  def log(message)
    Rails.logger.info("[reader-writeback] #{message}")
  end
end
