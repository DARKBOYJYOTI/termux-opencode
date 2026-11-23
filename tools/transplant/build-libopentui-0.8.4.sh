#!/usr/bin/env bash
#
# build-libopentui-0.8.4.sh — reproducible bionic build of the OpenTUI native
# library used by OpenCode v2 (opencode2).
#
# OpenCode v2 embeds a *glibc* libopentui.so in its bun standalone payload, so
# the TUI cannot dlopen it on Android. This script rebuilds the same library
# (OpenTUI 0.8.4, git d4a2af24) for aarch64-linux-android with zig 0.17.0 and
# installs a drop-in replacement for tools/transplant/swap_tui.py.
#
# Hard-won requirements (do not "simplify" these away):
#   1. zig 0.17.0 changed the --libc spec: crt_dir/cc_dir/gcc_dir are required,
#      and zig only accepts a libc installation when it can *find* libc.so on
#      the library path. We therefore pass -Dbionic-libdir=<crt dir> and keep
#      libc.so/libm.so/libdl.so symlinks there (libpthread/librt -> libc.so:
#      API 31 bionic dropped the separate libpthread stub).
#   2. Bionic headers refuse to compile without __ANDROID_API__ and
#      __ANDROID_MIN_SDK_VERSION__ (Termux headers ship android/ndk-version.h).
#      The target triple carries the API, but zig's translate-c steps do not,
#      so the build patch adds the macros to them explicitly.
#   3. Android 12 scudo returns TBI-tagged heap pointers (0xb4...). Native code
#      tolerates them (top-byte-ignore) but the JS FFI layer rejects values
#      above Number.MAX_SAFE_INTEGER. src/android-untag.c disables heap tagging
#      via mallopt(M_BIONIC_SET_HEAP_TAGGING_LEVEL, NONE) in a constructor.
#   4. swap_tui.py verifies the FFI negative-coordinate guard (mov w,#0x7fffffff
#      clamp + csel ..., vs). The 0.8.4 source predates those guards, so the
#      patch ports them; this script fails loudly if they are missing.
#   5. The replacement .so must fit the embedded asset slot (7,442,112 bytes).
#      Debug info alone makes it 24 MB, so --strip-debug (NOT --strip-all:
#      swap_tui needs .symtab to find the guard-owner functions).
#
# Usage:
#   tools/transplant/build-libopentui-0.8.4.sh
#   tools/transplant/build-libopentui-0.8.4.sh --check <libopentui.so>
#
# Output: artifacts/transplant/opentui-0.8.4/libopentui.so (+ .sha256)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

OPENTUI_VERSION="0.8.4"
OPENTUI_COMMIT="d4a2af24ba50636da5f222367f91746a1bf89644"
ZIG_VERSION="0.17.0"

# --- configurable locations (override via env) ---------------------------------
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  aarch64|arm64) ZIG_HOST="aarch64" ;;
  x86_64|amd64) ZIG_HOST="x86_64" ;;
  *) ZIG_HOST="$HOST_ARCH" ;;
esac

PREFIX_DIR="${PREFIX_DIR:-/data/data/com.termux/files/usr}"
# NDK sysroot mode (CI / cross builds): point at
# android-ndk-rNN/toolchains/llvm/prebuilt/linux-x86_64/sysroot. When unset the
# script uses Termux's local headers + /system/lib64.
NDK_SYSROOT="${NDK_SYSROOT:-}"
# Set SKIP_DLOPEN=1 where aarch64 bionic libraries cannot be loaded (x86_64 CI).
SKIP_DLOPEN="${SKIP_DLOPEN:-}"
SYSTEM_LIBDIR="${SYSTEM_LIBDIR:-/system/lib64}"
ANDROID_API="${ANDROID_API:-31}"
PATCH_FILE="${PATCH_FILE:-$REPO_ROOT/patches/opentui/android-bionic-0.8.4.patch}"
SHIM_SO="${SHIM_SO:-$REPO_ROOT/tools/transplant/toolchain/w7b-shim.so}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/artifacts/transplant/opentui-0.8.4}"
WORKDIR="${WORKDIR:-${TMPDIR:-/tmp}/opentui-$OPENTUI_VERSION-build}"
SOURCE_URL="${SOURCE_URL:-https://codeload.github.com/anomalyco/opentui/tar.gz/$OPENTUI_COMMIT}"
ZIG_URL="${ZIG_URL:-https://ziglang.org/download/$ZIG_VERSION/zig-$ZIG_HOST-linux-$ZIG_VERSION.tar.xz}"
ZIG_BIN="${ZIG_BIN:-$WORKDIR/zig-$ZIG_HOST-linux-$ZIG_VERSION/zig}"
EMBEDDED_SLOT_BYTES="${EMBEDDED_SLOT_BYTES:-7442112}"

say() { printf '%s\n' "$*" >&2; }
die() { printf 'build-libopentui-0.8.4: %s\n' "$*" >&2; exit 1; }

verify_guard() {
  local lib="$1"
  python3 - "$lib" "$REPO_ROOT" <<'EOF'
import sys
lib_path, repo_root = sys.argv[1], sys.argv[2]
sys.path.insert(0, repo_root + "/tools/transplant")
import swap_tui
lib = open(lib_path, "rb").read()
if swap_tui.is_glibc_linked(lib):
    sys.exit("glibc-linked .so (DT_NEEDED libc.so.6) can not dlopen on bionic")
if not swap_tui.has_ffi_guard(lib):
    sys.exit("FFI negative-coordinate guard missing (patches/opentui/android-bionic-0.8.4.patch not applied?)")
EOF
}

verify_dlopen() {
  local lib="$1"
  if [[ -n "$SKIP_DLOPEN" ]] || [[ "$(uname -m)" != aarch64 && "$(uname -m)" != arm64 ]]; then
    say "   dlopen check skipped (host is not aarch64; run on device)"
    return 0
  fi
  env -u LD_PRELOAD -u LD_LIBRARY_PATH python3 - "$lib" <<'EOF'
import ctypes, sys
ctypes.CDLL(sys.argv[1])
print("dlopen OK", file=sys.stderr)
EOF
}

if [[ "${1:-}" == "--check" ]]; then
  [[ -n "${2:-}" ]] || die "--check needs a libopentui.so path"
  verify_guard "$2"
  verify_dlopen "$2"
  exit 0
fi

mkdir -p "$WORKDIR"

# --- toolchain -----------------------------------------------------------------
if [[ ! -x "$ZIG_BIN" ]]; then
  say "== fetching zig $ZIG_VERSION"
  curl -fsSL "$ZIG_URL" -o "$WORKDIR/zig.tar.xz"
  tar xJf "$WORKDIR/zig.tar.xz" -C "$WORKDIR"
fi
[[ -x "$ZIG_BIN" ]] || die "zig binary not found: $ZIG_BIN"
"$ZIG_BIN" version | grep -qx "$ZIG_VERSION" || die "zig is not $ZIG_VERSION"

# --- source + patch ------------------------------------------------------------
SRC="$WORKDIR/src"
if [[ ! -d "$SRC/packages/native" ]]; then
  say "== fetching opentui $OPENTUI_VERSION ($OPENTUI_COMMIT)"
  curl -fsSL "$SOURCE_URL" -o "$WORKDIR/opentui.tar.gz"
  rm -rf "$SRC" "$WORKDIR/unpack"
  mkdir -p "$WORKDIR/unpack"
  tar xzf "$WORKDIR/opentui.tar.gz" -C "$WORKDIR/unpack"
  mv "$WORKDIR/unpack/opentui-$OPENTUI_COMMIT" "$SRC"
  rmdir "$WORKDIR/unpack"
fi

say "== applying $(basename "$PATCH_FILE")"
if patch -p1 -R --dry-run -f -d "$SRC" <"$PATCH_FILE" >/dev/null 2>&1; then
  say "   already applied"
else
  patch -p1 -d "$SRC" <"$PATCH_FILE"
fi

# vendored zig dependencies (ghostty, uucode, yoga)
NATIVE="$SRC/packages/native"
if [[ ! -d "$NATIVE/zig-deps/yoga" ]]; then
  say "== extracting vendored zig-deps"
  mkdir -p "$NATIVE/zig-deps"
  tar xzf "$NATIVE/src/vendor/zig-deps.tar.gz" -C "$NATIVE/zig-deps"
fi
[[ -d "$NATIVE/zig-deps/yoga" ]] || die "zig-deps/yoga missing after extraction"

# --- bionic sysroot pieces -----------------------------------------------------
MERGE="$WORKDIR/merge"
CRT="$WORKDIR/crt"
LIBC_TXT="$WORKDIR/libc.txt"
rm -rf "$MERGE" "$CRT"
mkdir -p "$CRT"

if [[ -n "$NDK_SYSROOT" ]]; then
  say "== preparing NDK sysroot pieces ($NDK_SYSROOT)"
  # NDK keeps arch-specific headers (asm/, bits/) in the per-arch include dir,
  # while bionic headers include <asm/...> directly. Merge both, like the
  # Termux recipe does, so zig's translate-c and C compiles see one tree.
  NDK_INC="$NDK_SYSROOT/usr/include"
  mkdir -p "$MERGE"
  for f in "$NDK_INC"/*; do ln -sfn "$f" "$MERGE/$(basename "$f")"; done
  for f in "$NDK_INC"/aarch64-linux-android/*; do ln -sfn "$f" "$MERGE/$(basename "$f")"; done
  NDK_LIB_DIR="$NDK_SYSROOT/usr/lib/aarch64-linux-android/$ANDROID_API"
  [[ -d "$NDK_LIB_DIR" ]] || NDK_LIB_DIR="$NDK_SYSROOT/usr/lib/aarch64-linux-android"
  [[ -e "$MERGE/asm/auxvec.h" ]] || die "merged NDK headers missing asm/auxvec.h"
  [[ -f "$NDK_LIB_DIR/libc.so" ]] || die "NDK stub libraries missing in $NDK_LIB_DIR"
  for l in libc.so libm.so libdl.so; do ln -sfn "$NDK_LIB_DIR/$l" "$CRT/$l"; done
  ln -sfn libc.so "$CRT/libpthread.so"
  ln -sfn libc.so "$CRT/librt.so"
  for o in crtbegin_so.o crtend_so.o crtbegin_dynamic.o crtend_android.o crt_pad_segment.o; do
    [[ -e "$NDK_LIB_DIR/$o" ]] && cp "$NDK_LIB_DIR/$o" "$CRT/$o"
  done
  CC_DIR="$NDK_LIB_DIR"
else
  say "== preparing merged bionic headers, crt objects, libc spec"
  mkdir -p "$MERGE"
  for f in "$PREFIX_DIR"/include/*; do ln -sfn "$f" "$MERGE/$(basename "$f")"; done
  for f in "$PREFIX_DIR"/include/aarch64-linux-android/*; do ln -sfn "$f" "$MERGE/$(basename "$f")"; done
  [[ -e "$MERGE/asm/auxvec.h" ]] || die "merged headers missing asm/auxvec.h"
  for o in crtbegin_so.o crtend_so.o crtbegin_dynamic.o crtend_android.o crt_pad_segment.o; do
    [[ -e "$PREFIX_DIR/lib/$o" ]] && cp "$PREFIX_DIR/lib/$o" "$CRT/$o"
  done
  ln -sfn "$SYSTEM_LIBDIR/libc.so" "$CRT/libc.so"
  ln -sfn "$SYSTEM_LIBDIR/libm.so" "$CRT/libm.so"
  ln -sfn "$SYSTEM_LIBDIR/libdl.so" "$CRT/libdl.so"
  ln -sfn libc.so "$CRT/libpthread.so"
  ln -sfn libc.so "$CRT/librt.so"
  CC_DIR="$PREFIX_DIR/lib"
fi

cat >"$LIBC_TXT" <<EOF
include_dir=$MERGE
sys_include_dir=$MERGE
crt_dir=$CRT
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
cc_dir=$CC_DIR
darwin_sdk_dir=
EOF

# --- pre-generate translate-c output ------------------------------------------
# zig's Build.TranslateC step has no --libc: on a glibc host it silently falls
# back to /usr/include and bionic headers fail on __GLIBC_USE. Generate the
# three translations here (where --libc is available) and let build.zig import
# them via -Dbionic-translate-dir.
TRANSLATE_DIR="$WORKDIR/translate"
EMPTY_SYSROOT="$WORKDIR/empty-sysroot"
rm -rf "$TRANSLATE_DIR"
mkdir -p "$TRANSLATE_DIR" "$EMPTY_SYSROOT"
say "== translating C headers with --libc (host-independent)"
(
  cd "$NATIVE"
  export ZIG_GLOBAL_CACHE_DIR="$WORKDIR/zig-cache"
  tc() {
    # --sysroot keeps the host's autodetected /usr/include out of the search
    # path (it would point into the empty dir); bionic comes from -isystem.
    "$ZIG_BIN" translate-c --libc "$LIBC_TXT" --sysroot "$EMPTY_SYSROOT" \
      -target "aarch64-linux-android.$ANDROID_API" \
      -O ReleaseSafe -isystem "$MERGE" -I src \
      -D__ANDROID_API__="$ANDROID_API" -D__ANDROID_MIN_SDK_VERSION__="$ANDROID_API" "$@"
  }
  tc src/vendor/miniaudio/miniaudio.h >"$TRANSLATE_DIR/miniaudio.zig"
  tc -I zig-deps/yoga src/yoga-bridge.h >"$TRANSLATE_DIR/yoga.zig"
  tc include/opentui.h >"$TRANSLATE_DIR/context.zig"
)
for f in miniaudio yoga context; do
  [[ -s "$TRANSLATE_DIR/$f.zig" ]] || die "translate-c produced no $f.zig"
done

# --- build ---------------------------------------------------------------------
say "== building libopentui.so for aarch64-linux-android$ANDROID_API"
PRELOAD=()
if [[ -f "$SHIM_SO" ]]; then
  PRELOAD=(env "LD_PRELOAD=$SHIM_SO")
fi
(
  cd "$NATIVE"
  export ZIG_GLOBAL_CACHE_DIR="$WORKDIR/zig-cache"
  "${PRELOAD[@]}" "$ZIG_BIN" build \
    -Dlibrary-target="aarch64-linux-android.$ANDROID_API" \
    -Doptimize=ReleaseSafe \
    -Dbionic-libdir="$CRT" \
    -Dbionic-include="$MERGE" \
    -Dbionic-api="$ANDROID_API" \
    -Dbionic-translate-dir="$TRANSLATE_DIR" \
    --libc "$LIBC_TXT"
)

BUILT="$NATIVE/lib/aarch64-linux-android.$ANDROID_API/libopentui.so"
[[ -f "$BUILT" ]] || die "build produced no $BUILT"

# --- strip + verify + install --------------------------------------------------
STRIP_BIN="${STRIP_BIN:-}"
if [[ -z "$STRIP_BIN" ]]; then
  for cand in llvm-strip llvm-strip-20 llvm-strip-19 llvm-strip-18 aarch64-linux-android-strip aarch64-linux-gnu-strip strip; do
    if command -v "$cand" >/dev/null 2>&1; then STRIP_BIN="$cand"; break; fi
  done
fi
[[ -n "$STRIP_BIN" ]] || die "no strip tool found (set STRIP_BIN)"
say "== stripping debug info with $STRIP_BIN (keeps .symtab for guard scans)"
mkdir -p "$OUT_DIR"
cp "$BUILT" "$OUT_DIR/libopentui.so"
"$STRIP_BIN" --strip-debug "$OUT_DIR/libopentui.so"
chmod 644 "$OUT_DIR/libopentui.so"

size=$(stat -c %s "$OUT_DIR/libopentui.so")
say "== stripped size: $size bytes (embeddable slot: $EMBEDDED_SLOT_BYTES)"
(( size <= EMBEDDED_SLOT_BYTES )) || die "library does not fit the embedded asset slot"

readelf -d "$OUT_DIR/libopentui.so" | grep -q 'NEEDED.*\[libc\.so\]' || die "missing NEEDED libc.so"
if readelf -d "$OUT_DIR/libopentui.so" | grep -q 'libc\.so\.6'; then
  die "glibc-linked output"
fi

verify_guard "$OUT_DIR/libopentui.so"
verify_dlopen "$OUT_DIR/libopentui.so"

( cd "$OUT_DIR" && sha256sum libopentui.so >libopentui.so.sha256 )
say "== installed $OUT_DIR/libopentui.so"
cat "$OUT_DIR/libopentui.so.sha256" >&2
