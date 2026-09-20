//! Shared accessibility vocabulary and input convergence for Daybook.
const zui = @import("zui");

pub const key = struct {
    pub const composer: u64 = 0x110001;
    pub const add: u64 = 0x110002;
    pub const clear: u64 = 0x110003;
    pub const prev: u64 = 0x110004;
    pub const next: u64 = 0x110005;
    pub const filter_all: u64 = 0x110011;
    pub const filter_active: u64 = 0x110012;
    pub const filter_done: u64 = 0x110013;
    pub const empty: u64 = 0x110014;
    pub const list: u64 = 0x110020;
    pub const win_min: u64 = 0x110031;
    pub const win_max: u64 = 0x110032;
    pub const win_close: u64 = 0x110033;

    pub fn row(id: u32) u64 {
        return 0x120000 + id;
    }
    pub fn check(id: u32) u64 {
        return 0x130000 + id;
    }
    pub fn del(id: u32) u64 {
        return 0x140000 + id;
    }
};

pub const Target = struct {
    key: u64 = 0,
    listener: zui.Listener = undefined,
    space_pending: bool = false,
};

pub fn focusDispatch(raw: *anyopaque, event: zui.platform.Event, raw_win: *anyopaque) bool {
    const target: *Target = @ptrCast(@alignCast(raw));
    if (event != .key) return false;
    const key_event = event.key;
    if (key_event.modifiers.ctrl or key_event.modifiers.alt or key_event.modifiers.super) return false;
    if (key_event.key == .enter) {
        if (key_event.pressed and !key_event.repeat) target.listener.call(raw_win);
        return true;
    }
    if (key_event.key != .space) return false;
    if (key_event.pressed) {
        if (!key_event.repeat) target.space_pending = true;
    } else if (target.space_pending) {
        target.space_pending = false;
        target.listener.call(raw_win);
    }
    return true;
}

pub fn semanticActivate(raw: *anyopaque, request: zui.a11y.Request, raw_win: *anyopaque) void {
    const target: *const Target = @ptrCast(@alignCast(raw));
    if (request.action == .activate) target.listener.call(raw_win);
}
