//! Blocking synchronization for the multi-threaded dispatcher.
//!
//! Zig 0.17 moved `std.Thread.Mutex`/`std.Thread.Condition` behind `std.Io`:
//! the primitives now exist as `std.Io.Mutex`/`std.Io.Condition` and their
//! methods take an `Io` value that supplies the futex wait/wake implementation.
//! The public `RenderContext.init` API does not take an `Io`, so this module
//! centralizes the deliberate choice of the standard library's stateless
//! futex-backed instance, `std.Io.Threaded.global_single_threaded.io()`.
//!
//! `global_single_threaded` documents that it does not support concurrency or
//! cancelation; the dispatcher does not use `Io.async`/`Io.concurrent`, only
//! the futex primitives, which are real blocking waits on a non-single-threaded
//! build. `adapt`: when `RenderContext` grows an explicit `Io` parameter, this
//! wrapper is the single place to rewire.

const std = @import("std");

/// The Io instance used for blocking futex waits.
///
/// This is a pointer to the standard library's stateless global instance; the
/// dispatcher keeps no mutable global state of its own.
pub fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// A mutual-exclusion lock (uncancelable; the dispatcher has no cancelation).
pub const Mutex = struct {
    /// The underlying standard library mutex.
    inner: std.Io.Mutex = .init,

    /// Acquire the lock, blocking until available.
    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    /// Release the lock.
    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }

    /// Try to acquire the lock without blocking.
    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

/// A condition variable (uncancelable; the dispatcher has no cancelation).
pub const Condition = struct {
    /// The underlying standard library condition.
    inner: std.Io.Condition = .init,

    /// Atomically release `mutex` and block until woken.
    pub fn wait(self: *Condition, mutex: *Mutex) void {
        self.inner.waitUncancelable(io(), &mutex.inner);
    }

    /// Wake one waiter.
    pub fn signal(self: *Condition) void {
        self.inner.signal(io());
    }

    /// Wake every waiter.
    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(io());
    }
};
