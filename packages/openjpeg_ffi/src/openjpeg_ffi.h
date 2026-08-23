#include <stdint.h>

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT
#endif

// Result of decoding one JPEG2000 codestream. [pixels] is interleaved,
// tightly packed, [width] * [height] * [num_components] bytes — NULL on
// failure, in which case [error] is set instead (else NULL).
//
// Every non-NULL result (whether it succeeded or carries an error) must be
// passed to jp2k_free_result exactly once.
typedef struct {
  int32_t width;
  int32_t height;
  int32_t num_components;
  uint8_t* pixels;
  char* error;
} Jp2kDecodeResult;

// Decodes a raw J2K codestream (starts FF4F = SOC marker — *not* the
// box-structured .jp2 file format) from [data]/[length].
//
// [reduced_resolution_factor] discards the N highest-resolution wavelet
// levels during decode (0 = full resolution), letting a caller who only
// needs a coarse preview skip most of the decode cost — pass 0 unless you
// have a specific reason not to.
//
// Blocking/synchronous: this call occupies the calling isolate for its
// full duration. It has no main-isolate restriction (unlike dart:ui's
// image codecs), so call it from a background isolate to keep decode work
// off the UI thread.
FFI_PLUGIN_EXPORT Jp2kDecodeResult* jp2k_decode(
    const uint8_t* data, intptr_t length, int32_t reduced_resolution_factor);

FFI_PLUGIN_EXPORT void jp2k_free_result(Jp2kDecodeResult* result);
