//! Port of kurbo 0.13.1 `affine.rs` (Apache-2.0 OR MIT).
//!
//! Coefficients are stored as `(a, b, c, d, e, f)` for the augmented matrix
//!
//! ```text
//! | a c e |
//! | b d f |
//! | 0 0 1 |
//! ```
//!
//! consistent with upstream. Zig has no operator overloading, so the upstream
//! operators are methods: `transformPoint` (`Affine * Point`), `compose`
//! (`Affine * Affine`), `mulScalar` (`f64 * Affine`).
//!
//! Omissions: the `mint` conversions (feature-gated upstream) and the
//! `Ellipse`/`Circle`/`Line`/`BezPath` transform operators, which live on
//! those types in this port (`Line.transform`, `QuadBez.transform`,
//! `CubicBez.transform`, `BezPath.applyAffine`).

const std = @import("std");
const common = @import("common.zig");
const Point = @import("point.zig").Point;
const Vec2 = @import("vec2.zig").Vec2;
const Rect = @import("rect.zig").Rect;

/// A 2D affine transform.
pub const Affine = struct {
    c: [6]f64,

    /// The identity transform.
    pub const IDENTITY: Affine = .{ .c = .{ 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 } };

    /// A transform that is flipped on the y-axis.
    pub const FLIP_Y: Affine = .{ .c = .{ 1.0, 0.0, 0.0, -1.0, 0.0, 0.0 } };

    /// A transform that is flipped on the x-axis.
    pub const FLIP_X: Affine = .{ .c = .{ -1.0, 0.0, 0.0, 1.0, 0.0, 0.0 } };

    /// Construct an affine transform from coefficients.
    pub inline fn new(c: [6]f64) Affine {
        return .{ .c = c };
    }

    /// An affine transform representing uniform scaling.
    pub inline fn scale(s: f64) Affine {
        return .{ .c = .{ s, 0.0, 0.0, s, 0.0, 0.0 } };
    }

    /// An affine transform representing non-uniform scaling.
    pub inline fn scaleNonUniform(s_x: f64, s_y: f64) Affine {
        return .{ .c = .{ s_x, 0.0, 0.0, s_y, 0.0, 0.0 } };
    }

    /// An affine transform representing a scale of `s` about `center`.
    pub fn scaleAbout(s: f64, center: Point) Affine {
        const center_v = center.toVec2();
        return Affine.translate(center_v.neg()).thenScale(s).thenTranslate(center_v);
    }

    /// An affine transform representing rotation.
    ///
    /// A positive angle rotates a positive X direction into positive Y.
    pub fn rotate(th: f64) Affine {
        const sc = common.FloatFuncs.sinCos(th);
        const s = sc[0];
        const c = sc[1];
        return .{ .c = .{ c, s, -s, c, 0.0, 0.0 } };
    }

    /// An affine transform representing a rotation of `th` radians about
    /// `center`.
    pub fn rotateAbout(th: f64, center: Point) Affine {
        const center_v = center.toVec2();
        return Affine.translate(center_v.neg()).thenRotate(th).thenTranslate(center_v);
    }

    /// An affine transform representing translation.
    pub inline fn translate(p: Vec2) Affine {
        return .{ .c = .{ 1.0, 0.0, 0.0, 1.0, p.x, p.y } };
    }

    /// An affine transformation representing a skew.
    pub inline fn skew(skew_x: f64, skew_y: f64) Affine {
        return .{ .c = .{ 1.0, skew_y, skew_x, 1.0, 0.0, 0.0 } };
    }

    /// Create an affine transform that represents reflection about the line
    /// `point + direction * t, t in (-inf, inf)`.
    pub fn reflect(point: Point, direction: Vec2) Affine {
        const n = Vec2.new(direction.y, -direction.x).normalize();

        // Compute Householder reflection matrix
        const x2 = n.x * n.x;
        const xy = n.x * n.y;
        const y2 = n.y * n.y;
        // Here we also add in the post translation, because it doesn't require
        // any further calc.
        const aff = Affine.new(.{
            1.0 - 2.0 * x2,
            -2.0 * xy,
            -2.0 * xy,
            1.0 - 2.0 * y2,
            point.x,
            point.y,
        });
        return aff.preTranslate(point.toVec2().neg());
    }

    /// A rotation by `th` followed by `self`. Equivalent to `self * Affine::rotate(th)`.
    pub inline fn preRotate(self: Affine, th: f64) Affine {
        return self.compose(Affine.rotate(th));
    }

    /// A rotation by `th` about `center` followed by `self`.
    pub inline fn preRotateAbout(self: Affine, th: f64, center: Point) Affine {
        return self.compose(Affine.rotateAbout(th, center));
    }

    /// A scale by `s` followed by `self`.
    pub inline fn preScale(self: Affine, s: f64) Affine {
        return self.compose(Affine.scale(s));
    }

    /// A scale by `(sx, sy)` followed by `self`.
    pub inline fn preScaleNonUniform(self: Affine, sx: f64, sy: f64) Affine {
        return self.compose(Affine.scaleNonUniform(sx, sy));
    }

    /// A translation of `trans` followed by `self`.
    pub inline fn preTranslate(self: Affine, trans: Vec2) Affine {
        return self.compose(Affine.translate(trans));
    }

    /// A skew followed by `self`.
    pub inline fn preSkew(self: Affine, skew_x: f64, skew_y: f64) Affine {
        return self.compose(Affine.skew(skew_x, skew_y));
    }

    /// A reflection followed by `self`.
    pub inline fn preReflect(self: Affine, point: Point, direction: Vec2) Affine {
        return self.compose(Affine.reflect(point, direction));
    }

    /// `self` followed by a rotation of `th`.
    pub inline fn thenRotate(self: Affine, th: f64) Affine {
        return Affine.rotate(th).compose(self);
    }

    /// `self` followed by a rotation of `th` about `center`.
    pub inline fn thenRotateAbout(self: Affine, th: f64, center: Point) Affine {
        return Affine.rotateAbout(th, center).compose(self);
    }

    /// `self` followed by a scale of `s`.
    pub inline fn thenScale(self: Affine, s: f64) Affine {
        return Affine.scale(s).compose(self);
    }

    /// `self` followed by a scale of `(sx, sy)`.
    pub inline fn thenScaleNonUniform(self: Affine, sx: f64, sy: f64) Affine {
        return Affine.scaleNonUniform(sx, sy).compose(self);
    }

    /// `self` followed by a scale of `s` about `center`.
    pub inline fn thenScaleAbout(self: Affine, s: f64, center: Point) Affine {
        return Affine.scaleAbout(s, center).compose(self);
    }

    /// `self` followed by a skew of `(skew_x, skew_y)`.
    pub inline fn thenSkew(self: Affine, skew_x: f64, skew_y: f64) Affine {
        return Affine.skew(skew_x, skew_y).compose(self);
    }

    /// `self` followed by a reflection about the line through `point` in
    /// `direction`.
    pub inline fn thenReflect(self: Affine, point: Point, direction: Vec2) Affine {
        return Affine.reflect(point, direction).compose(self);
    }

    /// `self` followed by a translation of `trans`.
    pub inline fn thenTranslate(self: Affine, trans: Vec2) Affine {
        var result = self;
        result.c[4] += trans.x;
        result.c[5] += trans.y;
        return result;
    }

    /// Creates an affine transformation that takes the unit square to the
    /// given rectangle.
    pub inline fn mapUnitSquare(rect: Rect) Affine {
        return .{ .c = .{ rect.width(), 0.0, 0.0, rect.height(), rect.x0, rect.y0 } };
    }

    /// Get the coefficients of the transform.
    pub inline fn asCoeffs(self: Affine) [6]f64 {
        return self.c;
    }

    /// Compute the determinant of this transform.
    pub inline fn determinant(self: Affine) f64 {
        return self.c[0] * self.c[3] - self.c[1] * self.c[2];
    }

    /// Compute the square of the nuclear norm of this transform.
    pub inline fn nuclearNormSquared(self: Affine) f64 {
        return self.frobeniusNormSquared() + 2.0 * @abs(self.determinant());
    }

    /// Compute the square of the Frobenius norm of this transform.
    pub inline fn frobeniusNormSquared(self: Affine) f64 {
        const c = self.asCoeffs();
        return c[0] * c[0] + c[1] * c[1] + c[2] * c[2] + c[3] * c[3];
    }

    /// Compute the spectral norm of this transform.
    pub inline fn spectralNorm(self: Affine) f64 {
        return self.svd().scale.x;
    }

    /// Compute the inverse transform.
    ///
    /// Produces NaN values when the determinant is zero.
    pub inline fn inverse(self: Affine) Affine {
        const inv_det = 1.0 / self.determinant();
        return .{ .c = .{
            inv_det * self.c[3],
            -inv_det * self.c[1],
            -inv_det * self.c[2],
            inv_det * self.c[0],
            inv_det * (self.c[2] * self.c[5] - self.c[3] * self.c[4]),
            inv_det * (self.c[1] * self.c[4] - self.c[0] * self.c[5]),
        } };
    }

    /// Compute the bounding box of a transformed rectangle.
    ///
    /// The returned rectangle always has non-negative width and height.
    pub fn transformRectBbox(self: Affine, rect: Rect) Rect {
        const p00 = self.transformPoint(Point.new(rect.x0, rect.y0));
        const p01 = self.transformPoint(Point.new(rect.x0, rect.y1));
        const p10 = self.transformPoint(Point.new(rect.x1, rect.y0));
        const p11 = self.transformPoint(Point.new(rect.x1, rect.y1));
        return Rect.fromPoints(p00, p01).unionWith(Rect.fromPoints(p10, p11));
    }

    /// Is this map finite?
    pub inline fn isFinite(self: Affine) bool {
        for (self.c) |v| {
            if (!std.math.isFinite(v)) return false;
        }
        return true;
    }

    /// Is this map `NaN`?
    pub inline fn isNan(self: Affine) bool {
        for (self.c) |v| {
            if (std.math.isNan(v)) return true;
        }
        return false;
    }

    /// The singular value decomposition result: `scale` is the pair of
    /// singular values (x >= y) and `angle` is the rotation in radians.
    pub const Svd = struct {
        scale: Vec2,
        angle: f64,
    };

    /// Compute the singular value decomposition of the linear transformation
    /// (ignoring the translation).
    ///
    /// Upstream this is `pub(crate)`; it is public here because it documents
    /// the numerical behavior of `spectralNorm` and is covered by the ported
    /// upstream tests.
    pub fn svd(self: Affine) Svd {
        const a = self.c[0];
        const b = self.c[1];
        const c = self.c[2];
        const d = self.c[3];
        const a2 = a * a;
        const b2 = b * b;
        const c2 = c * c;
        const d2 = d * d;
        const ab = a * b;
        const cd = c * d;
        const angle = 0.5 * std.math.atan2(2.0 * (ab + cd), a2 - b2 + c2 - d2);

        // See affine.rs for the derivation:
        //   sigma1 = 1/2 (S1 + S2), sigma2 = 1/2 |S1 - S2|
        const s1 = @sqrt((a + d) * (a + d) + (b - c) * (b - c));
        const s2 = @sqrt((a - d) * (a - d) + (b + c) * (b + c));
        return .{
            .scale = Vec2.new(0.5 * (s1 + s2), 0.5 * @abs(s1 - s2)),
            .angle = angle,
        };
    }

    /// Returns the translation part of this affine map.
    pub inline fn translation(self: Affine) Vec2 {
        return Vec2.new(self.c[4], self.c[5]);
    }

    /// Replaces the translation portion of this affine map.
    pub inline fn withTranslation(self: Affine, trans: Vec2) Affine {
        var result = self;
        result.c[4] = trans.x;
        result.c[5] = trans.y;
        return result;
    }

    // ------------------------------------------------------------ operators

    /// Upstream `Affine * Point`.
    pub inline fn transformPoint(self: Affine, other: Point) Point {
        return Point.new(
            self.c[0] * other.x + self.c[2] * other.y + self.c[4],
            self.c[1] * other.x + self.c[3] * other.y + self.c[5],
        );
    }

    /// Upstream `Affine * Affine`.
    pub inline fn compose(self: Affine, other: Affine) Affine {
        const s = self.c;
        const o = other.c;
        return .{ .c = .{
            s[0] * o[0] + s[2] * o[1],
            s[1] * o[0] + s[3] * o[1],
            s[0] * o[2] + s[2] * o[3],
            s[1] * o[2] + s[3] * o[3],
            s[0] * o[4] + s[2] * o[5] + s[4],
            s[1] * o[4] + s[3] * o[5] + s[5],
        } };
    }

    /// Upstream `f64 * Affine`.
    pub inline fn mulScalar(self: Affine, s: f64) Affine {
        return .{ .c = .{
            s * self.c[0],
            s * self.c[1],
            s * self.c[2],
            s * self.c[3],
            s * self.c[4],
            s * self.c[5],
        } };
    }
};

fn assertNear(p0: Point, p1: Point) !void {
    try std.testing.expect(p1.subPoint(p0).hypot() < 1e-9);
}

fn assertAffineNear(a0: Affine, a1: Affine) !void {
    for (0..6) |i| {
        try std.testing.expect(@abs(a0.c[i] - a1.c[i]) < 1e-9);
    }
}

test "affine basic" {
    const testing = std.testing;
    const p = Point.new(3.0, 4.0);

    try assertNear(Affine.IDENTITY.transformPoint(p), p);
    try assertNear(Affine.scale(2.0).transformPoint(p), Point.new(6.0, 8.0));
    try assertNear(Affine.rotate(0.0).transformPoint(p), p);
    try assertNear(Affine.rotate(std.math.pi / 2.0).transformPoint(p), Point.new(-4.0, 3.0));
    try assertNear(Affine.translate(Vec2.new(5.0, 6.0)).transformPoint(p), Point.new(8.0, 10.0));
    try assertNear(Affine.skew(0.0, 0.0).transformPoint(p), p);
    try assertNear(Affine.skew(2.0, 4.0).transformPoint(p), Point.new(11.0, 16.0));
    _ = testing;
}

test "affine mul" {
    const a1 = Affine.new(.{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 });
    const a2 = Affine.new(.{ 0.1, 1.2, 2.3, 3.4, 4.5, 5.6 });

    const px = Point.new(1.0, 0.0);
    const py = Point.new(0.0, 1.0);
    const pxy = Point.new(1.0, 1.0);
    try assertNear(a1.transformPoint(a2.transformPoint(px)), a1.compose(a2).transformPoint(px));
    try assertNear(a1.transformPoint(a2.transformPoint(py)), a1.compose(a2).transformPoint(py));
    try assertNear(a1.transformPoint(a2.transformPoint(pxy)), a1.compose(a2).transformPoint(pxy));
}

test "affine inv" {
    const testing = std.testing;
    const a = Affine.new(.{ 0.1, 1.2, 2.3, 3.4, 4.5, 5.6 });
    const a_inv = a.inverse();

    const px = Point.new(1.0, 0.0);
    const py = Point.new(0.0, 1.0);
    const pxy = Point.new(1.0, 1.0);
    try assertNear(a.transformPoint(a_inv.transformPoint(px)), px);
    try assertNear(a.transformPoint(a_inv.transformPoint(py)), py);
    try assertNear(a.transformPoint(a_inv.transformPoint(pxy)), pxy);
    try assertNear(a_inv.transformPoint(a.transformPoint(px)), px);
    try assertNear(a_inv.transformPoint(a.transformPoint(py)), py);
    try assertNear(a_inv.transformPoint(a.transformPoint(pxy)), pxy);
    _ = testing;
}

test "affine reflection" {
    try assertAffineNear(
        Affine.reflect(Point.ZERO, Vec2.new(1.0, 0.0)),
        Affine.new(.{ 1.0, 0.0, 0.0, -1.0, 0.0, 0.0 }),
    );
    try assertAffineNear(
        Affine.reflect(Point.ZERO, Vec2.new(0.0, 1.0)),
        Affine.new(.{ -1.0, 0.0, 0.0, 1.0, 0.0, 0.0 }),
    );
    // y = x
    try assertAffineNear(
        Affine.reflect(Point.ZERO, Vec2.new(1.0, 1.0)),
        Affine.new(.{ 0.0, 1.0, 1.0, 0.0, 0.0, 0.0 }),
    );

    // no translate
    const point = Point.new(0.0, 0.0);
    const vec = Vec2.new(1.0, 1.0);
    const map = Affine.reflect(point, vec);
    try assertNear(map.transformPoint(Point.new(0.0, 0.0)), Point.new(0.0, 0.0));
    try assertNear(map.transformPoint(Point.new(1.0, 1.0)), Point.new(1.0, 1.0));
    try assertNear(map.transformPoint(Point.new(1.0, 2.0)), Point.new(2.0, 1.0));

    // with translate
    const point2 = Point.new(1.0, 0.0);
    const map2 = Affine.reflect(point2, vec);
    try assertNear(map2.transformPoint(Point.new(1.0, 0.0)), Point.new(1.0, 0.0));
    try assertNear(map2.transformPoint(Point.new(2.0, 1.0)), Point.new(2.0, 1.0));
    try assertNear(map2.transformPoint(Point.new(2.0, 2.0)), Point.new(3.0, 1.0));
}

test "affine svd" {
    const testing = std.testing;
    const a = Affine.new(.{ 1.0, 2.0, 3.0, 4.0, 5.0, 6.0 });
    const a_no_translate = a.withTranslation(Vec2.ZERO);

    // translation should have no effect
    const svd_a = a.svd();
    const svd_nt = a_no_translate.svd();
    try assertNear(svd_a.scale.toPoint(), svd_nt.scale.toPoint());
    try testing.expect(@abs(svd_a.angle - svd_nt.angle) <= 1e-9);

    try assertNear(svd_a.scale.toPoint(), Point.new(5.4649857042190427, 0.36596619062625782));
    try testing.expect(@abs(svd_a.angle - 0.95691013360780001) <= 1e-9);

    // singular affine
    const singular = Affine.new(.{ 0.0, 0.0, 0.0, 0.0, 5.0, 6.0 });
    try testing.expectEqual(@as(f64, 0.0), singular.determinant());
    const singular_svd = singular.svd();
    try testing.expectEqualDeep(Vec2.new(0.0, 0.0), singular_svd.scale);
    try testing.expectEqual(@as(f64, 0.0), singular_svd.angle);
}

test "affine svd singular values" {
    const testing = std.testing;
    const mat = struct {
        fn f(a: f64, b: f64, c: f64, d: f64) Affine {
            return Affine.new(.{ a, b, c, d, 0.0, 0.0 });
        }
    }.f;

    try assertNear(mat(1.0, 0.0, 0.0, 1.0).svd().scale.toPoint(), Point.new(1.0, 1.0));
    try assertNear(mat(1.0, 0.0, 0.0, -1.0).svd().scale.toPoint(), Point.new(1.0, 1.0));
    try assertNear(mat(1.0, 1.0, 1.0, 1.0).svd().scale.toPoint(), Point.new(2.0, 0.0));
    try assertNear(mat(0.0, 0.0, 1.0, 0.0).svd().scale.toPoint(), Point.new(1.0, 0.0));

    // The singular values are the scaling of the affine map.
    const s = Affine.scaleNonUniform(4.0, 8.0)
        .thenRotateAbout(std.math.pi / 180.0 * 42.0, Point.new(-2.0, 50.0))
        .svd()
        .scale;
    try assertNear(s.toPoint(), Point.new(8.0, 4.0));

    // Correctly handles negative scaling (singular values are non-negative).
    try assertNear(Affine.scaleNonUniform(-20.0, 3.0).svd().scale.toPoint(), Point.new(20.0, 3.0));
    try assertNear(Affine.scaleNonUniform(-20.0, -3.0).svd().scale.toPoint(), Point.new(20.0, 3.0));
    try assertNear(Affine.scaleNonUniform(20.0, -3.0).svd().scale.toPoint(), Point.new(20.0, 3.0));

    // Product of singular values equals the absolute determinant.
    const m = mat(10.0, 9.0, -2.5, 3.3333);
    const sv = m.svd().scale;
    const prod = sv.x * sv.y;
    const det = @abs(m.determinant());
    try testing.expect((prod - det) < 1e-9);
}

test "affine rotate_about_composition" {
    const theta = std.math.pi / 2.0;
    const center = Point.new(-1.0, 0.0);
    const translation = Vec2.new(0.0, 1.0);
    const probe = Point.ORIGIN;

    const rotate_about = Affine.rotateAbout(theta, center);
    const translate = Affine.translate(translation);

    // Establish baselines with raw matrix composition.
    const rotate_then_translate = translate.compose(rotate_about);
    const translate_then_rotate = rotate_about.compose(translate);
    try assertNear(rotate_then_translate.transformPoint(probe), Point.new(-1.0, 2.0));
    try assertNear(translate_then_rotate.transformPoint(probe), Point.new(-2.0, 1.0));

    // Check `.then_*` semantics.
    try assertAffineNear(rotate_about.thenTranslate(translation), rotate_then_translate);
    try assertAffineNear(translate.thenRotateAbout(theta, center), translate_then_rotate);

    // Check `.pre_rotate_about` semantics.
    try assertAffineNear(translate.preRotateAbout(theta, center), rotate_then_translate);
}
