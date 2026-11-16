#!/bin/sh
# FFmpeg as Inbetween brings it, from the sources in sources.txt: for
# Windows (x86-64), beside the app, built on Linux with the MinGW-w64 cross
# compiler; for macOS (Apple silicon and Intel, macOS 13 or later), inside
# the app, built natively on a Mac of each kind:
#
#   ./build.sh            Windows, on Linux; into out/:
#                           inbetween-ffmpeg-<VERSION>-win64.zip   ffmpeg/ as it goes beside the app
#                           inbetween-ffmpeg-<VERSION>-source.tar  every source and this repository's files
#                           SHA256SUMS, RELEASE-NOTES.md
#   ./build.sh macos      on a Mac: FFmpeg for that Mac's own architecture
#                         (arm64 or x86_64), into out/macos-<arch>/
#   ./build.sh macos-zip <arm64 dir> <x86_64 dir>
#                         on a Mac: the two builds as universal programs:
#                           out/inbetween-ffmpeg-<VERSION>-macos.zip       ffmpeg/, as Inbetween.app takes it
#                         (with one dir: out/inbetween-ffmpeg-<VERSION>-macos-<arch>.zip,
#                         for test builds only)
#   ./build.sh notes      SHA256SUMS and RELEASE-NOTES.md for the zips and the
#                         source in out/ (the release workflow joins the builds with it)
#   ./build.sh fetch      only downloads and checks the sources (into cache/)
#
# What's in it, and why (README.md has more):
#   - FFmpeg under the GNU LGPL, version 2.1 or later: no --enable-gpl, no
#     GPL libraries;
#   - only the encoders Inbetween uses (ENCODERS and MAC_ENCODERS below):
#     H.264 and H.265 through the system's own encoder (Media Foundation on
#     Windows, VideoToolbox on macOS) or, on Windows, the graphics card's
#     (NVIDIA NVENC, AMD AMF), never x264, x265 or any other software
#     encoder of a patent-pooled format; VP9 (libvpx), WebP, ProRes, GIF,
#     PNG, MJPEG, AAC, Opus, PCM;
#   - every decoder but VVC's, so videos import whatever made them;
#   - libraries: zlib, libvpx, libwebp, Opus, dav1d (AV1), and on Windows
#     NVIDIA's and AMD's encoder headers, all static: inside FFmpeg's DLLs
#     on Windows, inside the two programs on macOS.
#
# Needs, for Windows: x86_64-w64-mingw32-gcc with the win32 thread model
# (Ubuntu's gcc-mingw-w64-x86-64-win32), nasm, meson, ninja, make,
# pkg-config, curl, zip, sha256sum. For macOS: the Xcode Command Line
# Tools, and from Homebrew meson, ninja, pkgconf, make (GNU make, as gmake)
# and, on Intel, nasm. (.github/workflows/release.yml installs them.)
# JOBS=<n> sets how many compile at once (default: all cores).
set -eu

cd "$(dirname "$0")"
here=$PWD
version=$(cat VERSION)
host=x86_64-w64-mingw32
jobs=${JOBS:-$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)}
cache=$here/cache
work=$here/work
prefix=$work/prefix
out=$here/out

# the encoders: what Inbetween's export, its proxies and its probes use
# (internal/media in the app), nothing else
ENCODERS=h264_mf,hevc_mf,h264_nvenc,hevc_nvenc,h264_amf,hevc_amf,libvpx_vp9,libwebp,libwebp_anim,prores_ks,gif,png,mjpeg,rawvideo,wrapped_avframe,aac,libopus,pcm_s16le
# on macOS, H.264 and H.265 through VideoToolbox, the encoder built into
# macOS (it uses the Mac's media engine, or software where there's none)
MAC_ENCODERS=h264_videotoolbox,hevc_videotoolbox,libvpx_vp9,libwebp,libwebp_anim,prores_ks,gif,png,mjpeg,rawvideo,wrapped_avframe,aac,libopus,pcm_s16le
# the oldest macOS it runs on: Inbetween's own
MAC_MIN=13.0

usage() {
	echo "usage: $0 [fetch | notes | macos | macos-zip <arm64 dir> [<x86_64 dir>]]" >&2
	exit 2
}

# sha256 <file>...: sha256sum, or shasum on a Mac without it (the same
# "<hash>  <file>" lines)
if command -v sha256sum >/dev/null 2>&1; then
	sha256() { sha256sum "$@"; }
else
	sha256() { shasum -a 256 "$@"; }
fi

# archive <name> <version> <url>: the file a source is kept as in cache/
archive() {
	case $3 in
	*.tar.xz) echo "$1-$2.tar.xz" ;;
	*.tar.gz) echo "$1-$2.tar.gz" ;;
	*.tar.bz2) echo "$1-$2.tar.bz2" ;;
	*) echo "$3: unknown archive type" >&2; exit 1 ;;
	esac
}

# sources: sources.txt without its comments and blank lines
sources() {
	grep -Ev '^[[:space:]]*(#|$)' "$here/sources.txt"
}

# fetch: every source into cache/, checked against its pinned SHA-256
fetch() {
	mkdir -p "$cache"
	sources | while read -r name ver url sha; do
		f=$cache/$(archive "$name" "$ver" "$url")
		if [ ! -f "$f" ]; then
			echo "downloading $name $ver"
			curl -fL --retry 3 -o "$f.part" "$url"
			mv "$f.part" "$f"
		fi
		[ "$(sha256 "$f" | awk '{print $1}')" = "$sha" ] || {
			echo "$f doesn't match its pinned SHA-256: deleted it, run again" >&2
			rm -f "$f"
			exit 1
		}
	done
}

# unpack <name>: its source into work/src/<name>, its top folder dropped
unpack() {
	line=$(grep "^$1[[:space:]]" "$here/sources.txt")
	set -- $line
	mkdir -p "$work/src/$1"
	tar -xf "$cache/$(archive "$1" "$2" "$3")" -C "$work/src/$1" --strip-components=1
	cd "$work/src/$1"
}

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

# pinned <name>: the version sources.txt pins
pinned() {
	grep "^$1[[:space:]]" "$here/sources.txt" | awk '{print $2}'
}

# notes: RELEASE-NOTES.md and SHA256SUMS for what's in out/ (the Windows
# zip, the macOS zip, the source)
notes() {
	ffver=$(echo "$version" | cut -d- -f1)
	win=inbetween-ffmpeg-$version-win64.zip
	mac=inbetween-ffmpeg-$version-macos.zip
	src=inbetween-ffmpeg-$version-source.tar
	cd "$out"
	[ -f "$win" ] || [ -f "$mac" ] || { echo "out/ has neither $win nor $mac" >&2; exit 1; }
	if [ -f "$win" ] && [ -f "$mac" ]; then
		systems="Windows and macOS"
	elif [ -f "$win" ]; then
		systems=Windows
	else
		systems=macOS
	fi
	{
		echo "FFmpeg $ffver for [Inbetween](https://inbetween.ink)'s $systems downloads, under the GNU LGPL 2.1 or later."
		echo
		[ ! -f "$win" ] || echo "- \`$win\`: the \`ffmpeg\` folder as it goes beside Inbetween (programs, DLLs, licence, notices, README, build info)."
		[ ! -f "$mac" ] || echo "- \`$mac\`: the \`ffmpeg\` folder for Inbetween on macOS: \`ffmpeg\` and \`ffprobe\` for Mac computers with Apple silicon or an Intel processor (macOS $MAC_MIN or later), licence, notices, README, build info. Inbetween.app holds the programs in \`Contents/MacOS\` and the texts in \`Contents/Resources/ffmpeg\`."
		if [ -f "$src" ]; then
			again="run \`./build.sh\` to build it again"
			[ ! -f "$mac" ] || again="run \`./build.sh\` (Windows, on Linux) or \`./build.sh macos\` on each kind of Mac, then \`./build.sh macos-zip\` (README.md says how), to build it again"
			echo "- \`$src\`: its complete source code: every source archive exactly as built (in \`sources/\`), and this repository's build script. Unpack it, put \`sources/*\` in \`cache/\` and $again."
		fi
		echo "- \`SHA256SUMS\`."
	} >RELEASE-NOTES.md
	files=
	for f in "$win" "$mac" "$src"; do
		[ ! -f "$f" ] || files="$files $f"
	done
	sha256 $files >SHA256SUMS
	cd "$here"
}

# --- macOS ------------------------------------------------------------------

# mac_setup <mode>: a Mac, building for MAC_MIN
mac_setup() {
	[ "$(uname -s)" = Darwin ] || { echo "./build.sh $1 runs on a Mac" >&2; exit 1; }
	export MACOSX_DEPLOYMENT_TARGET=$MAC_MIN
	minos=-mmacosx-version-min=$MAC_MIN
}

# need <tool>...: each is installed
need() {
	for t in "$@"; do
		command -v "$t" >/dev/null || { echo "$t not found (README.md: Building on a Mac)" >&2; exit 1; }
	done
}

# mac_guard <program> <arch>: the program needs nothing macOS doesn't have
# (no Homebrew library, nothing in /usr/local), and starts on MAC_MIN
mac_guard() {
	otool -arch "$2" -L "$1" | tail -n +2 | awk '{print $1}' | while read -r lib; do
		case $lib in
		/usr/lib/* | /System/Library/*) ;;
		*) echo "$(basename "$1") ($2) needs $lib, which macOS doesn't have" >&2; exit 1 ;;
		esac
	done
	v=$(otool -arch "$2" -l "$1" | awk '$1 == "cmd" && $2 == "LC_BUILD_VERSION" {b = 1} b && $1 == "minos" {print $2; exit}')
	[ -n "$v" ] || { echo "$(basename "$1") ($2) has no LC_BUILD_VERSION: what macOS it needs is unknown" >&2; exit 1; }
	awk -v v="$v" -v m="$MAC_MIN" 'BEGIN { split(v, a, "."); split(m, b, "."); exit !(a[1] + 0 < b[1] + 0 || (a[1] + 0 == b[1] + 0 && a[2] + 0 <= b[2] + 0)) }' ||
		{ echo "$(basename "$1") ($2) needs macOS $v; it must start on $MAC_MIN" >&2; exit 1; }
}

# smoke <bin dir>: its ffmpeg and ffprobe run here, make what Inbetween
# asks of them and read it back
smoke() {
	ff=$1/ffmpeg
	fp=$1/ffprobe
	t=$work/smoke
	rm -rf "$t"
	mkdir -p "$t"
	echo "== smoke test: $("$ff" -hide_banner -version | head -1)"
	pic="-f lavfi -i testsrc2=size=320x240:rate=24:duration=1"
	snd="-f lavfi -i sine=frequency=440:duration=1"
	# made <file> <codec>: ffprobe reads <codec> in the file made
	made() {
		c=$("$fp" -v error -select_streams 0 -show_entries stream=codec_name -of csv=p=0 "$t/$1" || true)
		[ "$c" = "$2" ] || { echo "smoke test: $1 is ${c:-unreadable}, not $2" >&2; exit 1; }
		echo "  $1: $2"
	}
	"$ff" -hide_banner -v error -y $pic -c:v prores_ks -profile:v 3 "$t/prores.mov"
	made prores.mov prores
	"$ff" -hide_banner -v error -y $pic -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -crf 40 -b:v 0 "$t/vp9.webm"
	made vp9.webm vp9
	"$ff" -hide_banner -v error -y $pic -frames:v 1 -c:v libwebp "$t/still.webp"
	made still.webp webp
	"$ff" -hide_banner -v error -y $pic -c:v libwebp_anim -loop 0 "$t/anim.webp"
	[ -s "$t/anim.webp" ] || { echo "smoke test: no animated WebP made" >&2; exit 1; }
	echo "  anim.webp: made"
	"$ff" -hide_banner -v error -y $pic -c:v gif "$t/anim.gif"
	made anim.gif gif
	"$ff" -hide_banner -v error -y $snd -c:a libopus "$t/sound.opus"
	made sound.opus opus
	"$ff" -hide_banner -v error -y $snd -c:a aac "$t/sound.m4a"
	made sound.m4a aac
	# H.264 decoded: one 16x16 grey frame (made with x264, its SEI taken
	# out: 43 bytes)
	printf '\000\000\000\001\147\102\300\012\332\173\001\020\000\000\003\000\020\000\000\003\000\040\361\042\152\000\000\000\001\150\316\017\310\000\000\001\145\210\204\072\046\050\016' >"$t/grey.h264"
	n=$("$fp" -v error -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$t/grey.h264" || true)
	[ "$n" = 1 ] || { echo "smoke test: H.264 decoded ${n:-no} frames, not 1" >&2; exit 1; }
	"$ff" -hide_banner -v error -i "$t/grey.h264" -f null -
	echo "  grey.h264: h264 decoded"
	# VideoToolbox: tried, never required here (GitHub's Mac runners are
	# virtual machines, which may lack it); Inbetween falls back by itself
	for e in h264_videotoolbox hevc_videotoolbox; do
		if "$ff" -hide_banner -v error -y $pic -c:v $e -allow_sw 1 -b:v 2M "$t/$e.mp4" 2>"$t/$e.log" && [ -s "$t/$e.mp4" ]; then
			echo "  $e: works here"
		else
			echo "  $e: didn't run here, not a failure ($(tail -1 "$t/$e.log" 2>/dev/null))"
		fi
	done
}

# build_macos: FFmpeg for this Mac's architecture, into out/macos-<arch>/
# (bin/ffmpeg, bin/ffprobe, and what BUILD-INFO.txt says of them)
build_macos() {
	mac_setup macos
	arch=$(uname -m)
	case $arch in
	arm64) vpx=arm64-darwin22-gcc ;;   # darwin22: macOS 13 (libvpx adds only -arch)
	x86_64) vpx=x86_64-darwin22-gcc ;;
	*) echo "$arch: not a Mac architecture this builds" >&2; exit 1 ;;
	esac
	need clang xcrun otool codesign strip install meson ninja pkg-config gmake curl tar
	# (x86 assembly: libvpx, dav1d and FFmpeg's own)
	[ "$arch" = arm64 ] || need nasm
	o=$out/macos-$arch

	fetch
	rm -rf "$work" "$o"
	mkdir -p "$work/src" "$prefix/include" "$prefix/lib/pkgconfig" "$o/bin"
	# only our own libraries: never Homebrew's (pkg-config looks nowhere
	# else, and our lib/ comes first on every link line)
	export CC=clang PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=
	cflags="-O2 $minos"

	echo "== zlib"
	unpack zlib
	CFLAGS="$cflags" ./configure --static --prefix="$prefix"
	gmake -j"$jobs" libz.a
	install -m644 libz.a "$prefix/lib/"
	install -m644 zlib.h zconf.h "$prefix/include/"

	echo "== libvpx"
	unpack libvpx
	set -- --target=$vpx --prefix="$prefix" --enable-static --disable-shared \
		--disable-examples --disable-tools --disable-docs --disable-unit-tests --extra-cflags="$minos"
	if [ "$arch" = x86_64 ]; then
		set -- "$@" --as=nasm
	fi
	./configure "$@"
	# only the library (as on Windows: make's default also builds libvpxrc,
	# a C++ rate controller FFmpeg doesn't use)
	gmake -j"$jobs" libvpx.a vpx.pc
	install -m644 libvpx.a "$prefix/lib/"
	install -m644 vpx.pc "$prefix/lib/pkgconfig/"
	mkdir -p "$prefix/include/vpx"
	install -m644 vpx/*.h "$prefix/include/vpx/"

	echo "== libwebp"
	unpack libwebp
	./configure --prefix="$prefix" --enable-static --disable-shared --enable-libwebpmux --enable-libwebpdemux \
		--disable-sdl --disable-gl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic CFLAGS="$cflags"
	gmake -j"$jobs"
	gmake install

	echo "== opus"
	unpack opus
	./configure --prefix="$prefix" --enable-static --disable-shared --disable-doc --disable-extra-programs CFLAGS="$cflags"
	gmake -j"$jobs"
	gmake install

	echo "== dav1d"
	unpack dav1d
	meson setup build --prefix="$prefix" --libdir=lib --buildtype=release \
		--default-library=static -Denable_tools=false -Denable_tests=false -Denable_examples=false \
		-Dc_args="$minos" -Dc_link_args="$minos"
	ninja -C build -j"$jobs" install

	echo "== ffmpeg"
	unpack ffmpeg
	# --disable-autodetect: nothing macOS offers is taken unasked (no
	# AudioToolbox, AVFoundation, Core Image, Metal, Secure Transport,
	# iconv, bzip2, lzma); threads and VideoToolbox are asked for
	set -- --prefix="$prefix/ffmpeg" --cc=clang \
		--pkg-config=pkg-config --pkg-config-flags=--static \
		--extra-cflags="-I$prefix/include $minos" --extra-ldflags="-L$prefix/lib $minos" \
		--extra-version=inbetween-${version#*-} \
		--enable-static --disable-shared --disable-debug --disable-doc --disable-ffplay --disable-network \
		--disable-autodetect --enable-pthreads --enable-videotoolbox \
		--enable-zlib --enable-libvpx --enable-libwebp --enable-libopus --enable-libdav1d \
		--disable-encoders --enable-encoder=$MAC_ENCODERS \
		--disable-decoder=vvc \
		--disable-indevs --enable-indev=lavfi --disable-outdevs
	echo "./configure $*" >"$o/configure-line.txt"
	./configure "$@" | tee "$work/configure.out"
	grep -q '^License: LGPL version 2.1 or later$' "$work/configure.out" || { echo "FFmpeg isn't LGPL 2.1+ as configured" >&2; exit 1; }
	# every encoder asked for is in (a library or framework not found
	# drops its encoder without a word)
	for e in $(echo "$MAC_ENCODERS" | tr , ' '); do
		grep -q "^#define CONFIG_$(echo "$e" | tr a-z A-Z)_ENCODER 1$" config_components.h ||
			{ echo "FFmpeg was configured without the $e encoder" >&2; exit 1; }
	done
	gmake -j"$jobs"
	gmake install

	echo "== out/macos-$arch/"
	cd "$here"
	for p in ffmpeg ffprobe; do
		cp "$prefix/ffmpeg/bin/$p" "$o/bin/"
		strip "$o/bin/$p"
		# signed again (ad hoc) after strip: Apple silicon only runs signed
		# programs (Inbetween's packaging signs them once more, as its own)
		codesign --force --sign - "$o/bin/$p"
		mac_guard "$o/bin/$p" "$arch"
	done
	{
		echo "Compiler: $(clang --version | head -1), macOS SDK $(xcrun --show-sdk-version), for macOS $MAC_MIN or later"
		echo "Tools: meson $(meson --version), ninja $(ninja --version), $(gmake --version | head -1)$([ "$arch" = arm64 ] || echo ", $(nasm -v)")"
	} >"$o/toolchain.txt"
	smoke "$o/bin"
	ls -la "$o" "$o/bin"
}

# macos_zip <dir> [<dir>]: build_macos's builds (arm64 and x86_64) as
# universal programs, with the licence, notices, README and build info,
# into out/inbetween-ffmpeg-<VERSION>-macos.zip (one build: a test zip
# named for its architecture)
macos_zip() {
	mac_setup macos-zip
	need lipo otool codesign zip curl tar
	for dir in "$@"; do
		for f in bin/ffmpeg bin/ffprobe configure-line.txt toolchain.txt; do
			[ -f "$dir/$f" ] || { echo "$dir isn't a ./build.sh macos build: no $f" >&2; exit 1; }
		done
	done
	fetch
	rm -rf "$work"
	mkdir -p "$work/src" "$out"
	stage=$work/stage
	d=$stage/ffmpeg
	mkdir -p "$d/bin"
	for p in ffmpeg ffprobe; do
		if [ $# -eq 2 ]; then
			lipo -create "$1/bin/$p" "$2/bin/$p" -output "$d/bin/$p"
		else
			cp "$1/bin/$p" "$d/bin/$p"
		fi
		chmod 755 "$d/bin/$p" # (GitHub's artifacts don't keep it)
		codesign --force --sign - "$d/bin/$p"
		codesign --verify "$d/bin/$p"
		archs=$(lipo -archs "$d/bin/$p")
		if [ $# -eq 2 ]; then
			for a in arm64 x86_64; do
				case " $archs " in
				*" $a "*) ;;
				*) echo "$p isn't universal: it has $archs, not $a" >&2; exit 1 ;;
				esac
			done
		fi
		for a in $archs; do
			mac_guard "$d/bin/$p" "$a"
		done
	done
	smoke "$d/bin"

	for s in ffmpeg zlib libvpx libwebp opus dav1d; do
		unpack "$s"
	done
	cd "$here"
	src=$work/src
	cp "$src/ffmpeg/COPYING.LGPLv2.1" "$d/LICENSE.txt"
	{
		cat <<TXT
FFmpeg $(echo "$version" | cut -d- -f1) for Inbetween on macOS: third-party notices
===================================================================

This FFmpeg is free software under the GNU Lesser General Public License,
version 2.1 or later (LICENSE.txt). Built into its programs are the
libraries below, each under its own licence, reproduced here in full. Its
complete source code: see README.txt.
TXT
		section "FFmpeg (its own notice: some files are under MIT/X11/BSD-style licences)" "LGPL-2.1-or-later" "$src/ffmpeg/LICENSE.md"
		section "zlib $(pinned zlib)" "Zlib" "$src/zlib/LICENSE"
		section "libvpx $(pinned libvpx) (VP8/VP9)" "BSD-3-Clause, with Google's patent grant" "$src/libvpx/LICENSE" "$src/libvpx/PATENTS"
		section "libwebp $(pinned libwebp) (WebP)" "BSD-3-Clause, with Google's patent grant" "$src/libwebp/COPYING" "$src/libwebp/PATENTS"
		section "Opus $(pinned opus)" "BSD-3-Clause" "$src/opus/COPYING"
		section "dav1d $(pinned dav1d) (AV1)" "BSD-2-Clause" "$src/dav1d/COPYING"
		printf '\nThe programs also hold parts of the LLVM compiler runtime (compiler-rt), under\nthe Apache License 2.0 with LLVM Exceptions, which lets them be part of any\nprogram.\n'
	} >"$d/THIRD-PARTY-NOTICES.txt"

	tag=v$version
	ffver=$(echo "$version" | cut -d- -f1)
	cat >"$d/README.txt" <<TXT
FFmpeg $ffver (build $version) for macOS, as Inbetween brings it
==============================================================

These files are FFmpeg, a separate free program made by the FFmpeg
developers, and the libraries built into it. Inbetween runs it (ffmpeg,
ffprobe) to read and write video and sound. It is not part of Inbetween,
and Inbetween's licence doesn't cover it. Inside Inbetween.app the
programs are in Contents/MacOS and these texts in Contents/Resources/ffmpeg.
They run on Mac computers with Apple silicon or an Intel processor, macOS
$MAC_MIN or later.

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
video with the encoder built into macOS (VideoToolbox).

To use another FFmpeg, set it in Inbetween's Preferences > FFmpeg.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
TXT

	{
		echo "inbetween-ffmpeg $version for macOS ($archs; macOS $MAC_MIN or later)"
		echo
		echo "Sources (sources.txt; NVIDIA's and AMD's encoder headers are only in the Windows build):"
		sources | grep -Ev '^(nv-codec-headers|amf-headers)[[:space:]]' | awk '{printf "  %-17s %-9s %s\n                    sha256 %s\n", $1, $2, $3, $4}'
		for dir in "$@"; do
			echo
			echo "$(lipo -archs "$dir/bin/ffmpeg"):"
			sed 's/^/  /' "$dir/toolchain.txt"
			echo "  FFmpeg's configure:"
			awk '{ gsub(/ --/, "\n      --"); print "    " $0 }' "$dir/configure-line.txt"
		done
		echo
		echo "Libraries the programs use (macOS's own only):"
		for a in $archs; do
			echo "  $a:"
			otool -arch "$a" -L "$d/bin/ffmpeg" | tail -n +2 | awk '{print "    " $1}'
		done
		echo
		echo "Files (sha256):"
		(cd "$d" && sha256 bin/* | sed 's/^/  /')
	} >"$d/BUILD-INFO.txt"

	echo "== out/"
	if [ $# -eq 2 ]; then
		zipname=inbetween-ffmpeg-$version-macos.zip
	else
		zipname=inbetween-ffmpeg-$version-macos-$archs.zip
	fi
	rm -f "$out/$zipname"
	(cd "$stage" && zip -qr9X "$out/$zipname" ffmpeg)
	ls -la "$out"
}

# --- which build ----------------------------------------------------------------

case ${1:-} in
fetch)
	fetch
	exit 0
	;;
esac
# a tagged release builds the version it's tagged with
case ${GITHUB_REF_NAME:-} in
v*) [ "$GITHUB_REF_NAME" = "v$version" ] || { echo "tag $GITHUB_REF_NAME, but VERSION says $version" >&2; exit 1; } ;;
esac
case ${1:-} in
'') ;; # Windows, below
notes)
	[ $# -eq 1 ] || usage
	notes
	exit 0
	;;
macos)
	[ $# -eq 1 ] || usage
	build_macos
	exit 0
	;;
macos-zip)
	[ $# -eq 2 ] || [ $# -eq 3 ] || usage
	shift
	macos_zip "$@"
	exit 0
	;;
*) usage ;;
esac

# --- Windows ------------------------------------------------------------------

# the cross compiler: MinGW-w64 GCC with Windows' own threads (with POSIX
# threads, the DLLs would need libwinpthread-1.dll beside them)
command -v $host-gcc >/dev/null || { echo "$host-gcc not found (Ubuntu: gcc-mingw-w64-x86-64-win32)" >&2; exit 1; }
$host-gcc -v 2>&1 | grep -q 'Thread model: win32' || { echo "$host-gcc must use the win32 thread model (update-alternatives --config $host-gcc)" >&2; exit 1; }
for t in nasm meson ninja make pkg-config zip; do
	command -v $t >/dev/null || { echo "$t not found" >&2; exit 1; }
done

fetch
rm -rf "$work" "$out"
mkdir -p "$work/src" "$prefix/include" "$prefix/lib/pkgconfig" "$out"

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
	section "zlib $(pinned zlib)" "Zlib" "$src/zlib/LICENSE"
	section "libvpx $(pinned libvpx) (VP8/VP9)" "BSD-3-Clause, with Google's patent grant" "$src/libvpx/LICENSE" "$src/libvpx/PATENTS"
	section "libwebp $(pinned libwebp) (WebP)" "BSD-3-Clause, with Google's patent grant" "$src/libwebp/COPYING" "$src/libwebp/PATENTS"
	section "Opus $(pinned opus)" "BSD-3-Clause" "$src/opus/COPYING"
	section "dav1d $(pinned dav1d) (AV1)" "BSD-2-Clause" "$src/dav1d/COPYING"
	section "NVIDIA Video Codec headers (nv-codec-headers $(pinned nv-codec-headers))" "MIT" "$nvlic"
	section "AMD Advanced Media Framework headers $(pinned amf-headers)" "MIT" "$amflic"
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
	sources | awk '{printf "  %-17s %-9s %s\n                    sha256 %s\n", $1, $2, $3, $4}'
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
sources | while read -r name ver url sha; do
	cp "$cache/$(archive "$name" "$ver" "$url")" "$srcdir/sources/"
done
tar -cf "$out/inbetween-ffmpeg-$version-source.tar" -C "$work" "inbetween-ffmpeg-$version-source"
notes
ls -la "$out"
