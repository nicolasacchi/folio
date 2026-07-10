# Reading activity synced from the Kindle(s): one row per book, newest
# activity first, with per-device detail. Populated by the kindled
# daemon's .sdr bundle sync; empty until a device starts syncing.
class ReadingController < ApplicationController
  def index
    states = ReadingState.includes(:device, book: :book_files)
                         .order(content_mtime: :desc)
                         .limit(600)
    @by_book = states.group_by(&:book).first(200)
  end
end
