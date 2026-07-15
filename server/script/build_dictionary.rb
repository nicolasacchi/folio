#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline ETL: turns a kaikki.org Wiktionary JSONL extract into the
# lemmas/lemma_forms tables that Dictionary#lookup queries at runtime. This
# script is NOT loaded by the Rails app (no controller or job ever requires
# it) — it's a one-off/occasional batch job you run by hand:
#
#   ruby script/build_dictionary.rb --lang en --input tmp/dictionary/kaikki-en.jsonl.gz
#   ruby script/build_dictionary.rb --lang it --input tmp/dictionary/kaikki-it.jsonl.gz
#   ruby script/build_dictionary.rb --lang en --input spec/fixtures/dictionary/sample-en.jsonl \
#     --db tmp/dictionary_spec.sqlite3 --limit 1000
#
# It boots the full app (config/environment) purely to reuse Dictionary's
# schema/path/normalization helpers; the actual load path below is raw
# sqlite3 (batched transactions, no ActiveRecord), so a real ~3 GB kaikki
# dump (kaikki.org ships English/Italian as a single JSONL file per
# language, one dictionary entry per line) still processes in O(1) memory —
# each line is read, transformed, and either buffered a few thousand rows
# deep or discarded before the next line is read.
#
# kaikki entry shape (only the fields we read):
#   { "word": "...", "pos": "...", "lang_code": "en",
#     "senses": [ { "glosses": ["..."], "form_of": [{"word": "..."}] }, ... ],
#     "forms": [ { "form": "...", "tags": ["..."] }, ... ] }

require_relative "../config/environment"
require "optparse"
require "zlib"
require "json"
require "time"

options = { limit: nil, db: nil }
OptionParser.new do |parser|
  parser.banner = "Usage: build_dictionary.rb --lang en|it --input PATH [--db PATH] [--limit N]"
  parser.on("--lang LANG", "Target language code (#{Dictionary::SUPPORTED_LANGS.join('|')})") { |v| options[:lang] = v }
  parser.on("--input PATH", "kaikki.org JSONL export (.jsonl or .jsonl.gz)") { |v| options[:input] = v }
  parser.on("--db PATH", "Override the dictionary SQLite file (defaults to Dictionary.db_path)") { |v| options[:db] = v }
  parser.on("--limit N", Integer, "Stop after N input lines (smoke-testing)") { |v| options[:limit] = v }
end.parse!

abort "missing --lang (#{Dictionary::SUPPORTED_LANGS.join('|')})" unless options[:lang]
abort "unsupported --lang #{options[:lang]} (supported: #{Dictionary::SUPPORTED_LANGS.join(', ')})" unless Dictionary::SUPPORTED_LANGS.include?(options[:lang])
abort "missing --input" unless options[:input]
abort "no such --input file: #{options[:input]}" unless File.exist?(options[:input])

LANG = options[:lang]
INPUT_PATH = options[:input]
DB_PATH = options[:db] ? Pathname.new(options[:db]) : Dictionary.db_path
LIMIT = options[:limit]
BATCH_SIZE = 5_000
PROGRESS_EVERY = 100_000

INSERT_LEMMA_SQL = "INSERT INTO lemmas (lang, lemma, pos, glosses) VALUES (?, ?, ?, ?)"
INSERT_FORM_SQL  = "INSERT OR IGNORE INTO lemma_forms (lang, surface, lemma) VALUES (?, ?, ?)"

# Yields each line (sans trailing newline) of a plain or gzip-compressed file.
def each_line(path)
  File.open(path, "rb") do |raw|
    reader = path.to_s.end_with?(".gz") ? Zlib::GzipReader.new(raw) : raw
    reader.each_line { |line| yield line.chomp }
  end
end

# First form_of target across this entry's senses, or nil. Real kaikki data
# always nests it as senses[].form_of == [{ "word" => "..." }, ...]; we
# tolerate a bare string too rather than raise on an unexpected shape.
def first_form_of(entry)
  Array(entry["senses"]).each do |sense|
    target = Array(sense["form_of"]).first
    word = target.is_a?(Hash) ? target["word"] : target
    return word if word && !word.to_s.strip.empty?
  end
  nil
end

# Up to Dictionary::MAX_GLOSSES gloss strings, shortest first, drawn from
# the last (most specific) gloss line of each sense — kaikki sometimes
# nests a broader category ahead of the actual definition in that array.
def shortest_glosses(entry)
  texts = Array(entry["senses"]).filter_map { |sense| Array(sense["glosses"]).last }
  texts.map { |t| t.to_s.strip }.reject(&:empty?).sort_by(&:length).first(Dictionary::MAX_GLOSSES)
end

# Appends [lang, surface, lemma] rows for the entry's own forms[] array,
# skipping table-reference pseudo-forms and multi-word forms when the
# headword itself is a single word (avoids polluting single-word lookups
# with phrase-level matches).
def expand_forms(entry, normalized_word, raw_word, form_batch, counts)
  headword_has_space = raw_word.include?(" ")

  Array(entry["forms"]).each do |form_entry|
    form = form_entry["form"]
    next if form.nil? || form.to_s.strip.empty?
    next if Array(form_entry["tags"]).include?("table")
    next if form.include?(" ") && !headword_has_space

    surface = Dictionary.normalize_word(form)
    next if surface.empty? || surface == normalized_word

    form_batch << [ LANG, surface, normalized_word ]
    counts[:forms] += 1
  end
end

counts = Hash.new(0)
lemma_batch = []
form_batch = []
started_at = Time.now

flush = lambda do |db|
  next if lemma_batch.empty? && form_batch.empty?

  db.transaction do
    lemma_batch.each { |row| db.execute(INSERT_LEMMA_SQL, row) }
    form_batch.each { |row| db.execute(INSERT_FORM_SQL, row) }
  end
  lemma_batch.clear
  form_batch.clear
end

FileUtils.mkdir_p(DB_PATH.dirname)
db = SQLite3::Database.new(DB_PATH.to_s)
db.busy_timeout(15_000)
db.execute("PRAGMA journal_mode=WAL")
db.execute("PRAGMA synchronous=OFF")
db.execute(Dictionary::LEMMAS_SCHEMA_SQL)
db.execute(Dictionary::LEMMA_FORMS_SCHEMA_SQL)

# Indexes are dropped (if Rails' boot-time Dictionary.ensure_schema! already
# created them) and rebuilt at the very end — maintaining them during a
# multi-million-row bulk load would make every INSERT pay for an index
# update it doesn't need yet.
db.execute("DROP INDEX IF EXISTS index_lemmas_on_lang_and_lemma")
db.execute("DROP INDEX IF EXISTS index_lemma_forms_on_lang_and_surface_and_lemma")

# Idempotent per language: a re-run fully replaces this lang's rows rather
# than accumulating duplicates.
db.execute("DELETE FROM lemmas WHERE lang = ?", [ LANG ])
db.execute("DELETE FROM lemma_forms WHERE lang = ?", [ LANG ])

each_line(INPUT_PATH) do |line|
  counts[:lines] += 1
  break if LIMIT && counts[:lines] > LIMIT

  if line.strip.empty?
    counts[:blank] += 1
    next
  end

  begin
    entry = JSON.parse(line)
  rescue JSON::ParserError
    counts[:junk] += 1
    next
  end

  word = entry["word"]
  if word.nil? || word.to_s.strip.empty?
    counts[:junk] += 1
    next
  end

  lang_code = entry["lang_code"]
  if lang_code && lang_code != LANG
    counts[:wrong_lang] += 1
    next
  end

  normalized_word = Dictionary.normalize_word(word)
  if normalized_word.empty?
    counts[:junk] += 1
    next
  end

  form_of_word = first_form_of(entry)
  if form_of_word
    normalized_target = Dictionary.normalize_word(form_of_word)
    if !normalized_target.empty? && normalized_target != normalized_word
      form_batch << [ LANG, normalized_word, normalized_target ]
      counts[:forms] += 1
    end
  else
    glosses = shortest_glosses(entry)
    if glosses.empty?
      counts[:no_gloss] += 1
    else
      lemma_batch << [ LANG, normalized_word, entry["pos"], glosses.to_json ]
      counts[:lemmas] += 1
    end
  end

  expand_forms(entry, normalized_word, word, form_batch, counts)

  if lemma_batch.size + form_batch.size >= BATCH_SIZE
    flush.call(db)
  end

  if (counts[:lines] % PROGRESS_EVERY).zero?
    elapsed = Time.now - started_at
    printf("... %d lines (%d lemmas, %d forms, %d skipped) in %.1fs\n",
      counts[:lines], counts[:lemmas], counts[:forms],
      counts[:junk] + counts[:no_gloss] + counts[:wrong_lang], elapsed)
  end
end

flush.call(db)

# The unique index was dropped (or never existed) during the load, so
# INSERT OR IGNORE above never actually deduped anything — different
# entries/POS lines legitimately produce the same (lang, surface, lemma)
# triple (e.g. "changes" as both a plural noun form and a verb form of
# "change"). Collapse those before the unique index can be rebuilt.
db.execute("DELETE FROM lemma_forms WHERE rowid NOT IN (SELECT MIN(rowid) FROM lemma_forms GROUP BY lang, surface, lemma)")

db.execute(Dictionary::LEMMAS_INDEX_SQL)
db.execute(Dictionary::LEMMA_FORMS_INDEX_SQL)
db.close

elapsed = Time.now - started_at
lines_per_sec = elapsed.positive? ? (counts[:lines] / elapsed) : counts[:lines]

puts "---"
puts "lang=#{LANG} db=#{DB_PATH} input=#{INPUT_PATH}"
puts "lines=#{counts[:lines]} lemmas=#{counts[:lemmas]} forms=#{counts[:forms]} " \
     "blank=#{counts[:blank]} junk=#{counts[:junk]} no_gloss=#{counts[:no_gloss]} wrong_lang=#{counts[:wrong_lang]}"
puts format("elapsed=%.1fs (%.0f lines/sec)", elapsed, lines_per_sec)

# Real kaikki.org per-language dumps run roughly 1.5M lines for English and
# 600K for Italian (as of the extracts this dictionary ships with) — a
# rough ETA at this run's measured throughput, for a full run (without
# --limit) against the whole file:
if lines_per_sec.positive?
  [ [ "en", 1_500_000 ], [ "it", 600_000 ] ].each do |lang, typical_lines|
    next unless lang == LANG
    eta_min = typical_lines / lines_per_sec / 60
    puts format("estimated full %s dump (~%d lines) at this rate: ~%.1f min", lang, typical_lines, eta_min)
  end
end
