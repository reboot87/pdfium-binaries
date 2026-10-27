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
OBJ_WIN=${YYTHUNKS_OBJ:-}
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

echo "YY-Thunks library directory: $LIB_DIR_WIN"
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
    # Only the import libraries are copied. The thunks entry point object is a
    # member of those libraries already (kernel32.lib pulls it in with a
    # /DEFAULTLIB: directive), and adding it a second time as a separate input
    # makes lld-link fail with "duplicate symbol".
    for f in "$LIB_DIR"/*; do
      case "$(basename "$f")" in
        *.Lib|*.lib) cp -f "$f" "$um/" ;;
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

# --- 2. Pin the PE subsystem version -----------------------------------------
#
# Chromium hardcodes the subsystem version in //build/config/win/BUILD.gn:
#
#   subsystem_version_suffix = ",10.0"
#   config("console")  { ldflags = [ "/SUBSYSTEM:CONSOLE$subsystem_version_suffix" ] }
#   config("windowed") { ldflags = [ "/SUBSYSTEM:WINDOWS$subsystem_version_suffix" ] }
#
# and //build/config/BUILDCONFIG.gn puts :console into the default configs of
# every Windows target (executables *and* shared libraries), so every image
# links with /SUBSYSTEM:*,10.0. Windows XP refuses to load images whose
# subsystem version is newer than 5.1 (5.2 on XP x64), so the suffix is lowered
# here, next to the per-target flags of step 3.
#
# The variable lives in build/config/win/BUILD.gn, not in the toolchain files,
# so search for it instead of assuming a location. Some versions spell the
# version inline ("/SUBSYSTEM:CONSOLE,10.0"), which the second expression
# rewrites too.

SUBSYSTEM_FILES=$(grep -rlI --exclude-dir=.git \
  -e 'subsystem_version_suffix' -e '/SUBSYSTEM:' \
  "$SOURCE/build/config" "$SOURCE/build/toolchain" 2>/dev/null || true)

if [ -z "$SUBSYSTEM_FILES" ]; then
  echo "WARNING: no file under build/config or build/toolchain mentions /SUBSYSTEM"
fi

for f in $SUBSYSTEM_FILES; do
  sed -i -E \
    -e "s|subsystem_version_suffix = \"[^\"]*\"|subsystem_version_suffix = \",$SUBSYSTEM\"|" \
    -e "s|/SUBSYSTEM:([A-Za-z]+),10\.[0-9]+|/SUBSYSTEM:\1,$SUBSYSTEM|g" \
    "$f"
  echo "Patched subsystem version in: $f"
  grep -n -E 'subsystem_version_suffix|/SUBSYSTEM:' "$f" | head -20
done

# --- 3. Add the YY-Thunks link flags to the PDFium DLL target -----------------

if [ "$BUILD_TYPE" == "shared" ]; then
  "$PYTHON" - "$SOURCE/BUILD.gn" "$SUBSYSTEM" "$GN_LIB_DIR" <<'PY'
import sys

path, subsystem, lib_dir = sys.argv[1:4]

with open(path, encoding='utf-8') as f:
    source = f.read()

anchor = 'shared_library("pdfium") {'
if anchor not in source:
    sys.exit('%s: %r not found' % (path, anchor))

nl = '\r\n' if '\r\n' in source else '\n'

# The flags live in a config, not in the target: Chromium appends the ldflags
# of the default configs (among them //build/config/win:console, i.e.
# "/SUBSYSTEM:CONSOLE,10.0") *after* the target's own ldflags, and lld-link
# keeps the last /SUBSYSTEM it sees, so a plain `ldflags` on the target is
# silently overridden. Removing the console config leaves the XP config as the
# only source of /SUBSYSTEM.
config_block = (
    'config("pdfium_xp_link") {\n'
    '  if (is_win) {\n'
    '    # Windows XP support (YY-Thunks): the image must not require a newer\n'
    '    # subsystem version than the OS, and a DLL must enter through the\n'
    '    # thunks CRT entry point so that thread_local does not crash XP. The\n'
    '    # entry point comes from YY-Thunks itself, which is on the library\n'
    '    # search path and is also pulled in by the import libraries.\n'
    '    ldflags = [\n'
    '      "/SUBSYSTEM:WINDOWS,%s",\n'
    '      "/ENTRY:DllMainCRTStartupForYY_Thunks",\n'
    '      "/LIBPATH:%s",\n'
    '    ]\n'
    '  }\n'
    '}\n'
) % (subsystem, lib_dir)

target_block = (
    '  if (is_win) {\n'
    '    # See config("pdfium_xp_link") above: drop Chromium\'s default\n'
    '    # /SUBSYSTEM:CONSOLE and link the DLL with the XP subsystem version.\n'
    '    configs -= [ "//build/config/win:console" ]\n'
    '    configs += [ ":pdfium_xp_link" ]\n'
    '  }\n'
)

config_block = config_block.replace('\n', nl)
target_block = target_block.replace('\n', nl)

source = source.replace(
    anchor,
    config_block + nl + anchor + nl + target_block,
    1,
)

with open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(source)

print(config_block)
print(target_block)
PY
else
  echo "Build type is '$BUILD_TYPE', not a DLL: skipping the link flag injection."
fi

# --- 4. Report -----------------------------------------------------------------

{
  echo "## Windows XP link configuration"
  echo
  echo "- YY-Thunks library directory: \`$LIB_DIR_WIN\`"
  echo "- PE subsystem version: \`$SUBSYSTEM\`"
  echo "- Windows SDK import library directories replaced: \`$REPLACED\`"
  if [ "$BUILD_TYPE" == "shared" ]; then
    echo
    echo '```gn'
    sed -n '/^config("pdfium_xp_link") {/,/^  output_name/p' "$SOURCE/BUILD.gn"
    echo '```'
  fi
} >>"${GITHUB_STEP_SUMMARY:-/dev/null}"
