/*
 * config.h - hand-written replacement for the autoconf-generated config.h of
 * LAME 4.0, used by the vendored encoder sources in ./libmp3lame.
 *
 * This file is part of the lame_mp3 Flutter plugin; it is NOT an upstream
 * LAME file (upstream generates it from config.h.in with ./configure).
 * The LAME sources include it as <config.h> when HAVE_CONFIG_H is defined,
 * before any other header, so everything below is seen by every LAME
 * translation unit.
 *
 * Supported toolchains: clang from the Android NDK (arm64-v8a, armeabi-v7a,
 * x86_64, x86), Apple clang for iOS (arm64 devices, arm64/x86_64 simulator)
 * and gcc/clang on Linux (host tests). All of them are hosted C99-or-newer
 * environments with IEEE-754 float/double, so nothing needs to be probed.
 */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

#if !defined(__STDC_VERSION__) || __STDC_VERSION__ < 199901L
#error "The vendored LAME sources must be compiled as C99 or newer."
#endif

/* ---------------------------------------------------------------------------
 * Standard headers. machine.h, id3tag.c and gain_analysis.h fall back to
 * pre-ANSI declarations (e.g. `char *strchr();`) unless these are set, which
 * modern compilers reject.
 * ------------------------------------------------------------------------- */
#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1 /* machine.h / gain_analysis.h: <inttypes.h> */
#define HAVE_STDINT_H 1

/* ---------------------------------------------------------------------------
 * Types that upstream's config.h provides. util.h declares
 * `ieee754_float32_t fast_log2(ieee754_float32_t)` unconditionally.
 * ------------------------------------------------------------------------- */
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;

/* ---------------------------------------------------------------------------
 * Architecture-specific shortcuts: all OFF, so every ABI (ARM and x86 alike)
 * runs LAME's portable C code paths.
 * ------------------------------------------------------------------------- */

/* Takehiro's IEEE-754 bit tricks (configure --enable-ieeehack, "speed
 * improvement for old CPUs"). The sources test it with #ifdef, so it must not
 * be defined at all (upstream's configure even writes "#define ... 0" when the
 * option is off, which #ifdef treats as enabled). */
#undef TAKEHIRO_IEEE754_HACK

/* Table-based log2 approximation; upstream enables it only on x86/PowerPC. */
#undef USE_FAST_LOG

/* NASM assembly (libmp3lame/i386) and SSE intrinsics
 * (libmp3lame/vector/xmm_quantize_sub.c) are not vendored. */
#undef HAVE_NASM
#undef HAVE_XMMINTRIN_H
#undef MIN_ARCH_SSE
#undef MMX_choose_table

/* ---------------------------------------------------------------------------
 * Encoder only: no mpg123/mpglib decoder, no decode-on-the-fly ReplayGain.
 * ------------------------------------------------------------------------- */
#undef HAVE_MPG123
#undef HAVE_MPGLIB
#undef DECODE_ON_THE_FLY

/* ---------------------------------------------------------------------------
 * Debugging switches.
 * LAME reads DEBUG as configure's --enable-debug=alot (per-granule trace
 * output), but Xcode/CocoaPods define DEBUG=1 in Debug configurations, so turn
 * it off explicitly. ABORTFP would unmask floating-point exceptions.
 * Assertions are controlled separately, via NDEBUG (see src/CMakeLists.txt
 * and ios/lame_mp3.podspec).
 * ------------------------------------------------------------------------- */
#undef DEBUG
#undef ABORTFP

#endif /* LAME_CONFIG_H */
