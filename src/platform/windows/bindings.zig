//! Win32 bindings for the future Win32 backend.
//!
//! Hand-written `extern` declarations — no headers, no link (dead
//! declarations need no library). Covers the minimal bring-up surface:
//! class registration, window creation, the message loop, and the input
//! messages that map to normalized events (`WM_CHAR` is the text path,
//! like X11's `XLookupString`). Mirrors what gpui_windows builds on
//! (user32 message pump + DirectWrite/DirectX rendering later).

const std = @import("std");

pub const HWND = ?*anyopaque;
pub const HIMC = ?*anyopaque;
pub const HINSTANCE = ?*anyopaque;
pub const HICON = ?*anyopaque;
pub const HCURSOR = ?*anyopaque;
pub const HBRUSH = ?*anyopaque;
pub const HMENU = ?*anyopaque;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const ATOM = u16;
pub const BOOL = c_int;
pub const UINT = c_uint;
pub const DWORD = u32;
pub const WAIT_TIMEOUT: DWORD = 0x00000102;
pub const QS_ALLINPUT: DWORD = 0x04FF;
pub const MWMO_INPUTAVAILABLE: DWORD = 0x0004;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: ?*const anyopaque,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: HICON,
};

/// Windows LONG is always 32 bits wide, unlike C long (64-bit on Linux).
/// Fixed-size fields keep these structs ABI-correct on every host, so the
/// size pins below verify the real layout anywhere.
pub const POINT = extern struct { x: i32, y: i32 };

pub const MSG = extern struct {
    hwnd: HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
    lPrivate: DWORD,
};

// Window messages that map to normalized input events.
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_CLOSE: UINT = 0x0010;
pub const WM_KEYDOWN: UINT = 0x0100;
pub const WM_KEYUP: UINT = 0x0101;
pub const WM_CHAR: UINT = 0x0102;
pub const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
pub const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
pub const WM_IME_COMPOSITION: UINT = 0x010F;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_MOUSEMOVE: UINT = 0x0200;
/// Win10+ per-monitor DPI change (lparam: suggested rect; wparam HIWORD: DPI).
pub const WM_DPICHANGED: UINT = 0x02E0;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_RBUTTONDOWN: UINT = 0x0204;
pub const WM_RBUTTONUP: UINT = 0x0205;
pub const WM_MBUTTONDOWN: UINT = 0x0207;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSEWHEEL: UINT = 0x020A;
pub const WM_MOUSEHWHEEL: UINT = 0x020E;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_KILLFOCUS: UINT = 0x0008;
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_SETTINGCHANGE: UINT = 0x001A;
pub const WM_INPUTLANGCHANGE: UINT = 0x0051;
pub const WM_DISPLAYCHANGE: UINT = 0x007E;
pub const WM_PAINT: UINT = 0x000F;
pub const WM_SETCURSOR: UINT = 0x0020;
pub const WM_APP: UINT = 0x8000;
pub const WM_ZUI_WAKE: UINT = WM_APP + 1;
pub const WA_INACTIVE: UINT = 0;
pub const WA_ACTIVE: UINT = 1;
pub const WA_CLICKACTIVE: UINT = 2;

// Class styles, window styles, show commands (stable WinUser ABI).
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_HREDRAW: UINT = 0x0002;
pub const CS_OWNDC: UINT = 0x0020;
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const SW_SHOW: c_int = 5;
pub const PM_REMOVE: UINT = 0x0001;
pub const GWLP_USERDATA: c_int = -21;

// Mouse modifier bits in button-message wParam (stable ABI).
pub const MK_LBUTTON: WPARAM = 0x0001;
pub const MK_RBUTTON: WPARAM = 0x0002;
pub const MK_SHIFT: WPARAM = 0x0004;
pub const MK_CONTROL: WPARAM = 0x0008;
pub const MK_MBUTTON: WPARAM = 0x0010;
pub const WHEEL_DELTA: i16 = 120;

// Virtual keys beyond the input set above.
pub const VK_MENU: UINT = 0x12;

// Stock cursors (MAKEINTRESOURCE ids, stable ABI).
pub const IDC_ARROW: u16 = 32512;
pub const IDC_IBEAM: u16 = 32513;
pub const IDC_HAND: u16 = 32649;

// Clipboard + global memory (stable ABI).
pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;

// IMM32 composition flags and candidate-window ABI.
pub const GCS_COMPSTR: DWORD = 0x0008;
pub const GCS_CURSORPOS: DWORD = 0x0080;
pub const GCS_RESULTSTR: DWORD = 0x0800;
pub const CFS_CANDIDATEPOS: DWORD = 0x0040;
pub const CFS_EXCLUDE: DWORD = 0x0080;

// SetWindowPos flags (stable ABI).
pub const SWP_NOSIZE: UINT = 0x0001;
pub const SWP_NOMOVE: UINT = 0x0002;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SWP_NOACTIVATE: UINT = 0x0010;

// Window-long indices, frame styles, show commands (stable ABI).
pub const GWL_STYLE: c_int = -16;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_THICKFRAME: DWORD = 0x00040000;
pub const SW_MINIMIZE: c_int = 6;
pub const SW_MAXIMIZE: c_int = 3;
pub const SW_RESTORE: c_int = 9;

// Non-client messages and hit-test codes (stable ABI).
pub const WM_NCLBUTTONDOWN: UINT = 0x00A1;
pub const WM_NCHITTEST: UINT = 0x0084;
pub const HTCLIENT: LRESULT = 1;
pub const HTCAPTION: LRESULT = 2;
pub const HTLEFT: LRESULT = 10;
pub const HTRIGHT: LRESULT = 11;
pub const HTTOP: LRESULT = 12;
pub const HTTOPLEFT: LRESULT = 13;
pub const HTTOPRIGHT: LRESULT = 14;
pub const HTBOTTOM: LRESULT = 15;
pub const HTBOTTOMLEFT: LRESULT = 16;
pub const HTBOTTOMRIGHT: LRESULT = 17;

pub const MONITOR_DEFAULTTONEAREST: DWORD = 2;
pub const SPI_GETWORKAREA: UINT = 48;

// GDI raster op + DIB constants (stable ABI).
pub const SRCCOPY: DWORD = 0x00CC0020;
pub const BI_RGB: DWORD = 0;
pub const DIB_RGB_COLORS: UINT = 0;

pub const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

pub const CANDIDATEFORM = extern struct {
    dwIndex: DWORD,
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: DWORD,
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16,
    biBitCount: u16,
    biCompression: DWORD,
    biSizeImage: DWORD,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: DWORD,
    biClrImportant: DWORD,
};

pub const BITMAPINFO = extern struct {
    header: BITMAPINFOHEADER,
    colors: [1]DWORD,
};

pub extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) ATOM;
pub extern "user32" fn CreateWindowExW(
    ex_style: DWORD,
    class_name: [*:0]const u16,
    window_name: [*:0]const u16,
    style: DWORD,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: HWND,
    menu: HMENU,
    instance: HINSTANCE,
    param: ?*anyopaque,
) HWND;
pub extern "user32" fn DefWindowProcW(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) LRESULT;
pub extern "user32" fn ShowWindow(hwnd: HWND, cmd_show: c_int) BOOL;
pub extern "user32" fn PeekMessageW(msg: *MSG, hwnd: HWND, filter_min: UINT, filter_max: UINT, remove: UINT) BOOL;
pub extern "user32" fn TranslateMessage(msg: *const MSG) BOOL;
pub extern "user32" fn DispatchMessageW(msg: *const MSG) LRESULT;
pub extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) HINSTANCE;

/// user32 function table, resolved with dlopen at backend init.
pub const User32Api = struct {
    RegisterClassExW: *const fn (*const WNDCLASSEXW) callconv(.c) ATOM,
    CreateWindowExW: *const fn (DWORD, [*:0]const u16, [*:0]const u8, DWORD, c_int, c_int, c_int, c_int, HWND, HMENU, HINSTANCE, ?*anyopaque) callconv(.c) HWND,
    DefWindowProcW: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT,
    ShowWindow: *const fn (HWND, c_int) callconv(.c) BOOL,
    PeekMessageW: *const fn (*MSG, HWND, UINT, UINT, UINT) callconv(.c) BOOL,
    TranslateMessage: *const fn (*const MSG) callconv(.c) BOOL,
    DispatchMessageW: *const fn (*const MSG) callconv(.c) LRESULT,
    GetModuleHandleW: *const fn (?[*:0]const u16) callconv(.c) HINSTANCE,
    UnregisterClassW: *const fn ([*:0]const u16, HINSTANCE) callconv(.c) BOOL,
    GetWindowLongPtrW: *const fn (HWND, c_int) callconv(.c) isize,
    DestroyWindow: *const fn (HWND) callconv(.c) BOOL,
    AdjustWindowRect: *const fn (*RECT, DWORD, BOOL) callconv(.c) BOOL,
    SetWindowLongPtrW: *const fn (HWND, c_int, isize) callconv(.c) isize,
    GetDC: *const fn (HWND) callconv(.c) ?*anyopaque,
    ReleaseDC: *const fn (HWND, ?*anyopaque) callconv(.c) c_int,
    SetCapture: *const fn (HWND) callconv(.c) HWND,
    ReleaseCapture: *const fn () callconv(.c) BOOL,
    LoadCursorW: *const fn (HINSTANCE, ?*anyopaque) callconv(.c) HCURSOR,
    SetCursor: *const fn (HCURSOR) callconv(.c) HCURSOR,
    SetWindowTextW: *const fn (HWND, [*:0]const u16) callconv(.c) BOOL,
    OpenClipboard: *const fn (HWND) callconv(.c) BOOL,
    CloseClipboard: *const fn () callconv(.c) BOOL,
    EmptyClipboard: *const fn () callconv(.c) BOOL,
    SetClipboardData: *const fn (UINT, ?*anyopaque) callconv(.c) ?*anyopaque,
    GetClipboardData: *const fn (UINT) callconv(.c) ?*anyopaque,
    IsClipboardFormatAvailable: *const fn (UINT) callconv(.c) BOOL,
    SetWindowPos: *const fn (HWND, HWND, c_int, c_int, c_int, c_int, UINT) callconv(.c) BOOL,
    SendMessageW: *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) LRESULT,
    IsZoomed: *const fn (HWND) callconv(.c) BOOL,
    GetWindowRect: *const fn (HWND, *RECT) callconv(.c) BOOL,
    /// Optional on older user32 implementations; lets the pump sleep until
    /// either a message arrives or its timer deadline expires.
    MsgWaitForMultipleObjectsEx: ?*const fn (DWORD, ?*const ?*anyopaque, DWORD, DWORD, DWORD) callconv(.c) DWORD = null,
    PostMessageW: ?*const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) BOOL = null,
    /// Optional (Win10+): resolved separately, may stay null.
    GetDpiForWindow: ?*const fn (HWND) callconv(.c) c_uint = null,
    GetDpiForSystem: ?*const fn () callconv(.c) c_uint = null,
    GetCursorPos: ?*const fn (*POINT) callconv(.c) BOOL = null,
    ShowCursor: ?*const fn (BOOL) callconv(.c) c_int = null,

    pub fn load(lib: @import("../dl.zig").Library) ?User32Api {
        return .{
            .RegisterClassExW = lib.lookup(@FieldType(User32Api, "RegisterClassExW"), "RegisterClassExW") orelse return null,
            .CreateWindowExW = lib.lookup(@FieldType(User32Api, "CreateWindowExW"), "CreateWindowExW") orelse return null,
            .DefWindowProcW = lib.lookup(@FieldType(User32Api, "DefWindowProcW"), "DefWindowProcW") orelse return null,
            .ShowWindow = lib.lookup(@FieldType(User32Api, "ShowWindow"), "ShowWindow") orelse return null,
            .PeekMessageW = lib.lookup(@FieldType(User32Api, "PeekMessageW"), "PeekMessageW") orelse return null,
            .TranslateMessage = lib.lookup(@FieldType(User32Api, "TranslateMessage"), "TranslateMessage") orelse return null,
            .DispatchMessageW = lib.lookup(@FieldType(User32Api, "DispatchMessageW"), "DispatchMessageW") orelse return null,
            .GetModuleHandleW = lib.lookup(@FieldType(User32Api, "GetModuleHandleW"), "GetModuleHandleW") orelse return null,
            .UnregisterClassW = lib.lookup(@FieldType(User32Api, "UnregisterClassW"), "UnregisterClassW") orelse return null,
            .GetWindowLongPtrW = lib.lookup(@FieldType(User32Api, "GetWindowLongPtrW"), "GetWindowLongPtrW") orelse return null,
            .DestroyWindow = lib.lookup(@FieldType(User32Api, "DestroyWindow"), "DestroyWindow") orelse return null,
            .AdjustWindowRect = lib.lookup(@FieldType(User32Api, "AdjustWindowRect"), "AdjustWindowRect") orelse return null,
            .SetWindowLongPtrW = lib.lookup(@FieldType(User32Api, "SetWindowLongPtrW"), "SetWindowLongPtrW") orelse return null,
            .GetDC = lib.lookup(@FieldType(User32Api, "GetDC"), "GetDC") orelse return null,
            .ReleaseDC = lib.lookup(@FieldType(User32Api, "ReleaseDC"), "ReleaseDC") orelse return null,
            .SetCapture = lib.lookup(@FieldType(User32Api, "SetCapture"), "SetCapture") orelse return null,
            .ReleaseCapture = lib.lookup(@FieldType(User32Api, "ReleaseCapture"), "ReleaseCapture") orelse return null,
            .LoadCursorW = lib.lookup(@FieldType(User32Api, "LoadCursorW"), "LoadCursorW") orelse return null,
            .SetCursor = lib.lookup(@FieldType(User32Api, "SetCursor"), "SetCursor") orelse return null,
            .SetWindowTextW = lib.lookup(@FieldType(User32Api, "SetWindowTextW"), "SetWindowTextW") orelse return null,
            .OpenClipboard = lib.lookup(@FieldType(User32Api, "OpenClipboard"), "OpenClipboard") orelse return null,
            .CloseClipboard = lib.lookup(@FieldType(User32Api, "CloseClipboard"), "CloseClipboard") orelse return null,
            .EmptyClipboard = lib.lookup(@FieldType(User32Api, "EmptyClipboard"), "EmptyClipboard") orelse return null,
            .SetClipboardData = lib.lookup(@FieldType(User32Api, "SetClipboardData"), "SetClipboardData") orelse return null,
            .GetClipboardData = lib.lookup(@FieldType(User32Api, "GetClipboardData"), "GetClipboardData") orelse return null,
            .IsClipboardFormatAvailable = lib.lookup(@FieldType(User32Api, "IsClipboardFormatAvailable"), "IsClipboardFormatAvailable") orelse return null,
            .SetWindowPos = lib.lookup(@FieldType(User32Api, "SetWindowPos"), "SetWindowPos") orelse return null,
            .SendMessageW = lib.lookup(@FieldType(User32Api, "SendMessageW"), "SendMessageW") orelse return null,
            .IsZoomed = lib.lookup(@FieldType(User32Api, "IsZoomed"), "IsZoomed") orelse return null,
            .GetWindowRect = lib.lookup(@FieldType(User32Api, "GetWindowRect"), "GetWindowRect") orelse return null,
            .MsgWaitForMultipleObjectsEx = lib.lookup(*const fn (DWORD, ?*const ?*anyopaque, DWORD, DWORD, DWORD) callconv(.c) DWORD, "MsgWaitForMultipleObjectsEx"),
            .PostMessageW = lib.lookup(*const fn (HWND, UINT, WPARAM, LPARAM) callconv(.c) BOOL, "PostMessageW"),
            .GetDpiForSystem = lib.lookup(*const fn () callconv(.c) c_uint, "GetDpiForSystem"),
            .GetCursorPos = lib.lookup(*const fn (*POINT) callconv(.c) BOOL, "GetCursorPos"),
            .ShowCursor = lib.lookup(*const fn (BOOL) callconv(.c) c_int, "ShowCursor"),
        };
    }
};

pub const KernelApi = struct {
    GlobalAlloc: *const fn (UINT, usize) callconv(.c) ?*anyopaque,
    GlobalLock: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    GlobalUnlock: *const fn (?*anyopaque) callconv(.c) BOOL,
    GlobalFree: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    Sleep: *const fn (DWORD) callconv(.c) void,

    pub fn load(lib: @import("../dl.zig").Library) ?KernelApi {
        return .{
            .GlobalAlloc = lib.lookup(@FieldType(KernelApi, "GlobalAlloc"), "GlobalAlloc") orelse return null,
            .GlobalLock = lib.lookup(@FieldType(KernelApi, "GlobalLock"), "GlobalLock") orelse return null,
            .GlobalUnlock = lib.lookup(@FieldType(KernelApi, "GlobalUnlock"), "GlobalUnlock") orelse return null,
            .GlobalFree = lib.lookup(@FieldType(KernelApi, "GlobalFree"), "GlobalFree") orelse return null,
            .Sleep = lib.lookup(@FieldType(KernelApi, "Sleep"), "Sleep") orelse return null,
        };
    }
};

pub const GdiApi = struct {
    CreateDIBSection: *const fn (?*anyopaque, *const BITMAPINFO, UINT, *?*anyopaque, ?*anyopaque, DWORD) callconv(.c) ?*anyopaque,
    CreateCompatibleDC: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    SelectObject: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque,
    DeleteObject: *const fn (?*anyopaque) callconv(.c) BOOL,
    DeleteDC: *const fn (?*anyopaque) callconv(.c) BOOL,
    BitBlt: *const fn (?*anyopaque, c_int, c_int, c_int, c_int, ?*anyopaque, c_int, c_int, DWORD) callconv(.c) BOOL,

    pub fn load(lib: @import("../dl.zig").Library) ?GdiApi {
        return .{
            .CreateDIBSection = lib.lookup(@FieldType(GdiApi, "CreateDIBSection"), "CreateDIBSection") orelse return null,
            .CreateCompatibleDC = lib.lookup(@FieldType(GdiApi, "CreateCompatibleDC"), "CreateCompatibleDC") orelse return null,
            .SelectObject = lib.lookup(@FieldType(GdiApi, "SelectObject"), "SelectObject") orelse return null,
            .DeleteObject = lib.lookup(@FieldType(GdiApi, "DeleteObject"), "DeleteObject") orelse return null,
            .DeleteDC = lib.lookup(@FieldType(GdiApi, "DeleteDC"), "DeleteDC") orelse return null,
            .BitBlt = lib.lookup(@FieldType(GdiApi, "BitBlt"), "BitBlt") orelse return null,
        };
    }
};

/// IMM32 is optional: Windows text controls and keyboard layouts can still
/// deliver WM_CHAR when the DLL or a composition context is unavailable.
pub const ImmApi = struct {
    ImmGetContext: *const fn (HWND) callconv(.c) HIMC,
    ImmReleaseContext: *const fn (HWND, HIMC) callconv(.c) BOOL,
    ImmGetCompositionStringW: *const fn (HIMC, DWORD, ?*anyopaque, DWORD) callconv(.c) isize,
    ImmSetOpenStatus: *const fn (HIMC, BOOL) callconv(.c) BOOL,
    ImmSetCandidateWindow: *const fn (HIMC, *const CANDIDATEFORM) callconv(.c) BOOL,

    pub fn load(lib: @import("../dl.zig").Library) ?ImmApi {
        return .{
            .ImmGetContext = lib.lookup(@FieldType(ImmApi, "ImmGetContext"), "ImmGetContext") orelse return null,
            .ImmReleaseContext = lib.lookup(@FieldType(ImmApi, "ImmReleaseContext"), "ImmReleaseContext") orelse return null,
            .ImmGetCompositionStringW = lib.lookup(@FieldType(ImmApi, "ImmGetCompositionStringW"), "ImmGetCompositionStringW") orelse return null,
            .ImmSetOpenStatus = lib.lookup(@FieldType(ImmApi, "ImmSetOpenStatus"), "ImmSetOpenStatus") orelse return null,
            .ImmSetCandidateWindow = lib.lookup(@FieldType(ImmApi, "ImmSetCandidateWindow"), "ImmSetCandidateWindow") orelse return null,
        };
    }
};

test "win32 message constants match the platform SDK" {
    // Spot-check against WinUser.h values so a typo can't silently remap
    // input. Core rationale: these numbers ARE the ABI.
    const t = std.testing;
    try t.expectEqual(@as(UINT, 0x0102), WM_CHAR);
    try t.expectEqual(@as(UINT, 0x010F), WM_IME_COMPOSITION);
    try t.expectEqual(@as(UINT, 0x0201), WM_LBUTTONDOWN);
    try t.expectEqual(@as(UINT, 0x020A), WM_MOUSEWHEEL);
    try t.expectEqual(@as(UINT, 0x020E), WM_MOUSEHWHEEL);
    try t.expectEqual(@as(UINT, 0x0010), WM_CLOSE);
    try t.expectEqual(@as(UINT, 0x000F), WM_PAINT);
    try t.expectEqual(@as(UINT, 0x0020), WM_SETCURSOR);
    try t.expectEqual(@as(UINT, 0x0006), WM_ACTIVATE);
    try t.expectEqual(@as(UINT, 0x001A), WM_SETTINGCHANGE);
    try t.expectEqual(@as(UINT, 0x0051), WM_INPUTLANGCHANGE);
    try t.expectEqual(@as(UINT, 0x8001), WM_ZUI_WAKE);
    try t.expectEqual(@as(DWORD, 0x0800), GCS_RESULTSTR);
    try t.expectEqual(@as(DWORD, 0x04FF), QS_ALLINPUT);
    try t.expectEqual(@as(usize, @sizeOf(usize)), @sizeOf(WPARAM));
    try t.expectEqual(@as(usize, 40), @sizeOf(BITMAPINFOHEADER));
    try t.expectEqual(@as(DWORD, 0x00CC0020), SRCCOPY);
    try t.expectEqual(@as(UINT, 13), CF_UNICODETEXT);
    try t.expectEqual(@as(u16, 32512), IDC_ARROW);
    try t.expectEqual(@as(u16, 32649), IDC_HAND);
}
