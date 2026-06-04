#!/usr/bin/env bash
# Build PoDoFo as a static library (+ its 3rdparty/private archives) from source,
# linking its dependencies statically, into vendor/podofo. Run once; re-run to update.
#
# Follows https://github.com/podofo/podofo/blob/master/README.md (static linking),
# combined with the "Build with brew" dependency setup.
set -euo pipefail

PODOFO_VERSION="${PODOFO_VERSION:-1.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/src/podofo"
BUILD="$ROOT/vendor/build/podofo"
PREFIX="$ROOT/vendor/podofo"

command -v cmake >/dev/null || { echo "cmake required: brew install cmake"; exit 1; }
brew --prefix >/dev/null || { echo "Homebrew required"; exit 1; }

# Build-time dependencies (static archives are pulled from these kegs).
brew install fontconfig freetype openssl@3 libxml2 jpeg-turbo libpng libtiff cmake >/dev/null 2>&1 || true

# Fetch source at the pinned tag.
if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  git clone --depth 1 --branch "$PODOFO_VERSION" https://github.com/podofo/podofo.git "$SRC"
fi

rm -rf "$BUILD" "$PREFIX"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DPODOFO_BUILD_STATIC=TRUE \
  -DPODOFO_BUILD_LIB_ONLY=TRUE \
  -DCMAKE_FIND_FRAMEWORK=NEVER \
  -D"CMAKE_FIND_LIBRARY_SUFFIXES=.a;.dylib" \
  -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DCMAKE_PREFIX_PATH="$(brew --prefix)" \
  -DFontconfig_INCLUDE_DIR="$(brew --prefix fontconfig)/include" \
  -DOPENSSL_ROOT_DIR="$(brew --prefix openssl@3)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
  -DCMAKE_INSTALL_PREFIX="$PREFIX"

cmake --build "$BUILD" --config Release -j"$(sysctl -n hw.ncpu)"
cmake --install "$BUILD"

# Merge PoDoFo + all static dependencies into one archive for simple linking.
# (System libs — libxml2, z, bz2, expat, iconv — are linked with -l in the app.)
PFX_SSL="$(brew --prefix openssl@3)"
deps=(
  "$PREFIX/lib/libpodofo.a"
  "$PREFIX/lib/libpodofo_private.a"
  "$PREFIX/lib/libpodofo_3rdparty.a"
  "$PFX_SSL/lib/libssl.a"
  "$PFX_SSL/lib/libcrypto.a"
  "$(brew --prefix fontconfig)/lib/libfontconfig.a"
  "$(brew --prefix gettext)/lib/libintl.a"
  "$(brew --prefix freetype)/lib/libfreetype.a"
  "$(brew --prefix libpng)/lib/libpng16.a"
  "$(brew --prefix libtiff)/lib/libtiff.a"
  "$(brew --prefix jpeg-turbo)/lib/libjpeg.a"
  "$(brew --prefix brotli)/lib/libbrotlidec.a"
  "$(brew --prefix brotli)/lib/libbrotlicommon.a"
  "$(brew --prefix xz)/lib/liblzma.a"
  "$(brew --prefix zstd)/lib/libzstd.a"
)
for d in "${deps[@]}"; do [ -f "$d" ] || { echo "missing dep archive: $d"; exit 1; }; done
libtool -static -o "$PREFIX/lib/libpodofo_bundle.a" "${deps[@]}" 2>/dev/null

echo "=== installed static PoDoFo to $PREFIX ==="
ls -1 "$PREFIX/lib"/*.a 2>/dev/null || echo "(no .a found!)"
echo "bundle: $(du -h "$PREFIX/lib/libpodofo_bundle.a" 2>/dev/null | cut -f1)"
