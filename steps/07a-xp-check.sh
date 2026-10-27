#!/bin/bash -eux

# Check what the Windows build actually produced: the PE subsystem version and
# the imported DLLs. Windows XP refuses to load an image whose subsystem version
# is newer than 5.1 (5.2 on XP x64), and it cannot resolve API set DLLs
# (api-ms-win-*), so this is the part of the XP work that CI can verify.

SOURCE=${PDFium_SOURCE_DIR:-pdfium}
BUILD=${PDFium_BUILD_DIR:-pdfium/out}
BUILD_TYPE=${PDFium_BUILD_TYPE:-shared}
DLL="$BUILD/pdfium.dll"

if [ "$BUILD_TYPE" != "shared" ]; then
  echo "Build type is '$BUILD_TYPE', not a DLL: nothing to check."
  exit 0
fi

if [ ! -f "$DLL" ]; then
  echo "Expected $DLL to exist."
  ls -la "$BUILD" | head -30
  exit 1
fi

echo "=== link flags used for pdfium.dll ==="
ninja -C "$BUILD" -t commands pdfium 2>/dev/null |
  grep -i 'link' |
  tail -3 |
  tr ' ' '\n' |
  grep -Ei 'subsystem|entry|libpath|yy-thunks|\.obj$|/defaultlib' || true

# The linker flags themselves are in the response file (GN writes
# {{ldflags}} into <output>.rsp on Windows), not in the command line above.
# The name varies with the output name and ninja may delete it again.
RSP=$(ls "$BUILD"/pdfium*.rsp 2>/dev/null | head -n 1)
if [ -n "$RSP" ]; then
  echo "=== $RSP ==="
  grep -Eio '(/|-)(subsystem|entry|libpath|defaultlib):[^ "]*' "$RSP" || true
else
  echo "No pdfium*.rsp left in $BUILD (ninja removed it after linking)"
fi

PYTHON=$(command -v python || command -v python3)

DLL="$DLL" "$PYTHON" - <<'PY'
import os
import struct
import sys

path = os.environ['DLL']
with open(path, 'rb') as f:
    data = f.read()


def u16(off):
    return struct.unpack_from('<H', data, off)[0]


def u32(off):
    return struct.unpack_from('<I', data, off)[0]


pe = u32(0x3C)
if data[pe:pe + 4] != b'PE\0\0':
    sys.exit('%s is not a PE image' % path)

coff = pe + 4
num_sections = u16(coff + 2)
opt_size = u16(coff + 16)
opt = coff + 20
magic = u16(opt)
pe32 = magic == 0x10B
if not pe32 and magic != 0x20B:
    sys.exit('unexpected optional header magic %#x' % magic)

# These absolute offsets are the same for PE32 and PE32+: the extra 4 bytes of
# PE32's BaseOfData cancel the extra 4 bytes of PE32+'s 64-bit ImageBase.
major_os, minor_os = u16(opt + 0x28), u16(opt + 0x2A)
major_sub, minor_sub = u16(opt + 0x30), u16(opt + 0x32)
subsystem = u16(opt + 0x44)
dirs = opt + (0x60 if pe32 else 0x70)
sections = opt + opt_size


def rva_to_offset(rva):
    for i in range(num_sections):
        s = sections + i * 40
        size = max(u32(s + 8), u32(s + 16))
        va = u32(s + 12)
        if va <= rva < va + size:
            return u32(s + 20) + (rva - va)
    raise ValueError('RVA %#x is not mapped by any section' % rva)


def read_cstr(rva):
    off = rva_to_offset(rva)
    end = data.index(b'\0', off)
    return data[off:end].decode('ascii', 'replace')


def data_dir(index):
    return u32(dirs + index * 8)


imports = []
imp_rva = data_dir(1)
if imp_rva:
    desc = rva_to_offset(imp_rva)
    while True:
        name = u32(desc + 12)
        if not name:
            break
        imports.append(read_cstr(name))
        desc += 20

delayed = []
delay_rva = data_dir(13)
if delay_rva:
    desc = rva_to_offset(delay_rva)
    while True:
        if u32(desc) == 0 and u32(desc + 4) == 0:
            break
        name = u32(desc + 4)
        if name:
            delayed.append(read_cstr(name))
        desc += 32

print('PE format          : %s' % ('PE32' if pe32 else 'PE32+'))
print('Minimum OS version : %d.%d' % (major_os, minor_os))
print('Subsystem          : %s' % {2: 'WINDOWS_GUI', 3: 'WINDOWS_CUI'}.get(subsystem, str(subsystem)))
print('Subsystem version  : %d.%d' % (major_sub, minor_sub))
print('Imports:')
for name in sorted(set(imports)):
    print('  ' + name)
if delayed:
    print('Delay-loaded imports:')
    for name in sorted(set(delayed)):
        print('  ' + name)

everything = imports + delayed
problems = []
if major_sub > 5:
    problems.append('PE subsystem version %d.%d is newer than Windows XP (5.1)' % (major_sub, minor_sub))
# lld-link copies the subsystem version into the OS version fields unless
# /osversion says otherwise, so both are set by the same /SUBSYSTEM flag.
if major_os > 5:
    problems.append('PE minimum OS version %d.%d is newer than Windows XP (5.1)' % (major_os, minor_os))
api_sets = [n for n in everything if n.lower().startswith(('api-ms-win-', 'ext-ms-win-'))]
if api_sets:
    problems.append('imports API set DLLs: %s' % ', '.join(sorted(set(api_sets))))
dynamic_crt = [n for n in everything if n.lower().startswith(('ucrtbase', 'vcruntime', 'msvcp', 'concrt', 'msvcr1'))]
if dynamic_crt:
    problems.append('imports a dynamic CRT: %s' % ', '.join(sorted(set(dynamic_crt))))

print('')
if problems:
    print('WINDOWS XP COMPATIBILITY: FAIL')
    for problem in problems:
        print('  - %s' % problem)
    sys.exit(1)

print('WINDOWS XP COMPATIBILITY: PASS')
print('(subsystem version <= 5.2, no API set and no dynamic CRT imports;')
print(' the remaining proof is loading pdfium.dll on a real Windows XP machine)')
PY
