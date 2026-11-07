// Thin C shim over Wuffs' image decoders, for src/wuffs.zig.
//
// Wuffs (https://github.com/google/wuffs, release/c/wuffs-v0.4.c at b36a81d,
// Apache-2.0 OR MIT, see LICENSE) is memory safe by construction: its decoders
// are checked by the Wuffs compiler, so a malformed file cannot write out of
// bounds. This file only exposes the calls the Zig side needs, with no global
// state: every decoder lives in a session the caller allocates.
//
// Each session holds one decoder, its I/O buffer and its image and pixel
// configuration. The decoder is initialized in place, so Zig owns all memory
// and the testing allocator sees every byte.

#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__BMP
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__GIF
#define WUFFS_CONFIG__MODULE__JPEG
#define WUFFS_CONFIG__MODULE__NETPBM
#define WUFFS_CONFIG__MODULE__PNG
#define WUFFS_CONFIG__MODULE__QOI
#define WUFFS_CONFIG__MODULE__TARGA
#define WUFFS_CONFIG__MODULE__VP8
#define WUFFS_CONFIG__MODULE__WEBP
#define WUFFS_CONFIG__MODULE__ZLIB
#define WUFFS_IMPLEMENTATION
#include "wuffs-v0.4.c"

#include <stddef.h>
#include <stdint.h>
#include <string.h>

// Return codes shared with src/wuffs.zig.
#define ZUI_OK 0
#define ZUI_END 1
#define ZUI_ERROR 2

// Codec ids shared with src/wuffs.zig (the Zig enum's order).
enum {
  ZUI_CODEC_BMP,
  ZUI_CODEC_GIF,
  ZUI_CODEC_JPEG,
  ZUI_CODEC_NETPBM,
  ZUI_CODEC_PNG,
  ZUI_CODEC_QOI,
  ZUI_CODEC_TARGA,
  ZUI_CODEC_WEBP,
  ZUI_CODEC_COUNT,
};

// Disposal values shared with src/wuffs.zig.
#define ZUI_DISPOSAL_NONE 0
#define ZUI_DISPOSAL_BACKGROUND 1
#define ZUI_DISPOSAL_PREVIOUS 2

// One frame's header. Bounds are min-inclusive, max-exclusive. Layout must match
// `FrameInfo` in src/wuffs.zig.
typedef struct zui_frame_info {
  uint32_t x0;
  uint32_t y0;
  uint32_t x1;
  uint32_t y1;
  uint32_t duration_ms;
  // ARGB, premultiplied, as Wuffs reports it.
  uint32_t background;
  uint8_t disposal;
  // Nonzero: the frame replaces its rectangle. Zero: it is blended over it.
  uint8_t overwrite;
  uint8_t reserved[2];
} zui_frame_info;

typedef struct zui_session {
  int codec;
  const char* error;
  wuffs_base__io_buffer src;
  wuffs_base__image_config ic;
  wuffs_base__pixel_buffer pb;
  // The decoder starts at zui_decoder_offset() bytes into the session.
} zui_session;

static size_t zui_decoder_offset(void) {
  return (sizeof(zui_session) + 15) & ~(size_t)15;
}

static size_t zui_decoder_size(int codec) {
  switch (codec) {
    case ZUI_CODEC_BMP: return sizeof__wuffs_bmp__decoder();
    case ZUI_CODEC_GIF: return sizeof__wuffs_gif__decoder();
    case ZUI_CODEC_JPEG: return sizeof__wuffs_jpeg__decoder();
    case ZUI_CODEC_NETPBM: return sizeof__wuffs_netpbm__decoder();
    case ZUI_CODEC_PNG: return sizeof__wuffs_png__decoder();
    case ZUI_CODEC_QOI: return sizeof__wuffs_qoi__decoder();
    case ZUI_CODEC_TARGA: return sizeof__wuffs_targa__decoder();
    case ZUI_CODEC_WEBP: return sizeof__wuffs_webp__decoder();
    default: return 0;
  }
}

static wuffs_base__image_decoder* zui_image_decoder(zui_session* s) {
  void* dec = (uint8_t*)s + zui_decoder_offset();
  switch (s->codec) {
    case ZUI_CODEC_BMP: return wuffs_bmp__decoder__upcast_as__wuffs_base__image_decoder(dec);
    case ZUI_CODEC_GIF: return wuffs_gif__decoder__upcast_as__wuffs_base__image_decoder(dec);
    case ZUI_CODEC_JPEG: return wuffs_jpeg__decoder__upcast_as__wuffs_base__image_decoder(dec);
    case ZUI_CODEC_NETPBM: return wuffs_netpbm__decoder__upcast_as__wuffs_base__image_decoder(dec);
    case ZUI_CODEC_PNG: return wuffs_png__decoder__upcast_as__wuffs_base__image_decoder(dec);
    case ZUI_CODEC_QOI: return wuffs_qoi__decoder__upcast_as__wuffs_base__image_decoder(dec);
    case ZUI_CODEC_TARGA: return wuffs_targa__decoder__upcast_as__wuffs_base__image_decoder(dec);
    case ZUI_CODEC_WEBP: return wuffs_webp__decoder__upcast_as__wuffs_base__image_decoder(dec);
    default: return NULL;
  }
}

// Maps a Wuffs status to a return code, and keeps the message for the caller.
static int zui_classify(zui_session* s, wuffs_base__status st) {
  if (wuffs_base__status__is_ok(&st)) {
    return ZUI_OK;
  }
  if (st.repr == wuffs_base__note__end_of_data) {
    return ZUI_END;
  }
  // With a closed input, Wuffs reports a short read as a suspension only in
  // states it cannot resume from; both are failures here.
  s->error = wuffs_base__status__message(&st);
  return ZUI_ERROR;
}

size_t zui_wuffs_session_size(int codec) {
  size_t n = zui_decoder_size(codec);
  if (n == 0) {
    return 0;
  }
  return zui_decoder_offset() + n;
}

// `mem` must be zui_wuffs_session_size(codec) bytes, aligned to 16. `data` must
// outlive the session.
int zui_wuffs_session_init(void* mem, int codec, const uint8_t* data, size_t len) {
  zui_session* s = (zui_session*)mem;
  if (codec < 0 || codec >= ZUI_CODEC_COUNT) {
    return ZUI_ERROR;
  }
  memset(s, 0, sizeof(*s));
  s->codec = codec;
  s->src.data.ptr = (uint8_t*)data;
  s->src.data.len = len;
  s->src.meta.wi = len;
  s->src.meta.ri = 0;
  s->src.meta.pos = 0;
  s->src.meta.closed = true;

  void* dec = (uint8_t*)s + zui_decoder_offset();
  wuffs_base__status st = {0};
  switch (codec) {
    case ZUI_CODEC_BMP:
      st = wuffs_bmp__decoder__initialize(dec, sizeof__wuffs_bmp__decoder(), WUFFS_VERSION, 0);
      break;
    case ZUI_CODEC_GIF:
      st = wuffs_gif__decoder__initialize(dec, sizeof__wuffs_gif__decoder(), WUFFS_VERSION, 0);
      break;
    case ZUI_CODEC_JPEG:
      st = wuffs_jpeg__decoder__initialize(dec, sizeof__wuffs_jpeg__decoder(), WUFFS_VERSION, 0);
      break;
    case ZUI_CODEC_NETPBM:
      st = wuffs_netpbm__decoder__initialize(dec, sizeof__wuffs_netpbm__decoder(), WUFFS_VERSION, 0);
      break;
    case ZUI_CODEC_PNG:
      st = wuffs_png__decoder__initialize(dec, sizeof__wuffs_png__decoder(), WUFFS_VERSION, 0);
      break;
    case ZUI_CODEC_QOI:
      st = wuffs_qoi__decoder__initialize(dec, sizeof__wuffs_qoi__decoder(), WUFFS_VERSION, 0);
      break;
    case ZUI_CODEC_TARGA:
      st = wuffs_targa__decoder__initialize(dec, sizeof__wuffs_targa__decoder(), WUFFS_VERSION, 0);
      break;
    case ZUI_CODEC_WEBP:
      st = wuffs_webp__decoder__initialize(dec, sizeof__wuffs_webp__decoder(), WUFFS_VERSION, 0);
      break;
  }
  return zui_classify(s, st);
}

// The last error message of the session, or "" if there is none.
const char* zui_wuffs_session_error(void* mem) {
  zui_session* s = (zui_session*)mem;
  return s->error ? s->error : "";
}

// Reads the image header. Returns the size, and sets the pixel format to BGRA
// non-premultiplied, which is what the frames are decoded into.
int zui_wuffs_image_config(void* mem, uint32_t* width, uint32_t* height) {
  zui_session* s = (zui_session*)mem;
  wuffs_base__image_decoder* dec = zui_image_decoder(s);
  int r = zui_classify(s, wuffs_base__image_decoder__decode_image_config(dec, &s->ic, &s->src));
  if (r != ZUI_OK) {
    return ZUI_ERROR;
  }
  if (!wuffs_base__image_config__is_valid(&s->ic)) {
    s->error = "invalid image configuration";
    return ZUI_ERROR;
  }
  uint32_t w = wuffs_base__pixel_config__width(&s->ic.pixcfg);
  uint32_t h = wuffs_base__pixel_config__height(&s->ic.pixcfg);
  wuffs_base__pixel_config__set(&s->ic.pixcfg, WUFFS_BASE__PIXEL_FORMAT__BGRA_NONPREMUL,
                                WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, w, h);
  *width = w;
  *height = h;
  return ZUI_OK;
}

// Reads the next frame's header. Returns ZUI_END after the last frame.
int zui_wuffs_frame_config(void* mem, zui_frame_info* out) {
  zui_session* s = (zui_session*)mem;
  wuffs_base__image_decoder* dec = zui_image_decoder(s);
  wuffs_base__frame_config fc;
  memset(&fc, 0, sizeof(fc));
  int r = zui_classify(s, wuffs_base__image_decoder__decode_frame_config(dec, &fc, &s->src));
  if (r != ZUI_OK) {
    return r;
  }
  wuffs_base__rect_ie_u32 b = wuffs_base__frame_config__bounds(&fc);
  out->x0 = b.min_incl_x;
  out->y0 = b.min_incl_y;
  out->x1 = b.max_excl_x;
  out->y1 = b.max_excl_y;
  uint64_t ms = wuffs_base__frame_config__duration(&fc) / WUFFS_BASE__FLICKS_PER_MILLISECOND;
  out->duration_ms = ms > UINT32_MAX ? UINT32_MAX : (uint32_t)ms;
  out->background = wuffs_base__frame_config__background_color(&fc);
  switch (wuffs_base__frame_config__disposal(&fc)) {
    case WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_BACKGROUND:
      out->disposal = ZUI_DISPOSAL_BACKGROUND;
      break;
    case WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_PREVIOUS:
      out->disposal = ZUI_DISPOSAL_PREVIOUS;
      break;
    default:
      out->disposal = ZUI_DISPOSAL_NONE;
      break;
  }
  out->overwrite = wuffs_base__frame_config__overwrite_instead_of_blend(&fc) ? 1 : 0;
  out->reserved[0] = 0;
  out->reserved[1] = 0;
  return ZUI_OK;
}

// The size of the work buffer the decoder needs. Returns ZUI_ERROR if the
// decoder cannot say.
int zui_wuffs_workbuf_len(void* mem, uint64_t* out) {
  zui_session* s = (zui_session*)mem;
  wuffs_base__image_decoder* dec = zui_image_decoder(s);
  wuffs_base__range_ii_u64 r = wuffs_base__image_decoder__workbuf_len(dec);
  if (wuffs_base__range_ii_u64__is_empty(&r)) {
    s->error = "indeterminate work buffer length";
    return ZUI_ERROR;
  }
  *out = r.max_incl;
  return ZUI_OK;
}

// Decodes the current frame into `pixels`, a BGRA non-premultiplied buffer of
// the image's size. With `overwrite` zero, the frame is blended over what is
// already there (source-over). Returns ZUI_END if there is no frame to decode.
int zui_wuffs_decode_frame(void* mem, uint8_t* pixels, size_t pixels_len, uint8_t* work, size_t work_len, int overwrite) {
  zui_session* s = (zui_session*)mem;
  wuffs_base__image_decoder* dec = zui_image_decoder(s);
  wuffs_base__status st = wuffs_base__pixel_buffer__set_from_slice(
      &s->pb, &s->ic.pixcfg, wuffs_base__make_slice_u8(pixels, pixels_len));
  if (!wuffs_base__status__is_ok(&st)) {
    s->error = wuffs_base__status__message(&st);
    return ZUI_ERROR;
  }
  wuffs_base__pixel_blend blend = overwrite ? WUFFS_BASE__PIXEL_BLEND__SRC : WUFFS_BASE__PIXEL_BLEND__SRC_OVER;
  st = wuffs_base__image_decoder__decode_frame(dec, &s->pb, &s->src, blend,
                                               wuffs_base__make_slice_u8(work, work_len), NULL);
  return zui_classify(s, st);
}
