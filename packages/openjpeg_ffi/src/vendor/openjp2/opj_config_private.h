/* Hand-resolved from opj_config_private.h.cmake.in for OpenJPEG 2.5.4 —
 * see opj_config.h for why this is static rather than CMake-generated.
 *
 * Every OPJ_HAVE_* capability macro below is deliberately left undefined:
 * each one only gates an *optional*, more-aligned malloc implementation
 * (see opj_malloc.c) — leaving them all undefined routes through the
 * library's own portable generic-aligned-malloc fallback on every
 * platform, which is correct (if very slightly less optimal) everywhere.
 * Likewise the largefile/fseeko macros are irrelevant here: this package
 * only ever decodes from an in-memory buffer via the custom stream
 * callbacks in openjpeg_ffi.c, never through OpenJPEG's own file-stream
 * helpers, so none of that machinery is exercised.
 *
 * OPJ_BIG_ENDIAN is intentionally never defined: every real Flutter
 * target (arm64, x86_64, x86) is little-endian. */

#define OPJ_PACKAGE_VERSION "2.5.4"
