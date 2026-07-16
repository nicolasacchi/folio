#!/usr/bin/env ruby
# READ-ONLY preview for the pre-cutover library reorg (see
# docs/folio-library-categories-design.html#migration): reports how many
# book_files are missing on disk right now, where the missing ones used to
# live, and how many of those would self-heal via Library::Ingest's
# sha256 relocation match once a rescan is pointed at a candidate new
# tree. Nothing here writes to the database or the filesystem — safe to
# run repeatedly while staging the new tree.
#
#   ruby script/relocate_report.rb [new-root]
#
# new-root defaults to the first configured SCAN_ROOTS entry.

require_relative "../config/environment"
require "find"
require "set"

new_root = ARGV[0] || Library::Scan.roots.first&.to_s
abort "usage: relocate_report.rb [new-root] (no root given and SCAN_ROOTS is empty/unset)" unless new_root
abort "no such directory: #{new_root}" unless File.directory?(new_root)

# The longest shared ancestor of a set of absolute paths, so "top dir"
# buckets below adapt to whatever machine this runs on instead of
# assuming a hardcoded layout.
def common_ancestor(paths)
  return Pathname.new("/") if paths.empty?

  segments = paths.map { |path| Pathname.new(path).dirname.each_filename.to_a }
  shared = segments.reduce { |a, b| a.zip(b).take_while { |x, y| x && x == y }.map(&:first) }
  Pathname.new("/#{shared.join('/')}")
end

puts "book_files total: #{BookFile.count}"
puts "checking every book_file against disk…"

missing = []
available_book_ids = Set.new

BookFile.find_each do |book_file|
  if File.exist?(book_file.absolute_path)
    available_book_ids << book_file.book_id
  else
    missing << book_file
  end
end

puts "missing on disk: #{missing.size}"

if missing.any?
  ancestor = common_ancestor(missing.map { |book_file| book_file.absolute_path.to_s })
  by_top_dir = missing.group_by do |book_file|
    book_file.absolute_path.relative_path_from(ancestor).each_filename.first || ancestor.basename.to_s
  end

  puts "missing by top dir (relative to #{ancestor}):"
  by_top_dir.sort_by { |_, files| -files.size }.each do |top_dir, files|
    puts "  #{top_dir}: #{files.size}"
  end
else
  puts "missing by top dir: (none)"
end

# Hash every candidate ebook file under new_root and check it against the
# missing sha256s — the exact match Library::Ingest performs during a real
# scan, so this count is a true preview of what pointing SCAN_ROOTS at
# new_root and rescanning would repair.
# group_by, not to_h: several missing rows can share one sha256, and the
# real relocation considers every candidate — collapsing them here would
# undercount which books become available.
missing_by_sha256 = missing.group_by(&:sha256)
relocatable_book_ids = Set.new

if missing_by_sha256.any?
  puts "\nhashing candidate files under #{new_root} to check for relocation matches…"
  scanned = 0
  matched_sha256s = Set.new

  Find.find(new_root) do |entry|
    basename = File.basename(entry)
    if File.directory?(entry)
      Find.prune if basename.start_with?(".") || (basename.start_with?("_") && basename != "_inbox")
      next
    end

    extension = File.extname(basename).delete_prefix(".").downcase
    next unless BookFile::FORMATS.include?(extension)
    next unless File.readable?(entry) && File.size(entry).positive?

    scanned += 1
    sha256 = Library.sha256(entry)
    next unless missing_by_sha256.key?(sha256)

    matched_sha256s << sha256
    missing_by_sha256[sha256].each { |book_file| relocatable_book_ids << book_file.book_id }
  end

  puts "scanned #{scanned} candidate files under #{new_root}"
  puts "relocatable (missing file whose sha256 was found under #{new_root}): " \
       "#{matched_sha256s.size} / #{missing.size}"
else
  puts "\nno missing files to check for relocation matches under #{new_root}"
end

zero_now = Book.count - Book.where(id: available_book_ids.to_a).count
zero_after = Book.count - Book.where(id: (available_book_ids | relocatable_book_ids).to_a).count

puts "\nbooks with zero available files now: #{zero_now}"
puts "books with zero available files after a hypothetical relocation onto #{new_root}: #{zero_after}"
