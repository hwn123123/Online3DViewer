//! Bounded HATCH display geometry. The original CAD entities remain unchanged.
use acadrust::entities::hatch::{BoundaryEdge, Hatch, HatchStyleType, SplineEdge};
use acadrust::o3dv_guard as guard;
use std::f64::consts::TAU;

type P = [f64; 2];
const MAX_VERTICES: usize = 65_536;
const MAX_LINES: usize = 120_000;
const MAX_WORK: usize = 4_000_000;
const EPS: f64 = 1e-9;

pub struct Geometry {
    pub triangles: Vec<[P; 3]>,
    pub lines: Vec<[P; 2]>,
}
fn sub(a: P, b: P) -> P {
    [a[0] - b[0], a[1] - b[1]]
}
fn add(a: P, b: P) -> P {
    [a[0] + b[0], a[1] + b[1]]
}
fn mul(a: P, s: f64) -> P {
    [a[0] * s, a[1] * s]
}
fn cross(a: P, b: P) -> f64 {
    a[0] * b[1] - a[1] * b[0]
}
fn dot(a: P, b: P) -> f64 {
    a[0] * b[0] + a[1] * b[1]
}
fn length(a: P) -> f64 {
    dot(a, a).sqrt()
}
fn push(out: &mut Vec<P>, p: P) -> Result<(), &'static str> {
    if !p[0].is_finite() || !p[1].is_finite() {
        return Err("无效的填充边界");
    }
    if out.last().map_or(true, |a| length(sub(*a, p)) > EPS) {
        out.push(p);
    }
    if out.len() > MAX_VERTICES {
        return Err("过于复杂的填充边界");
    }
    Ok(())
}
fn arc<F: Fn(f64) -> P>(
    out: &mut Vec<P>,
    start: f64,
    sweep: f64,
    f: F,
) -> Result<(), &'static str> {
    if !start.is_finite() || !sweep.is_finite() || sweep.abs() > TAU + 1e-7 {
        return Err("无效的填充曲线");
    }
    let steps = (sweep.abs() / 0.028284507).ceil().max(1.) as usize;
    if steps > MAX_VERTICES || out.len() + steps > MAX_VERTICES {
        return Err("过于复杂的填充边界");
    }
    for i in 0..=steps {
        guard::tick();
        push(out, f(start + sweep * i as f64 / steps as f64))?;
    }
    Ok(())
}
fn sweep(start: f64, end: f64, ccw: bool) -> f64 {
    let delta = if ccw { end - start } else { start - end };
    let turn = delta.rem_euclid(TAU);
    let extent = if turn.abs() < 1e-12 && delta.abs() > 1e-12 {
        TAU
    } else {
        turn
    };
    if ccw {
        extent
    } else {
        -extent
    }
}
fn spline(out: &mut Vec<P>, e: &SplineEdge) -> Result<(), &'static str> {
    let degree = usize::try_from(e.degree).map_err(|_| "无法求值的样条填充边界")?;
    let n = e.control_points.len();
    if degree > 32
        || n <= degree
        || e.knots.len() != n + degree + 1
        || e.knots
            .windows(2)
            .any(|w| !w[0].is_finite() || !w[1].is_finite() || w[0] > w[1])
    {
        return Err("无法求值的样条填充边界");
    }
    let evaluate = |t: f64| -> Result<P, &'static str> {
        let k = (degree..n)
            .rev()
            .find(|&i| e.knots[i] <= t)
            .unwrap_or(degree)
            .min(n - 1);
        let mut d = [[0.; 3]; 33];
        for j in 0..=degree {
            let p = e.control_points[k - degree + j];
            let w = if e.rational { p.z } else { 1. };
            if !p.x.is_finite() || !p.y.is_finite() || !w.is_finite() {
                return Err("无法求值的样条填充边界");
            }
            d[j] = [p.x * w, p.y * w, w];
        }
        for r in 1..=degree {
            for j in (r..=degree).rev() {
                let i = k - degree + j;
                let den = e.knots[i + degree + 1 - r] - e.knots[i];
                let a = if den == 0. {
                    0.
                } else {
                    (t - e.knots[i]) / den
                };
                for c in 0..3 {
                    d[j][c] = (1. - a) * d[j - 1][c] + a * d[j][c];
                }
            }
        }
        if d[degree][2].abs() < 1e-30 {
            return Err("无法求值的样条填充边界");
        }
        Ok([d[degree][0] / d[degree][2], d[degree][1] / d[degree][2]])
    };
    let span = e
        .control_points
        .windows(2)
        .map(|p| length([p[1].x - p[0].x, p[1].y - p[0].y]))
        .sum::<f64>();
    if !span.is_finite() {
        return Err("无法求值的样条填充边界");
    }
    let tolerance = (span * 1e-5).max(1e-9);
    for i in degree..n {
        let (a, b) = (e.knots[i], e.knots[i + 1]);
        if b <= a {
            continue;
        }
        let mut stack = vec![(a, b, evaluate(a)?, evaluate(b)?, 0u8)];
        while let Some((a, b, pa, pb, level)) = stack.pop() {
            guard::tick();
            let mid = evaluate((a + b) * 0.5)?;
            let q1 = evaluate(a + (b - a) * 0.25)?;
            let q3 = evaluate(a + (b - a) * 0.75)?;
            let error = length(sub(mid, mul(add(pa, pb), 0.5)))
                .max(length(sub(q1, add(mul(pa, 0.75), mul(pb, 0.25)))))
                .max(length(sub(q3, add(mul(pa, 0.25), mul(pb, 0.75)))));
            if error <= tolerance {
                push(out, pa)?;
                push(out, pb)?;
            } else {
                if level >= 24 || out.len() + stack.len() >= MAX_VERTICES {
                    return Err("过于复杂的样条填充边界");
                }
                let t = (a + b) * 0.5;
                stack.push((t, b, mid, pb, level + 1));
                stack.push((a, t, pa, mid, level + 1));
            }
        }
    }
    Ok(())
}
fn boundary(h: &Hatch) -> Result<Vec<Vec<P>>, &'static str> {
    let mut rings = guard::capacity(h.paths.len());
    let mut count = 0;
    for path in &h.paths {
        guard::tick();
        let flags = path.flags;
        if match h.style {
            HatchStyleType::Normal => false,
            HatchStyleType::Outer => !flags.is_external() && !flags.is_outermost(),
            HatchStyleType::Ignore => !flags.is_external(),
        } {
            continue;
        }
        if path.flags.is_not_closed() || path.flags.bits() & 64 != 0 {
            return Err("未闭合或自交的填充边界");
        }
        let mut ring = Vec::new();
        for e in &path.edges {
            let mut segment = Vec::new();
            match e {
                BoundaryEdge::Line(l) => {
                    push(&mut segment, [l.start.x, l.start.y])?;
                    push(&mut segment, [l.end.x, l.end.y])?;
                }
                BoundaryEdge::Polyline(p) => {
                    if !p.is_closed || p.vertices.len() < 3 {
                        return Err("未闭合的填充边界");
                    }
                    for i in 0..p.vertices.len() {
                        guard::tick();
                        let v = p.vertices[i];
                        let w = p.vertices[(i + 1) % p.vertices.len()];
                        let a = [v.x, v.y];
                        let b = [w.x, w.y];
                        let bulge = v.z;
                        if !bulge.is_finite() {
                            return Err("无效的填充曲线");
                        }
                        if bulge.abs() < 1e-14 {
                            push(&mut segment, a)?;
                            push(&mut segment, b)?;
                        } else {
                            let d = sub(b, a);
                            let c = add(
                                mul(add(a, b), 0.5),
                                mul([-d[1], d[0]], (1. - bulge * bulge) / (4. * bulge)),
                            );
                            let radius = length(sub(a, c));
                            let t = (a[1] - c[1]).atan2(a[0] - c[0]);
                            arc(&mut segment, t, 4. * bulge.atan(), |x| {
                                add(c, [radius * x.cos(), radius * x.sin()])
                            })?;
                        }
                    }
                }
                BoundaryEdge::CircularArc(e) => {
                    if !e.radius.is_finite() || e.radius <= 0. {
                        return Err("无效的填充曲线");
                    }
                    let (a, b) = if e.counter_clockwise {
                        (e.start_angle, e.end_angle)
                    } else {
                        (-e.start_angle, -e.end_angle)
                    };
                    arc(&mut segment, a, sweep(a, b, e.counter_clockwise), |t| {
                        [
                            e.center.x + e.radius * t.cos(),
                            e.center.y + e.radius * t.sin(),
                        ]
                    })?;
                }
                BoundaryEdge::EllipticArc(e) => {
                    if !e.minor_axis_ratio.is_finite() || e.minor_axis_ratio <= 0. {
                        return Err("无效的填充曲线");
                    }
                    let major = [e.major_axis_endpoint.x, e.major_axis_endpoint.y];
                    let minor = [
                        -major[1] * e.minor_axis_ratio,
                        major[0] * e.minor_axis_ratio,
                    ];
                    let (a, b) = if e.counter_clockwise {
                        (e.start_angle, e.end_angle)
                    } else {
                        (-e.start_angle, -e.end_angle)
                    };
                    arc(&mut segment, a, sweep(a, b, e.counter_clockwise), |t| {
                        add(
                            [e.center.x, e.center.y],
                            add(mul(major, t.cos()), mul(minor, t.sin())),
                        )
                    })?;
                }
                BoundaryEdge::Spline(e) => spline(&mut segment, e)?,
            }
            if segment.is_empty() {
                return Err("无效的填充边界");
            }
            if let Some(last) = ring.last() {
                if length(sub(*last, segment[0])) > 1e-6 {
                    return Err("未闭合的填充边界");
                }
            }
            for p in segment {
                push(&mut ring, p)?;
            }
        }
        if ring.len() < 4 || length(sub(ring[0], *ring.last().unwrap())) > 1e-6 {
            return Err("未闭合的填充边界");
        }
        ring.pop();
        if ring.len() < 3 || !area(&ring).is_finite() || area(&ring).abs() < EPS {
            return Err("无效的填充边界");
        }
        count += ring.len();
        if count > MAX_VERTICES {
            return Err("过于复杂的填充边界");
        }
        rings.push(ring);
    }
    if rings.is_empty() {
        return Err("缺少填充边界");
    }
    Ok(rings)
}
fn area(r: &[P]) -> f64 {
    let o = r[0];
    (0..r.len())
        .map(|i| cross(sub(r[i], o), sub(r[(i + 1) % r.len()], o)))
        .sum::<f64>()
        * 0.5
}
fn inside(p: P, ring: &[P]) -> bool {
    let mut hit = false;
    for i in 0..ring.len() {
        let a = ring[i];
        let b = ring[(i + 1) % ring.len()];
        if (a[1] > p[1]) != (b[1] > p[1])
            && p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0]
        {
            hit = !hit;
        }
    }
    hit
}
fn parents(rings: &[Vec<P>]) -> Result<Vec<Option<usize>>, &'static str> {
    if rings
        .len()
        .saturating_mul(rings.iter().map(Vec::len).sum::<usize>())
        > MAX_WORK
    {
        return Err("过于复杂的填充边界");
    }
    let areas: Vec<_> = rings.iter().map(|r| area(r).abs()).collect();
    let mut parents = vec![None; rings.len()];
    for i in 0..rings.len() {
        guard::tick();
        let mut best = f64::INFINITY;
        for j in 0..rings.len() {
            if i != j && areas[j] > areas[i] && areas[j] < best && inside(rings[i][0], &rings[j]) {
                parents[i] = Some(j);
                best = areas[j];
            }
        }
    }
    Ok(parents)
}
fn depth(mut i: usize, parents: &[Option<usize>]) -> usize {
    let mut n = 0;
    while let Some(p) = parents[i] {
        n += 1;
        i = p;
    }
    n
}
fn solid(
    rings: &[Vec<P>],
    parents: &[Option<usize>],
    style: HatchStyleType,
    out: &mut Geometry,
) -> Result<(), &'static str> {
    for i in 0..rings.len() {
        guard::tick();
        let d = depth(i, parents);
        let shell = match style {
            HatchStyleType::Normal => d % 2 == 0,
            _ => d == 0,
        };
        if !shell {
            continue;
        }
        let mut flat = Vec::new();
        let mut points = Vec::new();
        let mut holes = Vec::new();
        let mut indices = vec![i];
        if style != HatchStyleType::Ignore {
            indices.extend((0..rings.len()).filter(|j| parents[*j] == Some(i)));
        }
        let mut expected = area(&rings[i]).abs();
        for (n, j) in indices.iter().enumerate() {
            if n > 0 {
                holes.push(points.len());
                expected -= area(&rings[*j]).abs();
            }
            for p in &rings[*j] {
                flat.extend_from_slice(p);
                points.push(*p);
            }
        }
        if expected <= 0. {
            return Err("无效的填充孔洞");
        }
        let tris = earcutr::earcut(&flat, &holes, 2).map_err(|_| "填充边界无法三角化")?;
        let mut actual = 0.;
        for tri in tris.chunks_exact(3) {
            let t = [points[tri[0]], points[tri[1]], points[tri[2]]];
            actual += cross(sub(t[1], t[0]), sub(t[2], t[0])).abs() * 0.5;
            out.triangles.push(t);
        }
        if (actual - expected).abs() > expected * 1e-6 + 1e-8 || tris.is_empty() {
            return Err("填充边界无法完整三角化");
        }
    }
    Ok(())
}
fn occupied(p: P, rings: &[Vec<P>], style: HatchStyleType) -> bool {
    let n = rings.iter().filter(|r| inside(p, r)).count();
    match style {
        HatchStyleType::Normal => n % 2 == 1,
        HatchStyleType::Outer => n == 1,
        HatchStyleType::Ignore => n > 0,
    }
}
fn line(out: &mut Geometry, a: P, b: P) -> Result<(), &'static str> {
    if out.lines.len() >= MAX_LINES {
        return Err("过密的填充图案");
    }
    out.lines.push([a, b]);
    Ok(())
}
fn dashes(
    out: &mut Geometry,
    p: P,
    dir: P,
    a: f64,
    b: f64,
    dash: &[f64],
) -> Result<(), &'static str> {
    if dash.is_empty() {
        return line(out, add(p, mul(dir, a)), add(p, mul(dir, b)));
    }
    let period = dash.iter().map(|x| x.abs()).sum::<f64>();
    if !period.is_finite() || period < EPS {
        return Err("无效的填充线型");
    }
    let mut t = (a / period).floor() * period;
    let mut operations = 0;
    while t < b {
        for d in dash {
            guard::tick();
            operations += 1;
            if operations > MAX_LINES * 4 {
                return Err("过密的填充图案");
            }
            let end = t + d.abs();
            if *d > 0. && end > a && t < b {
                line(
                    out,
                    add(p, mul(dir, t.max(a))),
                    add(p, mul(dir, end.min(b))),
                )?;
            }
            if *d == 0. && t >= a && t <= b {
                let q = add(p, mul(dir, t));
                line(out, q, q)?;
            }
            t = end;
        }
    }
    Ok(())
}
fn patterned(h: &Hatch, rings: &[Vec<P>], out: &mut Geometry) -> Result<(), &'static str> {
    if h.pattern.lines.is_empty() {
        return Err("缺少填充图案定义");
    }
    let mut lo = [f64::INFINITY; 2];
    let mut hi = [f64::NEG_INFINITY; 2];
    for p in rings.iter().flatten() {
        for k in 0..2 {
            lo[k] = lo[k].min(p[k]);
            hi[k] = hi[k].max(p[k]);
        }
    }
    let corners = [lo, [hi[0], lo[1]], hi, [lo[0], hi[1]]];
    let vertices = rings.iter().map(Vec::len).sum::<usize>();
    let mut work = 0usize;
    // The stored definition lines already incorporate the hatch scale and
    // rotation; applying groups 41/52 again would distort real drawings.
    if h.is_double {
        return Err("双重填充图案");
    }
    for def in &h.pattern.lines {
        guard::tick();
        let angle = def.angle;
        if !angle.is_finite() {
            return Err("无效的填充图案");
        }
        let dir = [angle.cos(), angle.sin()];
        let normal = [-dir[1], dir[0]];
        let offset = [def.offset.x, def.offset.y];
        let origin = [def.base_point.x, def.base_point.y];
        let spacing = dot(offset, normal);
        if spacing.abs() < EPS && length(offset) > 0. {
            return Err("过密的填充图案");
        }
        let (first, last) = if spacing.abs() < EPS {
            (0, 0)
        } else {
            let vals = corners.map(|p| dot(sub(p, origin), normal) / spacing);
            let a = vals.iter().copied().fold(f64::INFINITY, f64::min).floor();
            let b = vals
                .iter()
                .copied()
                .fold(f64::NEG_INFINITY, f64::max)
                .ceil();
            if !a.is_finite()
                || !b.is_finite()
                || (b - a) > MAX_LINES as f64
                || a.abs() > 1e9
                || b.abs() > 1e9
            {
                return Err("过密的填充图案");
            }
            (a as i64, b as i64)
        };
        work = work.saturating_add((last - first + 1) as usize * vertices);
        if work > MAX_WORK {
            return Err("过密的填充图案");
        }
        let dash: Vec<f64> = def.dash_lengths.clone();
        if dash.iter().any(|d| !d.is_finite()) {
            return Err("无效的填充线型");
        }
        if dash.iter().any(|d| *d == 0.) {
            return Err("含点的填充图案");
        }
        for index in first..=last {
            guard::tick();
            let p = add(origin, mul(offset, index as f64));
            let mut cuts = Vec::new();
            for ring in rings {
                for i in 0..ring.len() {
                    let a = ring[i];
                    let b = ring[(i + 1) % ring.len()];
                    let da = dot(sub(a, p), normal);
                    let db = dot(sub(b, p), normal);
                    if (da > 0.) != (db > 0.) {
                        let q = add(a, mul(sub(b, a), da / (da - db)));
                        cuts.push(dot(sub(q, p), dir));
                    }
                }
            }
            cuts.sort_by(f64::total_cmp);
            cuts.dedup_by(|a, b| (*a - *b).abs() < EPS);
            work = work.saturating_add(cuts.len().saturating_mul(vertices));
            if work > MAX_WORK {
                return Err("过密的填充图案");
            }
            for pair in cuts.windows(2) {
                if pair[1] - pair[0] > EPS
                    && occupied(add(p, mul(dir, (pair[0] + pair[1]) * 0.5)), rings, h.style)
                {
                    dashes(out, p, dir, pair[0], pair[1], &dash)?;
                }
            }
        }
    }
    Ok(())
}
pub fn generate(h: &Hatch) -> Result<Geometry, &'static str> {
    if h.gradient_color.enabled {
        return Err("渐变填充");
    }
    if h.is_mpolygon {
        return Err("MPolygon 填充");
    }
    let rings = boundary(h)?;
    let parent = parents(&rings)?;
    let mut out = Geometry {
        triangles: Vec::new(),
        lines: Vec::new(),
    };
    if h.is_solid {
        solid(&rings, &parent, h.style, &mut out)?;
    } else {
        // Reject malformed rings before clipping; an incorrect fill is more
        // misleading than a clearly reported unsupported boundary.
        let mut validation = Geometry {
            triangles: Vec::new(),
            lines: Vec::new(),
        };
        solid(&rings, &parent, h.style, &mut validation)?;
        // Ignore deeper islands for these styles so the visible line and dash
        // phase is not spuriously split at boundaries that have no effect.
        let selected: Vec<Vec<P>> = rings
            .iter()
            .enumerate()
            .filter(|(i, _)| match h.style {
                HatchStyleType::Normal => true,
                HatchStyleType::Outer => depth(*i, &parent) <= 1,
                HatchStyleType::Ignore => depth(*i, &parent) == 0,
            })
            .map(|(_, r)| r.clone())
            .collect();
        patterned(h, &selected, &mut out)?;
    }
    Ok(out)
}
