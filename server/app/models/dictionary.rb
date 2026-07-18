# Offline word-lookup dictionary (Kindle-style "tap a word" popup), backed
# by its own SQLite file built ahead of time by script/build_dictionary.rb
# from kaikki.org Wiktionary extracts. Kept out of the primary database for
# the same reason as BookSearch: it's bulk-loaded out of band and has no
# relationship to the rest of the schema.
#
# Two tables:
#   lemmas       — one row per (lang, lemma, pos): up to 3 glosses (JSON array).
#   lemma_forms  — inflected surface -> base lemma, e.g. "mice" -> "mouse".
#
# The database may legitimately not exist yet (dictionary not built for this
# lang, or at all) — every public method degrades to nil/false/empty rather
# than raising.
module Dictionary
  LEMMAS_SCHEMA_SQL = <<~SQL.freeze
    CREATE TABLE IF NOT EXISTS lemmas (
      id INTEGER PRIMARY KEY,
      lang TEXT NOT NULL,
      lemma TEXT NOT NULL,
      pos TEXT,
      glosses TEXT NOT NULL
    );
  SQL

  LEMMAS_INDEX_SQL = <<~SQL.freeze
    CREATE INDEX IF NOT EXISTS index_lemmas_on_lang_and_lemma ON lemmas (lang, lemma);
  SQL

  LEMMA_FORMS_SCHEMA_SQL = <<~SQL.freeze
    CREATE TABLE IF NOT EXISTS lemma_forms (
      lang TEXT NOT NULL,
      surface TEXT NOT NULL,
      lemma TEXT NOT NULL
    );
  SQL

  LEMMA_FORMS_INDEX_SQL = <<~SQL.freeze
    CREATE UNIQUE INDEX IF NOT EXISTS index_lemma_forms_on_lang_and_surface_and_lemma
      ON lemma_forms (lang, surface, lemma);
  SQL

  SUPPORTED_LANGS = %w[en it].freeze

  MAX_GLOSSES = 3

  # Every process (Puma master, Solid Queue supervisor, each worker) opens
  # and uses only its own handle — see ForkSafeSqlite.
  extend ForkSafeSqlite

  @mutex = Mutex.new

  module_function

  def db_path
    Pathname.new(ENV.fetch("DICTIONARY_DB", Rails.root.join("storage", "#{Rails.env}_dictionary.sqlite3").to_s))
  end

  def ensure_schema!
    with_db { nil }
  end

  # word/lang -> { word:, lemma:, lang:, entries: [{ pos:, glosses: [] }] } or nil.
  # `word` in the result always echoes the caller's input verbatim (the
  # reader UI correlates the response back to the tapped text); `lemma` is
  # whichever normalized headword actually matched.
  def lookup(word, lang: "en")
    normalized = normalize_word(word)
    return nil if normalized.empty?

    lemma, entries = resolve(normalized, lang)
    return nil if entries.blank?

    { word: word, lemma: lemma, lang: lang, entries: entries }
  rescue SQLite3::Exception
    nil
  end

  def available?(lang)
    with_db { |db| db.get_first_value("SELECT EXISTS(SELECT 1 FROM lemmas WHERE lang = ?)", [ lang ]) } == 1
  rescue SQLite3::Exception
    false
  end

  # { "en" => 12345, "it" => 6789 } — lemma row counts per language.
  def stats
    rows = with_db { |db| db.execute("SELECT lang, COUNT(*) AS count FROM lemmas GROUP BY lang ORDER BY lang") }
    rows.each_with_object({}) { |row, counts| counts[row["lang"]] = row["count"] }
  rescue SQLite3::Exception
    {}
  end

  # Downcase + strip punctuation (including Unicode quotes/dashes) so the
  # same transform can be applied at ETL time and at lookup time and still
  # agree. Deliberately aggressive (e.g. "don't" -> "dont") — consistency
  # between storage and query matters more than linguistic purity here.
  def normalize_word(word)
    word.to_s.downcase.gsub(/[[:punct:]]/, "").strip
  end

  # [lemma, entries] — tries, cheapest first: exact lemma match, then
  # lemma_forms surface match, then suffix-stripping heuristics re-tried
  # as exact lemma matches. Returns [nil, []] when nothing resolves.
  def resolve(normalized, lang)
    entries = entries_for(normalized, lang)
    return [ normalized, entries ] if entries.any?

    surface_lemma = form_lemma(normalized, lang)
    if surface_lemma
      entries = entries_for(surface_lemma, lang)
      return [ surface_lemma, entries ] if entries.any?
    end

    suffix_candidates(normalized, lang).each do |candidate|
      next if candidate.empty? || candidate == normalized
      entries = entries_for(candidate, lang)
      return [ candidate, entries ] if entries.any?
    end

    [ nil, [] ]
  end

  def entries_for(lemma, lang)
    rows = with_db do |db|
      db.execute("SELECT pos, glosses FROM lemmas WHERE lang = ? AND lemma = ? ORDER BY id", [ lang, lemma ])
    end
    rows.map { |row| { pos: row["pos"], glosses: JSON.parse(row["glosses"]) } }
  end

  # First lemma_forms target for this surface (a surface could in principle
  # map to more than one lemma across parts of speech; the response shape
  # only carries a single `lemma`, so the first match by insertion order
  # wins — good enough for a "what does this word mean" popup).
  def form_lemma(surface, lang)
    row = with_db do |db|
      db.execute("SELECT lemma FROM lemma_forms WHERE lang = ? AND surface = ? ORDER BY rowid LIMIT 1", [ lang, surface ])
    end.first
    row && row["lemma"]
  end

  def suffix_candidates(word, lang)
    case lang
    when "en" then en_suffix_candidates(word)
    when "it" then it_suffix_candidates(word)
    else []
    end
  end

  # Ordered candidate roots, most specific suffix first. A word ending in
  # "-ies" or "-es" also ends in "-s", so trying the more specific rule
  # first (and falling through only if it doesn't resolve) avoids stripping
  # "flies" down to "fli" before "fly" gets a chance.
  def en_suffix_candidates(word)
    candidates = []

    if word.end_with?("ies") && word.length > 3
      candidates << word[0..-4] + "y" # flies -> fly
    end

    if word.end_with?("ing") && word.length > 3
      stem = word[0..-4]
      candidates << stem                       # jumping -> jump
      candidates << stem + "e"                 # making -> make
      candidates << undouble(stem)              # running -> runn -> run
    end

    if word.end_with?("ed") && word.length > 2
      stem = word[0..-3]
      candidates << stem                       # walked -> walk
      candidates << stem + "e"                 # loved -> love
      candidates << undouble(stem)              # stopped -> stopp -> stop
    end

    candidates << word[0..-3] if word.end_with?("es") && word.length > 2   # boxes -> box
    candidates << word[0..-3] if word.end_with?("ly") && word.length > 2   # quickly -> quick
    candidates << word[0..-2] if word.end_with?("s")  && word.length > 1   # cats -> cat

    candidates.compact
  end

  # Reverses the common Italian plural endings: -i -> -o (masculine),
  # -e -> -a (feminine), and the -chi/-ghi hard-consonant spellings back to
  # -co/-go (fuochi -> fuoco). Longer/more specific endings are tried first.
  def it_suffix_candidates(word)
    candidates = []

    candidates << word[0..-4] + "co" if word.end_with?("chi") && word.length > 3
    candidates << word[0..-4] + "go" if word.end_with?("ghi") && word.length > 3
    candidates << word[0..-2] + "o"  if word.end_with?("i")   && word.length > 1
    candidates << word[0..-2] + "a"  if word.end_with?("e")   && word.length > 1

    candidates.compact
  end

  # Drops a doubled trailing consonant (running- -> runn -> run). Returns
  # nil (filtered out by callers) when the stem doesn't end that way.
  def undouble(stem)
    return nil unless stem.length >= 2
    return nil unless stem[-1] == stem[-2]
    return nil if %w[a e i o u].include?(stem[-1])

    stem[0..-2]
  end

  # Test hook.
  def clear!
    with_db do |db|
      db.execute("DELETE FROM lemmas")
      db.execute("DELETE FROM lemma_forms")
    end
  end

  def reset!
    @mutex.synchronize do
      @db&.close
      @db = nil
      @db_pid = nil
    end
  end

  def open_database
    FileUtils.mkdir_p(db_path.dirname)
    db = SQLite3::Database.new(db_path.to_s, results_as_hash: true)
    db.busy_timeout(15_000)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute(LEMMAS_SCHEMA_SQL)
    db.execute(LEMMAS_INDEX_SQL)
    db.execute(LEMMA_FORMS_SCHEMA_SQL)
    db.execute(LEMMA_FORMS_INDEX_SQL)
    db
  end
end
