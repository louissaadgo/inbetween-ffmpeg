#!/bin/sh
# FFmpeg for Windows (x86-64) as Inbetween brings it beside the app, built on
# Linux with the MinGW-w64 cross compiler from the sources in sources.txt:
#
#   ./build.sh          builds everything, into out/:
#                         inbetween-ffmpeg-<VERSION>-win64.zip   ffmpeg/ as it goes beside the app
#                         inbetween-ffmpeg-<VERSION>-source.tar  every source and this repository's files
#                         SHA256SUMS, RELEASE-NOTES.md
#   ./build.sh fetch    only downloads and checks the sources (into cache/)
#
# What's in it, and why (README.md has more):
#   - FFmpeg under the GNU LGPL, version 2.1 or later: no --enable-gpl, no
#     GPL libraries;
#   - only the encoders Inbetween uses (ENCODERS below): H.264 and H.265
#     through Windows' own encoder (Media Foundation) or the graphics card's
#     (NVIDIA NVENC, AMD AMF), never x264, x265 or any other software encoder
#     of a patent-pooled format; VP9 (libvpx), WebP, ProRes, GIF, PNG, MJPEG,
#     AAC, Opus, PCM;
#   - every decoder but VVC's, so videos import whatever made them;
#   - libraries: zlib, libvpx, libwebp, Opus, dav1d (AV1), NVIDIA's and AMD's
#     encoder headers, all static inside FFmpeg's DLLs.
#
# Needs: x86_64-w64-mingw32-gcc with the win32 thread model (Ubuntu's
# gcc-mingw-w64-x86-64-win32), nasm, meson, ninja, make, pkg-config, curl,
# zip, sha256sum (.github/workflows/release.yml installs them). JOBS=<n> sets
# how many compile at once (default: all cores).
set -eu

cd "$(dirname "$0")"
here=$PWD
version=$(cat VERSION)
host=x86_64-w64-mingw32
jobs=${JOBS:-$(nproc)}
cache=$here/cache
work=$here/work
prefix=$work/prefix
out=$here/out

# the encoders: what Inbetween's export, its proxies and its probes use
# (internal/media in the app), nothing else
ENCODERS=h264_mf,hevc_mf,h264_nvenc,hevc_nvenc,h264_amf,hevc_amf,libvpx_vp9,libwebp,libwebp_anim,prores_ks,gif,png,mjpeg,rawvideo,wrapped_avframe,aac,libopus,pcm_s16le

# archive <name> <version> <url>: the file a source is kept as in cache/
archive() {
	case $3 in
	*.tar.xz) echo "$1-$2.tar.xz" ;;
	*.tar.gz) echo "$1-$2.tar.gz" ;;
	*.tar.bz2) echo "$1-$2.tar.bz2" ;;
	*) echo "$3: unknown archive type" >&2; exit 1 ;;
	esac
}

# fetch: every source into cache/, checked against its pinned SHA-256
fetch() {
	mkdir -p "$cache"
	grep -v '^[[:space:]]*\(#\|$\)' sources.txt | while read -r name ver url sha; do
		f=$cache/$(archive "$name" "$ver" "$url")
		if [ ! -f "$f" ]; then
			echo "downloading $name $ver"
			curl -fL --retry 3 -o "$f.part" "$url"
			mv "$f.part" "$f"
		fi
		echo "$sha  $f" | sha256sum -c --quiet - || {
			echo "$f doesn't match its pinned SHA-256: deleted it, run again" >&2
			rm -f "$f"
			exit 1
		}
	done
}

if [ "${1:-}" = fetch ]; then
	fetch
	exit 0
fi
[ $# -eq 0 ] || { echo "usage: $0 [fetch]" >&2; exit 2; }

# the cross compiler: MinGW-w64 GCC with Windows' own threads (with POSIX
# threads, the DLLs would need libwinpthread-1.dll beside them)
command -v $host-gcc >/dev/null || { echo "$host-gcc not found (Ubuntu: gcc-mingw-w64-x86-64-win32)" >&2; exit 1; }
$host-gcc -v 2>&1 | grep -q 'Thread model: win32' || { echo "$host-gcc must use the win32 thread model (update-alternatives --config $host-gcc)" >&2; exit 1; }
for t in nasm meson ninja make pkg-config zip; do
	command -v $t >/dev/null || { echo "$t not found" >&2; exit 1; }
done
# a tagged release builds the version it's tagged with
case ${GITHUB_REF_NAME:-} in
v*) [ "$GITHUB_REF_NAME" = "v$version" ] || { echo "tag $GITHUB_REF_NAME, but VERSION says $version" >&2; exit 1; } ;;
esac

fetch
rm -rf "$work" "$out"
mkdir -p "$work/src" "$prefix/include" "$prefix/lib/pkgconfig" "$out"

# unpack <name>: its source into work/src/<name>, its top folder dropped
unpack() {
	line=$(grep "^$1[[:space:]]" "$here/sources.txt")
	set -- $line
	mkdir -p "$work/src/$1"
	tar -xf "$cache/$(archive "$1" "$2" "$3")" -C "$work/src/$1" --strip-components=1
	cd "$work/src/$1"
}

export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=
cflags="-O2"

echo "== zlib"
unpack zlib
make -f win32/Makefile.gcc PREFIX=$host- CFLAGS="$cflags" -j"$jobs" libz.a
install -m644 libz.a "$prefix/lib/"
install -m644 zlib.h zconf.h "$prefix/include/"

echo "== libvpx"
unpack libvpx
CROSS=$host- ./configure --target=x86_64-win64-gcc --prefix="$prefix" --enable-static --disable-shared \
	--disable-examples --disable-tools --disable-docs --disable-unit-tests --as=nasm
# Windows' own threads, not MinGW's POSIX ones (they'd need libwinpthread
# beside the DLLs): libvpx takes Windows' when it thinks there's no
# pthread.h, and its configure finds MinGW's, with no switch to say no
# (vpx_config.asm is made from vpx_config.h)
sed -i 's/^#define HAVE_PTHREAD_H 1/#define HAVE_PTHREAD_H 0/; s/^#define HAVE_PTHREAD_SETNAME_NP 1/#define HAVE_PTHREAD_SETNAME_NP 0/' vpx_config.h
# only the library, installed by hand: make's default (and its install)
# also builds libvpxrc, a C++ rate controller FFmpeg doesn't use
make -j"$jobs" libvpx.a vpx.pc
sed -i 's/ -lpthread//' vpx.pc
install -m644 libvpx.a "$prefix/lib/"
install -m644 vpx.pc "$prefix/lib/pkgconfig/"
mkdir -p "$prefix/include/vpx"
install -m644 vpx/*.h "$prefix/include/vpx/"

echo "== libwebp"
unpack libwebp
./configure --host=$host --prefix="$prefix" --enable-static --disable-shared --enable-libwebpmux --enable-libwebpdemux \
	--disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic CFLAGS="$cflags"
make -j"$jobs"
make install

echo "== opus"
unpack opus
./configure --host=$host --prefix="$prefix" --enable-static --disable-shared --disable-doc --disable-extra-programs CFLAGS="$cflags"
make -j"$jobs"
make install

echo "== dav1d"
unpack dav1d
cat >"$work/cross.txt" <<CROSS
[binaries]
c = '$host-gcc'
ar = '$host-ar'
strip = '$host-strip'
windres = '$host-windres'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
CROSS
meson setup build --cross-file="$work/cross.txt" --prefix="$prefix" --libdir=lib --buildtype=release \
	--default-library=static -Denable_tools=false -Denable_tests=false -Denable_examples=false
ninja -C build -j"$jobs" install

echo "== nv-codec-headers"
unpack nv-codec-headers
make PREFIX="$prefix" install

echo "== amf-headers"
unpack amf-headers
cp -R AMF "$prefix/include/"

echo "== ffmpeg"
unpack ffmpeg
set -- --prefix="$prefix/ffmpeg" --target-os=mingw32 --arch=x86_64 --cross-prefix=$host- \
	--pkg-config=pkg-config --pkg-config-flags=--static \
	--extra-cflags="-I$prefix/include" --extra-ldflags="-L$prefix/lib -static-libgcc" \
	--extra-version=inbetween-${version#*-} \
	--enable-shared --disable-static --disable-debug --disable-doc --disable-ffplay --disable-network \
	--disable-autodetect --enable-w32threads --enable-d3d11va --enable-dxva2 --enable-mediafoundation \
	--enable-ffnvcodec --enable-nvenc --enable-amf \
	--enable-zlib --enable-libvpx --enable-libwebp --enable-libopus --enable-libdav1d \
	--disable-encoders --enable-encoder=$ENCODERS \
	--disable-decoder=vvc \
	--disable-indevs --enable-indev=lavfi --disable-outdevs
echo "./configure $*" >"$work/configure-line.txt"
./configure "$@" | tee "$work/configure.out"
grep -q '^License: LGPL version 2.1 or later$' "$work/configure.out" || { echo "FFmpeg isn't LGPL 2.1+ as configured" >&2; exit 1; }
make -j"$jobs"
make install

echo "== ffmpeg/ as it goes beside the app"
cd "$here"
stage=$work/stage
d=$stage/ffmpeg
mkdir -p "$d/bin"
cp "$prefix/ffmpeg/bin/ffmpeg.exe" "$prefix/ffmpeg/bin/ffprobe.exe" "$prefix/ffmpeg/bin/"*.dll "$d/bin/"
$host-strip --strip-unneeded "$d/bin/"*

# nothing in it may need a DLL every Windows doesn't have, but FFmpeg's
# own: no MinGW runtime DLL, and no Media Foundation one (Windows N has
# none until the Media Feature Pack: FFmpeg must load it only to encode
# with it, or ffmpeg.exe wouldn't start there at all)
own=$(cd "$d/bin" && ls *.dll | tr 'A-Z' 'a-z')
for f in "$d/bin/"*; do
	$host-objdump -p "$f" | sed -n 's/^[[:space:]]*DLL Name: //p' | tr 'A-Z' 'a-z' | while read -r dll; do
		case $dll in
		kernel32.dll | user32.dll | gdi32.dll | advapi32.dll | shell32.dll | ole32.dll | oleaut32.dll | bcrypt.dll | \
			msvcrt.dll | api-ms-win-*.dll | psapi.dll | shlwapi.dll | ws2_32.dll | secur32.dll | d3d11.dll | dxgi.dll | dxva2.dll) ;;
		*) echo "$own" | grep -qx "$dll" || { echo "$(basename "$f") needs $dll, which Windows doesn't have" >&2; exit 1; } ;;
		esac
	done
done

src=$work/src
cp "$src/ffmpeg/COPYING.LGPLv2.1" "$d/LICENSE.txt"

# section <title> <licence> <file|-> ...: one part of the notices
section() {
	printf '\n\n------------------------------------------------------------------------\n%s\n   Licence: %s\n------------------------------------------------------------------------\n\n' "$1" "$2"
	shift 2
	for f in "$@"; do
		cat "$f"
		printf '\n'
	done
}
# comment <file> <first line> <last line>: a licence kept in a source
# file's comment, its comment marks taken off
comment() {
	sed -n "$2,$3p" "$1" | sed -e 's#^[[:space:]]*/\*\**##' -e 's#^[[:space:]]*\*/##' -e 's#^[[:space:]]*\*[[:space:]]\{0,1\}##' -e 's#^//[[:space:]]\{0,1\}##' >"$work/$(basename "$1").licence"
	echo "$work/$(basename "$1").licence"
}
nvlic=$(comment "$src/nv-codec-headers/include/ffnvcodec/nvEncodeAPI.h" 2 25)
amflic=$(comment "$src/amf-headers/AMF/core/Version.h" 1 32)
{
	cat <<TXT
FFmpeg $(echo "$version" | cut -d- -f1) for Inbetween: third-party notices
==========================================================

This FFmpeg is free software under the GNU Lesser General Public License,
version 2.1 or later (LICENSE.txt). Built into it are the libraries below,
each under its own licence, reproduced here in full. Its complete source
code: see README.txt.
TXT
	section "FFmpeg (its own notice: some files are under MIT/X11/BSD-style licences)" "LGPL-2.1-or-later" "$src/ffmpeg/LICENSE.md"
	section "zlib $(grep '^zlib[[:space:]]' sources.txt | awk '{print $2}')" "Zlib" "$src/zlib/LICENSE"
	section "libvpx $(grep '^libvpx[[:space:]]' sources.txt | awk '{print $2}') (VP8/VP9)" "BSD-3-Clause, with Google's patent grant" "$src/libvpx/LICENSE" "$src/libvpx/PATENTS"
	section "libwebp $(grep '^libwebp[[:space:]]' sources.txt | awk '{print $2}') (WebP)" "BSD-3-Clause, with Google's patent grant" "$src/libwebp/COPYING" "$src/libwebp/PATENTS"
	section "Opus $(grep '^opus[[:space:]]' sources.txt | awk '{print $2}')" "BSD-3-Clause" "$src/opus/COPYING"
	section "dav1d $(grep '^dav1d[[:space:]]' sources.txt | awk '{print $2}') (AV1)" "BSD-2-Clause" "$src/dav1d/COPYING"
	section "NVIDIA Video Codec headers (nv-codec-headers $(grep '^nv-codec-headers[[:space:]]' sources.txt | awk '{print $2}'))" "MIT" "$nvlic"
	section "AMD Advanced Media Framework headers $(grep '^amf-headers[[:space:]]' sources.txt | awk '{print $2}')" "MIT" "$amflic"
	section "MinGW-w64 runtime (the programs and DLLs are linked with it)" "ZPL-2.1 and others below" "$here/licenses/mingw-w64-runtime.txt"
	printf '\nThey also hold GCC'"'"'s runtime library (libgcc), under the GNU GPL version 3 with\nthe GCC Runtime Library Exception, which lets it be part of any program.\n'
} >"$d/THIRD-PARTY-NOTICES.txt"

tag=v$version
ffver=$(echo "$version" | cut -d- -f1)
cat >"$d/README.txt" <<TXT
FFmpeg $ffver (build $version), as Inbetween brings it
==========================================

This folder holds FFmpeg, a separate free program made by the FFmpeg
developers, and the libraries built into it. Inbetween runs it (ffmpeg.exe,
ffprobe.exe) to read and write video and sound. It is not part of
Inbetween, and Inbetween's licence doesn't cover it.

Licence: the GNU Lesser General Public License, version 2.1 or later
(LICENSE.txt). The libraries built into it are under their own licences,
in THIRD-PARTY-NOTICES.txt. You may copy, change and share it under those
licences; nothing in Inbetween's licence limits that. It comes with no
warranty.

Its complete source code (FFmpeg and every library in it, exactly as built,
with the script that built it):
  https://github.com/louissaadgo/inbetween-ffmpeg/releases/tag/$tag
  (inbetween-ffmpeg-$version-source.tar)

How it was built: BUILD-INFO.txt. It leaves out x264, x265 and the other
software encoders of patent-pooled formats: Inbetween makes H.264 and H.265
video with Windows' own encoder or the graphics card's.

To use another FFmpeg, set it in Inbetween's Preferences > FFmpeg.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
TXT

{
	echo "inbetween-ffmpeg $version"
	echo
	echo "Sources (sources.txt):"
	grep -v '^[[:space:]]*\(#\|$\)' sources.txt | awk '{printf "  %-17s %-9s %s\n                    sha256 %s\n", $1, $2, $3, $4}'
	echo
	echo "Compiler: $($host-gcc --version | head -1) (win32 threads), $(nasm -v), meson $(meson --version)"
	echo
	echo "FFmpeg's configure:"
	sed 's/ --/\n  --/g' "$work/configure-line.txt"
	echo
	echo "Files (sha256):"
	(cd "$d" && sha256sum bin/* | sed 's/^/  /')
} >"$d/BUILD-INFO.txt"

# Windows text files: CRLF
for f in LICENSE.txt THIRD-PARTY-NOTICES.txt README.txt BUILD-INFO.txt; do
	sed -i 's/\r$//; s/$/\r/' "$d/$f"
done

echo "== out/"
zipname=inbetween-ffmpeg-$version-win64.zip
(cd "$stage" && zip -qr9X "$out/$zipname" ffmpeg)
# the source: every archive as downloaded, and this repository's files
srcdir=$work/inbetween-ffmpeg-$version-source
mkdir -p "$srcdir/sources"
cp README.md LICENSE VERSION sources.txt build.sh "$srcdir/"
cp -R licenses .github "$srcdir/"
grep -v '^[[:space:]]*\(#\|$\)' sources.txt | while read -r name ver url sha; do
	cp "$cache/$(archive "$name" "$ver" "$url")" "$srcdir/sources/"
done
tar -cf "$out/inbetween-ffmpeg-$version-source.tar" -C "$work" "inbetween-ffmpeg-$version-source"
cat >"$out/RELEASE-NOTES.md" <<TXT
FFmpeg $ffver for [Inbetween](https://inbetween.ink)'s Windows downloads, under the GNU LGPL 2.1 or later.

- \`$zipname\`: the \`ffmpeg\` folder as it goes beside Inbetween (programs, DLLs, licence, notices, README, build info).
- \`inbetween-ffmpeg-$version-source.tar\`: its complete source code: every source archive exactly as built (in \`sources/\`), and this repository's build script. Unpack it, put \`sources/*\` in \`cache/\` and run \`./build.sh\` to build it again.
- \`SHA256SUMS\`.
TXT
(cd "$out" && sha256sum "$zipname" "inbetween-ffmpeg-$version-source.tar" >SHA256SUMS)
ls -la "$out"
