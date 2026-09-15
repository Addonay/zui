//! Palette sampled from the shadcn dashboard reference screenshot.

use gpui_kit::{Hsla, rgb};

fn hex(value: u32) -> Hsla {
    rgb(value).into()
}

/// Window background, also the sidebar surface.
pub fn page() -> Hsla {
    hex(0x1e1e1e)
}

/// The inset main panel.
pub fn panel() -> Hsla {
    hex(0x121212)
}

/// Chart and table cards.
pub fn card() -> Hsla {
    hex(0x1e1e1e)
}

/// Metric cards sit a touch lighter than the other cards.
pub fn card_metric() -> Hsla {
    hex(0x202020)
}

pub fn card_border() -> Hsla {
    hex(0x343434)
}

/// Hairline borders (table rows, header divider).
pub fn border() -> Hsla {
    hex(0x262626)
}

pub fn table_head() -> Hsla {
    hex(0x2b2b2b)
}

pub fn tab_active() -> Hsla {
    hex(0x323232)
}

pub fn hover() -> Hsla {
    hex(0x292929)
}

pub fn text() -> Hsla {
    hex(0xfafafa)
}

pub fn body() -> Hsla {
    hex(0xd4d4d4)
}

pub fn muted() -> Hsla {
    hex(0xa1a1a1)
}

pub fn faint() -> Hsla {
    hex(0x71717a)
}

pub fn nav_text() -> Hsla {
    hex(0xb5b5b5)
}

pub fn green() -> Hsla {
    hex(0x0ddf72)
}

/// Quick Create pill / dashboard primary.
pub fn primary() -> Hsla {
    hex(0xe5e5e5)
}

pub fn primary_foreground() -> Hsla {
    hex(0x171717)
}

pub fn white() -> Hsla {
    hex(0xffffff)
}
