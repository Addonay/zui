//! Port of kurbo 0.13.1 `common.rs` (Apache-2.0 OR MIT).
//!
//! Contains the shared numerical helpers: the `FloatFuncs`/`FloatExt` float
//! helpers, the quadratic/cubic/quartic solvers, the ITP root solver, the
//! Legendre-Gauss quadrature tables used by curve arclength, and the
//! polynomial root finder used by `CubicBez::nearest`.
//!
//! Omissions and adaptations:
//! - Upstream `FloatFuncs` is a trait only compiled without `std`; Zig's
//!   `std.math` and language builtins cover every entry, so it is a namespace
//!   of functions here (call them as `FloatFuncs.sin(x)`).
//! - `solve_itp` takes an explicit context type and function because Zig has no
//!   closures; `solve_itp_fallible` (upstream `pub(crate)`) is folded into the
//!   infallible solver. The `1u64 << nmax` scale factor is clamped to `nmax <=
//!   63` (Rust would panic in debug / wrap the shift in release).
//! - `CubicBez::nearest` uses `polycool`'s polynomial solver upstream; the
//!   needed quintic `roots_between` (with the specialized cubic/quadratic
//!   bottom of the recursion) is ported here as `rootsBetweenQuintic`.
//! - Gauss-Legendre tables not used by the files in this port are omitted.
//!
//! No allocation happens in this file.

const std = @import("std");

/// A fixed-capacity vector, mirroring `arrayvec::ArrayVec<T, N>`.
///
/// Used for root lists, so the solvers here never allocate.
pub fn SmallVec(comptime T: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        buf: [cap]T = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn push(self: *Self, value: T) void {
            std.debug.assert(self.len < cap);
            self.buf[self.len] = value;
            self.len += 1;
        }

        pub fn pop(self: *Self) ?T {
            if (self.len == 0) return null;
            self.len -= 1;
            return self.buf[self.len];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        pub fn slice(self: *const Self) []const T {
            return self.buf[0..self.len];
        }

        pub fn sliceMut(self: *Self) []T {
            return self.buf[0..self.len];
        }

        pub fn get(self: *const Self, index: usize) T {
            std.debug.assert(index < self.len);
            return self.buf[index];
        }

        pub fn swap(self: *Self, a: usize, b: usize) void {
            std.mem.swap(T, &self.buf[a], &self.buf[b]);
        }
    };
}

pub const QuadraticRoots = SmallVec(f64, 2);
pub const CubicRoots = SmallVec(f64, 3);
pub const QuarticRoots = SmallVec(f64, 4);
pub const QuinticRoots = SmallVec(f64, 5);

/// The nearest position on a curve to some point.
///
/// Upstream `param_curve::Nearest`; lives here because this port has no
/// separate `param_curve.zig`.
pub const Nearest = struct {
    /// The square of the distance from the nearest position on the curve to
    /// the given point.
    distance_sq: f64,
    /// The position on the curve of the nearest point, as a parameter.
    t: f64,
};

/// Upstream `DEFAULT_ACCURACY` from `param_curve.rs`.
pub const DEFAULT_ACCURACY: f64 = 1e-6;

/// Upstream `MAX_EXTREMA` from `param_curve.rs`.
pub const MAX_EXTREMA: usize = 4;

/// Counterpart of kurbo's `common::FloatFuncs`.
///
/// Upstream this trait exists only for `no_std` + `libm`; Zig's builtins and
/// `std.math` provide the same operations, so these are thin delegates. The
/// special-cased `signum` and `rem_euclid` match the upstream implementations
/// exactly.
pub const FloatFuncs = struct {
    pub inline fn abs(x: f64) f64 {
        return @abs(x);
    }

    pub inline fn acos(x: f64) f64 {
        return std.math.acos(x);
    }

    pub inline fn atan2(y: f64, x: f64) f64 {
        return std.math.atan2(y, x);
    }

    pub inline fn cbrt(x: f64) f64 {
        return std.math.cbrt(x);
    }

    pub inline fn ceil(x: f64) f64 {
        return @ceil(x);
    }

    pub inline fn cos(x: f64) f64 {
        return @cos(x);
    }

    pub inline fn copysign(magnitude: f64, sign: f64) f64 {
        return std.math.copysign(magnitude, sign);
    }

    pub inline fn floor(x: f64) f64 {
        return @floor(x);
    }

    pub inline fn hypot(x: f64, y: f64) f64 {
        return std.math.hypot(x, y);
    }

    pub inline fn ln(x: f64) f64 {
        return @log(x);
    }

    pub inline fn log2(x: f64) f64 {
        return std.math.log2(x);
    }

    pub inline fn mulAdd(x: f64, a: f64, b: f64) f64 {
        return @mulAdd(f64, x, a, b);
    }

    /// Integer power using exponentiation by squaring, matching the LLVM
    /// `powi` expansion Rust compiles to (`powi(4) == (x*x)*(x*x)`, etc.).
    /// `std.math.pow` computes `exp(n*log(x))` and differs by an ULP near
    /// subdivision thresholds.
    pub inline fn powi(x: f64, n: i32) f64 {
        if (n == 0) return 1.0;
        var exponent: u32 = if (n < 0) @intCast(-@as(i64, n)) else @intCast(n);
        var base = x;
        var result: f64 = 1.0;
        while (exponent != 0) {
            if (exponent & 1 != 0) result *= base;
            exponent >>= 1;
            if (exponent != 0) base *= base;
        }
        return if (n < 0) 1.0 / result else result;
    }

    pub inline fn powf(x: f64, y: f64) f64 {
        return std.math.pow(f64, x, y);
    }

    pub inline fn round(x: f64) f64 {
        return @round(x);
    }

    pub inline fn sin(x: f64) f64 {
        return @sin(x);
    }

    /// Returns `(sin(x), cos(x))`, matching the upstream tuple order.
    pub inline fn sinCos(x: f64) struct { f64, f64 } {
        return .{ @sin(x), @cos(x) };
    }

    pub inline fn sqrt(x: f64) f64 {
        return @sqrt(x);
    }

    pub inline fn tan(x: f64) f64 {
        return @tan(x);
    }

    pub inline fn trunc(x: f64) f64 {
        return @trunc(x);
    }

    /// libm has no `signum`, so upstream special-cases it; so do we.
    pub inline fn signum(x: f64) f64 {
        if (std.math.isNan(x)) {
            return std.math.nan(f64);
        }
        return std.math.copysign(@as(f64, 1.0), x);
    }

    /// libm has no `rem_euclid`, so upstream special-cases it; so do we.
    pub inline fn remEuclid(x: f64, rhs: f64) f64 {
        const r = @rem(x, rhs);
        if (r < 0.0) {
            return r + @abs(rhs);
        }
        return r;
    }
};

/// Counterpart of upstream `FloatExt::expand` for `f64`.
pub inline fn expand(x: f64) f64 {
    return std.math.copysign(@ceil(@abs(x)), x);
}

/// 1.0 / x, the Zig spelling of Rust's `f64::recip`.
inline fn recip(x: f64) f64 {
    return 1.0 / x;
}

fn isFinite(x: f64) bool {
    return std.math.isFinite(x);
}

fn isNan(x: f64) bool {
    return std.math.isNan(x);
}

/// Find real roots of cubic equation.
///
/// The implementation is not (yet) fully robust, but it does handle the case
/// where `c3` is zero (in that case, solving the quadratic equation).
///
/// Return values of x for which c0 + c1 x + c2 x² + c3 x³ = 0.
pub fn solveCubic(c0: f64, c1: f64, c2: f64, c3: f64) CubicRoots {
    var result = CubicRoots{};
    const c3_recip = recip(c3);
    const ONETHIRD: f64 = 1.0 / 3.0;
    const scaled_c2 = c2 * (ONETHIRD * c3_recip);
    const scaled_c1 = c1 * (ONETHIRD * c3_recip);
    const scaled_c0 = c0 * c3_recip;
    if (!(isFinite(scaled_c0) and isFinite(scaled_c1) and isFinite(scaled_c2))) {
        // cubic coefficient is zero or nearly so.
        const quad = solveQuadratic(c0, c1, c2);
        for (quad.slice()) |v| result.push(v);
        return result;
    }
    const c0s = scaled_c0;
    const c1s = scaled_c1;
    const c2s = scaled_c2;
    // (d0, d1, d2) is called "Delta" in article
    const d0 = @mulAdd(f64, -c2s, c2s, c1s);
    const d1 = @mulAdd(f64, -c1s, c2s, c0s);
    const d2 = c2s * c0s - c1s * c1s;
    // d is called "Discriminant"
    const d = 4.0 * d0 * d2 - d1 * d1;
    // de is called "Depressed.x", Depressed.y = d0
    const de = @mulAdd(f64, -2.0 * c2s, d0, d1);
    if (d < 0.0) {
        const sq = @sqrt(-0.25 * d);
        const r = -0.5 * de;
        const t1 = std.math.cbrt(r + sq) + std.math.cbrt(r - sq);
        result.push(t1 - c2s);
    } else if (d == 0.0) {
        const t1 = std.math.copysign(@sqrt(-d0), de);
        result.push(t1 - c2s);
        result.push(-2.0 * t1 - c2s);
    } else {
        const th = std.math.atan2(@sqrt(d), -de) * ONETHIRD;
        const sc = FloatFuncs.sinCos(th);
        const th_sin = sc[0];
        const th_cos = sc[1];
        const r0 = th_cos;
        const ss3 = th_sin * @sqrt(3.0);
        const r1 = 0.5 * (-th_cos + ss3);
        const r2 = 0.5 * (-th_cos - ss3);
        const t = 2.0 * @sqrt(-d0);
        result.push(@mulAdd(f64, t, r0, -c2s));
        result.push(@mulAdd(f64, t, r1, -c2s));
        result.push(@mulAdd(f64, t, r2, -c2s));
    }
    return result;
}

/// Find real roots of quadratic equation.
///
/// Return values of x for which c0 + c1 x + c2 x² = 0.
///
/// This function tries to be quite numerically robust. If the equation
/// is nearly linear, it will return the root ignoring the quadratic term;
/// the other root might be out of representable range. In the degenerate
/// case where all coefficients are zero, so that all values of x satisfy
/// the equation, a single `0.0` is returned.
pub fn solveQuadratic(c0: f64, c1: f64, c2: f64) QuadraticRoots {
    var result = QuadraticRoots{};
    const sc0 = c0 * recip(c2);
    const sc1 = c1 * recip(c2);
    if (!isFinite(sc0) or !isFinite(sc1)) {
        // c2 is zero or very small, treat as linear eqn
        const root = -c0 / c1;
        if (isFinite(root)) {
            result.push(root);
        } else if (c0 == 0.0 and c1 == 0.0) {
            // Degenerate case
            result.push(0.0);
        }
        return result;
    }
    const arg = sc1 * sc1 - 4.0 * sc0;
    const root1: f64 = blk: {
        if (!isFinite(arg)) {
            // Likely, calculation of sc1 * sc1 overflowed. Find one root
            // using sc1 x + x² = 0, other root as sc0 / root1.
            break :blk -sc1;
        }
        if (arg < 0.0) {
            return result;
        } else if (arg == 0.0) {
            result.push(-0.5 * sc1);
            return result;
        }
        // See https://math.stackexchange.com/questions/866331
        break :blk -0.5 * (sc1 + std.math.copysign(@sqrt(arg), sc1));
    };
    const root2 = sc0 / root1;
    if (isFinite(root2)) {
        // Sort just to be friendly and make results deterministic.
        if (root2 > root1) {
            result.push(root1);
            result.push(root2);
        } else {
            result.push(root2);
            result.push(root1);
        }
    } else {
        result.push(root1);
    }
    return result;
}

/// Compute epsilon relative to coefficient.
///
/// A helper function from the Orellana and De Michele paper.
fn epsRel(raw: f64, a: f64) f64 {
    if (a == 0.0) {
        return @abs(raw);
    }
    return @abs((raw - a) / a);
}

/// Find real roots of a quartic equation.
///
/// This is a fairly literal implementation of the method described in:
/// Algorithm 1010: Boosting Efficiency in Solving Quartic Equations with
/// No Compromise in Accuracy, Orellana and De Michele, ACM
/// Transactions on Mathematical Software, Vol. 46, No. 2, May 2020.
pub fn solveQuartic(c0: f64, c1: f64, c2: f64, c3: f64, c4: f64) QuarticRoots {
    if (c4 == 0.0) {
        var result = QuarticRoots{};
        const roots = solveCubic(c0, c1, c2, c3);
        for (roots.slice()) |v| result.push(v);
        return result;
    }
    if (c0 == 0.0) {
        // Note: appends 0 root at end, doesn't sort. We might want to do that.
        var result = QuarticRoots{};
        const roots = solveCubic(c1, c2, c3, c4);
        for (roots.slice()) |v| result.push(v);
        result.push(0.0);
        return result;
    }
    const a = c3 / c4;
    const b = c2 / c4;
    const c = c1 / c4;
    const d = c0 / c4;
    if (solveQuarticInner(a, b, c, d, false)) |result| {
        return result;
    }
    // Do polynomial rescaling
    const K_Q: f64 = 7.16e76;
    for ([_]bool{ false, true }) |rescale| {
        if (solveQuarticInner(
            a / K_Q,
            b / FloatFuncs.powi(K_Q, 2),
            c / FloatFuncs.powi(K_Q, 3),
            d / FloatFuncs.powi(K_Q, 4),
            rescale,
        )) |inner| {
            var result = QuarticRoots{};
            for (inner.slice()) |x| result.push(x * K_Q);
            return result;
        }
    }
    // Overflow happened, just return no roots.
    return QuarticRoots{};
}

const QuadPair = struct { a: f64, b: f64 };
const QuadFactorResult = SmallVec(QuadPair, 2);

fn solveQuarticInner(a: f64, b: f64, c: f64, d: f64, rescale: bool) ?QuarticRoots {
    const quadratics = factorQuarticInner(a, b, c, d, rescale) orelse return null;
    var result = QuarticRoots{};
    for (quadratics.slice()) |q| {
        const roots = solveQuadratic(q.b, q.a, 1.0);
        for (roots.slice()) |r| result.push(r);
    }
    return result;
}

/// Factor a quartic into two quadratics.
///
/// Attempt to factor a quartic equation into two quadratic equations. Returns
/// `null` either if there is overflow (in which case rescaling might succeed)
/// or the factorization would result in complex coefficients.
fn calcEpsQ(a1: f64, b1: f64, a2: f64, b2: f64, aa: f64, bb: f64, cc: f64) f64 {
    const eps_a = epsRel(a1 + a2, aa);
    const eps_b = epsRel(b1 + a1 * a2 + b2, bb);
    const eps_c = epsRel(b1 * a2 + a1 * b2, cc);
    return eps_a + eps_b + eps_c;
}

fn calcEpsT(a1: f64, b1: f64, a2: f64, b2: f64, aa: f64, bb: f64, cc: f64, dd: f64) f64 {
    return calcEpsQ(a1, b1, a2, b2, aa, bb, cc) + epsRel(b1 * b2, dd);
}

pub fn factorQuarticInner(a: f64, b: f64, c: f64, d: f64, rescale: bool) ?QuadFactorResult {
    const disc = 9.0 * a * a - 24.0 * b;
    const s = if (disc >= 0.0)
        -2.0 * b / (3.0 * a + std.math.copysign(@sqrt(disc), a))
    else
        -0.25 * a;
    const a_prime = a + 4.0 * s;
    const b_prime = b + 3.0 * s * (a + 2.0 * s);
    const c_prime = c + s * (2.0 * b + s * (3.0 * a + 4.0 * s));
    const d_prime = d + s * (c + s * (b + s * (a + s)));
    var g_prime: f64 = undefined;
    var h_prime: f64 = undefined;
    const K_C: f64 = 3.49e102;
    if (rescale) {
        const a_prime_s = a_prime / K_C;
        const b_prime_s = b_prime / K_C;
        const c_prime_s = c_prime / K_C;
        const d_prime_s = d_prime / K_C;
        g_prime = a_prime_s * c_prime_s - (4.0 / K_C) * d_prime_s -
            (1.0 / 3.0) * FloatFuncs.powi(b_prime_s, 2);
        h_prime = (a_prime_s * c_prime_s + (8.0 / K_C) * d_prime_s -
            (2.0 / 9.0) * FloatFuncs.powi(b_prime_s, 2)) *
            (1.0 / 3.0) * b_prime_s -
            c_prime_s * (c_prime_s / K_C) -
            FloatFuncs.powi(a_prime_s, 2) * d_prime_s;
    } else {
        g_prime = a_prime * c_prime - 4.0 * d_prime -
            (1.0 / 3.0) * FloatFuncs.powi(b_prime, 2);
        h_prime = (a_prime * c_prime + 8.0 * d_prime -
            (2.0 / 9.0) * FloatFuncs.powi(b_prime, 2)) *
            (1.0 / 3.0) * b_prime -
            FloatFuncs.powi(c_prime, 2) -
            FloatFuncs.powi(a_prime, 2) * d_prime;
    }
    if (!(isFinite(g_prime) and isFinite(h_prime))) {
        return null;
    }
    const phi_raw = depressedCubicDominant(g_prime, h_prime);
    const phi = if (rescale) phi_raw * K_C else phi_raw;
    const l_1 = a * 0.5;
    const l_3 = (1.0 / 6.0) * b + 0.5 * phi;
    const delt_2 = c - a * l_3;
    const d_2_cand_1 = (2.0 / 3.0) * b - phi - l_1 * l_1;
    const l_2_cand_1 = 0.5 * delt_2 / d_2_cand_1;
    const l_2_cand_2 = 2.0 * (d - l_3 * l_3) / delt_2;
    const d_2_cand_2 = 0.5 * delt_2 / l_2_cand_2;
    const d_2_cand_3 = d_2_cand_1;
    const l_2_cand_3 = l_2_cand_2;
    var d_2_best: f64 = 0.0;
    var l_2_best: f64 = 0.0;
    var eps_l_best: f64 = 0.0;
    const cands = [3][2]f64{
        .{ d_2_cand_1, l_2_cand_1 },
        .{ d_2_cand_2, l_2_cand_2 },
        .{ d_2_cand_3, l_2_cand_3 },
    };
    for (cands, 0..) |cand, i| {
        const d_2 = cand[0];
        const l_2 = cand[1];
        const eps_0 = epsRel(d_2 + l_1 * l_1 + 2.0 * l_3, b);
        const eps_1 = epsRel(2.0 * (d_2 * l_2 + l_1 * l_3), c);
        const eps_2 = epsRel(d_2 * l_2 * l_2 + l_3 * l_3, d);
        const eps_l = eps_0 + eps_1 + eps_2;
        if (i == 0 or eps_l < eps_l_best) {
            d_2_best = d_2;
            l_2_best = l_2;
            eps_l_best = eps_l;
        }
    }
    const d_2 = d_2_best;
    const l_2 = l_2_best;
    var alpha_1: f64 = undefined;
    var beta_1: f64 = undefined;
    var alpha_2: f64 = undefined;
    var beta_2: f64 = undefined;
    if (d_2 < 0.0) {
        const sq = @sqrt(-d_2);
        alpha_1 = l_1 + sq;
        beta_1 = l_3 + sq * l_2;
        alpha_2 = l_1 - sq;
        beta_2 = l_3 - sq * l_2;
        if (@abs(beta_2) < @abs(beta_1)) {
            beta_2 = d / beta_1;
        } else if (@abs(beta_2) > @abs(beta_1)) {
            beta_1 = d / beta_2;
        }
        if (@abs(alpha_1) != @abs(alpha_2)) {
            var cand_a1: [3]f64 = undefined;
            var cand_a2: [3]f64 = undefined;
            if (@abs(alpha_1) < @abs(alpha_2)) {
                // Note: cand 3 is first because it is infallible, simplifying logic
                cand_a1 = .{ a - alpha_2, (c - beta_1 * alpha_2) / beta_2, (b - beta_2 - beta_1) / alpha_2 };
                cand_a2 = .{ alpha_2, alpha_2, alpha_2 };
            } else {
                cand_a1 = .{ alpha_1, alpha_1, alpha_1 };
                cand_a2 = .{ a - alpha_1, (c - alpha_1 * beta_2) / beta_1, (b - beta_2 - beta_1) / alpha_1 };
            }
            var eps_q_best: f64 = 0.0;
            for (cand_a1, cand_a2, 0..) |a1, a2, i| {
                if (isFinite(a1) and isFinite(a2)) {
                    const eps_q = calcEpsQ(a1, beta_1, a2, beta_2, a, b, c);
                    if (i == 0 or eps_q < eps_q_best) {
                        alpha_1 = a1;
                        alpha_2 = a2;
                        eps_q_best = eps_q;
                    }
                }
            }
        }
    } else if (d_2 == 0.0) {
        const d_3 = d - l_3 * l_3;
        alpha_1 = l_1;
        beta_1 = l_3 + @sqrt(-d_3);
        alpha_2 = l_1;
        beta_2 = l_3 - @sqrt(-d_3);
        if (@abs(beta_1) > @abs(beta_2)) {
            beta_2 = d / beta_1;
        } else if (@abs(beta_2) > @abs(beta_1)) {
            beta_1 = d / beta_2;
        }
        // TODO: handle case d_2 is very small?
    } else {
        // This case means no real roots; in the most general case we might want
        // to factor into quadratic equations with complex coefficients.
        return null;
    }
    // Newton-Raphson iteration on alpha/beta coeff's.
    var eps_t = calcEpsT(alpha_1, beta_1, alpha_2, beta_2, a, b, c, d);
    for (0..8) |_| {
        if (eps_t == 0.0) {
            break;
        }
        const f_0 = beta_1 * beta_2 - d;
        const f_1 = beta_1 * alpha_2 + alpha_1 * beta_2 - c;
        const f_2 = beta_1 + alpha_1 * alpha_2 + beta_2 - b;
        const f_3 = alpha_1 + alpha_2 - a;
        const c_1 = alpha_1 - alpha_2;
        const det_j = beta_1 * beta_1 -
            beta_1 * (alpha_2 * c_1 + 2.0 * beta_2) +
            beta_2 * (alpha_1 * c_1 + beta_2);
        if (det_j == 0.0) {
            break;
        }
        const inv = recip(det_j);
        const c_2 = beta_2 - beta_1;
        const c_3 = beta_1 * alpha_2 - alpha_1 * beta_2;
        const dz_0 = c_1 * f_0 + c_2 * f_1 + c_3 * f_2 - (beta_1 * c_2 + alpha_1 * c_3) * f_3;
        const dz_1 = (alpha_1 * c_1 + c_2) * f_0 -
            beta_1 * c_1 * f_1 -
            beta_1 * c_2 * f_2 -
            beta_1 * c_3 * f_3;
        const dz_2 = -c_1 * f_0 - c_2 * f_1 - c_3 * f_2 + (alpha_2 * c_3 + beta_2 * c_2) * f_3;
        const dz_3 = -(alpha_2 * c_1 + c_2) * f_0 +
            beta_2 * c_1 * f_1 +
            beta_2 * c_2 * f_2 +
            beta_2 * c_3 * f_3;
        const a1 = alpha_1 - inv * dz_0;
        const b1 = beta_1 - inv * dz_1;
        const a2 = alpha_2 - inv * dz_2;
        const b2 = beta_2 - inv * dz_3;
        const new_eps_t = calcEpsT(a1, b1, a2, b2, a, b, c, d);
        // We break if the new eps is equal, paper keeps going
        if (new_eps_t < eps_t) {
            alpha_1 = a1;
            beta_1 = b1;
            alpha_2 = a2;
            beta_2 = b2;
            eps_t = new_eps_t;
        } else {
            break;
        }
    }
    var result = QuadFactorResult{};
    result.push(.{ .a = alpha_1, .b = beta_1 });
    result.push(.{ .a = alpha_2, .b = beta_2 });
    return result;
}

/// Dominant root of depressed cubic x^3 + gx + h = 0.
///
/// Section 2.2 of Orellana and De Michele.
fn depressedCubicDominant(g: f64, h: f64) f64 {
    const q = (-1.0 / 3.0) * g;
    const r = 0.5 * h;
    var phi_0: f64 = undefined;
    const k: ?f64 = if (@abs(q) < 1e102 and @abs(r) < 1e154)
        null
    else if (@abs(q) < @abs(r))
        1.0 - q * FloatFuncs.powi(q / r, 2)
    else
        FloatFuncs.signum(q) * (FloatFuncs.powi(r / q, 2) / q - 1.0);
    if (k != null and r == 0.0) {
        if (g > 0.0) {
            phi_0 = 0.0;
        } else {
            phi_0 = @sqrt(-g);
        }
    } else if (if (k) |kk| kk < 0.0 else r * r < FloatFuncs.powi(q, 3)) {
        const t = if (k != null)
            r / q / @sqrt(q)
        else
            r / @sqrt(FloatFuncs.powi(q, 3));
        phi_0 = -2.0 * @sqrt(q) * std.math.copysign(
            @cos(std.math.acos(@abs(t)) * (1.0 / 3.0)),
            t,
        );
    } else {
        const a = if (k) |kk| blk: {
            if (@abs(q) < @abs(r)) {
                break :blk -r * (1.0 + @sqrt(kk));
            }
            break :blk -r - std.math.copysign(@sqrt(@abs(q)) * q * @sqrt(kk), r);
        } else -r - std.math.copysign(@sqrt(r * r - FloatFuncs.powi(q, 3)), r);
        const ac = std.math.cbrt(a);
        const b = if (ac == 0.0) 0.0 else q / ac;
        phi_0 = ac + b;
    }
    // Refine with Newton-Raphson iteration
    var x = phi_0;
    var f = (x * x + g) * x + h;
    const EPS_M: f64 = 2.22045e-16;
    if (@abs(f) < EPS_M * @max(FloatFuncs.powi(x, 3), @max(g * x, h))) {
        return x;
    }
    for (0..8) |_| {
        const delt_f = 3.0 * x * x + g;
        if (delt_f == 0.0) {
            break;
        }
        const new_x = x - f / delt_f;
        const new_f = (new_x * new_x + g) * new_x + h;
        if (new_f == 0.0) {
            return new_x;
        }
        if (@abs(new_f) >= @abs(f)) {
            break;
        }
        x = new_x;
        f = new_f;
    }
    return x;
}

/// Solve an arbitrary function for a zero-crossing.
///
/// This uses the [ITP method]; see `common.rs` for the full description.
/// `f` is a plain function taking the context pointer, matching the mutable
/// closure used upstream.
///
/// [ITP method]: https://en.wikipedia.org/wiki/ITP_Method
pub fn solveItp(
    comptime Ctx: type,
    comptime f: fn (ctx: *Ctx, x: f64) f64,
    ctx: *Ctx,
    a_in: f64,
    b_in: f64,
    epsilon: f64,
    n0: usize,
    k1: f64,
    ya_in: f64,
    yb_in: f64,
) f64 {
    var a = a_in;
    var b = b_in;
    var ya = ya_in;
    var yb = yb_in;
    const n1_2 = castToUsize(@max(@ceil(std.math.log2((b - a) / epsilon)) - 1.0, 0.0));
    const nmax = n0 + n1_2;
    var scaled_epsilon = epsilon * @as(f64, @floatFromInt(@as(u64, 1) << @intCast(@min(nmax, 63))));
    while (b - a > 2.0 * epsilon) {
        const x1_2 = 0.5 * (a + b);
        const r = scaled_epsilon - 0.5 * (b - a);
        const xf = (yb * a - ya * b) / (yb - ya);
        const sigma = x1_2 - xf;
        // This has k2 = 2 hardwired for efficiency.
        const delta = k1 * FloatFuncs.powi(b - a, 2);
        const xt = if (delta <= @abs(x1_2 - xf))
            xf + std.math.copysign(delta, sigma)
        else
            x1_2;
        const xitp = if (@abs(xt - x1_2) <= r)
            xt
        else
            x1_2 - std.math.copysign(r, sigma);
        const yitp = f(ctx, xitp);
        if (yitp > 0.0) {
            b = xitp;
            yb = yitp;
        } else if (yitp < 0.0) {
            a = xitp;
            ya = yitp;
        } else {
            return xitp;
        }
        scaled_epsilon *= 0.5;
    }
    return 0.5 * (a + b);
}

/// Rust `as usize` semantics for floats: truncate, saturate, NaN becomes 0.
pub fn castToUsize(x: f64) usize {
    if (isNan(x) or x <= 0.0) return 0;
    const max: f64 = @floatFromInt(std.math.maxInt(usize));
    if (x >= max) return std.math.maxInt(usize);
    return @intFromFloat(x);
}

/// Rust `(x.ceil() as usize).max(1)` semantics.
pub fn ceilToUsizeMin1(x: f64) usize {
    return @max(castToUsize(@ceil(x)), 1);
}

/// Default `ParamCurveArclen::inv_arclen`, shared by quadratics and cubics.
///
/// `subsegmentArclen(curve, t0, t1, accuracy)` must return
/// `curve.subsegment(t0, t1).arclen(accuracy)`. This is as robust as
/// bisection (ITP) and mirrors the upstream trait default exactly.
pub fn invArclen(
    comptime Curve: type,
    curve: Curve,
    arclen: f64,
    accuracy: f64,
    comptime subsegmentArclen: fn (Curve, f64, f64, f64) f64,
) f64 {
    if (arclen <= 0.0) {
        return 0.0;
    }
    const total_arclen = subsegmentArclen(curve, 0.0, 1.0, accuracy);
    if (arclen >= total_arclen) {
        return 1.0;
    }
    const Ctx = struct {
        curve: Curve,
        t_last: f64 = 0.0,
        arclen_last: f64 = 0.0,
        inner_accuracy: f64,
        target: f64,

        fn eval(ctx: *@This(), t: f64) f64 {
            const t_last = ctx.t_last;
            const arc = if (t > t_last)
                subsegmentArclen(ctx.curve, t_last, t, ctx.inner_accuracy)
            else
                subsegmentArclen(ctx.curve, t, t_last, ctx.inner_accuracy);
            const dir: f64 = if (t > t_last) 1.0 else -1.0;
            ctx.arclen_last += arc * dir;
            ctx.t_last = t;
            return ctx.arclen_last - ctx.target;
        }
    };
    const epsilon = accuracy / total_arclen;
    const n = 1.0 - @min(@ceil(std.math.log2(epsilon)), 0.0);
    var ctx = Ctx{
        .curve = curve,
        .inner_accuracy = accuracy / n,
        .target = arclen,
    };
    return solveItp(Ctx, Ctx.eval, &ctx, 0.0, 1.0, epsilon, 1, 0.2, -arclen, total_arclen - arclen);
}

// ------------------------------------------------------------------
// Polynomial root finding used by CubicBez::nearest.
//
// Port of the `polycool` 0.4.0 solver: `Poly::<6>::roots_between` with the
// specialized cubic and quadratic bottoms of the recursion.
// ------------------------------------------------------------------

fn differentSigns(x: f64, y: f64) bool {
    return (x < 0.0) != (y < 0.0);
}

/// Horner evaluation, matching `polycool::Poly::eval`.
fn evalPoly(coeffs: []const f64, x: f64) f64 {
    var acc: f64 = 0.0;
    var i = coeffs.len;
    while (i > 0) {
        i -= 1;
        acc = acc * x + coeffs[i];
    }
    return acc;
}

fn polyIsFinite(coeffs: []const f64) bool {
    for (coeffs) |c| {
        if (!isFinite(c)) return false;
    }
    return true;
}

/// Port of `polycool::yuksel::find_root`.
fn findRootYuksel(
    coeffs: []const f64,
    deriv_coeffs: []const f64,
    lower_in: f64,
    upper_in: f64,
    val_lower_in: f64,
    val_upper_in: f64,
    x_error: f64,
) f64 {
    var lower = lower_in;
    var upper = upper_in;
    const val_lower = val_lower_in;
    const val_upper = val_upper_in;
    if (!isFinite(val_lower) or !isFinite(val_upper)) {
        return std.math.nan(f64);
    }
    std.debug.assert(differentSigns(val_lower, val_upper));

    var x = lower + (upper - lower) / 2.0;
    var step = (upper - lower) / 2.0;

    if (@abs(step) <= x_error) {
        return x;
    }

    while (@abs(step) > x_error and isFinite(x)) {
        const deriv_x = evalPoly(deriv_coeffs, x);
        const val_x = evalPoly(coeffs, x);

        if (val_x == 0.0) {
            return x;
        }
        const root_in_first_half = differentSigns(val_lower, val_x);
        if (root_in_first_half) {
            upper = x;
        } else {
            lower = x;
        }

        step = -val_x / deriv_x;
        var new_x = x + step;

        if (new_x <= lower or new_x >= upper) {
            new_x = lower + (upper - lower) / 2.0;

            if (new_x == upper or new_x == lower) {
                return new_x;
            }
        }
        step = new_x - x;
        x = new_x;
    }
    return x;
}

/// Port of `polycool::Cubic::roots_between_with_buffer`; `out` must have
/// capacity 5 from the caller's perspective (the recursion's shared buffers).
fn rootsBetweenCubic(coeffs: [4]f64, lower: f64, upper: f64, x_error: f64, out: *QuinticRoots) void {
    if (firstRootCubic(coeffs, lower, upper, x_error)) |r| {
        out.push(r);
        const quad = deflateCubic(coeffs, r);
        if (positiveDiscriminantRoots(quad)) |p| {
            if (lower <= p[0] and p[0] <= upper) {
                out.push(p[0]);
            }
            if (lower <= p[1] and p[1] <= upper) {
                out.push(p[1]);
            }
            // `first_root` is supposed to return the smallest root in our
            // interval, but it's possible it doesn't because it misses a
            // double-root (or near-double-root).
            if (lower <= p[0] and p[0] < r) {
                partialSort(out);
            }
        }
    }
}

/// Port of `polycool::cubic::partial_sort` for our fixed buffer.
fn partialSort(buf: *QuinticRoots) void {
    if (buf.len > 1 and buf.buf[0] > buf.buf[1]) {
        buf.swap(0, 1);
        if (buf.len > 2 and buf.buf[1] > buf.buf[2]) {
            buf.swap(1, 2);
        }
    }
}

fn cubicDeriv(coeffs: [4]f64) [3]f64 {
    return .{ coeffs[1], 2.0 * coeffs[2], 3.0 * coeffs[3] };
}

/// Synthetic division by (x - root), matching `Poly::deflate`.
fn deflateCubic(coeffs: [4]f64, root: f64) [3]f64 {
    var out: [3]f64 = undefined;
    var acc: f64 = 0.0;
    var i: usize = 2;
    while (true) {
        acc = acc * root + coeffs[i + 1];
        out[i] = acc;
        if (i == 0) break;
        i -= 1;
    }
    return out;
}

fn positiveDiscriminantRoots(coeffs: [3]f64) ?[2]f64 {
    const c = coeffs[0];
    const b = coeffs[1];
    const a = coeffs[2];
    const disc = b * b - 4.0 * a * c;
    if (isFinite(disc)) {
        if (disc > 0.0) {
            const q = -0.5 * (b + std.math.copysign(@sqrt(disc), b));
            const r0 = q / a;
            const r1 = c / q;
            return .{ @min(r0, r1), @max(r0, r1) };
        }
        return null;
    }
    if (polyIsFinite(&coeffs)) {
        const scale = std.math.pow(f64, 2.0, -515.0);
        return positiveDiscriminantRoots(.{ coeffs[0] * scale, coeffs[1] * scale, coeffs[2] * scale });
    }
    return null;
}

fn cubicCriticalPoints(coeffs: [4]f64) ?[2]f64 {
    const a = 3.0 * coeffs[3];
    const b_2 = coeffs[2];
    const c = coeffs[1];
    const disc_4 = b_2 * b_2 - a * c;

    if (!isFinite(disc_4)) {
        const scale = std.math.pow(f64, 2.0, -515.0);
        return cubicCriticalPoints(.{
            coeffs[0] * scale,
            coeffs[1] * scale,
            coeffs[2] * scale,
            coeffs[3] * scale,
        });
    }
    if (disc_4 > 0.0) {
        const q = -(b_2 + std.math.copysign(@sqrt(disc_4), b_2));
        const r0 = q / a;
        const r1 = c / q;
        return .{ @min(r0, r1), @max(r0, r1) };
    }
    return null;
}

fn firstRootCubic(coeffs: [4]f64, lower: f64, upper: f64, x_error: f64) ?f64 {
    if (cubicCriticalPoints(coeffs)) |cp| {
        const possible_endpoints = [3]f64{ cp[0], cp[1], upper };
        var last = lower;
        var last_val = evalPoly(&coeffs, last);
        for (possible_endpoints) |x| {
            if (x > last and x <= upper) {
                const val = evalPoly(&coeffs, x);
                if (differentSigns(last_val, val)) {
                    return oneRootCubic(coeffs, last, x, last_val, val, x_error);
                }
                last = x;
                last_val = val;
            }
        }
        return null;
    }
    const lower_val = evalPoly(&coeffs, lower);
    const upper_val = evalPoly(&coeffs, upper);
    if (differentSigns(lower_val, upper_val)) {
        return oneRootCubic(coeffs, lower, upper, lower_val, upper_val, x_error);
    }
    return null;
}

fn oneRootCubic(
    coeffs: [4]f64,
    lower: f64,
    upper: f64,
    lower_val: f64,
    upper_val: f64,
    x_error: f64,
) f64 {
    const deriv = cubicDeriv(coeffs);
    if (!polyIsFinite(&deriv)) {
        return std.math.nan(f64);
    }
    return findRootYuksel(&coeffs, &deriv, lower, upper, lower_val, upper_val, x_error);
}

/// Generic recursive `roots_between` for degree >= 4, matching
/// `Poly::roots_between_with_buffer`. `out` and `scratch` are swapped between
/// recursion levels exactly like upstream.
fn rootsBetweenDerived(
    coeffs: []const f64,
    lower: f64,
    upper: f64,
    x_error: f64,
    out: *QuinticRoots,
    scratch: *QuinticRoots,
) void {
    const d = coeffs.len - 1;
    var deriv_buf: [5]f64 = undefined;
    for (0..d) |i| {
        deriv_buf[i] = @as(f64, @floatFromInt(i + 1)) * coeffs[i + 1];
    }
    const deriv = deriv_buf[0..d];
    if (!polyIsFinite(deriv)) {
        return;
    }
    if (coeffs.len == 5) {
        // Quartic level: the derivative is a cubic, solved directly by the
        // specialized port of `polycool::Cubic::roots_between_with_buffer`.
        rootsBetweenCubic(deriv[0..4].*, lower, upper, x_error, scratch);
    } else {
        rootsBetweenDerived(deriv, lower, upper, x_error, scratch, out);
    }
    scratch.push(upper);
    out.clear();
    var last = lower;
    var last_val = evalPoly(coeffs, last);

    // `scratch` now contains all the critical points (in increasing order)
    // and the upper endpoint of the interval.
    for (scratch.slice()) |x| {
        const val = evalPoly(coeffs, x);
        if (differentSigns(last_val, val)) {
            out.push(findRootYuksel(coeffs, deriv, last, x, last_val, val, x_error));
        }
        last = x;
        last_val = val;
    }
}

/// All roots of the quintic `c0 + c1 x + ... + c5 x^5` in `[lower, upper]`,
/// as found by `polycool::Poly::roots_between`. Matches
/// `CubicBez::nearest`'s call `Poly::new([c0..c5]).roots_between(0, 1, acc)`.
pub fn rootsBetweenQuintic(coeffs: [6]f64, lower: f64, upper: f64, x_error: f64) QuinticRoots {
    var out = QuinticRoots{};
    var scratch = QuinticRoots{};
    rootsBetweenDerived(&coeffs, lower, upper, x_error, &out, &scratch);
    return out;
}

/// Tables of Legendre-Gauss quadrature coefficients used by cubic arclength.
pub const GAUSS_LEGENDRE_COEFFS_8: []const [2]f64 = &.{
    .{ 0.3626837833783620, -0.1834346424956498 },
    .{ 0.3626837833783620, 0.1834346424956498 },
    .{ 0.3137066458778873, -0.5255324099163290 },
    .{ 0.3137066458778873, 0.5255324099163290 },
    .{ 0.2223810344533745, -0.7966664774136267 },
    .{ 0.2223810344533745, 0.7966664774136267 },
    .{ 0.1012285362903763, -0.9602898564975363 },
    .{ 0.1012285362903763, 0.9602898564975363 },
};

pub const GAUSS_LEGENDRE_COEFFS_8_HALF: []const [2]f64 = &.{
    .{ 0.3626837833783620, 0.1834346424956498 },
    .{ 0.3137066458778873, 0.5255324099163290 },
    .{ 0.2223810344533745, 0.7966664774136267 },
    .{ 0.1012285362903763, 0.9602898564975363 },
};

pub const GAUSS_LEGENDRE_COEFFS_16_HALF: []const [2]f64 = &.{
    .{ 0.1894506104550685, 0.0950125098376374 },
    .{ 0.1826034150449236, 0.2816035507792589 },
    .{ 0.1691565193950025, 0.4580167776572274 },
    .{ 0.1495959888165767, 0.6178762444026438 },
    .{ 0.1246289712555339, 0.7554044083550030 },
    .{ 0.0951585116824928, 0.8656312023878318 },
    .{ 0.0622535239386479, 0.9445750230732326 },
    .{ 0.0271524594117541, 0.9894009349916499 },
};

pub const GAUSS_LEGENDRE_COEFFS_24_HALF: []const [2]f64 = &.{
    .{ 0.1279381953467522, 0.0640568928626056 },
    .{ 0.1258374563468283, 0.1911188674736163 },
    .{ 0.1216704729278034, 0.3150426796961634 },
    .{ 0.1155056680537256, 0.4337935076260451 },
    .{ 0.1074442701159656, 0.5454214713888396 },
    .{ 0.0976186521041139, 0.6480936519369755 },
    .{ 0.0861901615319533, 0.7401241915785544 },
    .{ 0.0733464814110803, 0.8200019859739029 },
    .{ 0.0592985849154368, 0.8864155270044011 },
    .{ 0.0442774388174198, 0.9382745520027328 },
    .{ 0.0285313886289337, 0.9747285559713095 },
    .{ 0.0123412297999872, 0.9951872199970213 },
};

// ------------------------------------------------------------------
// Tests (ported from common.rs where they exist).
// ------------------------------------------------------------------

test "test_solve_cubic" {
    const testing = std.testing;

    const Case = struct { roots: CubicRoots, expected: []const f64 };
    const cases = [_]Case{
        .{ .roots = solveCubic(-5.0, 0.0, 0.0, 1.0), .expected = &.{std.math.cbrt(@as(f64, 5.0))} },
        .{ .roots = solveCubic(-5.0, -1.0, 0.0, 1.0), .expected = &.{1.90416085913492} },
        .{ .roots = solveCubic(0.0, -1.0, 0.0, 1.0), .expected = &.{ -1.0, 0.0, 1.0 } },
        .{ .roots = solveCubic(-2.0, -3.0, 0.0, 1.0), .expected = &.{ -1.0, 2.0 } },
        .{ .roots = solveCubic(2.0, -3.0, 0.0, 1.0), .expected = &.{ -2.0, 1.0 } },
        .{
            .roots = solveCubic(2.0 - 1e-12, 5.0, 4.0, 1.0),
            .expected = &.{ -1.9999999999989995, -1.0000010000848456, -0.9999989999161546 },
        },
        .{ .roots = solveCubic(2.0 + 1e-12, 5.0, 4.0, 1.0), .expected = &.{-2.0} },
    };
    for (cases) |case| {
        var roots = case.roots;
        const expected = case.expected;
        try testing.expectEqual(expected.len, roots.len);
        std.mem.sort(f64, roots.sliceMut(), {}, std.sort.asc(f64));
        for (expected, 0..) |e, i| {
            try testing.expect(@abs(roots.get(i) - e) < 1e-12);
        }
    }
}

test "test_solve_quadratic" {
    const testing = std.testing;

    {
        var roots = solveQuadratic(-5.0, 0.0, 1.0);
        try testing.expectEqual(@as(usize, 2), roots.len);
        try testing.expect(@abs(roots.get(0) + @sqrt(5.0)) < 1e-12);
        try testing.expect(@abs(roots.get(1) - @sqrt(5.0)) < 1e-12);
    }
    try testing.expectEqual(@as(usize, 0), solveQuadratic(5.0, 0.0, 1.0).len);
    {
        const roots = solveQuadratic(5.0, 1.0, 0.0);
        try testing.expectEqual(@as(usize, 1), roots.len);
        try testing.expect(@abs(roots.get(0) + 5.0) < 1e-12);
    }
    {
        const roots = solveQuadratic(1.0, 2.0, 1.0);
        try testing.expectEqual(@as(usize, 1), roots.len);
        try testing.expect(@abs(roots.get(0) + 1.0) < 1e-12);
    }
}

test "test_solve_quartic" {
    const Context = struct {
        fn testWithRoots(coeffs: [4]f64, roots: []const f64, rel_err: f64) !void {
            // Note: in paper, coefficients are in decreasing order.
            var actual = solveQuartic(coeffs[3], coeffs[2], coeffs[1], coeffs[0], 1.0);
            std.mem.sort(f64, actual.sliceMut(), {}, std.sort.asc(f64));
            try std.testing.expectEqual(roots.len, actual.len);
            for (roots, 0..) |expected, i| {
                const got = actual.get(i);
                try std.testing.expect(@abs(got - expected) < rel_err * @abs(expected));
            }
        }

        fn testVietaRoots(x1: f64, x2: f64, x3: f64, x4: f64, roots: []const f64, rel_err: f64) !void {
            const a = -(x1 + x2 + x3 + x4);
            const b = x1 * (x2 + x3) + x2 * (x3 + x4) + x4 * (x1 + x3);
            const c = -x1 * x2 * (x3 + x4) - x3 * x4 * (x1 + x2);
            const d = x1 * x2 * x3 * x4;
            try testWithRoots(.{ a, b, c, d }, roots, rel_err);
        }

        fn testVieta(x1: f64, x2: f64, x3: f64, x4: f64, rel_err: f64) !void {
            try testVietaRoots(x1, x2, x3, x4, &.{ x1, x2, x3, x4 }, rel_err);
        }
    };

    // case 1
    try Context.testVieta(1.0, 1e3, 1e6, 1e9, 1e-16);
    // case 2
    try Context.testVieta(2.0, 2.001, 2.002, 2.003, 1e-6);
    // case 3
    try Context.testVieta(1e47, 1e49, 1e50, 1e53, 2e-16);
    // case 4
    try Context.testVieta(-1.0, 1.0, 2.0, 1e14, 1e-16);
    // case 6
    try Context.testWithRoots(
        .{ -9000002.0, -9999981999998.0, 19999982e6, -2e13 },
        &.{ -1e6, 1e7 },
        1e-16,
    );
    // case 14
    try Context.testVietaRoots(1000.0, 1000.0, 1000.0, 1000.0, &.{ 1000.0, 1000.0 }, 1e-16);
    // case 22
    try Context.testVieta(1.0, 10.0, 1e152, 1e154, 3e-16);
    // case 23
    try Context.testWithRoots(
        .{ 1.0, 1.0, 3.0 / 8.0, 1e-3 },
        &.{ -0.497314148060048, -0.00268585193995149 },
        2e-15,
    );
    // case 24
    const S: f64 = 1e30;
    try Context.testWithRoots(
        .{ -(1.0 + 1.0 / S), 1.0 / S - S * S, S * S + S, -S },
        &.{ -S, 1e-30, 1.0, S },
        2e-16,
    );
}

test "test_solve_itp" {
    const testing = std.testing;
    const Ctx = struct {
        fn eval(_: *@This(), x: f64) f64 {
            return x * x * x - x - 2.0;
        }
    };
    var ctx = Ctx{};
    const x = solveItp(Ctx, Ctx.eval, &ctx, 1.0, 2.0, 1e-12, 0, 0.2, Ctx.eval(&ctx, 1.0), Ctx.eval(&ctx, 2.0));
    try testing.expect(@abs(Ctx.eval(&ctx, x)) < 6e-12);
}

test "rootsBetweenQuintic finds simple roots" {
    const testing = std.testing;
    // (x - 1)(x - 2)(x - 3)(x - 4)(x - 5)
    const coeffs = [6]f64{ -120.0, 274.0, -225.0, 85.0, -15.0, 1.0 };
    const roots = rootsBetweenQuintic(coeffs, 0.0, 6.0, 1e-12);
    try testing.expectEqual(@as(usize, 5), roots.len);
    for (roots.slice(), 0..) |r, i| {
        try testing.expect(@abs(r - @as(f64, @floatFromInt(i + 1))) < 1e-9);
    }
}
