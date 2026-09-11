//! Port of vello_common's shared-ownership usage (`alloc::sync::Arc`)
//! (Apache-2.0 OR MIT).
//!
//! Replaces Rust's `Arc<T>` for the cases vello_common uses it for
//! (`ImageSource::Pixmap(Arc<Pixmap>)`). One heap allocation holds the atomic
//! reference count next to the value; handles are plain two-pointer values.
//!
//! Ownership/allocator note: `Shared(T)` owns exactly one reference until
//! `release` is called. `create` allocates from the caller's allocator and
//! `release` must be given an allocator compatible with it (normally the same
//! one). Every value copy must be made through `clone`/`retain`; a plain Zig
//! struct copy does not adjust the count. When the last reference is released
//! and `T` declares `pub fn deinit(self: *T, allocator)` -- the repository's
//! standard owning-type contract -- that destructor runs before the control
//! block is freed, matching `Arc<T>`'s `Drop`.
//!
//! Thread-safety: `retain` and `release` are safe to call concurrently from
//! any thread and use atomic read-modify-write operations. Mutating the
//! pointed-to `T` is *not* synchronized, exactly like `Arc<T>` without
//! interior mutability: callers must ensure exclusive access while mutating
//! (or provide their own locking). `create` returns a fresh handle with a
//! count of one; a handle may be moved between threads freely.

const std = @import("std");

/// Whether `T` declares the repository's owning-type destructor
/// `pub fn deinit(self: *T, allocator)`.
fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, "deinit"),
        else => false,
    };
}

/// An atomically reference-counted heap allocation of `T`.
///
/// The returned type is a value handle: it can be stored and copied between
/// owning scopes, but each owned copy must come from `clone` (or `retain`).
pub fn Shared(comptime T: type) type {
    return struct {
        const Self = @This();

        /// One allocation: the count and the value travel together.
        const ControlBlock = struct {
            refcount: std.atomic.Value(usize),
            value: T,
        };

        /// Pointer to the shared value. Valid until the last handle is
        /// released.
        ptr: *T,

        /// The control block backing `ptr`.
        control: *ControlBlock,

        /// Create a new shared value with a reference count of one.
        ///
        /// Takes ownership of `value`: the caller must not `deinit` it
        /// separately, and must not use its prior location after this call.
        pub fn create(allocator: std.mem.Allocator, value: T) std.mem.Allocator.Error!Self {
            const control = try allocator.create(ControlBlock);
            control.* = .{
                .refcount = std.atomic.Value(usize).init(1),
                .value = value,
            };
            return .{ .ptr = &control.value, .control = control };
        }

        /// Add one reference. The caller owns the new reference.
        pub fn retain(self: Self) void {
            const previous = self.control.refcount.fetchAdd(1, .monotonic);
            std.debug.assert(previous > 0);
        }

        /// Drop one reference and free the value when it was the last one.
        ///
        /// If `T` declares `pub fn deinit(self: *T, allocator)` (the
        /// repository's owning-type contract), it is called before the control
        /// block is freed, matching `Arc<T>`'s `Drop`. The handle must not be
        /// used after `release`, and `release` must not be called more times
        /// than the handle was retained.
        pub fn release(self: Self, allocator: std.mem.Allocator) void {
            const previous = self.control.refcount.fetchSub(1, .acq_rel);
            std.debug.assert(previous > 0);
            if (previous == 1) {
                if (comptime hasDeinit(T)) {
                    self.ptr.deinit(allocator);
                }
                allocator.destroy(self.control);
            }
        }

        /// Return a pointer to the shared value.
        pub fn get(self: Self) *T {
            return self.ptr;
        }

        /// Retain and return a second owned handle (`Arc::clone`).
        pub fn clone(self: Self) Self {
            self.retain();
            return self;
        }

        /// The current reference count. Intended for tests and diagnostics.
        pub fn refCount(self: Self) usize {
            return self.control.refcount.load(.acquire);
        }

        /// Whether two handles refer to the same allocation (`Arc::ptr_eq`).
        pub fn ptrEq(a: Self, b: Self) bool {
            return a.ptr == b.ptr;
        }
    };
}

test "create, get, mutate and release" {
    const allocator = std.testing.allocator;
    const shared = try Shared(u32).create(allocator, 7);
    defer shared.release(allocator);

    try std.testing.expectEqual(@as(u32, 7), shared.get().*);
    try std.testing.expectEqual(@as(usize, 1), shared.refCount());

    shared.get().* = 9;
    try std.testing.expectEqual(@as(u32, 9), shared.get().*);
}

test "clone shares the value and last release frees it" {
    const allocator = std.testing.allocator;
    const first = try Shared(u32).create(allocator, 1);
    const second = first.clone();

    try std.testing.expect(first.ptrEq(second));
    try std.testing.expectEqual(@as(usize, 2), first.refCount());

    second.get().* = 42;
    first.release(allocator);
    try std.testing.expectEqual(@as(u32, 42), second.get().*);
    try std.testing.expectEqual(@as(usize, 1), second.refCount());

    // The testing allocator fails the test if this does not free.
    second.release(allocator);
}

test "large payload is stored out of line" {
    const allocator = std.testing.allocator;
    const Payload = struct { bytes: [64]u8 };
    const shared = try Shared(Payload).create(allocator, .{ .bytes = @splat(3) });
    defer shared.release(allocator);
    try std.testing.expectEqual(@as(u8, 3), shared.get().bytes[63]);
}

test "release runs T.deinit on the last reference" {
    const allocator = std.testing.allocator;
    const Tracked = struct {
        freed: *bool,
        pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
            self.freed.* = true;
        }
    };

    var freed = false;
    const shared = try Shared(Tracked).create(allocator, .{ .freed = &freed });
    const copy = shared.clone();

    shared.release(allocator);
    try std.testing.expect(!freed);

    copy.release(allocator);
    try std.testing.expect(freed);
}

fn hammer(shared: Shared(usize), iterations: usize) void {
    for (0..iterations) |_| {
        shared.retain();
        shared.release(std.testing.allocator);
    }
    shared.release(std.testing.allocator);
}

test "atomic refcount under contention" {
    const allocator = std.testing.allocator;
    const shared = try Shared(usize).create(allocator, 0);
    defer shared.release(allocator);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, hammer, .{ shared.clone(), 1_000 });
    }
    for (threads) |thread| thread.join();

    try std.testing.expectEqual(@as(usize, 1), shared.refCount());
}
