//! Application menus (GPUI `platform/app_menu.rs`): `Menu`, `MenuItem`, their owned copies, and
//! `MenuStore`, which keeps the copies a platform was given.
//!
//! Differences from GPUI:
//! - GPUI's `MenuItem::Action` and `MenuItem::Submenu` variants are `MenuItem.action_item` and
//!   `MenuItem.submenu_item` here, because a union field and the `MenuItem.action(..)` and
//!   `MenuItem.submenu(..)` constructors cannot share a name in Zig.
//! - Builder methods that clash with a field take a trailing `_` on the field: `Menu.items_` and
//!   `Menu.disabled_`. `Menu.items(..)` and `Menu.disabled(..)` are the builders, as in GPUI.
//! - `MenuItem.action` takes the action by value and boxes it with `smp_allocator`, because it
//!   has no `App` to allocate from. Zero-sized actions (every `Action(..)`) allocate nothing.
//!   Non-zero-sized copies live until the process exits; menus are set a few times at startup.

const std = @import("std");
const action_mod = @import("../action.zig");

const Allocator = std.mem.Allocator;
const AnyAction = action_mod.AnyAction;

fn oom() noreturn {
    @panic("out of memory");
}

/// The menus the operating system recognizes and fills in itself.
pub const SystemMenuType = enum {
    /// The 'Services' menu in the application menu on macOS.
    services,
};

/// Operating system actions the OS may give special behavior to (GPUI `OsAction`).
pub const OsAction = enum {
    cut,
    copy,
    paste,
    select_all,
    undo,
    redo,
};

/// A menu that the operating system fills in (GPUI `OsMenu` / `OwnedOsMenu`).
pub const OsMenu = struct {
    name: []const u8,
    menu_type: SystemMenuType,
};

/// One item of a menu that runs an action (GPUI `MenuItem::Action`).
pub const ActionItem = struct {
    name: []const u8,
    action: AnyAction,
    os_action: ?OsAction = null,
    checked: bool = false,
    disabled: bool = false,
};

/// The different kinds of items that can be in a menu (GPUI `MenuItem`).
pub const MenuItem = union(enum) {
    // Trailing underscore: `separator` is the GPUI constructor below, which a tag of the same name would clash with.
    separator_,
    submenu_item: Menu,
    system_menu: OsMenu,
    action_item: ActionItem,

    /// A separator between items (GPUI `MenuItem::separator`).
    pub fn separator() MenuItem {
        return .separator_;
    }
    /// The name `separator` had before it matched GPUI.
    pub const separator_item = separator;

    /// A submenu (GPUI `MenuItem::submenu`).
    pub fn submenu(menu: Menu) MenuItem {
        return .{ .submenu_item = menu };
    }

    /// A submenu populated by the OS (GPUI `MenuItem::os_submenu`).
    pub fn os_submenu(name: []const u8, menu_type: SystemMenuType) MenuItem {
        return .{ .system_menu = .{ .name = name, .menu_type = menu_type } };
    }

    /// An item that performs `act` (GPUI `MenuItem::action`).
    pub fn action(name: []const u8, act: anytype) MenuItem {
        return .{ .action_item = .{ .name = name, .action = action_mod.box_action(std.heap.smp_allocator, act) } };
    }

    /// An item that performs `act` and is tied to an OS action (GPUI `MenuItem::os_action`).
    pub fn os_action(name: []const u8, act: anytype, os: OsAction) MenuItem {
        return .{ .action_item = .{ .name = name, .action = action_mod.box_action(std.heap.smp_allocator, act), .os_action = os } };
    }

    /// Sets whether this item is checked. Only action items can be checked; others are unchanged.
    pub fn checked(self: MenuItem, value: bool) MenuItem {
        var m = self;
        switch (m) {
            .action_item => |*a| a.checked = value,
            else => {},
        }
        return m;
    }

    /// Whether this item is checked. Only action items can be; others return false.
    pub fn is_checked(self: MenuItem) bool {
        return switch (self) {
            .action_item => |a| a.checked,
            else => false,
        };
    }

    /// Sets whether this item is disabled. Applies to action items and submenus.
    pub fn disabled(self: MenuItem, value: bool) MenuItem {
        var m = self;
        switch (m) {
            .action_item => |*a| a.disabled = value,
            .submenu_item => |*s| s.disabled_ = value,
            else => {},
        }
        return m;
    }

    /// Whether this item is disabled. Only action items and submenus can be; others return false.
    pub fn is_disabled(self: MenuItem) bool {
        return switch (self) {
            .action_item => |a| a.disabled,
            .submenu_item => |s| s.disabled_,
            else => false,
        };
    }

    /// Copies the item's strings into `allocator` (GPUI `MenuItem::owned`). The action itself is
    /// shared, since it is immutable once boxed.
    pub fn owned(self: MenuItem, allocator: Allocator) error{OutOfMemory}!OwnedMenuItem {
        return switch (self) {
            .separator_ => .separator,
            .submenu_item => |s| .{ .submenu_item = try s.owned(allocator) },
            .system_menu => |s| .{ .system_menu = .{ .name = try allocator.dupe(u8, s.name), .menu_type = s.menu_type } },
            .action_item => |a| .{ .action_item = .{
                .name = try allocator.dupe(u8, a.name),
                .action = a.action,
                .os_action = a.os_action,
                .checked = a.checked,
                .disabled = a.disabled,
            } },
        };
    }
};

/// A menu of the application, either a main menu or a submenu (GPUI `Menu`).
pub const Menu = struct {
    name: []const u8,
    items_: []const MenuItem = &.{},
    disabled_: bool = false,

    /// Creates a menu with no items (GPUI `Menu::new`).
    pub fn new(name: []const u8) Menu {
        return .{ .name = name };
    }

    /// Sets the items of this menu. The slice must outlive the call to `App.set_menus`.
    pub fn items(self: Menu, list: []const MenuItem) Menu {
        var m = self;
        m.items_ = list;
        return m;
    }

    /// Sets whether this menu is disabled.
    pub fn disabled(self: Menu, value: bool) Menu {
        var m = self;
        m.disabled_ = value;
        return m;
    }

    /// Copies the menu and its items into `allocator` (GPUI `Menu::owned`).
    pub fn owned(self: Menu, allocator: Allocator) error{OutOfMemory}!OwnedMenu {
        const copied = try allocator.alloc(OwnedMenuItem, self.items_.len);
        for (self.items_, copied) |item, *slot| slot.* = try item.owned(allocator);
        return .{ .name = try allocator.dupe(u8, self.name), .items = copied, .disabled = self.disabled_ };
    }
};

/// An item of an `OwnedMenu`. Same variants as `MenuItem`, with owned strings.
pub const OwnedMenuItem = union(enum) {
    separator,
    submenu_item: OwnedMenu,
    system_menu: OsMenu,
    action_item: ActionItem,
};

/// A menu with its strings copied (GPUI `OwnedMenu`).
pub const OwnedMenu = struct {
    name: []const u8,
    items: []const OwnedMenuItem,
    disabled: bool,
};

/// Holds the owned menus a platform was last given (GPUI keeps them on the platform for
/// `get_menus`). Platforms without a menu bar store them and never draw them.
pub const MenuStore = struct {
    arena: ?std.heap.ArenaAllocator = null,
    menus: []const OwnedMenu = &.{},

    /// Replaces the stored menus with copies of `menus`, which may be discarded afterwards.
    pub fn set(self: *MenuStore, backing: Allocator, menus: []const Menu) void {
        var arena = std.heap.ArenaAllocator.init(backing);
        const copied = arena.allocator().alloc(OwnedMenu, menus.len) catch oom();
        for (menus, copied) |menu, *slot| slot.* = menu.owned(arena.allocator()) catch oom();
        if (self.arena) |*old| old.deinit();
        self.arena = arena;
        self.menus = copied;
    }

    /// The stored menus, or null if none were ever set (GPUI `get_menus`).
    pub fn get(self: *const MenuStore) ?[]const OwnedMenu {
        if (self.arena == null) return null;
        return self.menus;
    }

    pub fn deinit(self: *MenuStore) void {
        if (self.arena) |*a| a.deinit();
        self.arena = null;
        self.menus = &.{};
    }
};

test "menu: builders and owned copies" {
    const Toggle = action_mod.Action("test", "Toggle");
    const items = [_]MenuItem{
        MenuItem.separator_item(),
        MenuItem.action("Toggle", Toggle{}).checked(true),
        MenuItem.action("Off", action_mod.NoAction{}).disabled(true),
    };
    const menu = Menu.new("App").items(&items).disabled(true);
    try std.testing.expectEqualStrings("App", menu.name);
    try std.testing.expectEqual(@as(usize, 3), menu.items_.len);
    try std.testing.expect(menu.disabled_);
    try std.testing.expect(items[1].is_checked());
    try std.testing.expect(items[2].is_disabled());
    try std.testing.expect(!items[0].is_disabled());

    const submenu = MenuItem.submenu(Menu.new("Sub").disabled(true));
    try std.testing.expect(submenu.is_disabled());

    const owned = try menu.owned(std.testing.allocator);
    defer {
        for (owned.items) |item| switch (item) {
            .action_item => |a| std.testing.allocator.free(a.name),
            else => {},
        };
        std.testing.allocator.free(owned.items);
        std.testing.allocator.free(owned.name);
    }
    try std.testing.expectEqualStrings("App", owned.name);
    try std.testing.expect(owned.disabled);
    try std.testing.expect(owned.items[1].action_item.checked);
}

test "menu store: keeps copies until replaced" {
    var store: MenuStore = .{};
    defer store.deinit();
    try std.testing.expect(store.get() == null);
    store.set(std.testing.allocator, &.{Menu.new("App")});
    try std.testing.expectEqualStrings("App", store.get().?[0].name);
    store.set(std.testing.allocator, &.{});
    try std.testing.expectEqual(@as(usize, 0), store.get().?.len);
}
