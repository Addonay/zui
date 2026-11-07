//! Downloaded images on disk, so a URL seen before shows at once on the next launch. GPUI has no
//! such cache: it fetches again on every launch.
//!
//! Entries never count as fresh. The caller shows the saved copy and still fetches, and replaces the
//! image if the bytes changed, so a URL whose content changes is wrong for one second at most.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = Io.Dir;

/// Entries past this are not worth keeping: they would push out many small ones.
pub const MAX_ENTRY_BYTES: usize = 32 * 1024 * 1024;
/// Oldest entries go when the directory passes this.
pub const MAX_TOTAL_BYTES: u64 = 256 * 1024 * 1024;

/// The per-user cache directory for this platform, or null if the environment names none.
pub fn default_dir(allocator: Allocator) error{OutOfMemory}!?[]u8 {
    const env = struct {
        fn get(name: [*:0]const u8) ?[]const u8 {
            const value = std.mem.span(std.c.getenv(name) orelse return null);
            return if (value.len == 0) null else value;
        }
    }.get;
    return switch (builtin.os.tag) {
        .windows => if (env("LOCALAPPDATA")) |base| try std.fs.path.join(allocator, &.{ base, "zui", "images" }) else null,
        .macos => if (env("HOME")) |home| try std.fs.path.join(allocator, &.{ home, "Library", "Caches", "zui", "images" }) else null,
        else => if (env("XDG_CACHE_HOME")) |base|
            try std.fs.path.join(allocator, &.{ base, "zui", "images" })
        else if (env("HOME")) |home|
            try std.fs.path.join(allocator, &.{ home, ".cache", "zui", "images" })
        else
            null,
    };
}

fn entry_name(buffer: *[16]u8, key: u64) []const u8 {
    return std.fmt.bufPrint(buffer, "{x:0>16}", .{key}) catch unreachable;
}

/// Replaces the entry for `key`. A failure only means the next launch fetches again, so it is not
/// reported. The rename keeps a reader, or a crash, from ever seeing half a file.
pub fn write(io: Io, directory: []const u8, key: u64, bytes: []const u8, max_total: u64) void {
    if (bytes.len > MAX_ENTRY_BYTES) return;
    Dir.cwd().createDirPath(io, directory) catch return;
    var dir = Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var name_buffer: [16]u8 = undefined;
    const name = entry_name(&name_buffer, key);
    var temp_buffer: [40]u8 = undefined;
    const temp = std.fmt.bufPrint(&temp_buffer, "{s}.{x}.tmp", .{ name, std.Thread.getCurrentId() }) catch return;
    dir.writeFile(io, .{ .sub_path = temp, .data = bytes }) catch return;
    Dir.rename(dir, temp, dir, name, io) catch {
        dir.deleteFile(io, temp) catch {};
        return;
    };
    evict(io, dir, max_total) catch {};
}

/// Deletes the least recently written entries until the directory is well under `max_total`.
fn evict(io: Io, dir: Dir, max_total: u64) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Entry = struct {
        name: []const u8,
        size: u64,
        mtime: i96,
        fn older(_: void, a: @This(), b: @This()) bool {
            return a.mtime < b.mtime;
        }
    };
    var entries: std.ArrayList(Entry) = .empty;
    var total: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        try entries.append(arena, .{ .name = try arena.dupe(u8, entry.name), .size = stat.size, .mtime = stat.mtime.nanoseconds });
        total += stat.size;
    }
    if (total <= max_total) return;
    std.mem.sort(Entry, entries.items, {}, Entry.older);
    // Down to three quarters, so that this does not run on every write once full.
    const target = max_total / 4 * 3;
    for (entries.items) |entry| {
        if (total <= target) break;
        dir.deleteFile(io, entry.name) catch continue;
        total -= entry.size;
    }
}

/// The path of the entry for `key`, for reading.
pub fn entry_path(allocator: Allocator, directory: []const u8, key: u64) error{OutOfMemory}![]u8 {
    var name_buffer: [16]u8 = undefined;
    return std.fs.path.join(allocator, &.{ directory, entry_name(&name_buffer, key) });
}

test "write replaces an entry and eviction keeps the total under the limit" {
    const testing = std.testing;
    var threaded = Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const directory = try std.fs.path.join(testing.allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer testing.allocator.free(directory);

    var bytes: [1000]u8 = @splat('x');
    write(io, directory, 1, &bytes, 10_000);
    write(io, directory, 1, bytes[0..500], 10_000);
    const stat = try tmp.dir.statFile(io, "0000000000000001", .{});
    try testing.expectEqual(@as(u64, 500), stat.size);

    for (2..30) |key| write(io, directory, key, &bytes, 10_000);
    var total: u64 = 0;
    var count: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(io)) |entry| {
        total += (try tmp.dir.statFile(io, entry.name, .{})).size;
        count += 1;
        try testing.expect(!std.mem.endsWith(u8, entry.name, ".tmp"));
    }
    try testing.expect(total <= 10_000);
    try testing.expect(count > 0);
    // The one written last survives.
    _ = try tmp.dir.statFile(io, "000000000000001d", .{});

    const too_big = try testing.allocator.alloc(u8, MAX_ENTRY_BYTES + 1);
    defer testing.allocator.free(too_big);
    write(io, directory, 99, too_big, 10_000);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "0000000000000063", .{}));
}
