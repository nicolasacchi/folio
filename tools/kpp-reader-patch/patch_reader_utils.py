#!/usr/bin/env python3
"""Force-enable the KPP-reader format-migration gate in a 5.19.2
Reader-utils.jar's ReaderUtils.class.

Context: docs/kindle-519-kpp-reader-routing.html and
tools/kpp-reader-patch/README.md — READ THE README FIRST. This patch caused
a boot lockout on 2026-07-13; the recovery path is kpp-recover.sh. Do not
run this against a live device's jar without an offline dry run first and a
verified backup.

What it does: com/amazon/ebook/booklet/reader/utils/ReaderUtils.class has an
obfuscated method (named e.g. "aKM" on 5.19.2) that loads the string constant
"KINDLE_FEATURE_1308000" (the LegacyFormatMigration weblab id) and ends with
`iload_0; ireturn` (return the weblab-derived boolean argument). This script
finds that exact method by its string-constant reference (method names are
obfuscated and may differ across firmware builds) and flips the final
`iload_0` (0x1A) to `iconst_1` (0x04) so it unconditionally returns true —
one byte changed, method length and stack shape unchanged, so the class's
StackMapTable stays valid and the class file remains structurally correct.

Usage:
    python3 patch_reader_utils.py <path-to-ReaderUtils.class>

Operates in place. Always keep the original class file (or the jar it came
from) — this script does not create its own backup.
"""
import struct
import sys

TARGET_STRING = "KINDLE_FEATURE_1308000"
IMLOAD0_IRETURN = b"\x1a\xac"  # iload_0; ireturn


def parse_class(data):
    assert data[:4] == b"\xca\xfe\xba\xbe", "not a Java class file"
    off = 8
    cp_count = struct.unpack(">H", data[off:off + 2])[0]
    off += 2
    utf8 = {}
    string_to_utf8 = {}
    i = 1
    while i < cp_count:
        tag = data[off]
        off += 1
        if tag == 1:  # Utf8
            ln = struct.unpack(">H", data[off:off + 2])[0]
            off += 2
            utf8[i] = data[off:off + ln].decode("utf-8", "replace")
            off += ln
        elif tag == 8:  # String
            string_to_utf8[i] = struct.unpack(">H", data[off:off + 2])[0]
            off += 2
        elif tag in (7, 16, 19, 20):
            off += 2
        elif tag == 15:
            off += 3
        elif tag in (9, 10, 11, 3, 4, 12, 17, 18):
            off += 4
        elif tag in (5, 6):  # Long/Double take two constant-pool slots
            off += 8
            i += 1
        else:
            raise ValueError(f"unexpected constant-pool tag {tag} at offset {off}")
        i += 1
    return utf8, string_to_utf8, off


def find_target_string_index(utf8, string_to_utf8, target):
    for s_idx, u_idx in string_to_utf8.items():
        if utf8.get(u_idx) == target:
            return s_idx
    raise ValueError(f"string constant {target!r} not found in constant pool")


def skip_fields_and_get_methods_offset(data, off):
    off += 6  # access_flags, this_class, super_class
    ic = struct.unpack(">H", data[off:off + 2])[0]
    off += 2 + 2 * ic
    fc = struct.unpack(">H", data[off:off + 2])[0]
    off += 2
    for _ in range(fc):
        off += 6
        ac = struct.unpack(">H", data[off:off + 2])[0]
        off += 2
        for _ in range(ac):
            off += 2
            al = struct.unpack(">I", data[off:off + 4])[0]
            off += 4 + al
    return off


def patch(path):
    data = bytearray(open(path, "rb").read())
    utf8, string_to_utf8, off = parse_class(data)
    target_idx = find_target_string_index(utf8, string_to_utf8, TARGET_STRING)
    print(f"string constant index for {TARGET_STRING!r} = #{target_idx}")

    ldc1 = bytes([0x12, target_idx]) if target_idx < 256 else None
    ldcw = bytes([0x13, (target_idx >> 8) & 0xFF, target_idx & 0xFF])

    off = skip_fields_and_get_methods_offset(data, off)
    mc = struct.unpack(">H", data[off:off + 2])[0]
    off += 2

    patched = 0
    for _ in range(mc):
        name_idx = struct.unpack(">H", data[off + 2:off + 4])[0]
        method_name = utf8.get(name_idx)
        off += 6
        ac = struct.unpack(">H", data[off:off + 2])[0]
        off += 2
        for _ in range(ac):
            attr_name_idx = struct.unpack(">H", data[off:off + 2])[0]
            off += 2
            attr_len = struct.unpack(">I", data[off:off + 4])[0]
            off += 4
            attr_start = off
            if utf8.get(attr_name_idx) == "Code":
                code_len = struct.unpack(">I", data[off + 4:off + 8])[0]
                code_start = off + 8
                code = bytes(data[code_start:code_start + code_len])
                references_target = (ldc1 and ldc1 in code) or (ldcw in code)
                if references_target:
                    idx = code.rfind(IMLOAD0_IRETURN)
                    if idx < 0:
                        raise ValueError(
                            f"method {method_name!r} references {TARGET_STRING!r} "
                            "but doesn't end in the expected iload_0;ireturn pattern "
                            "— firmware build differs, do not blindly proceed"
                        )
                    data[code_start + idx] = 0x04  # iconst_1
                    patched += 1
                    print(
                        f"patched method {method_name!r}: iload_0 -> iconst_1 "
                        f"at code offset {idx}"
                    )
            off = attr_start + attr_len

    if patched != 1:
        raise ValueError(f"expected exactly 1 patch, made {patched} — refusing to write")

    with open(path, "wb") as f:
        f.write(data)
    print(f"wrote {path}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(1)
    patch(sys.argv[1])
