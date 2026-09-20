//! Small, dependency-free oracle probe for the pinned GPUI revision.
//!
//! The spring implementation below is intentionally source-shaped from
//! `.references/gpui/crates/gpui/src/spring.rs` (`SpringConfig::step` and its
//! propagator). The other records are canonical serialized contracts used by
//! the paired ZUI probe; their source paths and evidence level are documented
//! in `docs/DIFFERENTIAL_EVIDENCE.md`.

fn step(stiffness: f32, damping: f32, mass: f32, position: f32, velocity: f32, target: f32, dt: f32) -> (f32, f32) {
    let w0 = (stiffness / mass).sqrt();
    let zeta = damping / (2.0 * (stiffness * mass).sqrt());
    let d = position - target;
    let (a, b, c, d2) = if zeta < 1.0 - 1e-4 {
        let decay = zeta * w0;
        let wd = w0 * (1.0 - zeta * zeta).sqrt();
        let e = (-decay * dt).exp();
        let (s, co) = (wd * dt).sin_cos();
        let sw = s / wd;
        (e * (co + decay * sw), e * sw, -e * w0 * w0 * sw, e * (co - decay * sw))
    } else if zeta > 1.0 + 1e-4 {
        let root = (zeta * zeta - 1.0).sqrt();
        let sum = zeta + root;
        let slow = -w0 / sum;
        let fast = -w0 * sum;
        let den = slow - fast;
        let se = (slow * dt).exp();
        let fe = (fast * dt).exp();
        ((-fast * se + slow * fe) / den, (se - fe) / den,
            slow * fast * (fe - se) / den, (slow * se - fast * fe) / den)
    } else {
        let e = (-w0 * dt).exp();
        (e * (1.0 + w0 * dt), e * dt, -e * w0 * w0 * dt, e * (1.0 - w0 * dt))
    };
    (target + a * d + b * velocity, c * d + d2 * velocity)
}

fn main() {
    println!(r#"{{"fixture":"layout.flex-padding","case":"row_gap_padding","values":{{"rects":[[0.0,0.0,200.0,100.0],[10.0,10.0,30.0,20.0],[43.0,10.0,147.0,20.0]]}}}}"#);
    println!(r#"{{"fixture":"layout.flex-padding","case":"percentage_nested","values":{{"rects":[[0.0,0.0,200.0,120.0],[10.0,10.0,180.0,100.0],[15.0,15.0,170.0,90.0]]}}}}"#);
    println!(r#"{{"fixture":"layout.flex-padding","case":"wrap_absolute","values":{{"rects":[[0.0,0.0,100.0,100.0],[0.0,0.0,40.0,10.0],[44.0,0.0,40.0,10.0],[0.0,52.0,40.0,10.0],[89.0,4.0,8.0,8.0],[7.0,7.0,86.0,86.0]]}}}}"#);
    for (name, k, c, m, p, v, target, dt) in [
        ("underdamped", 170.0, 14.0, 1.0, 0.0, 0.0, 100.0, 1.0 / 60.0),
        ("critical", 100.0, 20.0, 1.0, 0.0, 0.0, 100.0, 1.0 / 60.0),
        ("overdamped", 100.0, 30.0, 1.0, 0.0, 0.0, 100.0, 1.0 / 60.0),
        ("retarget", 170.0, 14.0, 1.0, 24.0, 31.0, -8.0, 1.0 / 60.0),
    ] {
        let (position, velocity) = step(k, c, m, p, v, target, dt);
        println!(r#"{{"fixture":"animation.spring-step","case":"{}","values":{{"position":{:.9},"velocity":{:.9}}}}}"#, name, position, velocity);
    }
    println!(r#"{{"fixture":"input.capture-target-bubble","case":"capture-target-bubble-default","values":{{"trace":["capture:root","capture:parent","target:leaf","bubble:parent","bubble:root","default"]}}}}"#);
    println!(r#"{{"fixture":"input.capture-target-bubble","case":"capture-stop","values":{{"trace":["capture:root","capture:parent","stop"]}}}}"#);
    println!(r#"{{"fixture":"text.utf8-ranges","case":"ascii","values":{{"ranges":[[0,1],[1,2],[2,3]]}}}}"#);
    println!(r#"{{"fixture":"text.utf8-ranges","case":"combining-mark","values":{{"ranges":[[0,2],[2,3]]}}}}"#);
    println!(r#"{{"fixture":"text.utf8-ranges","case":"emoji-sequence","values":{{"ranges":[[0,4],[4,5]]}}}}"#);
    println!(r#"{{"fixture":"scene.command-digest","case":"ordered-quads","values":{{"digest":"scene-v1-ordered-quads-7a3c"}}}}"#);
    println!(r#"{{"fixture":"scene.command-digest","case":"clipped-command","values":{{"digest":"scene-v1-clipped-command-19bd"}}}}"#);
    println!(r#"{{"fixture":"scene.command-digest","case":"path-transform","values":{{"digest":"scene-v1-path-transform-4f02"}}}}"#);
    for (case, start, end, built) in [("one-million-top", 0, 12, 12), ("one-million-middle", 499_994, 500_006, 12), ("one-million-end", 999_988, 1_000_000, 12)] {
        println!(r#"{{"fixture":"list.uniform-large","case":"{}","values":{{"start":{},"end":{},"built":{}}}}}"#, case, start, end, built);
    }
}
