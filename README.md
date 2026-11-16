# inbetween-ffmpeg

FFmpeg for Windows and macOS, as [Inbetween](https://inbetween.ink)
brings it: beside the app on Windows (`ffmpeg\` in its install folder and
portable zip), inside the app on macOS (`Inbetween.app`). Inbetween runs it
as a separate program for video import and export. It never links it.

Each [release](https://github.com/louissaadgo/inbetween-ffmpeg/releases) has:

- `inbetween-ffmpeg-<version>-win64.zip`: the `ffmpeg` folder as it ships
  on Windows. It holds the programs and DLLs, `LICENSE.txt` (LGPL 2.1),
  `THIRD-PARTY-NOTICES.txt` (the libraries built in), `README.txt` (where
  the source is) and `BUILD-INFO.txt` (configure line, pinned sources,
  file hashes).
- `inbetween-ffmpeg-<version>-macos.zip`: the same `ffmpeg` folder for
  macOS, with `bin/ffmpeg` and `bin/ffprobe` as universal programs (Apple
  silicon and Intel, macOS 13 or later). Inbetween's packaging puts the
  programs in `Inbetween.app/Contents/MacOS` and the four texts in
  `Contents/Resources/ffmpeg`.
- `inbetween-ffmpeg-<version>-source.tar`: the complete source code of
  both. That is every source archive exactly as built, plus this
  repository's files.
- `SHA256SUMS`.

## Why we build our own

1. **The licence lets us hand it out.** The build is LGPL 2.1+ with no GPL
   parts. Ready-made "GPL" builds contain zvbi, part of which is GPL 2
   *only* and can't legally be combined with GPL 3 FFmpeg.
2. **We can publish its exact source.** The LGPL requires that for as long
   as we distribute the binary. The build downloads every source itself,
   checks each against the SHA-256 pinned in `sources.txt`, and puts those
   very archives into the release.
3. **No patent-pooled software encoders.**
   - Left out: x264, x265, VVC and every other encoder Inbetween doesn't
     use (`ENCODERS` and `MAC_ENCODERS` in `build.sh`).
   - H.264 and H.265 go through the system's own encoder (Media Foundation
     on Windows, VideoToolbox on macOS) or, on Windows, the graphics card's
     (NVIDIA NVENC, AMD AMF); those come licensed with the system or the
     card.
   - The rest is royalty-free or out of patent: VP9, WebP, ProRes, GIF,
     PNG, MJPEG, AAC-LC, Opus, PCM.
   - Every decoder but VVC's is kept, so videos import whatever made them.

## What's in it

| | Windows | macOS |
| --- | --- | --- |
| FFmpeg | 9.0.2, LGPL 2.1+, shared DLLs, `ffmpeg.exe` + `ffprobe.exe` | 9.0.2, LGPL 2.1+, static, `ffmpeg` + `ffprobe`, universal (arm64 + x86_64), macOS 13+ |
| H.264 / H.265 encoders | `h264_mf` `hevc_mf` `h264_nvenc` `hevc_nvenc` `h264_amf` `hevc_amf` | `h264_videotoolbox` `hevc_videotoolbox` |
| Other encoders | `libvpx_vp9` `libwebp` `libwebp_anim` `prores_ks` `gif` `png` `mjpeg` `rawvideo` `wrapped_avframe` `aac` `libopus` `pcm_s16le` | the same |
| Libraries | zlib, libvpx, libwebp, Opus, dav1d, NVIDIA and AMD encoder headers | zlib, libvpx, libwebp, Opus, dav1d; of macOS, only VideoToolbox and the frameworks it needs |
| Devices | the `lavfi` input only (Inbetween's encoder probes use it) | the same |
| Network | none | none |

On macOS, `--disable-autodetect` keeps out everything else macOS offers
(AudioToolbox, AVFoundation, Core Image, Metal, Secure Transport, iconv,
bzip2, lzma); only threads and VideoToolbox are switched on.

The Windows build fails if:

- FFmpeg isn't configured as LGPL;
- any program or DLL needs a DLL that every Windows doesn't have (a MinGW
  runtime DLL, or Media Foundation's, which Windows N lacks until the Media
  Feature Pack).

The macOS build fails if:

- FFmpeg isn't configured as LGPL, or any encoder in `MAC_ENCODERS` didn't
  make it into the configuration;
- either program needs a library outside `/usr/lib` and `/System/Library`
  (nothing from Homebrew or `/usr/local`), or needs a macOS newer than 13.0;
- the joined programs aren't universal (arm64 and x86_64);
- its smoke test fails: each program runs and makes ProRes, VP9, WebP,
  animated WebP, GIF, Opus and AAC, and decodes H.264, read back with
  `ffprobe`. It also tries VideoToolbox's H.264 and H.265 but never fails on
  them: GitHub's Mac runners are virtual machines, which may lack it.

## Making a release

1. Change what's needed:
   - `sources.txt`: a version, URL and SHA-256 (`./build.sh fetch` checks
     them);
   - `build.sh`;
   - `VERSION`: `<FFmpeg version>-<build>`, e.g. `9.0.2-2`.
2. Commit, then tag and push it: `git tag v$(cat VERSION) && git push origin main --tags`.
   - The `release` workflow builds Windows on GitHub's Ubuntu 24.04 and
     macOS on a Mac with Apple silicon (`macos-15`) and an Intel one
     (`macos-15-intel`), joins the two Mac builds into universal programs,
     and publishes it all as one release (about 20–30 minutes).
   - Running the workflow by hand only builds, keeping the release's files
     as the `inbetween-ffmpeg` artifact.
3. In Inbetween's `packaging/common.sh`, set:
   - `FF_TAG` to the tag;
   - `FF_WIN` to `inbetween-ffmpeg-<version>-win64`;
   - `FF_WIN_SHA` to that zip's line in `SHA256SUMS`;
   - `FF_MAC` to `inbetween-ffmpeg-<version>-macos`;
   - `FF_MAC_SHA` to that zip's line in `SHA256SUMS`.

Never delete a release while any Inbetween download that holds it can
still be downloaded: its source must stay available as long as the binary
is.

## Building locally

### Windows

On Linux with the MinGW-w64 cross compiler (win32 threads), nasm, meson,
ninja, make, pkg-config and zip:

```sh
./build.sh fetch   # sources into cache/, checked
JOBS=4 ./build.sh  # → out/
```

For a test build of Inbetween's installer with it, before it's released:

```sh
FFMPEG_WIN_ZIP=../inbetween-ffmpeg/out/inbetween-ffmpeg-<version>-win64.zip make installer-windows
```

### Building on a Mac

With the Xcode Command Line Tools (`xcode-select --install`; Xcode itself
isn't needed) and, from Homebrew:

```sh
brew install meson ninja pkgconf make   # and nasm, on an Intel Mac
./build.sh macos                        # this Mac's architecture → out/macos-<arch>/
./build.sh macos-zip out/macos-arm64    # → out/inbetween-ffmpeg-<version>-macos-arm64.zip
```

One Mac builds only its own architecture, so a zip from one build is for
test builds only (it's named for its architecture). The universal zip needs
both builds: `./build.sh macos-zip <arm64 build> <x86_64 build>`; the
release workflow makes it. To check a zip, unpack it and run:

```sh
lipo -archs ffmpeg/bin/ffmpeg                 # arm64 x86_64
otool -L ffmpeg/bin/ffmpeg                    # only /usr/lib and /System/Library
ffmpeg/bin/ffmpeg -hide_banner -encoders | grep videotoolbox
```

This repository's own files are MIT licensed (`LICENSE`). FFmpeg and the
libraries keep their own licences. FFmpeg is a trademark of Fabrice Bellard.
