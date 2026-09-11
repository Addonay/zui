//! Port of peniko 0.6.1 (palette use) / color 0.3.3 palette/css.rs
//! (Apache-2.0 OR MIT).
//!
//! The CSS named colors, also known as the X11 colors, as
//! `AlphaColor(Srgb)` constants. Generated from the upstream table; do not
//! hand-edit the values.

const std = @import("std");
const color = @import("color.zig");

const AlphaColor = color.AlphaColor;
const Srgb = color.Srgb;

/// The CSS named colors.
pub const css = struct {
    /// Alice blue (240, 248, 255, 255)
    pub const ALICE_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(240, 248, 255);
    /// Antique white (250, 235, 215, 255)
    pub const ANTIQUE_WHITE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(250, 235, 215);
    /// Aqua (0, 255, 255, 255)
    pub const AQUA: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 255, 255);
    /// Aquamarine (127, 255, 212, 255)
    pub const AQUAMARINE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(127, 255, 212);
    /// Azure (240, 255, 255, 255)
    pub const AZURE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(240, 255, 255);
    /// Beige (245, 245, 220, 255)
    pub const BEIGE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(245, 245, 220);
    /// Bisque (255, 228, 196, 255)
    pub const BISQUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 228, 196);
    /// Black (0, 0, 0, 255)
    pub const BLACK: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 0, 0);
    /// Blanched almond (255, 235, 205, 255)
    pub const BLANCHED_ALMOND: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 235, 205);
    /// Blue (0, 0, 255, 255)
    pub const BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 0, 255);
    /// Blue violet (138, 43, 226, 255)
    pub const BLUE_VIOLET: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(138, 43, 226);
    /// Brown (165, 42, 42, 255)
    pub const BROWN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(165, 42, 42);
    /// Burlywood (222, 184, 135, 255)
    pub const BURLYWOOD: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(222, 184, 135);
    /// Cadet blue (95, 158, 160, 255)
    pub const CADET_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(95, 158, 160);
    /// Chartreuse (127, 255, 0, 255)
    pub const CHARTREUSE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(127, 255, 0);
    /// Chocolate (210, 105, 30, 255)
    pub const CHOCOLATE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(210, 105, 30);
    /// Coral (255, 127, 80, 255)
    pub const CORAL: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 127, 80);
    /// Cornflower blue (100, 149, 237, 255)
    pub const CORNFLOWER_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(100, 149, 237);
    /// Cornsilk (255, 248, 220, 255)
    pub const CORNSILK: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 248, 220);
    /// Crimson (220, 20, 60, 255)
    pub const CRIMSON: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(220, 20, 60);
    /// Cyan (0, 255, 255, 255)
    pub const CYAN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 255, 255);
    /// Dark blue (0, 0, 139, 255)
    pub const DARK_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 0, 139);
    /// Dark cyan (0, 139, 139, 255)
    pub const DARK_CYAN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 139, 139);
    /// Dark goldenrod (184, 134, 11, 255)
    pub const DARK_GOLDENROD: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(184, 134, 11);
    /// Dark gray (169, 169, 169, 255)
    pub const DARK_GRAY: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(169, 169, 169);
    /// Dark green (0, 100, 0, 255)
    pub const DARK_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 100, 0);
    /// Dark khaki (189, 183, 107, 255)
    pub const DARK_KHAKI: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(189, 183, 107);
    /// Dark magenta (139, 0, 139, 255)
    pub const DARK_MAGENTA: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(139, 0, 139);
    /// Dark olive green (85, 107, 47, 255)
    pub const DARK_OLIVE_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(85, 107, 47);
    /// Dark orange (255, 140, 0, 255)
    pub const DARK_ORANGE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 140, 0);
    /// Dark orchid (153, 50, 204, 255)
    pub const DARK_ORCHID: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(153, 50, 204);
    /// Dark red (139, 0, 0, 255)
    pub const DARK_RED: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(139, 0, 0);
    /// Dark salmon (233, 150, 122, 255)
    pub const DARK_SALMON: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(233, 150, 122);
    /// Dark sea green (143, 188, 143, 255)
    pub const DARK_SEA_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(143, 188, 143);
    /// Dark slate blue (72, 61, 139, 255)
    pub const DARK_SLATE_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(72, 61, 139);
    /// Dark slate gray (47, 79, 79, 255)
    pub const DARK_SLATE_GRAY: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(47, 79, 79);
    /// Dark turquoise (0, 206, 209, 255)
    pub const DARK_TURQUOISE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 206, 209);
    /// Dark violet (148, 0, 211, 255)
    pub const DARK_VIOLET: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(148, 0, 211);
    /// Deep pink (255, 20, 147, 255)
    pub const DEEP_PINK: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 20, 147);
    /// Deep sky blue (0, 191, 255, 255)
    pub const DEEP_SKY_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 191, 255);
    /// Dim gray (105, 105, 105, 255)
    pub const DIM_GRAY: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(105, 105, 105);
    /// Dodger blue (30, 144, 255, 255)
    pub const DODGER_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(30, 144, 255);
    /// Firebrick (178, 34, 34, 255)
    pub const FIREBRICK: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(178, 34, 34);
    /// Floral white (255, 250, 240, 255)
    pub const FLORAL_WHITE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 250, 240);
    /// Forest green (34, 139, 34, 255)
    pub const FOREST_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(34, 139, 34);
    /// Fuchsia (255, 0, 255, 255)
    pub const FUCHSIA: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 0, 255);
    /// Gainsboro (220, 220, 220, 255)
    pub const GAINSBORO: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(220, 220, 220);
    /// Ghost white (248, 248, 255, 255)
    pub const GHOST_WHITE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(248, 248, 255);
    /// Gold (255, 215, 0, 255)
    pub const GOLD: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 215, 0);
    /// Goldenrod (218, 165, 32, 255)
    pub const GOLDENROD: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(218, 165, 32);
    /// Gray (128, 128, 128, 255)
    pub const GRAY: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(128, 128, 128);
    /// Green (0, 128, 0, 255)
    pub const GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 128, 0);
    /// Green yellow (173, 255, 47, 255)
    pub const GREEN_YELLOW: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(173, 255, 47);
    /// Honeydew (240, 255, 240, 255)
    pub const HONEYDEW: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(240, 255, 240);
    /// Hot pink (255, 105, 180, 255)
    pub const HOT_PINK: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 105, 180);
    /// Indian red (205, 92, 92, 255)
    pub const INDIAN_RED: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(205, 92, 92);
    /// Indigo (75, 0, 130, 255)
    pub const INDIGO: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(75, 0, 130);
    /// Ivory (255, 255, 240, 255)
    pub const IVORY: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 255, 240);
    /// Khaki (240, 230, 140, 255)
    pub const KHAKI: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(240, 230, 140);
    /// Lavender (230, 230, 250, 255)
    pub const LAVENDER: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(230, 230, 250);
    /// Lavender blush (255, 240, 245, 255)
    pub const LAVENDER_BLUSH: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 240, 245);
    /// Lawn green (124, 252, 0, 255)
    pub const LAWN_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(124, 252, 0);
    /// Lemon chiffon (255, 250, 205, 255)
    pub const LEMON_CHIFFON: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 250, 205);
    /// Light blue (173, 216, 230, 255)
    pub const LIGHT_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(173, 216, 230);
    /// Light coral (240, 128, 128, 255)
    pub const LIGHT_CORAL: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(240, 128, 128);
    /// Light cyan (224, 255, 255, 255)
    pub const LIGHT_CYAN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(224, 255, 255);
    /// Light goldenrod yellow (250, 250, 210, 255)
    pub const LIGHT_GOLDENROD_YELLOW: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(250, 250, 210);
    /// Light gray (211, 211, 211, 255)
    pub const LIGHT_GRAY: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(211, 211, 211);
    /// Light green (144, 238, 144, 255)
    pub const LIGHT_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(144, 238, 144);
    /// Light pink (255, 182, 193, 255)
    pub const LIGHT_PINK: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 182, 193);
    /// Light salmon (255, 160, 122, 255)
    pub const LIGHT_SALMON: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 160, 122);
    /// Light sea green (32, 178, 170, 255)
    pub const LIGHT_SEA_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(32, 178, 170);
    /// Light sky blue (135, 206, 250, 255)
    pub const LIGHT_SKY_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(135, 206, 250);
    /// Light slate gray (119, 136, 153, 255)
    pub const LIGHT_SLATE_GRAY: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(119, 136, 153);
    /// Light steel blue (176, 196, 222, 255)
    pub const LIGHT_STEEL_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(176, 196, 222);
    /// Light yellow (255, 255, 224, 255)
    pub const LIGHT_YELLOW: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 255, 224);
    /// Lime (0, 255, 0, 255)
    pub const LIME: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 255, 0);
    /// Lime green (50, 205, 50, 255)
    pub const LIME_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(50, 205, 50);
    /// Linen (250, 240, 230, 255)
    pub const LINEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(250, 240, 230);
    /// Magenta (255, 0, 255, 255)
    pub const MAGENTA: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 0, 255);
    /// Maroon (128, 0, 0, 255)
    pub const MAROON: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(128, 0, 0);
    /// Medium aquamarine (102, 205, 170, 255)
    pub const MEDIUM_AQUAMARINE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(102, 205, 170);
    /// Medium blue (0, 0, 205, 255)
    pub const MEDIUM_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 0, 205);
    /// Medium orchid (186, 85, 211, 255)
    pub const MEDIUM_ORCHID: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(186, 85, 211);
    /// Medium purple (147, 112, 219, 255)
    pub const MEDIUM_PURPLE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(147, 112, 219);
    /// Medium sea green (60, 179, 113, 255)
    pub const MEDIUM_SEA_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(60, 179, 113);
    /// Medium slate blue (123, 104, 238, 255)
    pub const MEDIUM_SLATE_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(123, 104, 238);
    /// Medium spring green (0, 250, 154, 255)
    pub const MEDIUM_SPRING_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 250, 154);
    /// Medium turquoise (72, 209, 204, 255)
    pub const MEDIUM_TURQUOISE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(72, 209, 204);
    /// Medium violet red (199, 21, 133, 255)
    pub const MEDIUM_VIOLET_RED: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(199, 21, 133);
    /// Midnight blue (25, 25, 112, 255)
    pub const MIDNIGHT_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(25, 25, 112);
    /// Mint cream (245, 255, 250, 255)
    pub const MINT_CREAM: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(245, 255, 250);
    /// Misty rose (255, 228, 225, 255)
    pub const MISTY_ROSE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 228, 225);
    /// Moccasin (255, 228, 181, 255)
    pub const MOCCASIN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 228, 181);
    /// Navajo white (255, 222, 173, 255)
    pub const NAVAJO_WHITE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 222, 173);
    /// Navy (0, 0, 128, 255)
    pub const NAVY: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 0, 128);
    /// Old lace (253, 245, 230, 255)
    pub const OLD_LACE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(253, 245, 230);
    /// Olive (128, 128, 0, 255)
    pub const OLIVE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(128, 128, 0);
    /// Olive drab (107, 142, 35, 255)
    pub const OLIVE_DRAB: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(107, 142, 35);
    /// Orange (255, 165, 0, 255)
    pub const ORANGE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 165, 0);
    /// Orange red (255, 69, 0, 255)
    pub const ORANGE_RED: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 69, 0);
    /// Orchid (218, 112, 214, 255)
    pub const ORCHID: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(218, 112, 214);
    /// Pale goldenrod (238, 232, 170, 255)
    pub const PALE_GOLDENROD: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(238, 232, 170);
    /// Pale green (152, 251, 152, 255)
    pub const PALE_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(152, 251, 152);
    /// Pale turquoise (175, 238, 238, 255)
    pub const PALE_TURQUOISE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(175, 238, 238);
    /// Pale violet red (219, 112, 147, 255)
    pub const PALE_VIOLET_RED: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(219, 112, 147);
    /// Papaya whip (255, 239, 213, 255)
    pub const PAPAYA_WHIP: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 239, 213);
    /// Peach puff (255, 218, 185, 255)
    pub const PEACH_PUFF: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 218, 185);
    /// Peru (205, 133, 63, 255)
    pub const PERU: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(205, 133, 63);
    /// Pink (255, 192, 203, 255)
    pub const PINK: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 192, 203);
    /// Plum (221, 160, 221, 255)
    pub const PLUM: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(221, 160, 221);
    /// Powder blue (176, 224, 230, 255)
    pub const POWDER_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(176, 224, 230);
    /// Purple (128, 0, 128, 255)
    pub const PURPLE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(128, 0, 128);
    /// Rebecca purple (102, 51, 153, 255)
    pub const REBECCA_PURPLE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(102, 51, 153);
    /// Red (255, 0, 0, 255)
    pub const RED: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 0, 0);
    /// Rosy brown (188, 143, 143, 255)
    pub const ROSY_BROWN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(188, 143, 143);
    /// Royal blue (65, 105, 225, 255)
    pub const ROYAL_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(65, 105, 225);
    /// Saddle brown (139, 69, 19, 255)
    pub const SADDLE_BROWN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(139, 69, 19);
    /// Salmon (250, 128, 114, 255)
    pub const SALMON: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(250, 128, 114);
    /// Sandy brown (244, 164, 96, 255)
    pub const SANDY_BROWN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(244, 164, 96);
    /// Sea green (46, 139, 87, 255)
    pub const SEA_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(46, 139, 87);
    /// Seashell (255, 245, 238, 255)
    pub const SEASHELL: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 245, 238);
    /// Sienna (160, 82, 45, 255)
    pub const SIENNA: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(160, 82, 45);
    /// Silver (192, 192, 192, 255)
    pub const SILVER: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(192, 192, 192);
    /// Sky blue (135, 206, 235, 255)
    pub const SKY_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(135, 206, 235);
    /// Slate blue (106, 90, 205, 255)
    pub const SLATE_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(106, 90, 205);
    /// Slate gray (112, 128, 144, 255)
    pub const SLATE_GRAY: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(112, 128, 144);
    /// Snow (255, 250, 250, 255)
    pub const SNOW: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 250, 250);
    /// Spring green (0, 255, 127, 255)
    pub const SPRING_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 255, 127);
    /// Steel blue (70, 130, 180, 255)
    pub const STEEL_BLUE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(70, 130, 180);
    /// Tan (210, 180, 140, 255)
    pub const TAN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(210, 180, 140);
    /// Teal (0, 128, 128, 255)
    pub const TEAL: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(0, 128, 128);
    /// Thistle (216, 191, 216, 255)
    pub const THISTLE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(216, 191, 216);
    /// Tomato (255, 99, 71, 255)
    pub const TOMATO: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 99, 71);
    /// Transparent (0, 0, 0, 0)
    pub const TRANSPARENT: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgba8(0, 0, 0, 0);
    /// Turquoise (64, 224, 208, 255)
    pub const TURQUOISE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(64, 224, 208);
    /// Violet (238, 130, 238, 255)
    pub const VIOLET: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(238, 130, 238);
    /// Wheat (245, 222, 179, 255)
    pub const WHEAT: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(245, 222, 179);
    /// White (255, 255, 255, 255)
    pub const WHITE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 255, 255);
    /// White smoke (245, 245, 245, 255)
    pub const WHITE_SMOKE: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(245, 245, 245);
    /// Yellow (255, 255, 0, 255)
    pub const YELLOW: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(255, 255, 0);
    /// Yellow green (154, 205, 50, 255)
    pub const YELLOW_GREEN: AlphaColor(Srgb) = AlphaColor(Srgb).fromRgb8(154, 205, 50);
};

test "palette round-trips through Rgba8" {
    // Every constant is exactly representable as bytes and survives a
    // straight-alpha RGBA8 round trip unchanged.
    const decls = comptime std.meta.declarations(css);
    try std.testing.expectEqual(@as(usize, 142), decls.len);
    inline for (decls) |decl_name| {
        const value: AlphaColor(Srgb) = @field(css, decl_name);
        const bytes = value.toRgba8();
        const round_tripped = AlphaColor(Srgb).fromRgba8(bytes.r, bytes.g, bytes.b, bytes.a);
        try std.testing.expectEqualSlices(f32, &value.components, &round_tripped.components);
    }
}

test "known palette values" {
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, css.RED.toRgba8().toU8Array());
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, css.LIME.toRgba8().toU8Array());
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, css.BLUE.toRgba8().toU8Array());
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, css.TRANSPARENT.toRgba8().toU8Array());
    try std.testing.expectEqual([4]u8{ 102, 51, 153, 255 }, css.REBECCA_PURPLE.toRgba8().toU8Array());
    try std.testing.expectEqual([4]u8{ 240, 248, 255, 255 }, css.ALICE_BLUE.toRgba8().toU8Array());
    try std.testing.expectEqual([4]u8{ 47, 79, 79, 255 }, css.DARK_SLATE_GRAY.toRgba8().toU8Array());
    try std.testing.expectEqual([4]u8{ 199, 21, 133, 255 }, css.MEDIUM_VIOLET_RED.toRgba8().toU8Array());
    try std.testing.expectEqual([4]u8{ 154, 205, 50, 255 }, css.YELLOW_GREEN.toRgba8().toU8Array());
    try std.testing.expectEqual([4]u8{ 253, 245, 230, 255 }, css.OLD_LACE.toRgba8().toU8Array());
    // Bit-exact components captured from `color` 0.3.3 (`x * (1/255)`).
    try std.testing.expectEqual(@as(u32, 1053609166), @as(u32, @bitCast(css.REBECCA_PURPLE.components[0])));
    try std.testing.expectEqual(@as(u32, 1064892666), @as(u32, @bitCast(css.ALICE_BLUE.components[1])));
    try std.testing.expectEqual(@as(f32, 0.0), css.TRANSPARENT.components[3]);
    try std.testing.expectEqual(@as(f32, 1.0), css.WHITE.components[3]);
}
