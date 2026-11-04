#!/bin/bash
# Builds SQLite for each Android CPU type into AndroidTV/build/sqlite/<abi>/{include,lib}.
#
#   AndroidTV/Tools/build_sqlite.sh
#
# The shared core's database library (GRDB) expects the system to provide SQLite, which Android
# doesn't do for apps, so the Android build compiles its own from the official amalgamation (one
# public-domain C file). Options match what the core relies on: full-text search (FTS5), WAL
# snapshots (GRDB uses them), and no extension loading.
set -euo pipefail
cd "$(dirname "$0")/../.."
source AndroidTV/Tools/env.sh

VERSION=3540100   # SQLite 3.54.1
URL="https://sqlite.org/2026/sqlite-amalgamation-$VERSION.zip"
SHA3="92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30"   # SHA3-256, from sqlite.org
OUT="AndroidTV/build/sqlite"
DOWNLOADS="AndroidTV/build/downloads"
ZIP="$DOWNLOADS/sqlite-amalgamation-$VERSION.zip"

mkdir -p "$DOWNLOADS"
if [ ! -f "$ZIP" ]; then
    echo "==> Downloading SQLite $VERSION"
    curl -fsSL -o "$ZIP" "$URL"
fi
python3 -c "import hashlib,sys; h=hashlib.sha3_256(open(sys.argv[1],'rb').read()).hexdigest(); sys.exit(0 if h==sys.argv[2] else 'SQLite download has the wrong checksum: '+h)" "$ZIP" "$SHA3"
rm -rf "$DOWNLOADS/sqlite-amalgamation-$VERSION"
unzip -q -o "$ZIP" -d "$DOWNLOADS"
SRC="$DOWNLOADS/sqlite-amalgamation-$VERSION"

CLANG_DIR="$(echo "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*/bin)"
FLAGS=(-O2 -fPIC -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_SNAPSHOT -DSQLITE_OMIT_LOAD_EXTENSION
       -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1 -DSQLITE_TEMP_STORE=2 -DHAVE_USLEEP=1)

# abi:clang-target
for pair in armeabi-v7a:armv7a-linux-androideabi arm64-v8a:aarch64-linux-android x86_64:x86_64-linux-android; do
    abi="${pair%%:*}"; target="${pair#*:}"
    echo "==> SQLite for $abi"
    mkdir -p "$OUT/$abi/include" "$OUT/$abi/lib"
    "$CLANG_DIR/$target$LUMIO_ANDROID_API-clang" "${FLAGS[@]}" -c "$SRC/sqlite3.c" -o "$OUT/$abi/sqlite3.o"
    "$CLANG_DIR/llvm-ar" rcs "$OUT/$abi/lib/libsqlite3.a" "$OUT/$abi/sqlite3.o"
    rm "$OUT/$abi/sqlite3.o"
    cp "$SRC/sqlite3.h" "$SRC/sqlite3ext.h" "$OUT/$abi/include/"
done
echo "==> Done: $OUT"
