class Device < ApplicationRecord
  has_many :reading_states, dependent: :destroy
  has_many :deliveries, dependent: :destroy
  has_many :queued_books, through: :deliveries, source: :book

  before_validation :assign_token, on: :create

  validates :name, presence: true, uniqueness: true
  validates :token, presence: true, uniqueness: true

  def touch_last_seen!
    # Avoid a write on every API call.
    update_column(:last_seen_at, Time.current) if last_seen_at.nil? || last_seen_at < 1.minute.ago
  end

  private

  def assign_token
    self.token ||= SecureRandom.hex(20)
  end
end
