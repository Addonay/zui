// Port of gpui_wgpu/src/shaders.wgsl to sokol-shdc GLSL. Instances are per-instance
// vertex attributes (portable without storage buffers); positions are device pixels
// with the origin at the top left. Coverage math follows the WGSL line by line.
// Uniform slots: vs_params is slot 0 in every vertex stage; fs_params is slot 1.

@block common
const float M_PI_F = 3.1415926;

float fmod_f(float a, float b) { return a - b * trunc(a / b); }
float saturate(float v) { return clamp(v, 0.0, 1.0); }
vec3 saturate(vec3 v) { return clamp(v, 0.0, 1.0); }
vec4 saturate(vec4 v) { return clamp(v, 0.0, 1.0); }

// Hsla (h, s, l, a) to linear RGBA. No clamping, no transfer function.
vec4 hsla_to_rgba(vec4 c) {
    float h = c.x * 6.0;
    float chroma = (1.0 - abs(2.0 * c.z - 1.0)) * c.y;
    float x = chroma * (1.0 - abs(fmod_f(h, 2.0) - 1.0));
    float m = c.z - chroma / 2.0;
    vec3 color = vec3(m);
    if (h >= 0.0 && h < 1.0) { color.r += chroma; color.g += x; }
    else if (h >= 1.0 && h < 2.0) { color.r += x; color.g += chroma; }
    else if (h >= 2.0 && h < 3.0) { color.g += chroma; color.b += x; }
    else if (h >= 3.0 && h < 4.0) { color.g += x; color.b += chroma; }
    else if (h >= 4.0 && h < 5.0) { color.r += x; color.b += chroma; }
    else { color.r += chroma; color.b += x; }
    return vec4(color, c.w);
}

float srgb_to_linear_c(float a) {
    return a < 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4);
}
float linear_to_srgb_c(float a) {
    return a < 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1.0 / 2.4) - 0.055;
}
vec4 srgba_to_linear(vec4 c) {
    return vec4(srgb_to_linear_c(c.r), srgb_to_linear_c(c.g), srgb_to_linear_c(c.b), c.a);
}
vec4 linear_to_srgba(vec4 c) {
    return vec4(linear_to_srgb_c(c.r), linear_to_srgb_c(c.g), linear_to_srgb_c(c.b), c.a);
}

vec4 linear_srgb_to_oklab(vec4 c) {
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    float l_ = pow(l, 1.0 / 3.0);
    float m_ = pow(m, 1.0 / 3.0);
    float s_ = pow(s, 1.0 / 3.0);
    return vec4(
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
        c.a);
}

vec4 oklab_to_linear_srgb(vec4 c) {
    float l_ = c.r + 0.3963377774 * c.g + 0.2158037573 * c.b;
    float m_ = c.r - 0.1055613458 * c.g - 0.0638541728 * c.b;
    float s_ = c.r - 0.0894841775 * c.g - 1.2914855480 * c.b;
    float l = l_ * l_ * l_;
    float m = m_ * m_ * m_;
    float s = s_ * s_ * s_;
    return vec4(
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
        c.a);
}

// Source-over of `above` onto `below` (straight alpha). Zero alpha yields zero color.
vec4 over(vec4 below, vec4 above) {
    float alpha = above.a + below.a * (1.0 - above.a);
    vec3 color = alpha > 0.0 ? (above.rgb * above.a + below.rgb * below.a * (1.0 - above.a)) / alpha : vec3(0.0);
    return vec4(color, alpha);
}

// Radius of the corner nearest to the point. radii is (top_left, top_right, bottom_right, bottom_left).
float pick_corner_radius(vec2 center_to_point, vec4 radii) {
    if (center_to_point.x < 0.0) {
        return center_to_point.y < 0.0 ? radii.x : radii.w;
    }
    return center_to_point.y < 0.0 ? radii.y : radii.z;
}

float quad_sdf_impl(vec2 corner_center_to_point, float corner_radius) {
    if (corner_radius == 0.0) {
        return max(corner_center_to_point.x, corner_center_to_point.y);
    }
    float signed_distance_to_inset_quad =
        length(max(vec2(0.0), corner_center_to_point)) +
        min(0.0, max(corner_center_to_point.x, corner_center_to_point.y));
    return signed_distance_to_inset_quad - corner_radius;
}

// Signed distance from `point` to a rounded rect (bounds = origin.xy, size.zw).
float quad_sdf(vec2 point, vec4 bounds, vec4 radii) {
    vec2 half_size = bounds.zw / 2.0;
    vec2 center = bounds.xy + half_size;
    vec2 center_to_point = point - center;
    float corner_radius = pick_corner_radius(center_to_point, radii);
    vec2 corner_to_point = abs(center_to_point) - half_size;
    return quad_sdf_impl(corner_to_point + corner_radius, corner_radius);
}

// Device position of a pixel-space point, origin at the top left.
vec4 to_device(vec2 position, vec2 viewport) {
    return vec4(position / viewport * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 0.0, 1.0);
}

// Distances to the clip rect (left, right, top, bottom); negative means clipped.
vec4 distance_from_clip(vec2 position, vec4 clip) {
    vec2 tl = position - clip.xy;
    vec2 br = clip.xy + clip.zw - position;
    return vec4(tl.x, br.x, tl.y, br.y);
}

// Background evaluation (gradient_color). Colors are prepared by prepare_gradient().
vec4 gradient_color(float tag, float color_space, float angle, float pct0, float pct1, float pattern_rem,
                    vec4 bounds, vec2 position, vec4 solid_color, vec4 color0, vec4 color1) {
    if (tag == 1.0) {
        float angle_rad = (fmod_f(angle, 360.0) - 90.0) * M_PI_F / 180.0;
        vec2 direction = vec2(cos(angle_rad), sin(angle_rad));
        vec2 size = bounds.zw;
        if (size.x > size.y) {
            direction.y *= size.y / size.x;
        } else {
            direction.x *= size.x / size.y;
        }
        vec2 half_size = size / 2.0;
        vec2 center = bounds.xy + half_size;
        vec2 center_to_point = position - center;
        float t = dot(center_to_point, direction) / length(direction);
        if (abs(direction.x) > abs(direction.y)) {
            t = (t + half_size.x) / size.x;
        } else {
            t = (t + half_size.y) / size.y;
        }
        t = (t - pct0) / (pct1 - pct0);
        t = clamp(t, 0.0, 1.0);
        if (color_space == 1.0) {
            return oklab_to_linear_srgb(mix(color0, color1, t));
        }
        return srgba_to_linear(mix(color0, color1, t));
    }
    if (tag == 2.0) {
        float pattern_width = (angle / 65535.0) / 255.0;
        // The packed height needs more bits than a float mantissa has, and in-shader fmod rounds
        // badly at that magnitude: stripes drift. The exact remainder comes from the instance.
        float pattern_interval = pattern_rem / 255.0;
        float pattern_height = pattern_width + pattern_interval;
        float stripe_angle = M_PI_F / 4.0;
        float pattern_period = pattern_height * sin(stripe_angle);
        vec2 relative_position = position - bounds.xy;
        float rotated_x = cos(stripe_angle) * relative_position.x + sin(stripe_angle) * relative_position.y;
        float pattern = fmod_f(rotated_x, pattern_period);
        float stripe_distance = min(pattern, pattern_period - pattern) - pattern_period * (pattern_width / pattern_height) / 2.0;
        vec4 c = solid_color;
        c.a *= saturate(0.5 - stripe_distance);
        return c;
    }
    if (tag == 3.0) {
        vec2 relative_position = position - bounds.xy;
        float x_index = floor(relative_position.x / angle);
        float y_index = floor(relative_position.y / angle);
        float should_be_colored = fmod_f(x_index + y_index, 2.0);
        vec4 c = solid_color;
        c.a *= saturate(should_be_colored);
        return c;
    }
    return solid_color;
}

// Prepares the solid and gradient stop colors of a background (prepare_gradient_color).
void prepare_gradient(float tag, float color_space, vec4 solid, vec4 stop0, vec4 stop1,
                      out vec4 out_solid, out vec4 out_color0, out vec4 out_color1) {
    out_solid = hsla_to_rgba(solid);
    out_color0 = vec4(0.0);
    out_color1 = vec4(0.0);
    if (tag == 1.0) {
        out_color0 = hsla_to_rgba(stop0);
        out_color1 = hsla_to_rgba(stop1);
        if (color_space == 0.0) {
            out_color0 = linear_to_srgba(out_color0);
            out_color1 = linear_to_srgba(out_color1);
        } else if (color_space == 1.0) {
            out_color0 = linear_srgb_to_oklab(out_color0);
            out_color1 = linear_srgb_to_oklab(out_color1);
        }
    }
}
@end

@block fs_params
layout(binding=1) uniform fs_params { vec4 gamma_ratios; vec4 settings; };
// settings.x: 1 for premultiplied output, settings.y: grayscale enhanced contrast.
vec4 blend_color(vec4 color, float alpha_factor) {
    float alpha = color.a * alpha_factor;
    float multiplier = settings.x != 0.0 ? alpha : 1.0;
    return vec4(color.rgb * multiplier, alpha);
}
@end

@block dash_alpha_fn
float dash_alpha(float t, float period, float dash_len, float dash_velocity, float antialias_threshold) {
    float half_period = period / 2.0;
    float half_length = dash_len / 2.0;
    float centered = fmod_f(t + half_period - half_length, period) - half_period;
    float signed_distance = abs(centered) - half_length;
    return saturate(antialias_threshold - signed_distance / dash_velocity);
}
@end

@vs quads_vs
layout(binding=0) uniform vs_params { vec4 viewport; };
@include_block common
layout(location=0) in vec4 q_bounds;
layout(location=1) in vec4 q_clip;
layout(location=2) in vec4 q_radii;
layout(location=3) in vec4 q_widths;
layout(location=4) in vec4 q_border;
layout(location=5) in vec4 q_solid;
layout(location=6) in vec4 q_color0;
layout(location=7) in vec4 q_color1;
layout(location=8) in vec4 q_bg;
layout(location=9) in vec4 q_bg2;
out vec2 v_pos;
out vec4 v_clip;
flat out vec4 f_bounds;
flat out vec4 f_radii;
flat out vec4 f_widths;
flat out vec4 f_border;
flat out vec4 f_bg;
flat out vec4 f_bg2;
flat out vec4 f_solid;
flat out vec4 f_color0;
flat out vec4 f_color1;
void main() {
    vec2 unit = vec2(float(gl_VertexIndex & 1), 0.5 * float(gl_VertexIndex & 2));
    vec2 position = unit * q_bounds.zw + q_bounds.xy;
    gl_Position = to_device(position, viewport.xy);
    v_pos = position;
    v_clip = distance_from_clip(position, q_clip);
    vec4 solid; vec4 color0; vec4 color1;
    prepare_gradient(q_bg.x, q_bg.y, q_solid, q_color0, q_color1, solid, color0, color1);
    f_bounds = q_bounds;
    f_radii = q_radii;
    f_widths = q_widths;
    f_border = hsla_to_rgba(q_border);
    f_bg = q_bg;
    f_bg2 = q_bg2;
    f_solid = solid;
    f_color0 = color0;
    f_color1 = color1;
}
@end

@fs quads_fs
@include_block common
@include_block fs_params
@include_block dash_alpha_fn
in vec2 v_pos;
in vec4 v_clip;
flat in vec4 f_bounds;
flat in vec4 f_radii;
flat in vec4 f_widths;
flat in vec4 f_border;
flat in vec4 f_bg;
flat in vec4 f_bg2;
flat in vec4 f_solid;
flat in vec4 f_color0;
flat in vec4 f_color1;
layout(location=0) out vec4 frag_color;
void main() {
    if (any(lessThan(v_clip, vec4(0.0)))) discard;

    float border_style = f_bg2.y;
    vec4 background_color = gradient_color(f_bg.x, f_bg.y, f_bg.z, f_bg.w, f_bg2.x, f_bg2.z,
        f_bounds, v_pos, f_solid, f_color0, f_color1);

    bool unrounded = f_radii.x == 0.0 && f_radii.w == 0.0 && f_radii.y == 0.0 && f_radii.z == 0.0;

    // Fast path when the quad is not rounded and doesn't have any border.
    if (f_widths.x == 0.0 && f_widths.y == 0.0 && f_widths.z == 0.0 && f_widths.w == 0.0 && unrounded) {
        frag_color = blend_color(background_color, 1.0);
        return;
    }

    vec2 size = f_bounds.zw;
    vec2 half_size = size / 2.0;
    vec2 point_rel = v_pos - f_bounds.xy;
    vec2 center_to_point = point_rel - half_size;

    // Signed distance field threshold for inclusion of pixels.
    const float antialias_threshold = 0.5;

    float corner_radius = pick_corner_radius(center_to_point, f_radii);

    // Width of the nearest borders.
    vec2 border = vec2(
        center_to_point.x < 0.0 ? f_widths.w : f_widths.y,
        center_to_point.y < 0.0 ? f_widths.x : f_widths.z);

    // 0-width borders are reduced so that inner_sdf >= antialias_threshold.
    vec2 reduced_border = vec2(
        border.x == 0.0 ? -antialias_threshold : border.x,
        border.y == 0.0 ? -antialias_threshold : border.y);

    vec2 corner_to_point = abs(center_to_point) - half_size;
    vec2 corner_center_to_point = corner_to_point + corner_radius;
    bool is_near_rounded_corner = corner_center_to_point.x >= 0.0 && corner_center_to_point.y >= 0.0;
    vec2 straight_border_inner_corner_to_point = corner_to_point + reduced_border;
    bool is_beyond_inner_straight_border =
        straight_border_inner_corner_to_point.x > 0.0 || straight_border_inner_corner_to_point.y > 0.0;
    bool is_within_inner_straight_border =
        straight_border_inner_corner_to_point.x < -antialias_threshold &&
        straight_border_inner_corner_to_point.y < -antialias_threshold;

    if (is_within_inner_straight_border && !is_near_rounded_corner) {
        frag_color = blend_color(background_color, 1.0);
        return;
    }

    float outer_sdf = quad_sdf_impl(corner_center_to_point, corner_radius);

    float inner_sdf = 0.0;
    if (corner_center_to_point.x <= 0.0 || corner_center_to_point.y <= 0.0) {
        inner_sdf = -max(straight_border_inner_corner_to_point.x, straight_border_inner_corner_to_point.y);
    } else if (is_beyond_inner_straight_border) {
        inner_sdf = -1.0;
    } else if (reduced_border.x == reduced_border.y) {
        inner_sdf = -(outer_sdf + reduced_border.x);
    } else {
        vec2 ellipse_radii = max(vec2(0.0), vec2(corner_radius) - reduced_border);
        // Quarter ellipse distance approximation.
        vec2 circle_vec = corner_center_to_point / ellipse_radii;
        float unit_circle_sdf = length(circle_vec) - 1.0;
        inner_sdf = unit_circle_sdf * (ellipse_radii.x + ellipse_radii.y) * -0.5;
    }

    // Negative when inside the border.
    float border_sdf = max(inner_sdf, outer_sdf);

    vec4 color = background_color;
    if (border_sdf < antialias_threshold) {
        vec4 border_color = f_border;

        if (border_style == 1.0) {
            float t = 0.0;
            float max_t = 0.0;
            const float dash_length_per_width = 2.0;
            const float dash_gap_per_width = 1.0;
            const float dash_period_per_width = dash_length_per_width + dash_gap_per_width;
            float dash_velocity = 0.0;
            const float dv_numerator = 1.0 / dash_period_per_width;

            if (unrounded) {
                bool is_horizontal = corner_center_to_point.x < corner_center_to_point.y;
                vec2 dashed_border = vec2(max(f_widths.z, f_widths.x), max(f_widths.y, f_widths.w));
                float border_width = is_horizontal ? dashed_border.x : dashed_border.y;
                dash_velocity = dv_numerator / border_width;
                t = (is_horizontal ? point_rel.x : point_rel.y) * dash_velocity;
                max_t = (is_horizontal ? size.x : size.y) * dash_velocity;
            } else {
                float r_tl = f_radii.x;
                float r_tr = f_radii.y;
                float r_br = f_radii.z;
                float r_bl = f_radii.w;
                float w_t = f_widths.x;
                float w_r = f_widths.y;
                float w_b = f_widths.z;
                float w_l = f_widths.w;

                float dv_t = w_t <= 0.0 ? 0.0 : dv_numerator / w_t;
                float dv_r = w_r <= 0.0 ? 0.0 : dv_numerator / w_r;
                float dv_b = w_b <= 0.0 ? 0.0 : dv_numerator / w_b;
                float dv_l = w_l <= 0.0 ? 0.0 : dv_numerator / w_l;

                float s_t = (size.x - r_tl - r_tr) * dv_t;
                float s_r = (size.y - r_tr - r_br) * dv_r;
                float s_b = (size.x - r_br - r_bl) * dv_b;
                float s_l = (size.y - r_bl - r_tl) * dv_l;

                float cdv_tr = (dv_t == 0.0) ? dv_r : ((dv_r == 0.0) ? dv_t : min(dv_t, dv_r));
                float cdv_br = (dv_b == 0.0) ? dv_r : ((dv_r == 0.0) ? dv_b : min(dv_b, dv_r));
                float cdv_bl = (dv_b == 0.0) ? dv_l : ((dv_l == 0.0) ? dv_b : min(dv_b, dv_l));
                float cdv_tl = (dv_t == 0.0) ? dv_l : ((dv_l == 0.0) ? dv_t : min(dv_t, dv_l));

                float c_tr = r_tr * (M_PI_F / 2.0) * cdv_tr;
                float c_br = r_br * (M_PI_F / 2.0) * cdv_br;
                float c_bl = r_bl * (M_PI_F / 2.0) * cdv_bl;
                float c_tl = r_tl * (M_PI_F / 2.0) * cdv_tl;

                float upto_tr = s_t;
                float upto_r = upto_tr + c_tr;
                float upto_br = upto_r + s_r;
                float upto_b = upto_br + c_br;
                float upto_bl = upto_b + s_b;
                float upto_l = upto_bl + c_bl;
                float upto_tl = upto_l + s_l;
                max_t = upto_tl + c_tl;

                if (is_near_rounded_corner) {
                    float angle_rad = atan(corner_center_to_point.y, corner_center_to_point.x);
                    float corner_t = angle_rad * corner_radius;
                    if (center_to_point.x >= 0.0) {
                        if (center_to_point.y < 0.0) {
                            dash_velocity = cdv_tr;
                            t = upto_r - corner_t * dash_velocity;
                        } else {
                            dash_velocity = cdv_br;
                            t = upto_br + corner_t * dash_velocity;
                        }
                    } else {
                        if (center_to_point.y >= 0.0) {
                            dash_velocity = cdv_bl;
                            t = upto_l - corner_t * dash_velocity;
                        } else {
                            dash_velocity = cdv_tl;
                            t = upto_tl + corner_t * dash_velocity;
                        }
                    }
                } else {
                    bool is_horizontal = corner_center_to_point.x < corner_center_to_point.y;
                    if (is_horizontal) {
                        if (center_to_point.y < 0.0) {
                            dash_velocity = dv_t;
                            t = (point_rel.x - r_tl) * dash_velocity;
                        } else {
                            dash_velocity = dv_b;
                            t = upto_bl - (point_rel.x - r_bl) * dash_velocity;
                        }
                    } else {
                        if (center_to_point.x < 0.0) {
                            dash_velocity = dv_l;
                            t = upto_tl - (point_rel.y - r_tl) * dash_velocity;
                        } else {
                            dash_velocity = dv_r;
                            t = upto_r + (point_rel.y - r_tr) * dash_velocity;
                        }
                    }
                }
            }

            float dash_length = dash_length_per_width / dash_period_per_width;
            float desired_dash_gap = dash_gap_per_width / dash_period_per_width;

            // Straight borders start and end with a dash.
            max_t -= unrounded ? dash_length : 0.0;
            if (max_t >= 1.0) {
                float dash_count = floor(max_t);
                float dash_period = max_t / dash_count;
                border_color.a *= dash_alpha(t, dash_period, dash_length, dash_velocity, antialias_threshold);
            } else if (unrounded) {
                float dash_gap = max_t - dash_length;
                if (dash_gap > 0.0) {
                    float dash_period = dash_length + dash_gap;
                    border_color.a *= dash_alpha(t, dash_period, dash_length, dash_velocity, antialias_threshold);
                }
            }
        }

        // Blend the border over the background, then interpolate inside the background.
        vec4 blended_border = over(background_color, border_color);
        color = mix(background_color, blended_border, saturate(antialias_threshold - inner_sdf));
    }

    frag_color = blend_color(color, saturate(antialias_threshold - outer_sdf));
}
@end


@vs shadows_vs
layout(binding=0) uniform vs_params { vec4 viewport; };
@include_block common
layout(location=0) in vec4 s_bounds;
layout(location=1) in vec4 s_radii;
layout(location=2) in vec4 s_clip;
layout(location=3) in vec4 s_color;
layout(location=4) in vec4 s_element_bounds;
layout(location=5) in vec4 s_element_radii;
layout(location=6) in vec4 s_params;
out vec2 v_pos;
out vec4 v_clip;
flat out vec4 f_color;
flat out vec4 f_bounds;
flat out vec4 f_radii;
flat out vec4 f_element_bounds;
flat out vec4 f_element_radii;
flat out vec4 f_params;
void main() {
    vec2 unit = vec2(float(gl_VertexIndex & 1), 0.5 * float(gl_VertexIndex & 2));
    bool inset = s_params.y > 0.5;
    vec4 geometry;
    if (inset) {
        geometry = s_element_bounds;
    } else {
        // Leave room for the gaussian tail outside the shadow rect.
        float margin = 3.0 * s_params.x;
        geometry = vec4(s_bounds.xy - vec2(margin), s_bounds.zw + 2.0 * vec2(margin));
    }
    vec2 position = unit * geometry.zw + geometry.xy;
    gl_Position = to_device(position, viewport.xy);
    v_pos = position;
    v_clip = distance_from_clip(position, s_clip);
    f_color = hsla_to_rgba(s_color);
    f_bounds = s_bounds;
    f_radii = s_radii;
    f_element_bounds = s_element_bounds;
    f_element_radii = s_element_radii;
    f_params = s_params;
}
@end

@fs shadows_fs
@include_block common
@include_block fs_params
in vec2 v_pos;
in vec4 v_clip;
flat in vec4 f_color;
flat in vec4 f_bounds;
flat in vec4 f_radii;
flat in vec4 f_element_bounds;
flat in vec4 f_element_radii;
flat in vec4 f_params;
layout(location=0) out vec4 frag_color;

float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2.0 * sigma * sigma)) / (sqrt(2.0 * M_PI_F) * sigma);
}

// Approximates the error function, needed for the gaussian integral.
vec2 erf_approx(vec2 v) {
    vec2 s = sign(v);
    vec2 a = abs(v);
    vec2 r1 = 1.0 + (0.278393 + (0.230389 + (0.000972 + 0.078108 * a) * a) * a) * a;
    vec2 r2 = r1 * r1;
    return s - s / (r2 * r2);
}

float blur_along_x(float x, float y, float sigma, float corner, vec2 half_size) {
    float delta = min(half_size.y - corner - abs(y), 0.0);
    float curved = half_size.x - corner + sqrt(max(0.0, corner * corner - delta * delta));
    vec2 integral = 0.5 + 0.5 * erf_approx((x + vec2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

void main() {
    if (any(lessThan(v_clip, vec4(0.0)))) discard;

    vec2 half_size = f_bounds.zw / 2.0;
    vec2 center = f_bounds.xy + half_size;
    vec2 center_to_point = v_pos - center;
    float blur_radius = f_params.x;
    bool inset = f_params.y > 0.5;

    float corner_radius = pick_corner_radius(center_to_point, f_radii);

    float alpha;
    if (blur_radius == 0.0) {
        float sdf = quad_sdf(v_pos, f_bounds, f_radii);
        alpha = saturate(0.5 - sdf);
    } else {
        // The signal is only non-zero in a limited range.
        float low = center_to_point.y - half_size.y;
        float high = center_to_point.y + half_size.y;
        float blur_start = clamp(-3.0 * blur_radius, low, high);
        float blur_end = clamp(3.0 * blur_radius, low, high);

        // Accumulate samples.
        float blur_step = (blur_end - blur_start) / 4.0;
        float y = blur_start + blur_step * 0.5;
        alpha = 0.0;
        for (int i = 0; i < 4; i++) {
            float blur = blur_along_x(center_to_point.x, center_to_point.y - y,
                blur_radius, corner_radius, half_size);
            alpha += blur * gaussian(y, blur_radius) * blur_step;
            y += blur_step;
        }
    }

    if (inset) {
        // The complement of the blurred hole rect, clipped to the element.
        alpha = 1.0 - alpha;
        float element_distance = quad_sdf(v_pos, f_element_bounds, f_element_radii);
        alpha *= saturate(0.5 - element_distance);
    }

    frag_color = blend_color(f_color, alpha);
}
@end

@vs underlines_vs
layout(binding=0) uniform vs_params { vec4 viewport; };
@include_block common
layout(location=0) in vec4 u_bounds;
layout(location=1) in vec4 u_clip;
layout(location=2) in vec4 u_color;
layout(location=3) in vec4 u_params;
out vec2 v_pos;
out vec4 v_clip;
flat out vec4 f_color;
flat out vec4 f_bounds;
flat out vec4 f_params;
void main() {
    vec2 unit = vec2(float(gl_VertexIndex & 1), 0.5 * float(gl_VertexIndex & 2));
    vec2 position = unit * u_bounds.zw + u_bounds.xy;
    gl_Position = to_device(position, viewport.xy);
    v_pos = position;
    v_clip = distance_from_clip(position, u_clip);
    f_color = hsla_to_rgba(u_color);
    f_bounds = u_bounds;
    f_params = u_params;
}
@end

@fs underlines_fs
@include_block common
@include_block fs_params
in vec2 v_pos;
in vec4 v_clip;
flat in vec4 f_color;
flat in vec4 f_bounds;
flat in vec4 f_params;
layout(location=0) out vec4 frag_color;
void main() {
    const float wave_frequency = 2.0;
    const float wave_height_ratio = 0.8;

    if (any(lessThan(v_clip, vec4(0.0)))) discard;

    if (f_params.y == 0.0) {
        frag_color = blend_color(f_color, f_color.a);
        return;
    }

    float thickness = f_params.x;
    float half_thickness = thickness * 0.5;
    vec2 st = (v_pos - f_bounds.xy) / f_bounds.w - vec2(0.0, 0.5);
    float frequency = M_PI_F * wave_frequency * thickness / f_bounds.w;
    float amplitude = (thickness * wave_height_ratio) / f_bounds.w;

    float sine = sin(st.x * frequency) * amplitude;
    float d_sine = cos(st.x * frequency) * amplitude * frequency;
    float sine_distance = (st.y - sine) / sqrt(1.0 + d_sine * d_sine);
    float distance_in_pixels = sine_distance * f_bounds.w;
    float distance_from_top_border = distance_in_pixels - half_thickness;
    float distance_from_bottom_border = distance_in_pixels + half_thickness;
    float alpha = saturate(0.5 - max(-distance_from_bottom_border, distance_from_top_border));
    frag_color = blend_color(f_color, alpha * f_color.a);
}
@end

@vs mono_vs
layout(binding=0) uniform vs_params { vec4 viewport; };
@include_block common
layout(location=0) in vec4 m_uv;
layout(location=1) in vec4 m_bounds;
layout(location=2) in vec4 m_clip;
layout(location=3) in vec4 m_color;
layout(location=4) in vec4 m_rs;
layout(location=5) in vec4 m_translation;
out vec2 v_tile;
out vec4 v_clip;
flat out vec4 f_color;
void main() {
    vec2 unit = vec2(float(gl_VertexIndex & 1), 0.5 * float(gl_VertexIndex & 2));
    vec2 position = unit * m_bounds.zw + m_bounds.xy;
    // Row-major rotation_scale applied to the position, then the translation.
    vec2 transformed = vec2(dot(m_rs.xy, position), dot(m_rs.zw, position)) + m_translation.xy;
    gl_Position = to_device(transformed, viewport.xy);
    v_tile = m_uv.xy + unit * m_uv.zw;
    v_clip = distance_from_clip(transformed, m_clip);
    f_color = hsla_to_rgba(m_color);
}
@end

@fs mono_fs
@include_block common
@include_block fs_params
layout(binding=0) uniform texture2D atlas_tex;
layout(binding=0) uniform sampler atlas_smp;
in vec2 v_tile;
in vec4 v_clip;
flat in vec4 f_color;
layout(location=0) out vec4 frag_color;

float color_brightness(vec3 color) {
    return dot(color, vec3(0.30, 0.59, 0.11));
}

// Contrast and gamma correction adapted from the Microsoft terminal dwrite.hlsl (MIT).
float apply_contrast_and_gamma_correction(float sample_value, vec3 color, float enhanced_contrast_factor, vec4 g) {
    float brightness = color_brightness(color);
    float multiplier = saturate(4.0 * (0.75 - brightness));
    float k = enhanced_contrast_factor * multiplier;
    float contrasted = sample_value * (k + 1.0) / (sample_value * k + 1.0);
    float brightness_adjustment = g.x * brightness + g.y;
    float correction = brightness_adjustment * contrasted + (g.z * brightness + g.w);
    return contrasted + contrasted * (1.0 - contrasted) * correction;
}

void main() {
    float sample_value = texture(sampler2D(atlas_tex, atlas_smp), v_tile).r;
    float alpha_corrected = apply_contrast_and_gamma_correction(sample_value, f_color.rgb, settings.y, gamma_ratios);

    // Alpha clip after using the derivatives.
    if (any(lessThan(v_clip, vec4(0.0)))) discard;

    frag_color = blend_color(f_color, alpha_corrected);
}
@end

@vs poly_vs
layout(binding=0) uniform vs_params { vec4 viewport; };
@include_block common
layout(location=0) in vec4 p_uv;
layout(location=1) in vec4 p_bounds;
layout(location=2) in vec4 p_clip;
layout(location=3) in vec4 p_radii;
layout(location=4) in vec4 p_params;
out vec2 v_tile;
out vec2 v_pos;
out vec4 v_clip;
flat out vec4 f_bounds;
flat out vec4 f_radii;
flat out vec4 f_params;
void main() {
    vec2 unit = vec2(float(gl_VertexIndex & 1), 0.5 * float(gl_VertexIndex & 2));
    vec2 position = unit * p_bounds.zw + p_bounds.xy;
    gl_Position = to_device(position, viewport.xy);
    v_tile = p_uv.xy + unit * p_uv.zw;
    v_pos = position;
    v_clip = distance_from_clip(position, p_clip);
    f_bounds = p_bounds;
    f_radii = p_radii;
    f_params = p_params;
}
@end

@fs poly_fs
@include_block common
@include_block fs_params
layout(binding=0) uniform texture2D atlas_tex;
layout(binding=0) uniform sampler atlas_smp;
in vec2 v_tile;
in vec2 v_pos;
in vec4 v_clip;
flat in vec4 f_bounds;
flat in vec4 f_radii;
flat in vec4 f_params;
layout(location=0) out vec4 frag_color;
void main() {
    vec4 sample_color = texture(sampler2D(atlas_tex, atlas_smp), v_tile);

    // Alpha clip after using the derivatives.
    if (any(lessThan(v_clip, vec4(0.0)))) discard;

    float sdf = quad_sdf(v_pos, f_bounds, f_radii);
    vec4 color = sample_color;
    if (f_params.x != 0.0) {
        float grayscale = dot(color.rgb, vec3(0.2126, 0.7152, 0.0722));
        color = vec4(vec3(grayscale), sample_color.a);
    }
    frag_color = blend_color(color, f_params.y * saturate(0.5 - sdf));
}
@end

@vs path_raster_vs
layout(binding=0) uniform vs_params { vec4 viewport; };
@include_block common
layout(location=0) in vec4 r_xy_st;
layout(location=1) in vec4 r_bounds;
layout(location=2) in vec4 r_bg;
layout(location=3) in vec4 r_solid;
layout(location=4) in vec4 r_color0;
layout(location=5) in vec4 r_color1;
layout(location=6) in vec4 r_bg2;
out vec2 v_st;
out vec2 v_pos;
out vec4 v_clip;
flat out vec4 f_bounds;
flat out vec4 f_bg;
flat out vec4 f_bg2;
flat out vec4 f_solid;
flat out vec4 f_color0;
flat out vec4 f_color1;
void main() {
    gl_Position = to_device(r_xy_st.xy, viewport.xy);
    v_st = r_xy_st.zw;
    v_pos = r_xy_st.xy;
    v_clip = distance_from_clip(r_xy_st.xy, r_bounds);
    vec4 solid; vec4 color0; vec4 color1;
    prepare_gradient(r_bg.x, r_bg.y, r_solid, r_color0, r_color1, solid, color0, color1);
    f_bounds = r_bounds;
    f_bg = r_bg;
    f_bg2 = r_bg2;
    f_solid = solid;
    f_color0 = color0;
    f_color1 = color1;
}
@end

@fs path_raster_fs
@include_block common
in vec2 v_st;
in vec2 v_pos;
in vec4 v_clip;
flat in vec4 f_bounds;
flat in vec4 f_bg;
flat in vec4 f_bg2;
flat in vec4 f_solid;
flat in vec4 f_color0;
flat in vec4 f_color1;
layout(location=0) out vec4 frag_color;
void main() {
    vec2 dx = dFdx(v_st);
    vec2 dy = dFdy(v_st);
    if (any(lessThan(v_clip, vec4(0.0)))) discard;

    float alpha;
    if (length(vec2(dx.x, dy.x)) < 0.001) {
        // The gradient is too small: solid coverage.
        alpha = 1.0;
    } else {
        vec2 gradient = 2.0 * v_st.x * vec2(dx.x, dy.x) - vec2(dx.y, dy.y);
        float f = v_st.x * v_st.x - v_st.y;
        float sdf_distance = f / length(gradient);
        alpha = saturate(0.5 - sdf_distance);
    }
    vec4 color = gradient_color(f_bg.x, f_bg.y, f_bg.z, f_bg.w, f_bg2.x, f_bg2.z,
        f_bounds, v_pos, f_solid, f_color0, f_color1);
    frag_color = vec4(color.rgb * color.a * alpha, color.a * alpha);
}
@end

@vs path_composite_vs
layout(binding=0) uniform vs_params { vec4 viewport; };
@include_block common
layout(location=0) in vec4 c_bounds;
out vec2 v_uv;
void main() {
    vec2 unit = vec2(float(gl_VertexIndex & 1), 0.5 * float(gl_VertexIndex & 2));
    vec2 position = unit * c_bounds.zw + c_bounds.xy;
    gl_Position = to_device(position, viewport.xy);
    // Screen position to texture coordinates; flipped when the backend's rows start at the bottom.
    vec2 uv = position / viewport.xy;
    if (viewport.z > 0.5) uv.y = 1.0 - uv.y;
    v_uv = uv;
}
@end

@fs path_composite_fs
layout(binding=0) uniform texture2D path_tex;
layout(binding=0) uniform sampler path_smp;
in vec2 v_uv;
layout(location=0) out vec4 frag_color;
void main() {
    frag_color = texture(sampler2D(path_tex, path_smp), v_uv);
}
@end

@program quads quads_vs quads_fs
@program shadows shadows_vs shadows_fs
@program underlines underlines_vs underlines_fs
@program mono_sprites mono_vs mono_fs
@program poly_sprites poly_vs poly_fs
@program path_raster path_raster_vs path_raster_fs
@program path_composite path_composite_vs path_composite_fs
