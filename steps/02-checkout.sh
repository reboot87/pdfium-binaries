#!/bin/bash -eux

PDFium_URL='https://pdfium.googlesource.com/pdfium.git'
OS=${PDFium_TARGET_OS:?}
ENABLE_V8=${PDFium_ENABLE_V8:-false}
ENABLE_SKIA=${PDFium_ENABLE_SKIA:-false}

CONFIG_ARGS=()
if [ "$ENABLE_V8" == "false" ]; then
  CONFIG_ARGS+=(
     --custom-var "checkout_configuration=minimal"
  )
fi

# The minimal checkout configuration sets checkout_skia=False, so the Skia
# sources are skipped. Re-enable them when the Skia rendering backend is
# requested, otherwise gn fails loading //third_party/skia/gn/codec.gni.
if [ "$ENABLE_SKIA" == "true" ]; then
  CONFIG_ARGS+=(
     --custom-var "checkout_skia=true"
  )
fi

# Clone
gclient config --unmanaged "$PDFium_URL" "${CONFIG_ARGS[@]-}"
echo "target_os = [ '$OS' ]" >> .gclient


# Reset
if [ -d pdfium ]; then
  find pdfium -name .git -prune -execdir sh -xc 'git reset --hard && git clean -df' \;
fi

gclient sync -r "origin/${PDFium_BRANCH:-main}" --no-history --shallow
