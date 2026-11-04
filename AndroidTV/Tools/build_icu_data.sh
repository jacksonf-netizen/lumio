#!/bin/bash
# Builds Lumio's trimmed ICU data (about 6 MB in place of 32 MB) into
# core-bridge/Sources/LumioICUData/icudt76l-lumio.dat.
#
#   AndroidTV/Tools/build_icu_data.sh
#
# Swift's Foundation on Android carries ICU's full data set (every language's names, calendars,
# sorting, word dictionaries and character sets) in liblumiocore.so. The core needs very little of
# it, so this keeps the core tables, all time-zone rules, root and English data, word-break rules
# and the small Western character sets, and drops the rest. The LumioICUData target defines the
# same symbol (icudt76_dat), so the linker uses this data instead of Swift's copy.
#
# The package keeps ICU's own item order and layout: ICU finds items by binary search in that order
# (ICU's newer icupkg tool re-sorts them, which ICU 76 can't read). After changing what's kept, run
# the test app's ICU checks against a full-data build (LUMIO_FULL_ICU=1).
set -euo pipefail
cd "$(dirname "$0")/../.."
source AndroidTV/Tools/env.sh

WORK="$LUMIO_ANDROID_DIR/build/icu"
OUT="$LUMIO_ANDROID_DIR/core-bridge/Sources/LumioICUData/icudt76l-lumio.dat"
ARCHIVE="$HOME/Library/org.swift.swiftpm/swift-sdks/$LUMIO_SWIFT_ANDROID_SDK.artifactbundle/swift-android/swift-resources/usr/lib/swift_static-aarch64/android/lib_FoundationICU.a"
BIN="$(echo "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin)"

mkdir -p "$WORK"
cd "$WORK"
echo "==> Extracting Swift's ICU data"
"$BIN/llvm-ar" x "$ARCHIVE" icu_packaged_data.cpp.o
"$BIN/llvm-objcopy" -O binary --only-section=.rodata.icudt76_dat icu_packaged_data.cpp.o icudt76l.dat

echo "==> Trimming"
python3 - <<'PY'
import re, struct

data = open("icudt76l.dat", "rb").read()
header_size = struct.unpack_from("<H", data, 0)[0]
count = struct.unpack_from("<I", data, header_size)[0]
entries = [struct.unpack_from("<II", data, header_size + 4 + 8 * i) for i in range(count)]
names = [data[header_size + n:data.index(b"\0", header_size + n)].decode() for n, _ in entries]
offsets = [d for _, d in entries] + [len(data) - header_size]

KEEP_LOCALES = {"root", "en", "en_US", "en_US_POSIX", "en_001", "en_GB", "en_150"}
KEEP_ANY = {"pool.res", "res_index.res"}
kept = []
for i, name in enumerate(names):
    size = offsets[i + 1] - offsets[i]
    parts = name.split("/", 1)[1].split("/")
    base = parts[-1]
    if len(parts) == 1:
        if base.endswith(".cnv"):
            keep = size <= 16 * 1024          # single-byte character sets only
        elif base not in KEEP_ANY and re.fullmatch(r"[a-z]{2,3}(_[A-Za-z0-9]+)*\.res", base):
            keep = base[:-4] in KEEP_LOCALES  # locale data: root and English only
        else:
            keep = True                       # core tables, time zones, plurals, metadata
    else:
        tree = parts[0]
        keep = (base in KEEP_ANY or base[:-4] in KEEP_LOCALES
                or (tree == "coll" and base == "ucadata.icu")
                or (tree == "zone" and base == "tzdbNames.res")
                or (tree == "brkitr" and base.endswith(".brk")))  # word-break rules, no dictionaries
    if keep:
        kept.append((name, data[header_size + offsets[i]:header_size + offsets[i + 1]]))

# Same layout as ICU writes it: header, table of contents, names, filler (0xAA) to a 16-byte
# boundary, then the items, which stay aligned because each keeps its length, padding included.
table = 4 + 8 * len(kept)
name_blob, name_offsets = b"", []
for name, _ in kept:
    name_offsets.append(table + len(name_blob))
    name_blob += name.encode() + b"\0"
position = table + len(name_blob)
padding = (-(header_size + position)) % 16
position += padding
data_offsets, blobs = [], b""
for _, blob in kept:
    data_offsets.append(position + len(blobs))
    blobs += blob
contents = struct.pack("<I", len(kept)) + b"".join(struct.pack("<II", n, d) for n, d in zip(name_offsets, data_offsets))
open("icudt76l-lumio.dat", "wb").write(data[:header_size] + contents + name_blob + b"\xaa" * padding + blobs)
print("    kept %d of %d items" % (len(kept), count))
PY

cp icudt76l-lumio.dat "$OUT"
touch "$LUMIO_ANDROID_DIR/core-bridge/Sources/LumioICUData/icu_data.S"   # the build doesn't track .incbin
printf "==> Done: %.1f MB (was %.1f MB)\n" "$(echo "$(stat -f%z "$OUT")/1048576" | bc -l)" "$(echo "$(stat -f%z icudt76l.dat)/1048576" | bc -l)"
