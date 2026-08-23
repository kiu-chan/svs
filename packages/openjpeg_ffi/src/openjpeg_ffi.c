#include "openjpeg_ffi.h"

#include <stdlib.h>
#include <string.h>

#include "vendor/openjp2/openjpeg.h"

// A read cursor over a fixed in-memory buffer — OpenJPEG has no built-in
// memory-stream helper, only a file-stream one, so this backs the
// read/skip/seek callbacks wired up in jp2k_decode below.
typedef struct {
  const uint8_t* data;
  size_t length;
  size_t offset;
} MemStream;

static OPJ_SIZE_T mem_read(void* buffer, OPJ_SIZE_T nb_bytes, void* user_data) {
  MemStream* s = (MemStream*)user_data;
  size_t remaining = s->length - s->offset;
  if (remaining == 0) {
    return (OPJ_SIZE_T)-1; // EOF sentinel, per openjpeg.h's opj_stream_read_fn docs
  }
  size_t n = nb_bytes < remaining ? nb_bytes : remaining;
  memcpy(buffer, s->data + s->offset, n);
  s->offset += n;
  return n;
}

static OPJ_OFF_T mem_skip(OPJ_OFF_T nb_bytes, void* user_data) {
  MemStream* s = (MemStream*)user_data;
  size_t remaining = s->length - s->offset;
  size_t n = (size_t)nb_bytes < remaining ? (size_t)nb_bytes : remaining;
  s->offset += n;
  return (OPJ_OFF_T)n;
}

static OPJ_BOOL mem_seek(OPJ_OFF_T nb_bytes, void* user_data) {
  MemStream* s = (MemStream*)user_data;
  if (nb_bytes < 0 || (size_t)nb_bytes > s->length) {
    return OPJ_FALSE;
  }
  s->offset = (size_t)nb_bytes;
  return OPJ_TRUE;
}

static void error_cb(const char* msg, void* client_data) {
  char* buf = (char*)client_data;
  strncpy(buf, msg, 255);
  buf[255] = 0;
}

Jp2kDecodeResult* jp2k_decode(const uint8_t* data, intptr_t length, int32_t reduced_resolution_factor) {
  Jp2kDecodeResult* result = calloc(1, sizeof(Jp2kDecodeResult));
  char error_buf[256] = {0};

  MemStream stream_data = {data, (size_t)length, 0};
  opj_stream_t* stream = opj_stream_create(1024, OPJ_TRUE);
  opj_stream_set_read_function(stream, mem_read);
  opj_stream_set_skip_function(stream, mem_skip);
  opj_stream_set_seek_function(stream, mem_seek);
  opj_stream_set_user_data(stream, &stream_data, NULL);
  opj_stream_set_user_data_length(stream, (OPJ_UINT64)length);

  opj_codec_t* codec = opj_create_decompress(OPJ_CODEC_J2K);
  opj_set_error_handler(codec, error_cb, error_buf);

  opj_dparameters_t params;
  opj_set_default_decoder_parameters(&params);
  params.cp_reduce = reduced_resolution_factor;
  if (!opj_setup_decoder(codec, &params)) {
    result->error = strdup(error_buf[0] ? error_buf : "opj_setup_decoder failed");
    opj_stream_destroy(stream);
    opj_destroy_codec(codec);
    return result;
  }

  opj_image_t* image = NULL;
  if (!opj_read_header(stream, codec, &image)) {
    result->error = strdup(error_buf[0] ? error_buf : "opj_read_header failed");
    opj_stream_destroy(stream);
    opj_destroy_codec(codec);
    return result;
  }
  if (!opj_decode(codec, stream, image)) {
    result->error = strdup(error_buf[0] ? error_buf : "opj_decode failed");
    opj_stream_destroy(stream);
    opj_image_destroy(image);
    opj_destroy_codec(codec);
    return result;
  }
  opj_end_decompress(codec, stream);

  uint32_t width = image->x1 - image->x0;
  uint32_t height = image->y1 - image->y0;
  uint32_t n = image->numcomps;
  uint8_t* out = malloc((size_t)width * height * n);
  if (!out) {
    result->error = strdup("out of memory allocating decoded pixel buffer");
    opj_stream_destroy(stream);
    opj_image_destroy(image);
    opj_destroy_codec(codec);
    return result;
  }

  // Real Aperio tiles are dx=dy=1 (no chroma subsampling) and prec=8,
  // sgnd=0 (verified against real sample files during development), so
  // this loop's subsampling/bit-depth handling is defensive rather than
  // exercised in practice — kept because JPEG2000 permits both generally.
  for (uint32_t ci = 0; ci < n; ci++) {
    opj_image_comp_t* c = &image->comps[ci];
    for (uint32_t y = 0; y < height; y++) {
      uint32_t sy = c->dy > 0 ? y / c->dy : y;
      if (sy >= c->h) sy = c->h - 1;
      for (uint32_t x = 0; x < width; x++) {
        uint32_t sx = c->dx > 0 ? x / c->dx : x;
        if (sx >= c->w) sx = c->w - 1;
        int32_t v = c->data[sy * c->w + sx];
        if (c->sgnd) v += 1 << (c->prec - 1);
        if (c->prec > 8) v >>= (c->prec - 8);
        else if (c->prec < 8) v <<= (8 - c->prec);
        if (v < 0) v = 0;
        if (v > 255) v = 255;
        out[(y * width + x) * n + ci] = (uint8_t)v;
      }
    }
  }

  result->width = (int32_t)width;
  result->height = (int32_t)height;
  result->num_components = (int32_t)n;
  result->pixels = out;

  opj_stream_destroy(stream);
  opj_image_destroy(image);
  opj_destroy_codec(codec);
  return result;
}

void jp2k_free_result(Jp2kDecodeResult* result) {
  if (!result) return;
  free(result->pixels);
  free(result->error);
  free(result);
}
