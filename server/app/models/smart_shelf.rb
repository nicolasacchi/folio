# A saved, named set of conditions that resolves to a live Book scope —
# e.g. "Sci-fi by Asimov" or "Unread from 2023" (see #books). Nothing here
# ever builds SQL out of user-supplied strings: `rules` is a JSON
# {match, conditions} structure, and every condition's `field` and `op`
# must be a literal key in the FIELDS whitelist below before it can touch
# the database — an unknown field/op is a validation error, full stop, and
# #books re-checks the same whitelist at resolution time so a row that
# somehow bypassed validation (e.g. edited directly in a console) still
# can't reach an unsafe query. Only `value` is ever user-controlled data,
# and it always travels as an ActiveRecord bind parameter.
class SmartShelf < ApplicationRecord
  MATCH_MODES = %w[all any].freeze
  READ_STATES = %w[currently_reading finished never_opened].freeze
  # A shelf with more rows than this is almost certainly a mistake (or an
  # attempt to make resolution expensive) — bounded rather than unlimited.
  MAX_CONDITIONS = 20

  # Mirrors Book's own `category` format validation (see Book#validates
  # :category) — lowercase kebab segments, one optional "/sub".
  CATEGORY_FORMAT = %r{\A[a-z0-9_]+(?:/[a-z0-9_]+)?\z}

  # Display labels for operators, shared across every field that offers
  # them (the row form has one flat operator <select>, not one scoped per
  # field — see app/views/smart_shelves/_condition_row.html.erb).
  OPERATOR_LABELS = {
    "equals" => "equals",
    "contains" => "contains",
    "under" => "is under (category root)",
    "between" => "is between (comma-separated, e.g. 1950,1960)",
    "after" => "on/after (date, YYYY-MM-DD)",
    "present" => "is present",
    "absent" => "is absent"
  }.freeze

  # The whitelist. Each field maps to a fixed column/association lookup;
  # each operator maps to a `value` shape (checked in #rules_are_valid
  # against VALUE_VALIDATORS) and an `apply` lambda that turns
  # (scope, value) into a narrower Book scope using ordinary parameterized
  # ActiveRecord calls — never string-interpolated SQL built from `field`
  # or `op`.
  FIELDS = {
    "author" => {
      label: "Author",
      operators: {
        "equals" => { value: :text, apply: ->(scope, v) { scope.where(author: v) } },
        "contains" => { value: :text, apply: ->(scope, v) {
          scope.where("books.author LIKE ? ESCAPE '\\'", "%#{Book.sanitize_sql_like(v)}%")
        } }
      }
    },
    "series" => {
      label: "Series",
      operators: {
        "equals" => { value: :text, apply: ->(scope, v) { scope.where(series: v) } }
      }
    },
    "category" => {
      label: "Category",
      operators: {
        "equals" => { value: :category, apply: ->(scope, v) { scope.in_category(v) } },
        "under" => { value: :category, apply: ->(scope, v) { scope.in_category_root(v) } }
      }
    },
    "format" => {
      label: "Format (has a file of…)",
      operators: {
        "equals" => { value: :format, apply: ->(scope, v) {
          scope.where(id: BookFile.where(format: v).select(:book_id))
        } }
      }
    },
    "language" => {
      label: "Language",
      operators: {
        "equals" => { value: :text, apply: ->(scope, v) { scope.where(language: v) } }
      }
    },
    "published_year" => {
      label: "Published year",
      operators: {
        "equals" => { value: :year, apply: ->(scope, v) { scope.where(published_year: Integer(v)) } },
        "between" => { value: :year_range, apply: ->(scope, v) {
          from, to = split_range(v).map { |n| Integer(n) }.minmax
          scope.where(published_year: from..to)
        } }
      }
    },
    "added_at" => {
      label: "Date added",
      operators: {
        "after" => { value: :date, apply: ->(scope, v) { scope.where(created_at: Date.iso8601(v).beginning_of_day..) } },
        "between" => { value: :date_range, apply: ->(scope, v) {
          from, to = split_range(v).map { |d| Date.iso8601(d) }.minmax
          scope.where(created_at: from.beginning_of_day..to.end_of_day)
        } }
      }
    },
    "read_state" => {
      label: "Reading status",
      operators: {
        "equals" => { value: :read_state, apply: ->(scope, v) { scope.merge(SmartShelf.read_state_scope(v)) } }
      }
    },
    "has_highlights" => {
      label: "Highlights",
      operators: {
        "present" => { value: :none, apply: ->(scope, _v) { scope.where(id: Annotation.highlights.select(:book_id)) } },
        "absent" => { value: :none, apply: ->(scope, _v) { scope.where.not(id: Annotation.highlights.select(:book_id)) } }
      }
    },
    "has_fulltext" => {
      label: "Full text indexed",
      operators: {
        "present" => { value: :none, apply: ->(scope, _v) { scope.where(has_fulltext: true) } },
        "absent" => { value: :none, apply: ->(scope, _v) { scope.where(has_fulltext: false) } }
      }
    }
  }.freeze

  # One validator per `value` shape referenced above. Each takes the raw
  # value already coerced to a (possibly blank) String — never the raw
  # param — and returns true/false. Nothing here executes a query.
  VALUE_VALIDATORS = {
    none: ->(v) { v.blank? },
    text: ->(v) { v.present? && v.length <= 200 },
    category: ->(v) { v.present? && v.match?(CATEGORY_FORMAT) },
    format: ->(v) { BookFile::FORMATS.include?(v) },
    year: ->(v) { valid_year?(v) },
    year_range: ->(v) { (parts = split_range(v)) && parts.all? { |p| valid_year?(p) } },
    date: ->(v) { valid_date?(v) },
    date_range: ->(v) { (parts = split_range(v)) && parts.all? { |p| valid_date?(p) } },
    read_state: ->(v) { READ_STATES.include?(v) }
  }.freeze

  serialize :rules, coder: JSON

  before_validation :assign_position, on: :create

  validates :name, presence: true, uniqueness: true
  validates :position, presence: true, numericality: { only_integer: true }
  validate :rules_are_valid

  scope :ordered, -> { order(:position, :id) }

  # [{"field" => ..., "op" => ..., "value" => ...}, ...] — always an Array,
  # never nil, regardless of what shape `rules` currently holds.
  def conditions
    normalized_rules["conditions"] || []
  end

  def match_any?
    normalized_rules["match"] == "any"
  end

  # The resolved scope, eager-loading exactly what the shelf grid partial
  # needs (mirrors BooksController#index) so rendering a page of results
  # never N+1s across books_files/conversions. Every condition is
  # re-validated against the whitelist here too (see class comment) — an
  # unknown field/op/value shape is silently dropped rather than executed.
  # A shelf with zero valid conditions resolves to no books (never "every
  # book"), so a broken or blank shelf renders as an empty state, not an
  # accidental full-library dump.
  def books
    applied = conditions.filter_map { |condition| normalize_condition(condition) }
    return Book.none if applied.empty?

    scope = if match_any?
      applied.map { |c| apply_condition(Book.all, c) }.reduce { |acc, s| acc.or(s) }
    else
      applied.reduce(Book.all) { |acc, c| apply_condition(acc, c) }
    end

    scope.includes(:book_files, :conversions)
  end

  # Book scope for the three read_state values. A correlated subquery
  # picks each book's most-recently-active reading_states row (mirrors
  # Book.currently_reading's "freshest activity wins" rule) and classifies
  # it against Book::READING_FINISHED_THRESHOLD; a book with no
  # reading_states at all is never_opened.
  def self.read_state_scope(value)
    case value
    when "never_opened"
      # A plain NOT IN subquery rather than `where.missing(:reading_states)`
      # on purpose: `.missing` adds a LEFT OUTER JOIN, which would make this
      # condition's scope structurally incompatible with every other
      # condition's plain `where(id: subquery)` shape (see #books) the
      # moment a shelf combines it with another condition via "any" — `.or`
      # raises on relations with different joins.
      Book.where.not(id: ReadingState.select(:book_id))
    when "finished"
      Book.where(id: latest_reading_states.where(
        "reading_states.progress_percent > ?", Book::READING_FINISHED_THRESHOLD
      ).select(:book_id))
    when "currently_reading"
      Book.where(id: latest_reading_states.where(
        "reading_states.progress_percent IS NULL OR reading_states.progress_percent <= ?", Book::READING_FINISHED_THRESHOLD
      ).select(:book_id))
    else
      Book.none
    end
  end

  def self.latest_reading_states
    ReadingState.where(
      "reading_states.content_mtime = (" \
      "SELECT MAX(rs2.content_mtime) FROM reading_states rs2 WHERE rs2.book_id = reading_states.book_id)"
    )
  end

  # Deduped [op, label] pairs across every field, in FIELDS order — backs
  # the condition row's single flat operator <select>.
  def self.operator_options
    seen = []
    FIELDS.each_value do |spec|
      spec[:operators].each_key { |op| seen << op unless seen.include?(op) }
    end
    seen.map { |op| [ op, OPERATOR_LABELS.fetch(op, op) ] }
  end

  def self.valid_year?(v)
    n = Integer(v, exception: false)
    !n.nil? && (0..9999).cover?(n)
  end

  def self.valid_date?(v)
    Date.iso8601(v)
    true
  rescue ArgumentError, TypeError
    false
  end

  # "1950,1960" => ["1950", "1960"]; anything that isn't exactly two
  # non-blank comma-separated parts is not a valid range.
  def self.split_range(v)
    parts = v.to_s.split(",", -1).map(&:strip)
    return nil unless parts.size == 2 && parts.all?(&:present?)
    parts
  end

  private

  def normalized_rules
    rules.is_a?(Hash) ? rules.deep_stringify_keys : {}
  end

  def assign_position
    self.position ||= (SmartShelf.maximum(:position) || 0) + 1
  end

  # Returns {spec:, value:} for a condition whose field/op are in FIELDS
  # and whose value passes that operator's validator — or nil. The single
  # gate every condition (whether freshly submitted or loaded back out of
  # the database) must pass before it can influence a query.
  def normalize_condition(raw)
    return nil unless raw.is_a?(Hash)

    raw = raw.stringify_keys
    field_spec = self.class::FIELDS[raw["field"].to_s]
    return nil unless field_spec

    op_spec = field_spec[:operators][raw["op"].to_s]
    return nil unless op_spec

    value = string_value(raw["value"])
    return nil unless VALUE_VALIDATORS.fetch(op_spec[:value]).call(value)

    { spec: op_spec, value: value }
  end

  # Rejects value shapes that were never blessed to be strings/numbers in
  # the first place — a Hash/Array/anything else never reaches a
  # per-type validator (whose checks assume a String) or an apply lambda.
  def string_value(value)
    return "" if value.nil?
    return nil unless value.is_a?(String) || value.is_a?(Numeric)
    value.to_s.strip
  end

  def apply_condition(scope, condition)
    condition[:spec][:apply].call(scope, condition[:value])
  end

  def rules_are_valid
    unless rules.is_a?(Hash)
      errors.add(:rules, "must be an object")
      return
    end

    normalized = rules.deep_stringify_keys
    match = normalized["match"]
    errors.add(:rules, "match must be \"all\" or \"any\"") if match.present? && !MATCH_MODES.include?(match.to_s)

    raw_conditions = normalized["conditions"] || []
    unless raw_conditions.is_a?(Array)
      errors.add(:rules, "conditions must be a list")
      return
    end

    if raw_conditions.size > MAX_CONDITIONS
      errors.add(:rules, "has too many conditions (max #{MAX_CONDITIONS})")
      return
    end

    raw_conditions.each_with_index { |raw, index| validate_condition(raw, index) }
  end

  def validate_condition(raw, index)
    # A condition row the user never filled in (no field chosen) is
    # dropped before it ever gets here — see
    # SmartShelvesController#build_rules_from_params — so reaching this
    # method with a blank field is already a real, reportable error.
    unless raw.is_a?(Hash)
      errors.add(:rules, "condition #{index + 1} must be an object")
      return
    end

    raw = raw.stringify_keys
    field = raw["field"].to_s
    op = raw["op"].to_s

    field_spec = self.class::FIELDS[field]
    unless field_spec
      errors.add(:rules, "condition #{index + 1}: unknown field #{field.inspect}")
      return
    end

    op_spec = field_spec[:operators][op]
    unless op_spec
      errors.add(:rules, "condition #{index + 1}: unknown operator #{op.inspect} for #{field_spec[:label]}")
      return
    end

    value = string_value(raw["value"])
    if value.nil?
      errors.add(:rules, "condition #{index + 1}: value must be plain text")
    elsif !VALUE_VALIDATORS.fetch(op_spec[:value]).call(value)
      errors.add(:rules, "condition #{index + 1}: invalid value for #{field_spec[:label]}")
    end
  end
end
