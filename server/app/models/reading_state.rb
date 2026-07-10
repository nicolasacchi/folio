# One `.sdr` sidecar bundle (tar.gz) per book per device. The newest
# +content_mtime+ across devices wins when another Kindle asks for state.
class ReadingState < ApplicationRecord
  belongs_to :book
  belongs_to :device

  validates :path, presence: true
  validates :content_mtime, presence: true
  validates :sha256, presence: true
  validates :size, presence: true
  validates :device_id, uniqueness: { scope: :book_id }

  after_destroy :remove_from_disk

  def absolute_path
    Library.reading_states_root.join(path)
  end

  private

  def remove_from_disk
    FileUtils.rm_f(absolute_path)
  end
end
