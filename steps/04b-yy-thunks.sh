#!/bin/bash -eux

# Make the PDFium DLL able to load on Windows XP / XP x64 by wiring in YY-Thunks.
#
# YY-Thunks (Readme.md, "2.4.2 using lib files (LLD-Link)") requires:
#   1. its Lib/<min-os>/<arch> directory to be searched ahead of the Windows SDK,
#   2. the PE subsystem version to be 5.1 (5.2 for XP x64),
#   3. for a DLL, the CRT entry point DllMainCRTStartupForYY_Thunks
#      (without it XP may crash on thread_local).
#
# Chromium's Windows toolchain decides by itself how SDK library paths reach the
# linker, so instead of relying on /LIBPATH ordering the YY-Thunks import
# libraries are copied over the SDK ones: they are drop-in replacements with the
# exact same file names (kernel32.Lib, shell32.lib, mincore.lib, ...).

SOURCE=${PDFium_SOURCE_DIR:-pdfium}
LIB_DIR_WIN=${YYTHUNKS_LIB_DIR:?}
OBJ_WIN=${YYTHUNKS_OBJ:?}
SDK_ARCH=${YYTHUNKS_SDK_ARCH:?}
SUBSYSTEM=${YYTHUNKS_SUBSYSTEM:?}
BUILD_TYPE=${PDFium_BUILD_TYPE:-shared}

to_unix_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1"
  else
    printf '%s' "$1" | sed -e 's|\\|/|g'
  fi
}

PYTHON=$(command -v python || command -v python3)

LIB_DIR=$(to_unix_path "$LIB_DIR_WIN")
# GN/lld want forward slashes; no backslash escaping is needed then.
GN_LIB_DIR=$(printf '%s' "$LIB_DIR_WIN" | sed -e 's|\\|/|g')
GN_OBJ=$(printf '%s' "$OBJ_WIN" | sed -e 's|\\|/|g')

echo "YY-Thunks library directory: $LIB_DIR_WIN"
echo "YY-Thunks entry object:      $OBJ_WIN"
echo "YY-Thunks subsystem:         $SUBSYSTEM"

# --- 1. Replace the Windows SDK import libraries in place ---------------------

SDK_ROOTS=(
  "/c/Program Files (x86)/Windows Kits/10/Lib"
  "/c/Program Files/Windows Kits/10/Lib"
)

REPLACED=0
for root in "${SDK_ROOTS[@]}"; do
  [ -d "$root" ] || continue
  for um in "$root"/*/um/"$SDK_ARCH"; do
    [ -d "$um" ] || continue
    for f in "$LIB_DIR"/*; do
      case "$(basename "$f")" in
        *.Lib|*.lib|*.obj) cp -f "$f" "$um/" ;;
        *) ;;
      esac
    done
    echo "Replaced SDK import libraries in: $um"
    REPLACED=$((REPLACED + 1))
  done
done

if [ "$REPLACED" -eq 0 ]; then
  echo "No Windows SDK um/$SDK_ARCH directory found. Candidates:"
  ls -d "/c/Program Files (x86)/Windows Kits"/* 2>/dev/null || true
  ls -d "/c/Program Files (x86)/Windows Kits/10/Lib"/* 2>/dev/null || true
  exit 1
fi

# --- 2. Pin the PE subsystem version of the PDFium DLL ------------------------
#
# PDFium links through Chromium's Windows toolchain, which hardcodes
# "/SUBSYSTEM:* ,10.0" and says it only supports Windows 10 or later. Windows XP
# refuses to load images whose subsystem version is newer than 5.1 (5.2 on XP
# x64), so the suffix is lowered here as well, next to the per-target flags.

for f in "$SOURCE/build/toolchain/win/BUILD.gn" "$SOURCE/build/toolchain/win/toolchain.gni"; do
  [ -f "$f" ] || continue
  if grep -q 'subsystem_version_suffix' "$f"; then
    sed -i "s|subsystem_version_suffix = \"[^\"]*\"|subsystem_version_suffix = \",$SUBSYSTEM\"|" "$f"
    grep -n 'subsystem_version_suffix' "$f"
  fi
done

# --- 3. Add the YY-Thunks link flags to the PDFium DLL target -----------------

if [ "$BUILD_TYPE" == "shared" ]; then
  "$PYTHON" - "$SOURCE/BUILD.gn" "$SUBSYSTEM" "$GN_OBJ" "$GN_LIB_DIR" <<'PY'
import sys

path, subsystem, obj, lib_dir = sys.argv[1:5]

with open(path, encoding='utf-8') as f:
    source = f.read()

anchor = 'shared_library("pdfium") {'
if anchor not in source:
    sys.exit('%s: %r not found' % (path, anchor))

nl = '\r\n' if '\r\n' in source else '\n'
block = (
    '  if (is_win) {\n'
    '    # Windows XP support (YY-Thunks): the image must not require a newer\n'
    '    # subsystem version than the OS, and a DLL must enter through the\n'
    '    # thunks CRT entry point so that thread_local does not crash XP.\n'
    '    ldflags = [\n'
    '      "/SUBSYSTEM:WINDOWS,%s",\n'
    '      "/ENTRY:DllMainCRTStartupForYY_Thunks",\n'
    '      "/LIBPATH:%s",\n'
    '      "%s",\n'
    '    ]\n'
    '  }\n'
) % (subsystem, lib_dir, obj)
block = block.replace('\n', nl)

source = source.replace(anchor, anchor + nl + block, 1)

with open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(source)

print(block)
PY
else
  echo "Build type is '$BUILD_TYPE', not a DLL: skipping the link flag injection."
fi

# --- 4. Report -----------------------------------------------------------------

{
  echo "## Windows XP link configuration"
  echo
  echo "- YY-Thunks library directory: \`$LIB_DIR_WIN\`"
  echo "- YY-Thunks entry object: \`$OBJ_WIN\`"
  echo "- PE subsystem version: \`$SUBSYSTEM\`"
  echo "- Windows SDK import library directories replaced: \`$REPLACED\`"
  if [ "$BUILD_TYPE" == "shared" ]; then
    echo
    echo '```gn'
    sed -n '/shared_library("pdfium") {/,/^  output_name/p' "$SOURCE/BUILD.gn"
    echo '```'
  fi
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
