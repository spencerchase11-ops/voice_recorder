# Vendored LAME 4.0 encoder

Source: the LAME 4.0 release tarball `lame_4.0.orig.tar.gz`
(sha256 `3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb`,
the same checksum as in Debian/Ubuntu's `lame_4.0-1.dsc`).
Upstream: <https://lame.sourceforge.io>. License: LGPL-2.0-or-later, see
`COPYING` and `LICENSE` in this directory.

## Patches

**None.** Every file copied from upstream is byte-identical to the tarball.
The build is configured only through `config.h` (below) and compile
definitions: `HAVE_CONFIG_H` always, and `NDEBUG` unless LAME's asserts are
wanted (the host test build enables them).

## What is vendored

| Path | Contents |
| --- | --- |
| `libmp3lame/*.c`, `libmp3lame/*.h` | the encoder library (19 `.c`, 22 `.h`) |
| `libmp3lame/vector/lame_intrin.h` | only this header: `fft.c` includes it unconditionally. It just declares two SSE function prototypes, which are never used |
| `include/lame.h` | the public LAME API, used by `../lame_mp3.c` |
| `COPYING`, `LICENSE`, `README` | upstream license and notes |

Not vendored:

- `libmp3lame/mpglib_interface.c`: the decoder glue (`hip_*`, `lame_decode*`).
  In 4.0 it unconditionally includes `mpglib/mpglib.h`, which lives outside
  `libmp3lame`. The encoder references it only under `DECODE_ON_THE_FLY`,
  which is not defined. The library links with `-Wl,--no-undefined`, so a
  missing symbol would fail the build.
- `libmp3lame/i386/` (NASM), `libmp3lame/vector/*.c` (SSE intrinsics),
  Makefiles, `lame.rc`, `logoe.ico`, `lame.pc.in`, `depcomp`, and everything
  outside `libmp3lame/` and `include/` (frontend, mpglib, docs, ...).

## Local files (not from upstream)

- `config.h`: replaces the file that `./configure` generates from
  `config.h.in`. It declares the standard C headers (`STDC_HEADERS`,
  `HAVE_STDINT_H`, `HAVE_INTTYPES_H`, ...) and `ieee754_float32_t`. It makes
  sure that the following are **not** defined, so that every ABI (ARM and x86
  alike) runs LAME's portable C code:
  - `TAKEHIRO_IEEE754_HACK`: upstream's configure writes `#define ... 0` when
    the option is off, and the sources test it with `#ifdef`.
  - `USE_FAST_LOG`, `HAVE_XMMINTRIN_H`, `MIN_ARCH_SSE`, `HAVE_NASM`.
  - `HAVE_MPG123`, `HAVE_MPGLIB`, `DECODE_ON_THE_FLY`: the build is encoder only.
  - `DEBUG`: Xcode defines it in Debug builds, but LAME reads it as "verbose
    trace output".
  - `ABORTFP`.
- `PATCHES.md`: this file.

## Verification

The upstream command-line encoder was built from the same tarball with
`./configure`, with the four x86-only settings above removed from the
generated `config.h` and `CFLAGS=-O2`. From the same 16-bit PCM
(`-b N --cbr -q 5 -t --noreplaygain`, mono and joint stereo, 16 to 48 kHz),
it produces byte-identical MP3 files to this plugin's Dart API.
Upstream's default x86_64 build (`-O3 -ffast-math`, SSE, fast log, IEEE hack)
differs only in rounding, with the same SNR to within 0.2 dB.

## Updating LAME

1. Copy the new `libmp3lame/*.c` and `*.h` (without `mpglib_interface.c`),
   `libmp3lame/vector/lame_intrin.h`, `include/lame.h`, `COPYING`, `LICENSE`
   and `README`.
2. Diff the new `config.h.in`, `configure.ac`, `machine.h` and `util.h` for
   new configuration macros, and update `config.h`.
3. Update the source list in `../CMakeLists.txt` and the forwarders in
   `../../ios/Classes/libmp3lame/`. `test/native_sources_test.dart` checks
   that they match the vendored files.
4. Run `tool/build_host_lib.sh && flutter test`. The host build keeps LAME's
   asserts enabled.
