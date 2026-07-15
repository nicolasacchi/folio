require "stringio"

# KRDS ("Kindle Reader Data Store") is the lab126 typed-value container
# used by KPP-era firmware (5.19+) for `.mbs`/`.mbp1`/`.yjr`/`.azw3r`
# sidecars — see Library::SidecarProgress for the read-only fast path.
# This is the full read/write codec: parse a blob into a tree that
# retains enough detail to serialize back to the *exact* original
# bytes, and a helper to rewrite reading-position objects in place.
#
# Format (cross-checked byte-by-byte against spec/fixtures/sidecars/
# krds.mbp1 and krds.mbs, real captures off a Kindle on firmware
# 5.19.2 — where this disagreed with public krds.py notes, the fixture
# bytes won; see the deviations called out below):
#
#   magic(8) int64(=1) int32(object count) object...
#
# A value is a 1-byte type tag + payload:
#   0x00 bool    1 byte, 0/1
#   0x01 int32   4 bytes BE, signed
#   0x02 int64   8 bytes BE, signed
#   0x03 string  1-byte "empty" flag; flag==1 -> empty, no length byte
#                at all; flag==0 -> u16 BE length + that many bytes
#                (an explicit zero length is a *different* on-disk
#                encoding of the same empty string — both appear in
#                the real fixtures, so both are preserved verbatim
#                rather than normalized)
#   0x04 double  8 bytes BE (IEEE 754)
#   0x05 int16   2 bytes BE, signed
#   0x06 float32 4 bytes BE (IEEE 754)
#   0x07 byte    1 byte, signed
#   0x09 char    1-byte flag + payload, encoded like string (never
#                seen in the wild; best-effort per the format notes)
#   0xFE object  string-style name (flag+len+bytes, but WITHOUT its
#                own leading 0x03 type byte) then nested values until
#                0xFF
#
# Deviations from the "spec" text handed down from krds.py that the
# fixtures overrode:
#   - the top-level "must equal 1" marker is type 0x02 (int64), not
#     0x01 (int32), in both fixtures.
#   - fpr's second and third fields (after the position string) are
#     both int64 (0x02), not int32 — real values are the -1 sentinel
#     (0xFFFFFFFFFFFFFFFF) in the mbs fixture, i.e. "never read".
#   - objects can nest (timer.model contains a nested
#     timer.average.calculator object) — the value stream inside an
#     object is fully general, not a flat scalar list.
module Library
  module Krds
    MAGIC = "\x00\x00\x00\x00\x00\x1A\xB1\x26".b.freeze

    TAG_BOOL = 0x00
    TAG_INT32 = 0x01
    TAG_INT64 = 0x02
    TAG_STRING = 0x03
    TAG_DOUBLE = 0x04
    TAG_INT16 = 0x05
    TAG_FLOAT = 0x06
    TAG_BYTE = 0x07
    TAG_CHAR = 0x09
    TAG_OBJECT_BEGIN = 0xFE
    TAG_OBJECT_END = 0xFF

    # Object names that carry a reading position, per Library::Krds.update_positions.
    POSITION_OBJECT_NAMES = %w[lpr fpr updated_lpr sync_lpr].freeze

    # Real captures nest at most a couple of levels deep (e.g. timer.model
    # containing timer.average.calculator) — this is generous headroom
    # above that, not a real limit anyone should hit. read_value recurses
    # once per nesting level with no depth tracking otherwise, so a
    # hostile/corrupt blob claiming thousands of levels of nested objects
    # would raise SystemStackError — a direct Exception subclass, not
    # StandardError, so it isn't caught by update_positions' `rescue
    # Error` or any of this parser's callers. Raising Error here instead
    # keeps a malformed blob inside the error type every caller already
    # rescues.
    MAX_NESTING_DEPTH = 64

    class Error < StandardError; end

    # One typed value. Scalars use `value`; objects use `name` +
    # `children` (an Array of Node). `short_empty` only matters for
    # :string nodes and the :object name — it records which of the
    # two on-disk empty-string encodings was used, so serialize can
    # reproduce it.
    Node = Struct.new(:type, :value, :name, :children, :short_empty, keyword_init: true) do
      def object?
        type == :object
      end
    end

    Document = Struct.new(:version, :objects, keyword_init: true)

    module_function

    def krds?(bytes)
      bytes.is_a?(String) && bytes.b.byteslice(0, MAGIC.bytesize) == MAGIC
    end

    def parse(bytes)
      bytes = bytes.to_s.b
      raise Error, "not a KRDS blob (bad magic)" unless krds?(bytes)

      io = StringIO.new(bytes)
      io.read(MAGIC.bytesize)

      version = read_typed(io, TAG_INT64) { |payload| unpack_int64(payload) }
      raise Error, "unsupported KRDS version #{version.inspect}" unless version == 1

      count = read_typed(io, TAG_INT32) { |payload| unpack_int32(payload) }
      objects = Array.new(count) { read_value(io) }

      Document.new(version: version, objects: objects)
    end

    def serialize(document)
      out = +"".b
      out << MAGIC
      out << [ TAG_INT64 ].pack("C") << [ document.version ].pack("q>")
      out << [ TAG_INT32 ].pack("C") << [ document.objects.size ].pack("l>")
      document.objects.each { |node| write_value(out, node) }
      out
    end

    # Rewrites the reading position (and, when present, the time
    # field immediately after it) in every lpr/fpr/updated_lpr/
    # sync_lpr object. Returns the new serialized bytes, or nil if no
    # object had a rewritable position (e.g. sync_lpr's boolean-only
    # shape in the real .mbp1 fixture, or the blob isn't valid KRDS).
    def update_positions(bytes, position, at: Time.now)
      document = parse(bytes)
      changed = false

      document.objects.each do |object|
        next unless object.object? && POSITION_OBJECT_NAMES.include?(object.name)

        index = position_index(object)
        next unless index

        position_node = object.children[index]
        rewritten = rewrite_position_value(position_node.value, position)
        next unless rewritten

        position_node.value = rewritten
        changed = true

        time_node = object.children[index + 1]
        time_node.value = epoch_ms(at) if time_node&.type == :int64
      end

      return nil unless changed

      serialize(document)
    rescue Error
      nil
    end

    # -- reading -------------------------------------------------------

    def read_value(io, depth = 0)
      tag = read_byte(io)
      case tag
      when TAG_BOOL then Node.new(type: :bool, value: read_bytes(io, 1).unpack1("C") != 0)
      when TAG_INT32 then Node.new(type: :int32, value: unpack_int32(read_bytes(io, 4)))
      when TAG_INT64 then Node.new(type: :int64, value: unpack_int64(read_bytes(io, 8)))
      when TAG_STRING
        value, short_empty = read_string_body(io)
        Node.new(type: :string, value: value, short_empty: short_empty)
      when TAG_DOUBLE then Node.new(type: :double, value: read_bytes(io, 8).unpack1("G"))
      when TAG_INT16 then Node.new(type: :int16, value: read_bytes(io, 2).unpack1("s>"))
      when TAG_FLOAT then Node.new(type: :float, value: read_bytes(io, 4).unpack1("g"))
      when TAG_BYTE then Node.new(type: :byte, value: read_bytes(io, 1).unpack1("c"))
      when TAG_CHAR
        value, short_empty = read_string_body(io)
        Node.new(type: :char, value: value, short_empty: short_empty)
      when TAG_OBJECT_BEGIN
        raise Error, "KRDS object nesting exceeds #{MAX_NESTING_DEPTH} levels" if depth >= MAX_NESTING_DEPTH

        name, short_empty = read_string_body(io)
        children = []
        children << read_value(io, depth + 1) until peek_byte(io) == TAG_OBJECT_END
        read_byte(io) # consume 0xFF
        Node.new(type: :object, name: name, short_empty: short_empty, children: children)
      else
        raise Error, "unknown KRDS type tag 0x#{tag.to_s(16)} at offset #{io.pos - 1}"
      end
    end

    def read_typed(io, expected_tag)
      tag = read_byte(io)
      raise Error, "expected tag 0x#{expected_tag.to_s(16)}, got 0x#{tag.to_s(16)}" unless tag == expected_tag
      yield read_bytes(io, {
        TAG_INT32 => 4, TAG_INT64 => 8
      }.fetch(expected_tag))
    end

    def read_string_body(io)
      flag = read_byte(io)
      case flag
      when 1 then [ "".b, true ]
      when 0
        length = read_bytes(io, 2).unpack1("n")
        [ (length.zero? ? "".b : read_bytes(io, length)), false ]
      else
        raise Error, "unexpected string flag byte 0x#{flag.to_s(16)}"
      end
    end

    def peek_byte(io)
      byte = io.getbyte
      io.ungetbyte(byte) if byte
      byte
    end

    def read_byte(io)
      byte = io.getbyte
      raise Error, "unexpected end of KRDS stream" if byte.nil?
      byte
    end

    def read_bytes(io, length)
      return "".b if length.zero?

      bytes = io.read(length)
      raise Error, "unexpected end of KRDS stream" if bytes.nil? || bytes.bytesize != length
      bytes
    end

    def unpack_int32(bytes) = bytes.unpack1("l>")
    def unpack_int64(bytes) = bytes.unpack1("q>")

    # -- writing ---------------------------------------------------------

    def write_value(out, node)
      case node.type
      when :bool then out << [ TAG_BOOL, node.value ? 1 : 0 ].pack("CC")
      when :int32 then out << [ TAG_INT32 ].pack("C") << [ node.value ].pack("l>")
      when :int64 then out << [ TAG_INT64 ].pack("C") << [ node.value ].pack("q>")
      when :string
        out << [ TAG_STRING ].pack("C")
        write_string_body(out, node.value, node.short_empty)
      when :double then out << [ TAG_DOUBLE ].pack("C") << [ node.value ].pack("G")
      when :int16 then out << [ TAG_INT16 ].pack("C") << [ node.value ].pack("s>")
      when :float then out << [ TAG_FLOAT ].pack("C") << [ node.value ].pack("g")
      when :byte then out << [ TAG_BYTE, node.value ].pack("Cc")
      when :char
        out << [ TAG_CHAR ].pack("C")
        write_string_body(out, node.value, node.short_empty)
      when :object
        out << [ TAG_OBJECT_BEGIN ].pack("C")
        write_string_body(out, node.name, node.short_empty)
        node.children.each { |child| write_value(out, child) }
        out << [ TAG_OBJECT_END ].pack("C")
      else
        raise Error, "unknown node type #{node.type.inspect}"
      end
    end

    def write_string_body(out, value, short_empty)
      if short_empty
        out << [ 1 ].pack("C")
      else
        out << [ 0 ].pack("C") << [ value.bytesize ].pack("n") << value
      end
    end

    # -- position rewriting -----------------------------------------------

    # Index of the position-string child within a position object, or
    # nil if this instance doesn't carry a rewritable position (e.g.
    # sync_lpr's plain-boolean shape).
    #
    #   lpr           = [byte version(<=2), string position, int64 time]  (new-style)
    #               or = [string position, ...]                          (old-style)
    #   fpr/updated_lpr/sync_lpr = [string position, int64 time, ...]
    def position_index(object)
      first = object.children.first
      return nil unless first

      index =
        if object.name == "lpr" && first.type == :byte && first.value <= 2
          1
        else
          0
        end

      object.children[index]&.type == :string ? index : nil
    end

    # Rewrites a position string per the two on-disk shapes seen on
    # real devices, and leaves anything else untouched:
    #   - all digits ("31740")                    -> whole-value replace
    #   - leading "INT:INT:" ("31739:31739:15:…")  -> replace both
    #     leading integers, keep the opaque remainder verbatim
    #   - anything else (non-numeric-leading)      -> nil (don't touch)
    def rewrite_position_value(value, position)
      if value.match?(/\A[0-9]+\z/)
        position.to_s
      elsif (match = value.match(/\A[0-9]+:[0-9]+:/))
        "#{position}:#{position}:#{value.byteslice(match[0].bytesize..)}"
      end
    end

    def epoch_ms(time)
      (time.to_r * 1000).round
    end
  end
end
