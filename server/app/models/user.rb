class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :reader_positions, dependent: :destroy
  has_many :vocab_entries, dependent: :destroy

  normalizes :email_address, with: ->(e) { e.strip.downcase }
end
