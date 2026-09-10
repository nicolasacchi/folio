class User < ApplicationRecord
  has_secure_password
  has_many :sessions, dependent: :destroy
  has_many :reader_positions, dependent: :destroy
  has_many :vocab_entries, dependent: :destroy
  has_many :owned_devices, class_name: "Device", foreign_key: :main_user_id, inverse_of: :main_user, dependent: :nullify
  belongs_to :preferred_device, class_name: "Device", optional: true

  normalizes :email_address, with: ->(e) { e.strip.downcase }

  serialize :reader_preferences, coder: JSON

  # Keys and defaults mirror the web reader's JS DEFAULT_SETTINGS.
  DEFAULT_READER_PREFERENCES = {
    "fontSize" => 100,
    "lineHeight" => 1.5,
    "margin" => 24,
    "theme" => "light",
    "flow" => "paginated",
    "fontFamily" => "publisher",
    "justify" => false,
    "hyphenate" => true,
    "keepScreenOn" => true,
    "pageMode" => "fit"
  }.freeze

  FONT_FAMILIES = %w[publisher serif sans literata bitter garamond atkinson opendyslexic].freeze
  THEMES = %w[light sepia dark].freeze
  FLOWS = %w[paginated scrolled].freeze
  PAGE_MODES = %w[fit zoom].freeze

  validate :preferred_device_must_be_physical, if: -> { preferred_device_id.present? }

  def reader_preferences
    raw = super
    stored = raw.is_a?(Hash) ? raw : {}
    DEFAULT_READER_PREFERENCES.merge(stored.stringify_keys.slice(*DEFAULT_READER_PREFERENCES.keys))
  end

  def update_reader_preferences!(attrs)
    sanitized = sanitize_reader_preferences(attrs)
    current = (self[:reader_preferences].is_a?(Hash) ? self[:reader_preferences] : {}).stringify_keys
    update!(reader_preferences: current.merge(sanitized))
    reader_preferences
  end

  def preferred_kindle
    device = preferred_device
    device if device&.kind == "kindle"
  end

  private

  def preferred_device_must_be_physical
    return if preferred_device&.kind == "kindle"

    errors.add(:preferred_device, "must be a physical Kindle")
  end

  def sanitize_reader_preferences(attrs)
    return {} if attrs.blank?

    hash = attrs.respond_to?(:to_unsafe_h) ? attrs.to_unsafe_h : attrs
    hash = hash.to_h if hash.respond_to?(:to_h)
    return {} unless hash.is_a?(Hash)

    out = {}
    hash.each do |key, value|
      key = key.to_s
      next unless DEFAULT_READER_PREFERENCES.key?(key)

      case key
      when "fontSize"
        n = coerce_number(value)
        out[key] = n.round.clamp(70, 200) if n
      when "lineHeight"
        n = coerce_number(value)
        out[key] = n.clamp(1.2, 2.4) if n
      when "margin"
        n = coerce_number(value)
        out[key] = n.round.clamp(0, 64) if n
      when "theme"
        s = value.to_s
        out[key] = s if THEMES.include?(s)
      when "flow"
        s = value.to_s
        out[key] = s if FLOWS.include?(s)
      when "pageMode"
        s = value.to_s
        out[key] = s if PAGE_MODES.include?(s)
      when "fontFamily"
        s = value.to_s
        out[key] = s if FONT_FAMILIES.include?(s)
      when "justify", "hyphenate", "keepScreenOn"
        b = coerce_boolean(value)
        out[key] = b unless b.nil?
      end
    end
    out
  end

  def coerce_number(value)
    return value if value.is_a?(Numeric)
    Float(value)
  rescue ArgumentError, TypeError
    nil
  end

  def coerce_boolean(value)
    case value
    when true, false then value
    when "true", "1", 1 then true
    when "false", "0", 0 then false
    else nil
    end
  end
end
