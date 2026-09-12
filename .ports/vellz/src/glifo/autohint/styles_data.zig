//! Generated autohint script/style tables (do not edit).
//!
//! Transcribed from `skrifa-0.44.0/generated/generated_autohint_styles.rs`
//! by `tools/convert_autohint_styles.py`. Raw indices/bit masks only;
//! `styles.zig` maps them onto typed values.

const bz = @import("blue_zones.zig");

pub const RawBlue = bz.BluePair;

pub const RawScript = struct {
    name: []const u8,
    /// 0 = Default, 1 = Cjk, 2 = Indic (`ScriptGroup`).
    group: u8,
    tag: [4]u8,
    hint_top_to_bottom: bool,
    std_chars: []const u8,
    blues: []const RawBlue,
};

pub const RawStyle = struct {
    name: []const u8,
    script: u16,
    feature: ?[4]u8,
};

pub const RawRange = struct {
    first: u32,
    last: u32,
    style: u16,
    non_base: bool,
};

pub const SCRIPT_CLASSES = [_]RawScript{
    .{
        .name = "Adlam",
        .group = 0,
        .tag = .{ 0x41, 0x64, 0x6c, 0x6d },
        .hint_top_to_bottom = false,
        .std_chars = "𞤌 𞤮",
        .blues = &.{
            .{ .chars = "𞤌 𞤅 𞤈 𞤏 𞤔 𞤚", .zones = .{ .bits = 2 } },
            .{ .chars = "𞤂 𞤖", .zones = .{ .bits = 0 } },
            .{ .chars = "𞤬 𞤮 𞤻 𞤼 𞤾", .zones = .{ .bits = 34 } },
            .{ .chars = "𞤤 𞤨 𞤩 𞤭 𞤴 𞤸 𞤺 𞥀", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Arabic",
        .group = 0,
        .tag = .{ 0x41, 0x72, 0x61, 0x62 },
        .hint_top_to_bottom = false,
        .std_chars = "ل ح ـ",
        .blues = &.{
            .{ .chars = "ا إ ل ك ط ظ", .zones = .{ .bits = 2 } },
            .{ .chars = "ت ث ط ظ ك", .zones = .{ .bits = 0 } },
            .{ .chars = "ـ", .zones = .{ .bits = 8 } },
        },
    },
    .{
        .name = "Armenian",
        .group = 0,
        .tag = .{ 0x41, 0x72, 0x6d, 0x6e },
        .hint_top_to_bottom = false,
        .std_chars = "ս Ս",
        .blues = &.{
            .{ .chars = "Ա Մ Ւ Ս Բ Գ Դ Օ", .zones = .{ .bits = 2 } },
            .{ .chars = "Ւ Ո Դ Ճ Շ Ս Տ Օ", .zones = .{ .bits = 0 } },
            .{ .chars = "ե է ի մ վ ֆ ճ", .zones = .{ .bits = 2 } },
            .{ .chars = "ա յ ւ ս գ շ ր օ", .zones = .{ .bits = 34 } },
            .{ .chars = "հ ո ճ ա ե ծ ս օ", .zones = .{ .bits = 0 } },
            .{ .chars = "բ ը ի լ ղ պ փ ց", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Avestan",
        .group = 0,
        .tag = .{ 0x41, 0x76, 0x73, 0x74 },
        .hint_top_to_bottom = false,
        .std_chars = "𐬚",
        .blues = &.{
            .{ .chars = "𐬀 𐬁 𐬐 𐬛", .zones = .{ .bits = 2 } },
            .{ .chars = "𐬀 𐬁", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Bamum",
        .group = 0,
        .tag = .{ 0x42, 0x61, 0x6d, 0x75 },
        .hint_top_to_bottom = false,
        .std_chars = "ꛁ ꛯ",
        .blues = &.{
            .{ .chars = "ꚧ ꚨ ꛛ ꛉ ꛁ ꛈ ꛫ ꛯ", .zones = .{ .bits = 2 } },
            .{ .chars = "ꚭ ꚳ ꚶ ꛬ ꚢ ꚽ ꛯ ꛲", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Bengali",
        .group = 0,
        .tag = .{ 0x42, 0x65, 0x6e, 0x67 },
        .hint_top_to_bottom = true,
        .std_chars = "০ ৪",
        .blues = &.{
            .{ .chars = "ই ট ঠ ি ী ৈ ৗ", .zones = .{ .bits = 2 } },
            .{ .chars = "ও এ ড ত ন ব ল ক", .zones = .{ .bits = 2 } },
            .{ .chars = "অ ড ত ন ব ভ ল ক", .zones = .{ .bits = 42 } },
            .{ .chars = "অ ড ত ন ব ভ ল ক", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Buhid",
        .group = 0,
        .tag = .{ 0x42, 0x75, 0x68, 0x64 },
        .hint_top_to_bottom = false,
        .std_chars = "ᝋ ᝏ",
        .blues = &.{
            .{ .chars = "ᝐ ᝈ", .zones = .{ .bits = 2 } },
            .{ .chars = "ᝅ ᝊ ᝎ", .zones = .{ .bits = 2 } },
            .{ .chars = "ᝂ ᝃ ᝉ ᝌ", .zones = .{ .bits = 34 } },
            .{ .chars = "ᝀ ᝃ ᝆ ᝉ ᝋ ᝏ ᝑ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Chakma",
        .group = 0,
        .tag = .{ 0x43, 0x61, 0x6b, 0x6d },
        .hint_top_to_bottom = false,
        .std_chars = "𑄤 𑄉 𑄛",
        .blues = &.{
            .{ .chars = "𑄃 𑄅 𑄉 𑄙 𑄗", .zones = .{ .bits = 2 } },
            .{ .chars = "𑄅 𑄛 𑄝 𑄗 𑄓", .zones = .{ .bits = 0 } },
            .{ .chars = "𑄖𑄳𑄢 𑄘𑄳𑄢 𑄙𑄳𑄢 𑄤𑄳𑄢 𑄥𑄳𑄢", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Canadian Syllabics",
        .group = 0,
        .tag = .{ 0x43, 0x61, 0x6e, 0x73 },
        .hint_top_to_bottom = false,
        .std_chars = "ᑌ ᓚ",
        .blues = &.{
            .{ .chars = "ᗜ ᖴ ᐁ ᒣ ᑫ ᑎ ᔑ ᗰ", .zones = .{ .bits = 2 } },
            .{ .chars = "ᗶ ᖵ ᒧ ᐃ ᑌ ᒍ ᔑ ᗢ", .zones = .{ .bits = 0 } },
            .{ .chars = "ᓓ ᓕ ᓀ ᓂ ᓄ ᕄ ᕆ ᘣ", .zones = .{ .bits = 34 } },
            .{ .chars = "ᕃ ᓂ ᓀ ᕂ ᓗ ᓚ ᕆ ᘣ", .zones = .{ .bits = 0 } },
            .{ .chars = "ᐪ ᙆ ᣘ ᐢ ᒾ ᣗ ᔆ", .zones = .{ .bits = 2 } },
            .{ .chars = "ᙆ ᗮ ᒻ ᐞ ᔆ ᒡ ᒢ ᓑ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Carian",
        .group = 0,
        .tag = .{ 0x43, 0x61, 0x72, 0x69 },
        .hint_top_to_bottom = false,
        .std_chars = "𐊫 𐋉",
        .blues = &.{
            .{ .chars = "𐊧 𐊫 𐊬 𐊭 𐊱 𐊺 𐊼 𐊿", .zones = .{ .bits = 2 } },
            .{ .chars = "𐊣 𐊧 𐊷 𐋀 𐊫 𐊸 𐋉", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Cherokee",
        .group = 0,
        .tag = .{ 0x43, 0x68, 0x65, 0x72 },
        .hint_top_to_bottom = false,
        .std_chars = "Ꭴ Ꮕ ꮕ",
        .blues = &.{
            .{ .chars = "Ꮖ Ꮋ Ꭼ Ꮓ Ꭴ Ꮳ Ꭶ Ꮥ", .zones = .{ .bits = 2 } },
            .{ .chars = "Ꮖ Ꮋ Ꭼ Ꮓ Ꭴ Ꮳ Ꭶ Ꮥ", .zones = .{ .bits = 0 } },
            .{ .chars = "ꮒ ꮤ ꮶ ꭴ ꭾ ꮗ ꮝ ꮿ", .zones = .{ .bits = 2 } },
            .{ .chars = "ꮖ ꭼ ꮓ ꮠ ꮳ ꭶ ꮥ ꮻ", .zones = .{ .bits = 34 } },
            .{ .chars = "ꮖ ꭼ ꮓ ꮠ ꮳ ꭶ ꮥ ꮻ", .zones = .{ .bits = 0 } },
            .{ .chars = "ᏸ ꮐ ꭹ ꭻ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Coptic",
        .group = 0,
        .tag = .{ 0x43, 0x6f, 0x70, 0x74 },
        .hint_top_to_bottom = false,
        .std_chars = "Ⲟ ⲟ",
        .blues = &.{
            .{ .chars = "Ⲍ Ⲏ Ⲡ Ⳟ Ⲟ Ⲑ Ⲥ Ⳋ", .zones = .{ .bits = 2 } },
            .{ .chars = "Ⳑ Ⳙ Ⳟ Ⲏ Ⲟ Ⲑ Ⳝ Ⲱ", .zones = .{ .bits = 0 } },
            .{ .chars = "ⲍ ⲏ ⲡ ⳟ ⲟ ⲑ ⲥ ⳋ", .zones = .{ .bits = 34 } },
            .{ .chars = "ⳑ ⳙ ⳟ ⲏ ⲟ ⲑ ⳝ Ⳓ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Cypriot",
        .group = 0,
        .tag = .{ 0x43, 0x70, 0x72, 0x74 },
        .hint_top_to_bottom = false,
        .std_chars = "𐠅 𐠣",
        .blues = &.{
            .{ .chars = "𐠍 𐠙 𐠳 𐠱 𐠅 𐠓 𐠣 𐠦", .zones = .{ .bits = 2 } },
            .{ .chars = "𐠃 𐠊 𐠛 𐠣 𐠳 𐠵 𐠐", .zones = .{ .bits = 0 } },
            .{ .chars = "𐠈 𐠏 𐠖", .zones = .{ .bits = 2 } },
            .{ .chars = "𐠈 𐠏 𐠖", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Cyrillic",
        .group = 0,
        .tag = .{ 0x43, 0x79, 0x72, 0x6c },
        .hint_top_to_bottom = false,
        .std_chars = "о О",
        .blues = &.{
            .{ .chars = "Б В Е П З О С Э", .zones = .{ .bits = 2 } },
            .{ .chars = "Б В Е Ш З О С Э", .zones = .{ .bits = 0 } },
            .{ .chars = "х п н ш е з о с", .zones = .{ .bits = 34 } },
            .{ .chars = "х п н ш е з о с", .zones = .{ .bits = 0 } },
            .{ .chars = "р у ф", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Devanagari",
        .group = 0,
        .tag = .{ 0x44, 0x65, 0x76, 0x61 },
        .hint_top_to_bottom = true,
        .std_chars = "ठ व ट",
        .blues = &.{
            .{ .chars = "ई ऐ ओ औ ि ी ो ौ", .zones = .{ .bits = 2 } },
            .{ .chars = "क म अ आ थ ध भ श", .zones = .{ .bits = 2 } },
            .{ .chars = "क न म उ छ ट ठ ड", .zones = .{ .bits = 42 } },
            .{ .chars = "क न म उ छ ट ठ ड", .zones = .{ .bits = 0 } },
            .{ .chars = "ु ृ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Deseret",
        .group = 0,
        .tag = .{ 0x44, 0x73, 0x72, 0x74 },
        .hint_top_to_bottom = false,
        .std_chars = "𐐄 𐐬",
        .blues = &.{
            .{ .chars = "𐐂 𐐄 𐐋 𐐗 𐐑", .zones = .{ .bits = 2 } },
            .{ .chars = "𐐀 𐐂 𐐄 𐐗 𐐛", .zones = .{ .bits = 0 } },
            .{ .chars = "𐐪 𐐬 𐐳 𐐿 𐐹", .zones = .{ .bits = 34 } },
            .{ .chars = "𐐨 𐐪 𐐬 𐐿 𐑃", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Ethiopic",
        .group = 0,
        .tag = .{ 0x45, 0x74, 0x68, 0x69 },
        .hint_top_to_bottom = false,
        .std_chars = "ዐ",
        .blues = &.{
            .{ .chars = "ሀ ሃ ዘ ፐ ማ በ ዋ ዐ", .zones = .{ .bits = 2 } },
            .{ .chars = "ለ ሐ በ ዘ ሀ ሪ ዐ ጨ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Georgian (Mkhedruli)",
        .group = 0,
        .tag = .{ 0x47, 0x65, 0x6f, 0x72 },
        .hint_top_to_bottom = false,
        .std_chars = "ი ე ა Ჿ",
        .blues = &.{
            .{ .chars = "გ დ ე ვ თ ი ო ღ", .zones = .{ .bits = 34 } },
            .{ .chars = "ა ზ მ ს შ ძ ხ პ", .zones = .{ .bits = 0 } },
            .{ .chars = "ს ხ ქ ზ მ შ ჩ წ", .zones = .{ .bits = 2 } },
            .{ .chars = "ე ვ ჟ ტ უ ფ ქ ყ", .zones = .{ .bits = 0 } },
            .{ .chars = "Ნ Ჟ Ჳ Ჸ Გ Ე Ო Ჴ", .zones = .{ .bits = 2 } },
            .{ .chars = "Ი Ჲ Ო Ჩ Მ Შ Ჯ Ჽ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Georgian (Khutsuri)",
        .group = 0,
        .tag = .{ 0x47, 0x65, 0x6f, 0x6b },
        .hint_top_to_bottom = false,
        .std_chars = "Ⴖ Ⴑ ⴙ",
        .blues = &.{
            .{ .chars = "Ⴑ Ⴇ Ⴙ Ⴜ Ⴄ Ⴅ Ⴓ Ⴚ", .zones = .{ .bits = 2 } },
            .{ .chars = "Ⴄ Ⴅ Ⴇ Ⴈ Ⴆ Ⴑ Ⴊ Ⴋ", .zones = .{ .bits = 0 } },
            .{ .chars = "ⴁ ⴗ ⴂ ⴄ ⴅ ⴇ ⴔ ⴖ", .zones = .{ .bits = 34 } },
            .{ .chars = "ⴈ ⴌ ⴖ ⴎ ⴃ ⴆ ⴋ ⴢ", .zones = .{ .bits = 0 } },
            .{ .chars = "ⴐ ⴑ ⴓ ⴕ ⴙ ⴛ ⴡ ⴣ", .zones = .{ .bits = 2 } },
            .{ .chars = "ⴄ ⴅ ⴔ ⴕ ⴁ ⴂ ⴘ ⴝ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Glagolitic",
        .group = 0,
        .tag = .{ 0x47, 0x6c, 0x61, 0x67 },
        .hint_top_to_bottom = false,
        .std_chars = "Ⱅ ⱅ",
        .blues = &.{
            .{ .chars = "Ⰵ Ⱄ Ⱚ Ⰴ Ⰲ Ⰺ Ⱛ Ⰻ", .zones = .{ .bits = 2 } },
            .{ .chars = "Ⰵ Ⰴ Ⰲ Ⱚ Ⱎ Ⱑ Ⰺ Ⱄ", .zones = .{ .bits = 0 } },
            .{ .chars = "ⰵ ⱄ ⱚ ⰴ ⰲ ⰺ ⱛ ⰻ", .zones = .{ .bits = 34 } },
            .{ .chars = "ⰵ ⰴ ⰲ ⱚ ⱎ ⱑ ⰺ ⱄ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Gothic",
        .group = 0,
        .tag = .{ 0x47, 0x6f, 0x74, 0x68 },
        .hint_top_to_bottom = true,
        .std_chars = "𐌴 𐌾 𐍃",
        .blues = &.{
            .{ .chars = "𐌲 𐌶 𐍀 𐍄 𐌴 𐍃 𐍈 𐌾", .zones = .{ .bits = 2 } },
            .{ .chars = "𐌶 𐌴 𐍃 𐍈", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Greek",
        .group = 0,
        .tag = .{ 0x47, 0x72, 0x65, 0x6b },
        .hint_top_to_bottom = false,
        .std_chars = "ο Ο",
        .blues = &.{
            .{ .chars = "Γ Β Ε Ζ Θ Ο Ω", .zones = .{ .bits = 2 } },
            .{ .chars = "Β Δ Ζ Ξ Θ Ο", .zones = .{ .bits = 0 } },
            .{ .chars = "β θ δ ζ λ ξ", .zones = .{ .bits = 2 } },
            .{ .chars = "α ε ι ο π σ τ ω", .zones = .{ .bits = 34 } },
            .{ .chars = "α ε ι ο π σ τ ω", .zones = .{ .bits = 0 } },
            .{ .chars = "β γ η μ ρ φ χ ψ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Gujarati",
        .group = 0,
        .tag = .{ 0x47, 0x75, 0x6a, 0x72 },
        .hint_top_to_bottom = false,
        .std_chars = "ટ ૦",
        .blues = &.{
            .{ .chars = "ત ન ઋ ઌ છ ટ ર ૦", .zones = .{ .bits = 34 } },
            .{ .chars = "ખ ગ ઘ ઞ ઇ ઈ ઠ જ", .zones = .{ .bits = 0 } },
            .{ .chars = "ઈ ઊ િ ી લી શ્ચિ જિ સી", .zones = .{ .bits = 2 } },
            .{ .chars = "ુ ૃ ૄ ખુ છૃ છૄ", .zones = .{ .bits = 0 } },
            .{ .chars = "૦ ૧ ૨ ૩ ૭", .zones = .{ .bits = 2 } },
        },
    },
    .{
        .name = "Gurmukhi",
        .group = 0,
        .tag = .{ 0x47, 0x75, 0x72, 0x75 },
        .hint_top_to_bottom = true,
        .std_chars = "ਠ ਰ ੦",
        .blues = &.{
            .{ .chars = "ਇ ਈ ਉ ਏ ਓ ੳ ਿ ੀ", .zones = .{ .bits = 2 } },
            .{ .chars = "ਕ ਗ ਙ ਚ ਜ ਤ ਧ ਸ", .zones = .{ .bits = 2 } },
            .{ .chars = "ਕ ਗ ਙ ਚ ਜ ਤ ਧ ਸ", .zones = .{ .bits = 42 } },
            .{ .chars = "ਅ ਏ ਓ ਗ ਜ ਠ ਰ ਸ", .zones = .{ .bits = 0 } },
            .{ .chars = "੦ ੧ ੨ ੩ ੭", .zones = .{ .bits = 2 } },
        },
    },
    .{
        .name = "Hebrew",
        .group = 0,
        .tag = .{ 0x48, 0x65, 0x62, 0x72 },
        .hint_top_to_bottom = false,
        .std_chars = "ם",
        .blues = &.{
            .{ .chars = "ב ד ה ח ך כ ם ס", .zones = .{ .bits = 66 } },
            .{ .chars = "ב ט כ ם ס צ", .zones = .{ .bits = 0 } },
            .{ .chars = "ק ך ן ף ץ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Nyiakeng Puachue Hmong",
        .group = 0,
        .tag = .{ 0x48, 0x6d, 0x6e, 0x70 },
        .hint_top_to_bottom = false,
        .std_chars = "𞄨",
        .blues = &.{
            .{ .chars = "𞄀 𞄁 𞄈 𞄑 𞄧 𞄬", .zones = .{ .bits = 2 } },
            .{ .chars = "𞄁 𞄜 𞄠 𞄡 𞄤 𞅂", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Kayah Li",
        .group = 0,
        .tag = .{ 0x4b, 0x61, 0x6c, 0x69 },
        .hint_top_to_bottom = false,
        .std_chars = "ꤍ ꤀",
        .blues = &.{
            .{ .chars = "꤅ ꤏ ꤁ ꤋ ꤀ ꤍ", .zones = .{ .bits = 34 } },
            .{ .chars = "꤈ ꤘ ꤀ ꤍ ꤢ", .zones = .{ .bits = 0 } },
            .{ .chars = "ꤖ ꤡ", .zones = .{ .bits = 2 } },
            .{ .chars = "ꤑ ꤜ ꤞ", .zones = .{ .bits = 0 } },
            .{ .chars = "ꤑ꤬ ꤜ꤭ ꤔ꤬", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Khmer",
        .group = 0,
        .tag = .{ 0x4b, 0x68, 0x6d, 0x72 },
        .hint_top_to_bottom = false,
        .std_chars = "០",
        .blues = &.{
            .{ .chars = "ខ ទ ន ឧ ឩ ា", .zones = .{ .bits = 34 } },
            .{ .chars = "ក្ក ក្ខ ក្គ ក្ថ", .zones = .{ .bits = 4 } },
            .{ .chars = "ខ ឃ ច ឋ ប ម យ ឲ", .zones = .{ .bits = 0 } },
            .{ .chars = "ត្រ រៀ ឲ្យ អឿ", .zones = .{ .bits = 0 } },
            .{ .chars = "ន្ត្រៃ ង្ខ្យ ក្បៀ ច្រៀ ន្តឿ ល្បឿ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Khmer Symbols",
        .group = 0,
        .tag = .{ 0x4b, 0x68, 0x6d, 0x73 },
        .hint_top_to_bottom = false,
        .std_chars = "᧡ ᧪",
        .blues = &.{
            .{ .chars = "᧠ ᧡", .zones = .{ .bits = 34 } },
            .{ .chars = "᧶ ᧹", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Kannada",
        .group = 0,
        .tag = .{ 0x4b, 0x6e, 0x64, 0x61 },
        .hint_top_to_bottom = false,
        .std_chars = "೦ ಬ",
        .blues = &.{
            .{ .chars = "ಇ ಊ ಐ ಣ ಸಾ ನಾ ದಾ ರಾ", .zones = .{ .bits = 2 } },
            .{ .chars = "ಅ ಉ ಎ ಲ ೦ ೨ ೬ ೭", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Lao",
        .group = 0,
        .tag = .{ 0x4c, 0x61, 0x6f, 0x6f },
        .hint_top_to_bottom = false,
        .std_chars = "໐",
        .blues = &.{
            .{ .chars = "າ ດ ອ ມ ລ ວ ຣ ງ", .zones = .{ .bits = 34 } },
            .{ .chars = "າ ອ ບ ຍ ຣ ຮ ວ ຢ", .zones = .{ .bits = 0 } },
            .{ .chars = "ປ ຢ ຟ ຝ", .zones = .{ .bits = 2 } },
            .{ .chars = "ໂ ໄ ໃ", .zones = .{ .bits = 2 } },
            .{ .chars = "ງ ຊ ຖ ຽ ໆ ຯ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Latin",
        .group = 0,
        .tag = .{ 0x4c, 0x61, 0x74, 0x6e },
        .hint_top_to_bottom = false,
        .std_chars = "o O 0",
        .blues = &.{
            .{ .chars = "T H E Z O C Q S", .zones = .{ .bits = 2 } },
            .{ .chars = "H E Z L O C U S", .zones = .{ .bits = 0 } },
            .{ .chars = "f i j k d b h", .zones = .{ .bits = 2 } },
            .{ .chars = "u v x z o e s c", .zones = .{ .bits = 34 } },
            .{ .chars = "n r x z o e s c", .zones = .{ .bits = 0 } },
            .{ .chars = "p q g j y", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Latin Subscript Fallback",
        .group = 0,
        .tag = .{ 0x4c, 0x61, 0x74, 0x62 },
        .hint_top_to_bottom = false,
        .std_chars = "ₒ ₀",
        .blues = &.{
            .{ .chars = "₀ ₃ ₅ ₇ ₈", .zones = .{ .bits = 2 } },
            .{ .chars = "₀ ₁ ₂ ₃ ₈", .zones = .{ .bits = 0 } },
            .{ .chars = "ᵢ ⱼ ₕ ₖ ₗ", .zones = .{ .bits = 2 } },
            .{ .chars = "ₐ ₑ ₒ ₓ ₙ ₛ ᵥ ᵤ ᵣ", .zones = .{ .bits = 34 } },
            .{ .chars = "ₐ ₑ ₒ ₓ ₙ ₛ ᵥ ᵤ ᵣ", .zones = .{ .bits = 0 } },
            .{ .chars = "ᵦ ᵧ ᵨ ᵩ ₚ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Latin Superscript Fallback",
        .group = 0,
        .tag = .{ 0x4c, 0x61, 0x74, 0x70 },
        .hint_top_to_bottom = false,
        .std_chars = "ᵒ ᴼ ⁰",
        .blues = &.{
            .{ .chars = "⁰ ³ ⁵ ⁷ ᵀ ᴴ ᴱ ᴼ", .zones = .{ .bits = 2 } },
            .{ .chars = "⁰ ¹ ² ³ ᴱ ᴸ ᴼ ᵁ", .zones = .{ .bits = 0 } },
            .{ .chars = "ᵇ ᵈ ᵏ ʰ ʲ ᶠ ⁱ", .zones = .{ .bits = 2 } },
            .{ .chars = "ᵉ ᵒ ʳ ˢ ˣ ᶜ ᶻ", .zones = .{ .bits = 34 } },
            .{ .chars = "ᵉ ᵒ ʳ ˢ ˣ ᶜ ᶻ", .zones = .{ .bits = 0 } },
            .{ .chars = "ᵖ ʸ ᵍ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Lisu",
        .group = 0,
        .tag = .{ 0x4c, 0x69, 0x73, 0x75 },
        .hint_top_to_bottom = false,
        .std_chars = "ꓳ",
        .blues = &.{
            .{ .chars = "ꓡ ꓧ ꓱ ꓶ ꓩ ꓚ ꓵ ꓳ", .zones = .{ .bits = 2 } },
            .{ .chars = "ꓕ ꓜ ꓞ ꓡ ꓛ ꓢ ꓳ ꓴ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Malayalam",
        .group = 0,
        .tag = .{ 0x4d, 0x6c, 0x79, 0x6d },
        .hint_top_to_bottom = false,
        .std_chars = "ഠ റ",
        .blues = &.{
            .{ .chars = "ഒ ട ഠ റ ച പ ച്ച പ്പ", .zones = .{ .bits = 2 } },
            .{ .chars = "ട ഠ ധ ശ ഘ ച ഥ ല", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Medefaidrin",
        .group = 0,
        .tag = .{ 0x4d, 0x65, 0x64, 0x66 },
        .hint_top_to_bottom = false,
        .std_chars = "𖹡 𖹛 𖹯",
        .blues = &.{
            .{ .chars = "𖹀 𖹁 𖹂 𖹃 𖹏 𖹚 𖹟", .zones = .{ .bits = 2 } },
            .{ .chars = "𖹀 𖹁 𖹂 𖹃 𖹏 𖹚 𖹒 𖹓", .zones = .{ .bits = 0 } },
            .{ .chars = "𖹤 𖹬 𖹧 𖹴 𖹶 𖹾", .zones = .{ .bits = 2 } },
            .{ .chars = "𖹠 𖹡 𖹢 𖹹 𖹳 𖹮", .zones = .{ .bits = 34 } },
            .{ .chars = "𖹠 𖹡 𖹢 𖹳 𖹭 𖹽", .zones = .{ .bits = 0 } },
            .{ .chars = "𖹥 𖹨 𖹩", .zones = .{ .bits = 0 } },
            .{ .chars = "𖺀 𖺅 𖺈 𖺄 𖺍", .zones = .{ .bits = 2 } },
        },
    },
    .{
        .name = "Mongolian",
        .group = 0,
        .tag = .{ 0x4d, 0x6f, 0x6e, 0x67 },
        .hint_top_to_bottom = true,
        .std_chars = "ᡂ ᠪ",
        .blues = &.{
            .{ .chars = "ᠳ ᠴ ᠶ ᠽ ᡂ ᡊ \\u{200d}ᡡ\\u{200d} \\u{200d}ᡳ\\u{200d}", .zones = .{ .bits = 2 } },
            .{ .chars = "ᡃ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Myanmar",
        .group = 0,
        .tag = .{ 0x4d, 0x79, 0x6d, 0x72 },
        .hint_top_to_bottom = false,
        .std_chars = "ဝ င ဂ",
        .blues = &.{
            .{ .chars = "ခ ဂ င ဒ ဝ ၥ ၊ ။", .zones = .{ .bits = 34 } },
            .{ .chars = "င ဎ ဒ ပ ဗ ဝ ၊ ။", .zones = .{ .bits = 0 } },
            .{ .chars = "ဩ ြ ၍ ၏ ၆ ါ ိ", .zones = .{ .bits = 2 } },
            .{ .chars = "ဉ ည ဥ ဩ ဨ ၂ ၅ ၉", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "N'Ko",
        .group = 0,
        .tag = .{ 0x4e, 0x6b, 0x6f, 0x6f },
        .hint_top_to_bottom = false,
        .std_chars = "ߋ ߀",
        .blues = &.{
            .{ .chars = "ߐ ߉ ߒ ߟ ߖ ߜ ߠ ߥ", .zones = .{ .bits = 2 } },
            .{ .chars = "߀ ߘ ߡ ߠ ߥ", .zones = .{ .bits = 0 } },
            .{ .chars = "ߏ ߛ ߋ", .zones = .{ .bits = 34 } },
            .{ .chars = "ߎ ߏ ߛ ߋ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "no script",
        .group = 0,
        .tag = .{ 0x4e, 0x6f, 0x6e, 0x65 },
        .hint_top_to_bottom = false,
        .std_chars = "",
        .blues = &.{},
    },
    .{
        .name = "Ol Chiki",
        .group = 0,
        .tag = .{ 0x4f, 0x6c, 0x63, 0x6b },
        .hint_top_to_bottom = false,
        .std_chars = "ᱛ",
        .blues = &.{
            .{ .chars = "ᱛ ᱜ ᱝ ᱡ ᱢ ᱥ", .zones = .{ .bits = 2 } },
            .{ .chars = "ᱛ ᱜ ᱝ ᱡ ᱢ ᱥ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Old Turkic",
        .group = 0,
        .tag = .{ 0x4f, 0x72, 0x6b, 0x68 },
        .hint_top_to_bottom = false,
        .std_chars = "𐰗",
        .blues = &.{
            .{ .chars = "𐰗 𐰘 𐰧", .zones = .{ .bits = 2 } },
            .{ .chars = "𐰉 𐰗 𐰦 𐰧", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Osage",
        .group = 0,
        .tag = .{ 0x4f, 0x73, 0x67, 0x65 },
        .hint_top_to_bottom = false,
        .std_chars = "𐓂 𐓪",
        .blues = &.{
            .{ .chars = "𐒾 𐓍 𐓒 𐓓 𐒻 𐓂 𐒵 𐓆", .zones = .{ .bits = 2 } },
            .{ .chars = "𐒰 𐓍 𐓂 𐒿 𐓎 𐒹", .zones = .{ .bits = 0 } },
            .{ .chars = "𐒼 𐒽 𐒾", .zones = .{ .bits = 0 } },
            .{ .chars = "𐓵 𐓶 𐓺 𐓻 𐓝 𐓣 𐓪 𐓮", .zones = .{ .bits = 34 } },
            .{ .chars = "𐓘 𐓚 𐓣 𐓵 𐓡 𐓧 𐓪 𐓶", .zones = .{ .bits = 0 } },
            .{ .chars = "𐓤 𐓦 𐓸 𐓹 𐓛", .zones = .{ .bits = 2 } },
            .{ .chars = "𐓤 𐓥 𐓦", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Osmanya",
        .group = 0,
        .tag = .{ 0x4f, 0x73, 0x6d, 0x61 },
        .hint_top_to_bottom = false,
        .std_chars = "𐒆 𐒠",
        .blues = &.{
            .{ .chars = "𐒆 𐒉 𐒐 𐒒 𐒘 𐒛 𐒠 𐒣", .zones = .{ .bits = 2 } },
            .{ .chars = "𐒀 𐒂 𐒆 𐒈 𐒊 𐒒 𐒠 𐒩", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Hanifi Rohingya",
        .group = 0,
        .tag = .{ 0x52, 0x6f, 0x68, 0x67 },
        .hint_top_to_bottom = false,
        .std_chars = "𐴰",
        .blues = &.{
            .{ .chars = "𐴃 𐴀 𐴆 𐴖 𐴕", .zones = .{ .bits = 2 } },
            .{ .chars = "𐴔 𐴖 𐴕 𐴑 𐴐", .zones = .{ .bits = 0 } },
            .{ .chars = "ـ", .zones = .{ .bits = 8 } },
        },
    },
    .{
        .name = "Saurashtra",
        .group = 0,
        .tag = .{ 0x53, 0x61, 0x75, 0x72 },
        .hint_top_to_bottom = false,
        .std_chars = "ꢝ ꣐",
        .blues = &.{
            .{ .chars = "ꢜ ꢞ ꢳ ꢂ ꢖ ꢒ ꢝ ꢛ", .zones = .{ .bits = 2 } },
            .{ .chars = "ꢂ ꢨ ꢺ ꢤ ꢎ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Shavian",
        .group = 0,
        .tag = .{ 0x53, 0x68, 0x61, 0x77 },
        .hint_top_to_bottom = false,
        .std_chars = "𐑴",
        .blues = &.{
            .{ .chars = "𐑕 𐑙", .zones = .{ .bits = 2 } },
            .{ .chars = "𐑔 𐑖 𐑗 𐑹 𐑻", .zones = .{ .bits = 0 } },
            .{ .chars = "𐑟 𐑣", .zones = .{ .bits = 0 } },
            .{ .chars = "𐑱 𐑲 𐑳 𐑴 𐑸 𐑺 𐑼", .zones = .{ .bits = 34 } },
            .{ .chars = "𐑴 𐑻 𐑹", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Sinhala",
        .group = 0,
        .tag = .{ 0x53, 0x69, 0x6e, 0x68 },
        .hint_top_to_bottom = false,
        .std_chars = "ට",
        .blues = &.{
            .{ .chars = "ඉ ක ඝ ඳ ප ය ල ෆ", .zones = .{ .bits = 2 } },
            .{ .chars = "එ ඔ ඝ ජ ට ථ ධ ර", .zones = .{ .bits = 0 } },
            .{ .chars = "ද ඳ උ ල තූ තු බු දු", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Sundanese",
        .group = 0,
        .tag = .{ 0x53, 0x75, 0x6e, 0x64 },
        .hint_top_to_bottom = false,
        .std_chars = "᮰",
        .blues = &.{
            .{ .chars = "ᮋ ᮞ ᮮ ᮽ ᮰ ᮈ", .zones = .{ .bits = 2 } },
            .{ .chars = "ᮄ ᮔ ᮕ ᮗ ᮰ ᮆ ᮈ ᮉ", .zones = .{ .bits = 0 } },
            .{ .chars = "ᮼ ᳄", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Tamil",
        .group = 0,
        .tag = .{ 0x54, 0x61, 0x6d, 0x6c },
        .hint_top_to_bottom = false,
        .std_chars = "௦",
        .blues = &.{
            .{ .chars = "உ ஒ ஓ ற ஈ க ங ச", .zones = .{ .bits = 2 } },
            .{ .chars = "க ச ல ஶ உ ங ட ப", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Tai Viet",
        .group = 0,
        .tag = .{ 0x54, 0x61, 0x76, 0x74 },
        .hint_top_to_bottom = false,
        .std_chars = "ꪒ ꪫ",
        .blues = &.{
            .{ .chars = "ꪆ ꪔ ꪒ ꪖ ꪫ", .zones = .{ .bits = 2 } },
            .{ .chars = "ꪉ ꪫ ꪮ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Telugu",
        .group = 0,
        .tag = .{ 0x54, 0x65, 0x6c, 0x75 },
        .hint_top_to_bottom = false,
        .std_chars = "౦ ౧",
        .blues = &.{
            .{ .chars = "ఇ ఌ ఙ ఞ ణ ఱ ౯", .zones = .{ .bits = 2 } },
            .{ .chars = "అ క చ ర ఽ ౨ ౬", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Tifinagh",
        .group = 0,
        .tag = .{ 0x54, 0x66, 0x6e, 0x67 },
        .hint_top_to_bottom = false,
        .std_chars = "ⵔ",
        .blues = &.{
            .{ .chars = "ⵔ ⵙ ⵛ ⵞ ⴵ ⴼ ⴹ ⵎ", .zones = .{ .bits = 2 } },
            .{ .chars = "ⵔ ⵙ ⵛ ⵞ ⴵ ⴼ ⴹ ⵎ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Thai",
        .group = 0,
        .tag = .{ 0x54, 0x68, 0x61, 0x69 },
        .hint_top_to_bottom = false,
        .std_chars = "า ๅ ๐",
        .blues = &.{
            .{ .chars = "บ เ แ อ ก า", .zones = .{ .bits = 34 } },
            .{ .chars = "บ ป ษ ฯ อ ย ฮ", .zones = .{ .bits = 0 } },
            .{ .chars = "ป ฝ ฟ", .zones = .{ .bits = 2 } },
            .{ .chars = "โ ใ ไ", .zones = .{ .bits = 2 } },
            .{ .chars = "ฎ ฏ ฤ ฦ", .zones = .{ .bits = 0 } },
            .{ .chars = "ญ ฐ", .zones = .{ .bits = 0 } },
            .{ .chars = "๐ ๑ ๓", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Vai",
        .group = 0,
        .tag = .{ 0x56, 0x61, 0x69, 0x69 },
        .hint_top_to_bottom = false,
        .std_chars = "ꘓ ꖜ ꖴ",
        .blues = &.{
            .{ .chars = "ꗍ ꘖ ꘙ ꘜ ꖜ ꖝ ꔅ ꕢ", .zones = .{ .bits = 2 } },
            .{ .chars = "ꗍ ꘖ ꘙ ꗞ ꔅ ꕢ ꖜ ꔆ", .zones = .{ .bits = 0 } },
        },
    },
    .{
        .name = "Limbu",
        .group = 2,
        .tag = .{ 0x4c, 0x69, 0x6d, 0x62 },
        .hint_top_to_bottom = false,
        .std_chars = "o",
        .blues = &.{},
    },
    .{
        .name = "Oriya",
        .group = 2,
        .tag = .{ 0x4f, 0x72, 0x79, 0x61 },
        .hint_top_to_bottom = false,
        .std_chars = "o",
        .blues = &.{},
    },
    .{
        .name = "Syloti Nagri",
        .group = 2,
        .tag = .{ 0x53, 0x79, 0x6c, 0x6f },
        .hint_top_to_bottom = false,
        .std_chars = "o",
        .blues = &.{},
    },
    .{
        .name = "Tibetan",
        .group = 2,
        .tag = .{ 0x54, 0x69, 0x62, 0x74 },
        .hint_top_to_bottom = false,
        .std_chars = "o",
        .blues = &.{},
    },
    .{
        .name = "CJKV ideographs",
        .group = 1,
        .tag = .{ 0x48, 0x61, 0x6e, 0x69 },
        .hint_top_to_bottom = false,
        .std_chars = "田 囗",
        .blues = &.{
            .{ .chars = "他 们 你 來 們 到 和 地 对 對 就 席 我 时 時 會 来 為 能 舰 說 说 这 這 齊 | 军 同 已 愿 既 星 是 景 民 照 现 現 理 用 置 要 軍 那 配 里 開 雷 露 面 顾", .zones = .{ .bits = 2 } },
            .{ .chars = "个 为 人 他 以 们 你 來 個 們 到 和 大 对 對 就 我 时 時 有 来 為 要 說 说 | 主 些 因 它 想 意 理 生 當 看 着 置 者 自 著 裡 过 还 进 進 過 道 還 里 面", .zones = .{ .bits = 0 } },
            .{ .chars = " 些 们 你 來 們 到 和 地 她 将 將 就 年 得 情 最 样 樣 理 能 說 说 这 這 通 | 即 吗 吧 听 呢 品 响 嗎 师 師 收 断 斷 明 眼 間 间 际 陈 限 除 陳 随 際 隨", .zones = .{ .bits = 4 } },
            .{ .chars = "事 前 學 将 將 情 想 或 政 斯 新 样 樣 民 沒 没 然 特 现 現 球 第 經 谁 起 | 例 別 别 制 动 動 吗 嗎 增 指 明 朝 期 构 物 确 种 調 调 費 费 那 都 間 间", .zones = .{ .bits = 6 } },
        },
    },
};

pub const STYLE_CLASSES = [_]RawStyle{
    .{
        .name = "Adlam",
        .script = 0,
        .feature = null,
    },
    .{
        .name = "Arabic",
        .script = 1,
        .feature = null,
    },
    .{
        .name = "Armenian",
        .script = 2,
        .feature = null,
    },
    .{
        .name = "Avestan",
        .script = 3,
        .feature = null,
    },
    .{
        .name = "Bamum",
        .script = 4,
        .feature = null,
    },
    .{
        .name = "Bengali",
        .script = 5,
        .feature = null,
    },
    .{
        .name = "Buhid",
        .script = 6,
        .feature = null,
    },
    .{
        .name = "Chakma",
        .script = 7,
        .feature = null,
    },
    .{
        .name = "Canadian Syllabics",
        .script = 8,
        .feature = null,
    },
    .{
        .name = "Carian",
        .script = 9,
        .feature = null,
    },
    .{
        .name = "Cherokee",
        .script = 10,
        .feature = null,
    },
    .{
        .name = "Coptic",
        .script = 11,
        .feature = null,
    },
    .{
        .name = "Cypriot",
        .script = 12,
        .feature = null,
    },
    .{
        .name = "Cyrillic petite capitals from capitals",
        .script = 13,
        .feature = .{ 0x63, 0x32, 0x63, 0x70 },
    },
    .{
        .name = "Cyrillic small capitals from capitals",
        .script = 13,
        .feature = .{ 0x63, 0x32, 0x73, 0x63 },
    },
    .{
        .name = "Cyrillic ordinals",
        .script = 13,
        .feature = .{ 0x6f, 0x72, 0x64, 0x6e },
    },
    .{
        .name = "Cyrillic petite capitals",
        .script = 13,
        .feature = .{ 0x70, 0x63, 0x61, 0x70 },
    },
    .{
        .name = "Cyrillic ruby",
        .script = 13,
        .feature = .{ 0x72, 0x75, 0x62, 0x79 },
    },
    .{
        .name = "Cyrillic scientific inferiors",
        .script = 13,
        .feature = .{ 0x73, 0x69, 0x6e, 0x66 },
    },
    .{
        .name = "Cyrillic small capitals",
        .script = 13,
        .feature = .{ 0x73, 0x6d, 0x63, 0x70 },
    },
    .{
        .name = "Cyrillic subscript",
        .script = 13,
        .feature = .{ 0x73, 0x75, 0x62, 0x73 },
    },
    .{
        .name = "Cyrillic superscript",
        .script = 13,
        .feature = .{ 0x73, 0x75, 0x70, 0x73 },
    },
    .{
        .name = "Cyrillic titling",
        .script = 13,
        .feature = .{ 0x74, 0x69, 0x74, 0x6c },
    },
    .{
        .name = "Cyrillic",
        .script = 13,
        .feature = null,
    },
    .{
        .name = "Devanagari",
        .script = 14,
        .feature = null,
    },
    .{
        .name = "Deseret",
        .script = 15,
        .feature = null,
    },
    .{
        .name = "Ethiopic",
        .script = 16,
        .feature = null,
    },
    .{
        .name = "Georgian (Mkhedruli)",
        .script = 17,
        .feature = null,
    },
    .{
        .name = "Georgian (Khutsuri)",
        .script = 18,
        .feature = null,
    },
    .{
        .name = "Glagolitic",
        .script = 19,
        .feature = null,
    },
    .{
        .name = "Gothic",
        .script = 20,
        .feature = null,
    },
    .{
        .name = "Greek petite capitals from capitals",
        .script = 21,
        .feature = .{ 0x63, 0x32, 0x63, 0x70 },
    },
    .{
        .name = "Greek small capitals from capitals",
        .script = 21,
        .feature = .{ 0x63, 0x32, 0x73, 0x63 },
    },
    .{
        .name = "Greek ordinals",
        .script = 21,
        .feature = .{ 0x6f, 0x72, 0x64, 0x6e },
    },
    .{
        .name = "Greek petite capitals",
        .script = 21,
        .feature = .{ 0x70, 0x63, 0x61, 0x70 },
    },
    .{
        .name = "Greek ruby",
        .script = 21,
        .feature = .{ 0x72, 0x75, 0x62, 0x79 },
    },
    .{
        .name = "Greek scientific inferiors",
        .script = 21,
        .feature = .{ 0x73, 0x69, 0x6e, 0x66 },
    },
    .{
        .name = "Greek small capitals",
        .script = 21,
        .feature = .{ 0x73, 0x6d, 0x63, 0x70 },
    },
    .{
        .name = "Greek subscript",
        .script = 21,
        .feature = .{ 0x73, 0x75, 0x62, 0x73 },
    },
    .{
        .name = "Greek superscript",
        .script = 21,
        .feature = .{ 0x73, 0x75, 0x70, 0x73 },
    },
    .{
        .name = "Greek titling",
        .script = 21,
        .feature = .{ 0x74, 0x69, 0x74, 0x6c },
    },
    .{
        .name = "Greek",
        .script = 21,
        .feature = null,
    },
    .{
        .name = "Gujarati",
        .script = 22,
        .feature = null,
    },
    .{
        .name = "Gurmukhi",
        .script = 23,
        .feature = null,
    },
    .{
        .name = "Hebrew",
        .script = 24,
        .feature = null,
    },
    .{
        .name = "Nyiakeng Puachue Hmong",
        .script = 25,
        .feature = null,
    },
    .{
        .name = "Kayah Li",
        .script = 26,
        .feature = null,
    },
    .{
        .name = "Khmer",
        .script = 27,
        .feature = null,
    },
    .{
        .name = "Khmer Symbols",
        .script = 28,
        .feature = null,
    },
    .{
        .name = "Kannada",
        .script = 29,
        .feature = null,
    },
    .{
        .name = "Lao",
        .script = 30,
        .feature = null,
    },
    .{
        .name = "Latin petite capitals from capitals",
        .script = 31,
        .feature = .{ 0x63, 0x32, 0x63, 0x70 },
    },
    .{
        .name = "Latin small capitals from capitals",
        .script = 31,
        .feature = .{ 0x63, 0x32, 0x73, 0x63 },
    },
    .{
        .name = "Latin ordinals",
        .script = 31,
        .feature = .{ 0x6f, 0x72, 0x64, 0x6e },
    },
    .{
        .name = "Latin petite capitals",
        .script = 31,
        .feature = .{ 0x70, 0x63, 0x61, 0x70 },
    },
    .{
        .name = "Latin ruby",
        .script = 31,
        .feature = .{ 0x72, 0x75, 0x62, 0x79 },
    },
    .{
        .name = "Latin scientific inferiors",
        .script = 31,
        .feature = .{ 0x73, 0x69, 0x6e, 0x66 },
    },
    .{
        .name = "Latin small capitals",
        .script = 31,
        .feature = .{ 0x73, 0x6d, 0x63, 0x70 },
    },
    .{
        .name = "Latin subscript",
        .script = 31,
        .feature = .{ 0x73, 0x75, 0x62, 0x73 },
    },
    .{
        .name = "Latin superscript",
        .script = 31,
        .feature = .{ 0x73, 0x75, 0x70, 0x73 },
    },
    .{
        .name = "Latin titling",
        .script = 31,
        .feature = .{ 0x74, 0x69, 0x74, 0x6c },
    },
    .{
        .name = "Latin",
        .script = 31,
        .feature = null,
    },
    .{
        .name = "Latin Subscript Fallback",
        .script = 32,
        .feature = null,
    },
    .{
        .name = "Latin Superscript Fallback",
        .script = 33,
        .feature = null,
    },
    .{
        .name = "Lisu",
        .script = 34,
        .feature = null,
    },
    .{
        .name = "Malayalam",
        .script = 35,
        .feature = null,
    },
    .{
        .name = "Medefaidrin",
        .script = 36,
        .feature = null,
    },
    .{
        .name = "Mongolian",
        .script = 37,
        .feature = null,
    },
    .{
        .name = "Myanmar",
        .script = 38,
        .feature = null,
    },
    .{
        .name = "N'Ko",
        .script = 39,
        .feature = null,
    },
    .{
        .name = "no script",
        .script = 40,
        .feature = null,
    },
    .{
        .name = "Ol Chiki",
        .script = 41,
        .feature = null,
    },
    .{
        .name = "Old Turkic",
        .script = 42,
        .feature = null,
    },
    .{
        .name = "Osage",
        .script = 43,
        .feature = null,
    },
    .{
        .name = "Osmanya",
        .script = 44,
        .feature = null,
    },
    .{
        .name = "Hanifi Rohingya",
        .script = 45,
        .feature = null,
    },
    .{
        .name = "Saurashtra",
        .script = 46,
        .feature = null,
    },
    .{
        .name = "Shavian",
        .script = 47,
        .feature = null,
    },
    .{
        .name = "Sinhala",
        .script = 48,
        .feature = null,
    },
    .{
        .name = "Sundanese",
        .script = 49,
        .feature = null,
    },
    .{
        .name = "Tamil",
        .script = 50,
        .feature = null,
    },
    .{
        .name = "Tai Viet",
        .script = 51,
        .feature = null,
    },
    .{
        .name = "Telugu",
        .script = 52,
        .feature = null,
    },
    .{
        .name = "Tifinagh",
        .script = 53,
        .feature = null,
    },
    .{
        .name = "Thai",
        .script = 54,
        .feature = null,
    },
    .{
        .name = "Vai",
        .script = 55,
        .feature = null,
    },
    .{
        .name = "Limbu",
        .script = 56,
        .feature = null,
    },
    .{
        .name = "Oriya",
        .script = 57,
        .feature = null,
    },
    .{
        .name = "Syloti Nagri",
        .script = 58,
        .feature = null,
    },
    .{
        .name = "Tibetan",
        .script = 59,
        .feature = null,
    },
    .{
        .name = "CJKV ideographs",
        .script = 60,
        .feature = null,
    },
};

pub const STYLE_RANGES = [_]RawRange{
    .{ .first = 32, .last = 93, .style = 61, .non_base = false },
    .{ .first = 94, .last = 96, .style = 61, .non_base = true },
    .{ .first = 97, .last = 125, .style = 61, .non_base = false },
    .{ .first = 126, .last = 126, .style = 61, .non_base = true },
    .{ .first = 127, .last = 127, .style = 61, .non_base = false },
    .{ .first = 160, .last = 167, .style = 61, .non_base = false },
    .{ .first = 168, .last = 169, .style = 61, .non_base = true },
    .{ .first = 170, .last = 170, .style = 63, .non_base = false },
    .{ .first = 171, .last = 173, .style = 61, .non_base = false },
    .{ .first = 174, .last = 176, .style = 61, .non_base = true },
    .{ .first = 177, .last = 177, .style = 61, .non_base = false },
    .{ .first = 178, .last = 179, .style = 63, .non_base = false },
    .{ .first = 180, .last = 180, .style = 61, .non_base = true },
    .{ .first = 181, .last = 183, .style = 61, .non_base = false },
    .{ .first = 184, .last = 184, .style = 61, .non_base = true },
    .{ .first = 185, .last = 186, .style = 63, .non_base = false },
    .{ .first = 187, .last = 187, .style = 61, .non_base = false },
    .{ .first = 188, .last = 190, .style = 61, .non_base = true },
    .{ .first = 191, .last = 687, .style = 61, .non_base = false },
    .{ .first = 688, .last = 696, .style = 63, .non_base = false },
    .{ .first = 697, .last = 735, .style = 61, .non_base = true },
    .{ .first = 736, .last = 740, .style = 63, .non_base = false },
    .{ .first = 741, .last = 879, .style = 61, .non_base = true },
    .{ .first = 880, .last = 889, .style = 41, .non_base = false },
    .{ .first = 890, .last = 890, .style = 41, .non_base = true },
    .{ .first = 891, .last = 899, .style = 41, .non_base = false },
    .{ .first = 900, .last = 901, .style = 41, .non_base = true },
    .{ .first = 902, .last = 1023, .style = 41, .non_base = false },
    .{ .first = 1024, .last = 1154, .style = 23, .non_base = false },
    .{ .first = 1155, .last = 1161, .style = 23, .non_base = true },
    .{ .first = 1162, .last = 1327, .style = 23, .non_base = false },
    .{ .first = 1328, .last = 1368, .style = 2, .non_base = false },
    .{ .first = 1369, .last = 1375, .style = 2, .non_base = true },
    .{ .first = 1376, .last = 1423, .style = 2, .non_base = false },
    .{ .first = 1424, .last = 1424, .style = 44, .non_base = false },
    .{ .first = 1425, .last = 1471, .style = 44, .non_base = true },
    .{ .first = 1472, .last = 1472, .style = 44, .non_base = false },
    .{ .first = 1473, .last = 1474, .style = 44, .non_base = true },
    .{ .first = 1475, .last = 1475, .style = 44, .non_base = false },
    .{ .first = 1476, .last = 1477, .style = 44, .non_base = true },
    .{ .first = 1478, .last = 1478, .style = 44, .non_base = false },
    .{ .first = 1479, .last = 1479, .style = 44, .non_base = true },
    .{ .first = 1480, .last = 1535, .style = 44, .non_base = false },
    .{ .first = 1536, .last = 1541, .style = 1, .non_base = true },
    .{ .first = 1542, .last = 1551, .style = 1, .non_base = false },
    .{ .first = 1552, .last = 1562, .style = 1, .non_base = true },
    .{ .first = 1563, .last = 1610, .style = 1, .non_base = false },
    .{ .first = 1611, .last = 1631, .style = 1, .non_base = true },
    .{ .first = 1632, .last = 1647, .style = 1, .non_base = false },
    .{ .first = 1648, .last = 1648, .style = 1, .non_base = true },
    .{ .first = 1649, .last = 1749, .style = 1, .non_base = false },
    .{ .first = 1750, .last = 1756, .style = 1, .non_base = true },
    .{ .first = 1757, .last = 1758, .style = 1, .non_base = false },
    .{ .first = 1759, .last = 1764, .style = 1, .non_base = true },
    .{ .first = 1765, .last = 1766, .style = 1, .non_base = false },
    .{ .first = 1767, .last = 1768, .style = 1, .non_base = true },
    .{ .first = 1769, .last = 1769, .style = 1, .non_base = false },
    .{ .first = 1770, .last = 1773, .style = 1, .non_base = true },
    .{ .first = 1774, .last = 1791, .style = 1, .non_base = false },
    .{ .first = 1872, .last = 2047, .style = 1, .non_base = false },
    .{ .first = 2208, .last = 2258, .style = 1, .non_base = false },
    .{ .first = 2259, .last = 2303, .style = 1, .non_base = true },
    .{ .first = 2304, .last = 2306, .style = 24, .non_base = true },
    .{ .first = 2307, .last = 2361, .style = 24, .non_base = false },
    .{ .first = 2362, .last = 2362, .style = 24, .non_base = true },
    .{ .first = 2363, .last = 2363, .style = 24, .non_base = false },
    .{ .first = 2365, .last = 2368, .style = 24, .non_base = false },
    .{ .first = 2369, .last = 2376, .style = 24, .non_base = true },
    .{ .first = 2377, .last = 2380, .style = 24, .non_base = false },
    .{ .first = 2381, .last = 2381, .style = 24, .non_base = true },
    .{ .first = 2382, .last = 2384, .style = 24, .non_base = false },
    .{ .first = 2387, .last = 2391, .style = 24, .non_base = true },
    .{ .first = 2392, .last = 2401, .style = 24, .non_base = false },
    .{ .first = 2402, .last = 2403, .style = 24, .non_base = true },
    .{ .first = 2406, .last = 2431, .style = 24, .non_base = false },
    .{ .first = 2432, .last = 2432, .style = 5, .non_base = false },
    .{ .first = 2433, .last = 2433, .style = 5, .non_base = true },
    .{ .first = 2434, .last = 2491, .style = 5, .non_base = false },
    .{ .first = 2492, .last = 2492, .style = 5, .non_base = true },
    .{ .first = 2493, .last = 2496, .style = 5, .non_base = false },
    .{ .first = 2497, .last = 2500, .style = 5, .non_base = true },
    .{ .first = 2501, .last = 2508, .style = 5, .non_base = false },
    .{ .first = 2509, .last = 2509, .style = 5, .non_base = true },
    .{ .first = 2510, .last = 2529, .style = 5, .non_base = false },
    .{ .first = 2530, .last = 2531, .style = 5, .non_base = true },
    .{ .first = 2532, .last = 2557, .style = 5, .non_base = false },
    .{ .first = 2558, .last = 2558, .style = 5, .non_base = true },
    .{ .first = 2559, .last = 2559, .style = 5, .non_base = false },
    .{ .first = 2560, .last = 2560, .style = 43, .non_base = false },
    .{ .first = 2561, .last = 2562, .style = 43, .non_base = true },
    .{ .first = 2563, .last = 2619, .style = 43, .non_base = false },
    .{ .first = 2620, .last = 2620, .style = 43, .non_base = true },
    .{ .first = 2621, .last = 2624, .style = 43, .non_base = false },
    .{ .first = 2625, .last = 2641, .style = 43, .non_base = true },
    .{ .first = 2642, .last = 2671, .style = 43, .non_base = false },
    .{ .first = 2672, .last = 2673, .style = 43, .non_base = true },
    .{ .first = 2674, .last = 2676, .style = 43, .non_base = false },
    .{ .first = 2677, .last = 2677, .style = 43, .non_base = true },
    .{ .first = 2678, .last = 2687, .style = 43, .non_base = false },
    .{ .first = 2688, .last = 2688, .style = 42, .non_base = false },
    .{ .first = 2689, .last = 2690, .style = 42, .non_base = true },
    .{ .first = 2691, .last = 2747, .style = 42, .non_base = false },
    .{ .first = 2748, .last = 2748, .style = 42, .non_base = true },
    .{ .first = 2749, .last = 2752, .style = 42, .non_base = false },
    .{ .first = 2753, .last = 2760, .style = 42, .non_base = true },
    .{ .first = 2761, .last = 2764, .style = 42, .non_base = false },
    .{ .first = 2765, .last = 2765, .style = 42, .non_base = true },
    .{ .first = 2766, .last = 2785, .style = 42, .non_base = false },
    .{ .first = 2786, .last = 2787, .style = 42, .non_base = true },
    .{ .first = 2788, .last = 2809, .style = 42, .non_base = false },
    .{ .first = 2810, .last = 2815, .style = 42, .non_base = true },
    .{ .first = 2816, .last = 2816, .style = 87, .non_base = false },
    .{ .first = 2817, .last = 2818, .style = 87, .non_base = true },
    .{ .first = 2819, .last = 2875, .style = 87, .non_base = false },
    .{ .first = 2876, .last = 2876, .style = 87, .non_base = true },
    .{ .first = 2877, .last = 2878, .style = 87, .non_base = false },
    .{ .first = 2879, .last = 2879, .style = 87, .non_base = true },
    .{ .first = 2880, .last = 2880, .style = 87, .non_base = false },
    .{ .first = 2881, .last = 2884, .style = 87, .non_base = true },
    .{ .first = 2885, .last = 2892, .style = 87, .non_base = false },
    .{ .first = 2893, .last = 2902, .style = 87, .non_base = true },
    .{ .first = 2903, .last = 2913, .style = 87, .non_base = false },
    .{ .first = 2914, .last = 2915, .style = 87, .non_base = true },
    .{ .first = 2916, .last = 2943, .style = 87, .non_base = false },
    .{ .first = 2944, .last = 2945, .style = 80, .non_base = false },
    .{ .first = 2946, .last = 2946, .style = 80, .non_base = true },
    .{ .first = 2947, .last = 3007, .style = 80, .non_base = false },
    .{ .first = 3008, .last = 3010, .style = 80, .non_base = true },
    .{ .first = 3011, .last = 3020, .style = 80, .non_base = false },
    .{ .first = 3021, .last = 3021, .style = 80, .non_base = true },
    .{ .first = 3022, .last = 3071, .style = 80, .non_base = false },
    .{ .first = 3072, .last = 3072, .style = 82, .non_base = true },
    .{ .first = 3073, .last = 3075, .style = 82, .non_base = false },
    .{ .first = 3076, .last = 3076, .style = 82, .non_base = true },
    .{ .first = 3077, .last = 3133, .style = 82, .non_base = false },
    .{ .first = 3134, .last = 3136, .style = 82, .non_base = true },
    .{ .first = 3137, .last = 3141, .style = 82, .non_base = false },
    .{ .first = 3142, .last = 3158, .style = 82, .non_base = true },
    .{ .first = 3159, .last = 3169, .style = 82, .non_base = false },
    .{ .first = 3170, .last = 3171, .style = 82, .non_base = true },
    .{ .first = 3172, .last = 3199, .style = 82, .non_base = false },
    .{ .first = 3200, .last = 3200, .style = 49, .non_base = false },
    .{ .first = 3201, .last = 3201, .style = 49, .non_base = true },
    .{ .first = 3202, .last = 3259, .style = 49, .non_base = false },
    .{ .first = 3260, .last = 3260, .style = 49, .non_base = true },
    .{ .first = 3261, .last = 3262, .style = 49, .non_base = false },
    .{ .first = 3263, .last = 3263, .style = 49, .non_base = true },
    .{ .first = 3264, .last = 3269, .style = 49, .non_base = false },
    .{ .first = 3270, .last = 3270, .style = 49, .non_base = true },
    .{ .first = 3271, .last = 3275, .style = 49, .non_base = false },
    .{ .first = 3276, .last = 3277, .style = 49, .non_base = true },
    .{ .first = 3278, .last = 3297, .style = 49, .non_base = false },
    .{ .first = 3298, .last = 3299, .style = 49, .non_base = true },
    .{ .first = 3300, .last = 3327, .style = 49, .non_base = false },
    .{ .first = 3328, .last = 3329, .style = 65, .non_base = true },
    .{ .first = 3330, .last = 3386, .style = 65, .non_base = false },
    .{ .first = 3387, .last = 3388, .style = 65, .non_base = true },
    .{ .first = 3389, .last = 3404, .style = 65, .non_base = false },
    .{ .first = 3405, .last = 3406, .style = 65, .non_base = true },
    .{ .first = 3407, .last = 3425, .style = 65, .non_base = false },
    .{ .first = 3426, .last = 3427, .style = 65, .non_base = true },
    .{ .first = 3428, .last = 3455, .style = 65, .non_base = false },
    .{ .first = 3456, .last = 3529, .style = 78, .non_base = false },
    .{ .first = 3530, .last = 3530, .style = 78, .non_base = true },
    .{ .first = 3531, .last = 3537, .style = 78, .non_base = false },
    .{ .first = 3538, .last = 3542, .style = 78, .non_base = true },
    .{ .first = 3543, .last = 3583, .style = 78, .non_base = false },
    .{ .first = 3584, .last = 3632, .style = 84, .non_base = false },
    .{ .first = 3633, .last = 3633, .style = 84, .non_base = true },
    .{ .first = 3634, .last = 3635, .style = 84, .non_base = false },
    .{ .first = 3636, .last = 3642, .style = 84, .non_base = true },
    .{ .first = 3643, .last = 3654, .style = 84, .non_base = false },
    .{ .first = 3655, .last = 3662, .style = 84, .non_base = true },
    .{ .first = 3663, .last = 3711, .style = 84, .non_base = false },
    .{ .first = 3712, .last = 3760, .style = 50, .non_base = false },
    .{ .first = 3761, .last = 3761, .style = 50, .non_base = true },
    .{ .first = 3762, .last = 3763, .style = 50, .non_base = false },
    .{ .first = 3764, .last = 3772, .style = 50, .non_base = true },
    .{ .first = 3773, .last = 3783, .style = 50, .non_base = false },
    .{ .first = 3784, .last = 3789, .style = 50, .non_base = true },
    .{ .first = 3790, .last = 3839, .style = 50, .non_base = false },
    .{ .first = 3840, .last = 3863, .style = 89, .non_base = false },
    .{ .first = 3864, .last = 3865, .style = 89, .non_base = true },
    .{ .first = 3866, .last = 3892, .style = 89, .non_base = false },
    .{ .first = 3893, .last = 3893, .style = 89, .non_base = true },
    .{ .first = 3894, .last = 3894, .style = 89, .non_base = false },
    .{ .first = 3895, .last = 3895, .style = 89, .non_base = true },
    .{ .first = 3896, .last = 3896, .style = 89, .non_base = false },
    .{ .first = 3897, .last = 3897, .style = 89, .non_base = true },
    .{ .first = 3898, .last = 3901, .style = 89, .non_base = false },
    .{ .first = 3902, .last = 3903, .style = 89, .non_base = true },
    .{ .first = 3904, .last = 3952, .style = 89, .non_base = false },
    .{ .first = 3953, .last = 3966, .style = 89, .non_base = true },
    .{ .first = 3967, .last = 3967, .style = 89, .non_base = false },
    .{ .first = 3968, .last = 3972, .style = 89, .non_base = true },
    .{ .first = 3973, .last = 3973, .style = 89, .non_base = false },
    .{ .first = 3974, .last = 3975, .style = 89, .non_base = true },
    .{ .first = 3976, .last = 3980, .style = 89, .non_base = false },
    .{ .first = 3981, .last = 4028, .style = 89, .non_base = true },
    .{ .first = 4029, .last = 4095, .style = 89, .non_base = false },
    .{ .first = 4096, .last = 4140, .style = 68, .non_base = false },
    .{ .first = 4141, .last = 4144, .style = 68, .non_base = true },
    .{ .first = 4145, .last = 4145, .style = 68, .non_base = false },
    .{ .first = 4146, .last = 4151, .style = 68, .non_base = true },
    .{ .first = 4152, .last = 4153, .style = 68, .non_base = false },
    .{ .first = 4154, .last = 4154, .style = 68, .non_base = true },
    .{ .first = 4155, .last = 4156, .style = 68, .non_base = false },
    .{ .first = 4157, .last = 4158, .style = 68, .non_base = true },
    .{ .first = 4159, .last = 4183, .style = 68, .non_base = false },
    .{ .first = 4184, .last = 4185, .style = 68, .non_base = true },
    .{ .first = 4186, .last = 4189, .style = 68, .non_base = false },
    .{ .first = 4190, .last = 4192, .style = 68, .non_base = true },
    .{ .first = 4193, .last = 4208, .style = 68, .non_base = false },
    .{ .first = 4209, .last = 4212, .style = 68, .non_base = true },
    .{ .first = 4213, .last = 4225, .style = 68, .non_base = false },
    .{ .first = 4226, .last = 4226, .style = 68, .non_base = true },
    .{ .first = 4227, .last = 4228, .style = 68, .non_base = false },
    .{ .first = 4229, .last = 4230, .style = 68, .non_base = true },
    .{ .first = 4231, .last = 4236, .style = 68, .non_base = false },
    .{ .first = 4237, .last = 4237, .style = 68, .non_base = true },
    .{ .first = 4238, .last = 4255, .style = 68, .non_base = false },
    .{ .first = 4256, .last = 4301, .style = 28, .non_base = false },
    .{ .first = 4304, .last = 4351, .style = 27, .non_base = false },
    .{ .first = 4352, .last = 4607, .style = 90, .non_base = false },
    .{ .first = 4608, .last = 4956, .style = 26, .non_base = false },
    .{ .first = 4957, .last = 4959, .style = 26, .non_base = true },
    .{ .first = 4960, .last = 5023, .style = 26, .non_base = false },
    .{ .first = 5024, .last = 5119, .style = 10, .non_base = false },
    .{ .first = 5120, .last = 5759, .style = 8, .non_base = false },
    .{ .first = 5952, .last = 5969, .style = 6, .non_base = false },
    .{ .first = 5970, .last = 5971, .style = 6, .non_base = true },
    .{ .first = 5972, .last = 5983, .style = 6, .non_base = false },
    .{ .first = 6016, .last = 6070, .style = 47, .non_base = false },
    .{ .first = 6071, .last = 6077, .style = 47, .non_base = true },
    .{ .first = 6078, .last = 6085, .style = 47, .non_base = false },
    .{ .first = 6086, .last = 6086, .style = 47, .non_base = true },
    .{ .first = 6087, .last = 6088, .style = 47, .non_base = false },
    .{ .first = 6089, .last = 6099, .style = 47, .non_base = true },
    .{ .first = 6100, .last = 6108, .style = 47, .non_base = false },
    .{ .first = 6109, .last = 6109, .style = 47, .non_base = true },
    .{ .first = 6110, .last = 6143, .style = 47, .non_base = false },
    .{ .first = 6144, .last = 6276, .style = 67, .non_base = false },
    .{ .first = 6277, .last = 6278, .style = 67, .non_base = true },
    .{ .first = 6279, .last = 6312, .style = 67, .non_base = false },
    .{ .first = 6313, .last = 6313, .style = 67, .non_base = true },
    .{ .first = 6314, .last = 6319, .style = 67, .non_base = false },
    .{ .first = 6320, .last = 6399, .style = 8, .non_base = false },
    .{ .first = 6400, .last = 6431, .style = 86, .non_base = false },
    .{ .first = 6432, .last = 6434, .style = 86, .non_base = true },
    .{ .first = 6435, .last = 6438, .style = 86, .non_base = false },
    .{ .first = 6439, .last = 6452, .style = 86, .non_base = true },
    .{ .first = 6453, .last = 6454, .style = 86, .non_base = false },
    .{ .first = 6455, .last = 6459, .style = 86, .non_base = true },
    .{ .first = 6460, .last = 6479, .style = 86, .non_base = false },
    .{ .first = 6624, .last = 6655, .style = 48, .non_base = false },
    .{ .first = 6832, .last = 6846, .style = 61, .non_base = true },
    .{ .first = 7040, .last = 7042, .style = 79, .non_base = true },
    .{ .first = 7043, .last = 7072, .style = 79, .non_base = false },
    .{ .first = 7073, .last = 7085, .style = 79, .non_base = true },
    .{ .first = 7086, .last = 7103, .style = 79, .non_base = false },
    .{ .first = 7248, .last = 7295, .style = 71, .non_base = false },
    .{ .first = 7296, .last = 7311, .style = 23, .non_base = false },
    .{ .first = 7312, .last = 7359, .style = 27, .non_base = false },
    .{ .first = 7360, .last = 7375, .style = 79, .non_base = false },
    .{ .first = 7424, .last = 7467, .style = 61, .non_base = false },
    .{ .first = 7468, .last = 7521, .style = 63, .non_base = false },
    .{ .first = 7522, .last = 7530, .style = 62, .non_base = false },
    .{ .first = 7531, .last = 7543, .style = 61, .non_base = false },
    .{ .first = 7544, .last = 7544, .style = 63, .non_base = false },
    .{ .first = 7545, .last = 7578, .style = 61, .non_base = false },
    .{ .first = 7579, .last = 7615, .style = 63, .non_base = false },
    .{ .first = 7616, .last = 7679, .style = 61, .non_base = true },
    .{ .first = 7680, .last = 7935, .style = 61, .non_base = false },
    .{ .first = 7936, .last = 8124, .style = 41, .non_base = false },
    .{ .first = 8125, .last = 8129, .style = 41, .non_base = true },
    .{ .first = 8130, .last = 8140, .style = 41, .non_base = false },
    .{ .first = 8141, .last = 8143, .style = 41, .non_base = true },
    .{ .first = 8144, .last = 8156, .style = 41, .non_base = false },
    .{ .first = 8157, .last = 8159, .style = 41, .non_base = true },
    .{ .first = 8160, .last = 8172, .style = 41, .non_base = false },
    .{ .first = 8173, .last = 8175, .style = 41, .non_base = true },
    .{ .first = 8176, .last = 8188, .style = 41, .non_base = false },
    .{ .first = 8189, .last = 8190, .style = 41, .non_base = true },
    .{ .first = 8191, .last = 8191, .style = 41, .non_base = false },
    .{ .first = 8192, .last = 8214, .style = 61, .non_base = false },
    .{ .first = 8215, .last = 8215, .style = 61, .non_base = true },
    .{ .first = 8216, .last = 8253, .style = 61, .non_base = false },
    .{ .first = 8254, .last = 8254, .style = 61, .non_base = true },
    .{ .first = 8255, .last = 8303, .style = 61, .non_base = false },
    .{ .first = 8304, .last = 8319, .style = 63, .non_base = false },
    .{ .first = 8320, .last = 8348, .style = 62, .non_base = false },
    .{ .first = 8352, .last = 8376, .style = 61, .non_base = false },
    .{ .first = 8377, .last = 8377, .style = 24, .non_base = false },
    .{ .first = 8378, .last = 8399, .style = 61, .non_base = false },
    .{ .first = 8528, .last = 8591, .style = 61, .non_base = false },
    .{ .first = 11264, .last = 11359, .style = 29, .non_base = false },
    .{ .first = 11360, .last = 11387, .style = 61, .non_base = false },
    .{ .first = 11388, .last = 11388, .style = 62, .non_base = false },
    .{ .first = 11389, .last = 11389, .style = 63, .non_base = false },
    .{ .first = 11390, .last = 11391, .style = 61, .non_base = false },
    .{ .first = 11392, .last = 11502, .style = 11, .non_base = false },
    .{ .first = 11503, .last = 11505, .style = 11, .non_base = true },
    .{ .first = 11506, .last = 11519, .style = 11, .non_base = false },
    .{ .first = 11520, .last = 11565, .style = 28, .non_base = false },
    .{ .first = 11568, .last = 11647, .style = 83, .non_base = false },
    .{ .first = 11648, .last = 11743, .style = 26, .non_base = false },
    .{ .first = 11744, .last = 11775, .style = 23, .non_base = true },
    .{ .first = 11776, .last = 11903, .style = 61, .non_base = false },
    .{ .first = 11904, .last = 12255, .style = 90, .non_base = false },
    .{ .first = 12272, .last = 12329, .style = 90, .non_base = false },
    .{ .first = 12330, .last = 12335, .style = 90, .non_base = true },
    .{ .first = 12336, .last = 12687, .style = 90, .non_base = false },
    .{ .first = 12688, .last = 12703, .style = 90, .non_base = true },
    .{ .first = 12704, .last = 12799, .style = 90, .non_base = false },
    .{ .first = 13056, .last = 40959, .style = 90, .non_base = false },
    .{ .first = 42192, .last = 42239, .style = 64, .non_base = false },
    .{ .first = 42240, .last = 42559, .style = 85, .non_base = false },
    .{ .first = 42560, .last = 42606, .style = 23, .non_base = false },
    .{ .first = 42607, .last = 42623, .style = 23, .non_base = true },
    .{ .first = 42624, .last = 42653, .style = 23, .non_base = false },
    .{ .first = 42654, .last = 42655, .style = 23, .non_base = true },
    .{ .first = 42656, .last = 42735, .style = 4, .non_base = false },
    .{ .first = 42736, .last = 42737, .style = 4, .non_base = true },
    .{ .first = 42738, .last = 42751, .style = 4, .non_base = false },
    .{ .first = 42784, .last = 42863, .style = 61, .non_base = false },
    .{ .first = 42864, .last = 42864, .style = 63, .non_base = false },
    .{ .first = 42865, .last = 42887, .style = 61, .non_base = false },
    .{ .first = 42888, .last = 42888, .style = 61, .non_base = true },
    .{ .first = 42889, .last = 42999, .style = 61, .non_base = false },
    .{ .first = 43000, .last = 43001, .style = 63, .non_base = false },
    .{ .first = 43002, .last = 43002, .style = 61, .non_base = true },
    .{ .first = 43003, .last = 43007, .style = 61, .non_base = false },
    .{ .first = 43008, .last = 43009, .style = 88, .non_base = false },
    .{ .first = 43010, .last = 43010, .style = 88, .non_base = true },
    .{ .first = 43011, .last = 43013, .style = 88, .non_base = false },
    .{ .first = 43014, .last = 43014, .style = 88, .non_base = true },
    .{ .first = 43015, .last = 43018, .style = 88, .non_base = false },
    .{ .first = 43019, .last = 43019, .style = 88, .non_base = true },
    .{ .first = 43020, .last = 43044, .style = 88, .non_base = false },
    .{ .first = 43045, .last = 43046, .style = 88, .non_base = true },
    .{ .first = 43047, .last = 43055, .style = 88, .non_base = false },
    .{ .first = 43136, .last = 43137, .style = 76, .non_base = true },
    .{ .first = 43138, .last = 43187, .style = 76, .non_base = false },
    .{ .first = 43188, .last = 43205, .style = 76, .non_base = true },
    .{ .first = 43206, .last = 43231, .style = 76, .non_base = false },
    .{ .first = 43232, .last = 43249, .style = 24, .non_base = true },
    .{ .first = 43250, .last = 43262, .style = 24, .non_base = false },
    .{ .first = 43263, .last = 43263, .style = 24, .non_base = true },
    .{ .first = 43264, .last = 43301, .style = 46, .non_base = false },
    .{ .first = 43302, .last = 43309, .style = 46, .non_base = true },
    .{ .first = 43310, .last = 43311, .style = 46, .non_base = false },
    .{ .first = 43360, .last = 43391, .style = 90, .non_base = false },
    .{ .first = 43488, .last = 43492, .style = 68, .non_base = false },
    .{ .first = 43493, .last = 43493, .style = 68, .non_base = true },
    .{ .first = 43494, .last = 43519, .style = 68, .non_base = false },
    .{ .first = 43616, .last = 43643, .style = 68, .non_base = false },
    .{ .first = 43644, .last = 43644, .style = 68, .non_base = true },
    .{ .first = 43645, .last = 43647, .style = 68, .non_base = false },
    .{ .first = 43648, .last = 43695, .style = 81, .non_base = false },
    .{ .first = 43696, .last = 43696, .style = 81, .non_base = true },
    .{ .first = 43697, .last = 43697, .style = 81, .non_base = false },
    .{ .first = 43698, .last = 43700, .style = 81, .non_base = true },
    .{ .first = 43701, .last = 43702, .style = 81, .non_base = false },
    .{ .first = 43703, .last = 43704, .style = 81, .non_base = true },
    .{ .first = 43705, .last = 43709, .style = 81, .non_base = false },
    .{ .first = 43710, .last = 43711, .style = 81, .non_base = true },
    .{ .first = 43712, .last = 43712, .style = 81, .non_base = false },
    .{ .first = 43713, .last = 43713, .style = 81, .non_base = true },
    .{ .first = 43714, .last = 43743, .style = 81, .non_base = false },
    .{ .first = 43776, .last = 43823, .style = 26, .non_base = false },
    .{ .first = 43824, .last = 43867, .style = 61, .non_base = false },
    .{ .first = 43868, .last = 43871, .style = 63, .non_base = false },
    .{ .first = 43872, .last = 43887, .style = 61, .non_base = false },
    .{ .first = 43888, .last = 43967, .style = 10, .non_base = false },
    .{ .first = 44032, .last = 55295, .style = 90, .non_base = false },
    .{ .first = 63744, .last = 64255, .style = 90, .non_base = false },
    .{ .first = 64256, .last = 64262, .style = 61, .non_base = false },
    .{ .first = 64275, .last = 64279, .style = 2, .non_base = false },
    .{ .first = 64285, .last = 64285, .style = 44, .non_base = false },
    .{ .first = 64286, .last = 64286, .style = 44, .non_base = true },
    .{ .first = 64287, .last = 64335, .style = 44, .non_base = false },
    .{ .first = 64336, .last = 64433, .style = 1, .non_base = false },
    .{ .first = 64434, .last = 64449, .style = 1, .non_base = true },
    .{ .first = 64450, .last = 65023, .style = 1, .non_base = false },
    .{ .first = 65040, .last = 65055, .style = 90, .non_base = false },
    .{ .first = 65072, .last = 65103, .style = 90, .non_base = false },
    .{ .first = 65136, .last = 65136, .style = 1, .non_base = true },
    .{ .first = 65137, .last = 65137, .style = 1, .non_base = false },
    .{ .first = 65138, .last = 65138, .style = 1, .non_base = true },
    .{ .first = 65139, .last = 65139, .style = 1, .non_base = false },
    .{ .first = 65140, .last = 65140, .style = 1, .non_base = true },
    .{ .first = 65141, .last = 65141, .style = 1, .non_base = false },
    .{ .first = 65142, .last = 65142, .style = 1, .non_base = true },
    .{ .first = 65143, .last = 65143, .style = 1, .non_base = false },
    .{ .first = 65144, .last = 65144, .style = 1, .non_base = true },
    .{ .first = 65145, .last = 65145, .style = 1, .non_base = false },
    .{ .first = 65146, .last = 65146, .style = 1, .non_base = true },
    .{ .first = 65147, .last = 65147, .style = 1, .non_base = false },
    .{ .first = 65148, .last = 65148, .style = 1, .non_base = true },
    .{ .first = 65149, .last = 65149, .style = 1, .non_base = false },
    .{ .first = 65150, .last = 65150, .style = 1, .non_base = true },
    .{ .first = 65151, .last = 65279, .style = 1, .non_base = false },
    .{ .first = 65280, .last = 65519, .style = 90, .non_base = false },
    .{ .first = 66208, .last = 66271, .style = 9, .non_base = false },
    .{ .first = 66352, .last = 66383, .style = 30, .non_base = false },
    .{ .first = 66560, .last = 66639, .style = 25, .non_base = false },
    .{ .first = 66640, .last = 66687, .style = 77, .non_base = false },
    .{ .first = 66688, .last = 66735, .style = 74, .non_base = false },
    .{ .first = 66736, .last = 66815, .style = 73, .non_base = false },
    .{ .first = 67584, .last = 67647, .style = 12, .non_base = false },
    .{ .first = 68352, .last = 68408, .style = 3, .non_base = false },
    .{ .first = 68409, .last = 68415, .style = 3, .non_base = true },
    .{ .first = 68608, .last = 68687, .style = 72, .non_base = false },
    .{ .first = 68864, .last = 68927, .style = 75, .non_base = false },
    .{ .first = 69888, .last = 69890, .style = 7, .non_base = true },
    .{ .first = 69891, .last = 69926, .style = 7, .non_base = false },
    .{ .first = 69927, .last = 69940, .style = 7, .non_base = true },
    .{ .first = 69941, .last = 69957, .style = 7, .non_base = false },
    .{ .first = 69958, .last = 69958, .style = 7, .non_base = true },
    .{ .first = 69959, .last = 69967, .style = 7, .non_base = false },
    .{ .first = 71264, .last = 71295, .style = 67, .non_base = false },
    .{ .first = 93760, .last = 93855, .style = 66, .non_base = false },
    .{ .first = 110592, .last = 110895, .style = 90, .non_base = false },
    .{ .first = 119552, .last = 119647, .style = 90, .non_base = false },
    .{ .first = 119808, .last = 120831, .style = 61, .non_base = false },
    .{ .first = 122880, .last = 122927, .style = 29, .non_base = true },
    .{ .first = 123136, .last = 123215, .style = 45, .non_base = false },
    .{ .first = 125184, .last = 125258, .style = 0, .non_base = true },
    .{ .first = 125259, .last = 125279, .style = 0, .non_base = false },
    .{ .first = 126464, .last = 126719, .style = 1, .non_base = false },
    .{ .first = 131072, .last = 173791, .style = 90, .non_base = false },
    .{ .first = 173824, .last = 191471, .style = 90, .non_base = false },
    .{ .first = 194560, .last = 195103, .style = 90, .non_base = false },
};

pub const script_index = struct {
    pub const adlm: usize = 0;
    pub const arab: usize = 1;
    pub const armn: usize = 2;
    pub const avst: usize = 3;
    pub const bamu: usize = 4;
    pub const beng: usize = 5;
    pub const buhd: usize = 6;
    pub const cakm: usize = 7;
    pub const cans: usize = 8;
    pub const cari: usize = 9;
    pub const cher: usize = 10;
    pub const copt: usize = 11;
    pub const cprt: usize = 12;
    pub const cyrl: usize = 13;
    pub const deva: usize = 14;
    pub const dsrt: usize = 15;
    pub const ethi: usize = 16;
    pub const geor: usize = 17;
    pub const geok: usize = 18;
    pub const glag: usize = 19;
    pub const goth: usize = 20;
    pub const grek: usize = 21;
    pub const gujr: usize = 22;
    pub const guru: usize = 23;
    pub const hebr: usize = 24;
    pub const hmnp: usize = 25;
    pub const kali: usize = 26;
    pub const khmr: usize = 27;
    pub const khms: usize = 28;
    pub const knda: usize = 29;
    pub const laoo: usize = 30;
    pub const latn: usize = 31;
    pub const latb: usize = 32;
    pub const latp: usize = 33;
    pub const lisu: usize = 34;
    pub const mlym: usize = 35;
    pub const medf: usize = 36;
    pub const mong: usize = 37;
    pub const mymr: usize = 38;
    pub const nkoo: usize = 39;
    pub const none: usize = 40;
    pub const olck: usize = 41;
    pub const orkh: usize = 42;
    pub const osge: usize = 43;
    pub const osma: usize = 44;
    pub const rohg: usize = 45;
    pub const saur: usize = 46;
    pub const shaw: usize = 47;
    pub const sinh: usize = 48;
    pub const sund: usize = 49;
    pub const taml: usize = 50;
    pub const tavt: usize = 51;
    pub const telu: usize = 52;
    pub const tfng: usize = 53;
    pub const thai: usize = 54;
    pub const vaii: usize = 55;
    pub const limb: usize = 56;
    pub const orya: usize = 57;
    pub const sylo: usize = 58;
    pub const tibt: usize = 59;
    pub const hani: usize = 60;
};

pub const style_index = struct {
    pub const adlm: usize = 0;
    pub const arab: usize = 1;
    pub const armn: usize = 2;
    pub const avst: usize = 3;
    pub const bamu: usize = 4;
    pub const beng: usize = 5;
    pub const buhd: usize = 6;
    pub const cakm: usize = 7;
    pub const cans: usize = 8;
    pub const cari: usize = 9;
    pub const cher: usize = 10;
    pub const copt: usize = 11;
    pub const cprt: usize = 12;
    pub const cyrl_c2cp: usize = 13;
    pub const cyrl_c2sc: usize = 14;
    pub const cyrl_ordn: usize = 15;
    pub const cyrl_pcap: usize = 16;
    pub const cyrl_ruby: usize = 17;
    pub const cyrl_sinf: usize = 18;
    pub const cyrl_smcp: usize = 19;
    pub const cyrl_subs: usize = 20;
    pub const cyrl_sups: usize = 21;
    pub const cyrl_titl: usize = 22;
    pub const cyrl: usize = 23;
    pub const deva: usize = 24;
    pub const dsrt: usize = 25;
    pub const ethi: usize = 26;
    pub const geor: usize = 27;
    pub const geok: usize = 28;
    pub const glag: usize = 29;
    pub const goth: usize = 30;
    pub const grek_c2cp: usize = 31;
    pub const grek_c2sc: usize = 32;
    pub const grek_ordn: usize = 33;
    pub const grek_pcap: usize = 34;
    pub const grek_ruby: usize = 35;
    pub const grek_sinf: usize = 36;
    pub const grek_smcp: usize = 37;
    pub const grek_subs: usize = 38;
    pub const grek_sups: usize = 39;
    pub const grek_titl: usize = 40;
    pub const grek: usize = 41;
    pub const gujr: usize = 42;
    pub const guru: usize = 43;
    pub const hebr: usize = 44;
    pub const hmnp: usize = 45;
    pub const kali: usize = 46;
    pub const khmr: usize = 47;
    pub const khms: usize = 48;
    pub const knda: usize = 49;
    pub const laoo: usize = 50;
    pub const latn_c2cp: usize = 51;
    pub const latn_c2sc: usize = 52;
    pub const latn_ordn: usize = 53;
    pub const latn_pcap: usize = 54;
    pub const latn_ruby: usize = 55;
    pub const latn_sinf: usize = 56;
    pub const latn_smcp: usize = 57;
    pub const latn_subs: usize = 58;
    pub const latn_sups: usize = 59;
    pub const latn_titl: usize = 60;
    pub const latn: usize = 61;
    pub const latb: usize = 62;
    pub const latp: usize = 63;
    pub const lisu: usize = 64;
    pub const mlym: usize = 65;
    pub const medf: usize = 66;
    pub const mong: usize = 67;
    pub const mymr: usize = 68;
    pub const nkoo: usize = 69;
    pub const none: usize = 70;
    pub const olck: usize = 71;
    pub const orkh: usize = 72;
    pub const osge: usize = 73;
    pub const osma: usize = 74;
    pub const rohg: usize = 75;
    pub const saur: usize = 76;
    pub const shaw: usize = 77;
    pub const sinh: usize = 78;
    pub const sund: usize = 79;
    pub const taml: usize = 80;
    pub const tavt: usize = 81;
    pub const telu: usize = 82;
    pub const tfng: usize = 83;
    pub const thai: usize = 84;
    pub const vaii: usize = 85;
    pub const limb: usize = 86;
    pub const orya: usize = 87;
    pub const sylo: usize = 88;
    pub const tibt: usize = 89;
    pub const hani: usize = 90;
};
