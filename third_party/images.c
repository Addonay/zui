// Vendored SVG backend, compiled into the zui module.
//
// - nanosvg (nanosvg.h, nanosvgrast.h): Zlib licensed,
//   Copyright (c) 2013-14 Mikko Mononen. SVG parse + rasterize.
//
// Upstream: https://github.com/memononen/nanosvg
// It is single-file, zero-dependency C99 with a stable API; vendored
// (not fetched) so builds stay reproducible offline.
//
// Raster decoding is Wuffs, in third_party/wuffs, built as its own library.

#define NANOSVG_IMPLEMENTATION
#include "nanosvg/nanosvg.h"

#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvg/nanosvgrast.h"
