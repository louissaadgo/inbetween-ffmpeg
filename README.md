# inbetween-ffmpeg

FFmpeg for Windows, as [Inbetween](https://inbetween.ink) puts it beside the
app (`ffmpeg\` in its install folder and portable zip). Inbetween runs it
as a separate program for video import and export. It never links it.

Each [release](https://github.com/louissaadgo/inbetween-ffmpeg/releases) has:

- `inbetween-ffmpeg-<version>-win64.zip`: the `ffmpeg` folder as it ships.
  It holds the programs and DLLs, `LICENSE.txt` (LGPL 2.1),
  `THIRD-PARTY-NOTICES.txt` (the libraries built in), `README.txt` (where
  the source is) and `BUILD-INFO.txt` (configure line, pinned sources,
  file hashes).
- `inbetween-ffmpeg-<version>-source.tar`: its complete source code. That
  is every source archive exactly as built, plus this repository's files.
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
     use (`ENCODERS` in `build.sh`).
   - H.264 and H.265 go through Windows' own encoder (Media Foundation) or
     the graphics card's (NVIDIA NVENC, AMD AMF); those come licensed with
     Windows or the card.
   - The rest is royalty-free or out of patent: VP9, WebP, ProRes, GIF,
     PNG, MJPEG, AAC-LC, Opus, PCM.
   - Every decoder but VVC's is kept, so videos import whatever made them.

## What's in it

| | |
|---|---|
| FFmpeg | 9.0.2, LGPL 2.1+, shared DLLs, `ffmpeg.exe` + `ffprobe.exe` |
| Encoders | `h264_mf` `hevc_mf` `h264_nvenc` `hevc_nvenc` `h264_amf` `hevc_amf` `libvpx_vp9` `libwebp` `libwebp_anim` `prores_ks` `gif` `png` `mjpeg` `rawvideo` `wrapped_avframe` `aac` `libopus` `pcm_s16le` |
| Libraries | zlib, libvpx, libwebp, Opus, dav1d, NVIDIA and AMD encoder headers |
| Devices | the `lavfi` input only (Inbetween's encoder probes use it) |
| Network | none |

The build fails if:
- FFmpeg isn't configured as LGPL;
- any program or DLL needs a DLL that every Windows doesn't have (a MinGW
  runtime DLL, or Media Foundation's, which Windows N lacks until the Media
  Feature Pack).

## Making a release

1. Change what's needed:
   - `sources.txt`: a version, URL and SHA-256 (`./build.sh fetch` checks
     them);
   - `build.sh`;
   - `VERSION`: `<FFmpeg version>-<build>`, e.g. `9.0.2-2`.
2. Commit, then tag and push it: `git tag v$(cat VERSION) && git push origin main --tags`.
   - The `release` workflow builds the release on GitHub's Ubuntu 24.04
     (about 15–20 minutes) and publishes it.
   - Running the workflow by hand only builds, keeping `out/` as an artifact.
3. In Inbetween's `packaging/common.sh`, set:
   - `FF_TAG` to the tag;
   - `FF_WIN` to `inbetween-ffmpeg-<version>-win64`;
   - `FF_WIN_SHA` to the zip's line in `SHA256SUMS`.

Never delete a release while any Inbetween download that holds it can
still be downloaded: its source must stay available as long as the binary
is.

## Building locally

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

This repository's own files are MIT licensed (`LICENSE`). FFmpeg and the
libraries keep their own licences. FFmpeg is a trademark of Fabrice Bellard.
