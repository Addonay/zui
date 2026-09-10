// Vendored image backends, compiled into the zui module.
//
// - nanosvg (nanosvg.h, nanosvgrast.h): Zlib licensed,
//   Copyright (c) 2013-14 Mikko Mononen. SVG parse + rasterize.
// - stb_image (stb_image.h): public domain (Unlicense/MIT), Sean Barrett.
//   JPEG/PNG/GIF/BMP/PSD/TGA/HDR/PIC/PNM decode.
//
// Upstream: https://github.com/memononen/nanosvg
//           https://github.com/nothings/stb
// Both are single-file, zero-dependency C99 with stable APIs; vendored
// (not fetched) so builds stay reproducible offline.

#define NANOSVG_IMPLEMENTATION
#include "nanosvg/nanosvg.h"

#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvg/nanosvgrast.h"

#define STB_IMAGE_IMPLEMENTATION
#include "stb/stb_image.h"
