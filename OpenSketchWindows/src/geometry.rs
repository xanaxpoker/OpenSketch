use crate::model::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq)]
pub enum PathSegment {
    MoveTo(Point2D),
    LineTo(Point2D),
    CurveTo {
        ctrl1: Point2D,
        ctrl2: Point2D,
        to: Point2D,
    },
    Close,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct VectorPath {
    pub segments: Vec<PathSegment>,
    pub subpaths: Vec<Vec<Point2D>>,
}

impl VectorPath {
    pub fn is_empty(&self) -> bool {
        self.segments.is_empty() && self.subpaths.is_empty()
    }

    pub fn bounding_box(&self) -> SketchRect {
        let mut min_x = f64::INFINITY;
        let mut min_y = f64::INFINITY;
        let mut max_x = f64::NEG_INFINITY;
        let mut max_y = f64::NEG_INFINITY;
        let mut any = false;

        for seg in &self.segments {
            match seg {
                PathSegment::MoveTo(p) | PathSegment::LineTo(p) => {
                    min_x = min_x.min(p.x);
                    min_y = min_y.min(p.y);
                    max_x = max_x.max(p.x);
                    max_y = max_y.max(p.y);
                    any = true;
                }
                PathSegment::CurveTo { ctrl1, ctrl2, to } => {
                    for p in [ctrl1, ctrl2, to] {
                        min_x = min_x.min(p.x);
                        min_y = min_y.min(p.y);
                        max_x = max_x.max(p.x);
                        max_y = max_y.max(p.y);
                    }
                    any = true;
                }
                PathSegment::Close => {}
            }
        }
        if !any {
            return SketchRect::new(0.0, 0.0, 0.0, 0.0);
        }
        SketchRect::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }
}

// MARK: - Bezier Builder & Corner Radius Fillet Engine (`MSBezierBuilder`)

pub struct SketchBezierBuilder;

impl SketchBezierBuilder {
    /// Exact constant from `MSBezierBuilder::appendCurveFromPoint:toPoint:toCGPath:` (`0x3fdc71c71c88995b` = `0.4477152502`)
    pub const FILLET_KAPPA_COMPLEMENT: f64 = 0.4477152502;

    pub fn build_vector_path(
        points: &[SketchCurvePoint],
        rect: SketchRect,
        is_closed: bool,
        fixed_radius: f64,
    ) -> VectorPath {
        if points.is_empty() {
            return VectorPath::default();
        }

        let abs_points: Vec<Point2D> = points
            .iter()
            .map(|p| SketchPointString::convert_from_unit(p.unit_point(), rect))
            .collect();
        let abs_from: Vec<Point2D> = points
            .iter()
            .map(|p| SketchPointString::convert_from_unit(p.unit_curve_from(), rect))
            .collect();
        let abs_to: Vec<Point2D> = points
            .iter()
            .map(|p| SketchPointString::convert_from_unit(p.unit_curve_to(), rect))
            .collect();
        let count = points.len();

        let has_fillet = is_closed
            && count >= 3
            && points
                .iter()
                .all(|p| !p.has_curve_from && !p.has_curve_to)
            && (fixed_radius > 0.0 || points.iter().any(|p| p.corner_radius > 0.0));

        let mut segments = Vec::new();
        let mut poly = Vec::new();

        if has_fillet {
            for i in 0..count {
                let prev = abs_points[(i + count - 1) % count];
                let curr = abs_points[i];
                let next = abs_points[(i + 1) % count];

                let r_raw = if points[i].corner_radius > 0.0 {
                    points[i].corner_radius
                } else {
                    fixed_radius
                };
                let v_in = Point2D::new(prev.x - curr.x, prev.y - curr.y);
                let v_out = Point2D::new(next.x - curr.x, next.y - curr.y);
                let len_in = v_in.x.hypot(v_in.y);
                let len_out = v_out.x.hypot(v_out.y);
                let max_r = (len_in.min(len_out) * 0.5).max(0.0);
                let radius = r_raw.min(max_r);

                if radius > 0.01 && len_in > 0.001 && len_out > 0.001 {
                    let u_in = Point2D::new(v_in.x / len_in, v_in.y / len_in);
                    let u_out = Point2D::new(v_out.x / len_out, v_out.y / len_out);
                    let start_arc = Point2D::new(curr.x + u_in.x * radius, curr.y + u_in.y * radius);
                    let end_arc =
                        Point2D::new(curr.x + u_out.x * radius, curr.y + u_out.y * radius);

                    let k = Self::FILLET_KAPPA_COMPLEMENT;
                    let c1 = Point2D::new(
                        curr.x + (start_arc.x - curr.x) * k,
                        curr.y + (start_arc.y - curr.y) * k,
                    );
                    let c2 = Point2D::new(
                        curr.x + (end_arc.x - curr.x) * k,
                        curr.y + (end_arc.y - curr.y) * k,
                    );

                    if i == 0 {
                        segments.push(PathSegment::MoveTo(start_arc));
                    } else {
                        segments.push(PathSegment::LineTo(start_arc));
                    }
                    segments.push(PathSegment::CurveTo {
                        ctrl1: c1,
                        ctrl2: c2,
                        to: end_arc,
                    });
                    sample_cubic(start_arc, c1, c2, end_arc, 6, &mut poly);
                } else {
                    if i == 0 {
                        segments.push(PathSegment::MoveTo(curr));
                    } else {
                        segments.push(PathSegment::LineTo(curr));
                    }
                    poly.push(curr);
                }
            }
            segments.push(PathSegment::Close);
            return VectorPath {
                segments,
                subpaths: vec![poly],
            };
        }

        segments.push(PathSegment::MoveTo(abs_points[0]));
        poly.push(abs_points[0]);
        let seg_count = if is_closed {
            count
        } else {
            count.saturating_sub(1)
        };

        for i in 0..seg_count {
            let next_idx = (i + 1) % count;
            let p0 = abs_points[i];
            let p1 = abs_points[next_idx];
            let use_c1 = points[i].has_curve_from && points[i].curve_mode != 1;
            let use_c2 = points[next_idx].has_curve_to && points[next_idx].curve_mode != 1;

            if use_c1 || use_c2 {
                let c1 = if use_c1 { abs_from[i] } else { p0 };
                let c2 = if use_c2 { abs_to[next_idx] } else { p1 };
                segments.push(PathSegment::CurveTo {
                    ctrl1: c1,
                    ctrl2: c2,
                    to: p1,
                });
                sample_cubic(p0, c1, c2, p1, 8, &mut poly);
            } else {
                segments.push(PathSegment::LineTo(p1));
                poly.push(p1);
            }
        }

        if is_closed {
            segments.push(PathSegment::Close);
        }

        VectorPath {
            segments,
            subpaths: vec![poly],
        }
    }

    pub fn svg_path_data(path: &VectorPath) -> String {
        fn fmt(v: f64) -> String {
            if (v - v.round()).abs() < 1e-4 {
                format!("{}", v.round() as i64)
            } else {
                format!("{:.2}", v)
            }
        }
        let mut cmds = Vec::new();
        for seg in &path.segments {
            match seg {
                PathSegment::MoveTo(p) => cmds.push(format!("M{},{}", fmt(p.x), fmt(p.y))),
                PathSegment::LineTo(p) => cmds.push(format!("L{},{}", fmt(p.x), fmt(p.y))),
                PathSegment::CurveTo { ctrl1, ctrl2, to } => cmds.push(format!(
                    "C{},{} {},{} {},{}",
                    fmt(ctrl1.x),
                    fmt(ctrl1.y),
                    fmt(ctrl2.x),
                    fmt(ctrl2.y),
                    fmt(to.x),
                    fmt(to.y)
                )),
                PathSegment::Close => cmds.push("Z".to_string()),
            }
        }
        cmds.join(" ")
    }
}

fn sample_cubic(
    p0: Point2D,
    c1: Point2D,
    c2: Point2D,
    p1: Point2D,
    steps: usize,
    out: &mut Vec<Point2D>,
) {
    for step in 1..=steps {
        let t = (step as f64) / (steps as f64);
        let mt = 1.0 - t;
        let x = mt * mt * mt * p0.x
            + 3.0 * mt * mt * t * c1.x
            + 3.0 * mt * t * t * c2.x
            + t * t * t * p1.x;
        let y = mt * mt * mt * p0.y
            + 3.0 * mt * mt * t * c1.y
            + 3.0 * mt * t * t * c2.y
            + t * t * t * p1.y;
        out.push(Point2D::new(x, y));
    }
}

// MARK: - Boolean Operations Engine (`MSPath::booleanOp:withPath:` codes 0..3)

pub struct SketchBooleanEngine;

impl SketchBooleanEngine {
    pub fn combine_layers(
        first: &SketchLayer,
        second: &SketchLayer,
        operation: SketchBooleanOperation,
    ) -> SketchLayer {
        let union_rect = first.frame.union(&second.frame);
        let mut child_a = first.clone();
        child_a.frame.x -= union_rect.x;
        child_a.frame.y -= union_rect.y;
        child_a.boolean_operation = SketchBooleanOperation::None;

        let mut child_b = second.clone();
        child_b.frame.x -= union_rect.x;
        child_b.frame.y -= union_rect.y;
        child_b.boolean_operation = operation;

        let mut group = SketchLayer::new(
            SketchLayerKind::ShapeGroup,
            format!("{} ({})", first.name, operation.title()),
            union_rect,
        );
        group.style = first.style.clone();
        group.layers = vec![child_a, child_b];
        group
    }

    pub fn evaluate_shape_group_path(shape_group: &SketchLayer) -> VectorPath {
        if shape_group.layers.is_empty() {
            let local_rect = SketchRect::new(0.0, 0.0, shape_group.frame.width, shape_group.frame.height);
            return SketchBezierBuilder::build_vector_path(
                &shape_group.points,
                local_rect,
                shape_group.is_closed,
                shape_group.fixed_radius,
            );
        }

        let mut subpaths: Vec<Vec<Point2D>> = Vec::new();
        for (idx, child) in shape_group.layers.iter().enumerate() {
            if !child.is_visible {
                continue;
            }
            let child_path = SketchBezierBuilder::build_vector_path(
                &child.points,
                child.frame,
                child.is_closed,
                child.fixed_radius,
            );
            let poly = child_path
                .subpaths
                .first()
                .cloned()
                .unwrap_or_else(|| rect_polygon(child.frame));

            if idx == 0 {
                subpaths.push(poly);
                continue;
            }

            match child.boolean_operation {
                SketchBooleanOperation::None
                | SketchBooleanOperation::Union
                | SketchBooleanOperation::Difference => {
                    subpaths.push(poly);
                }
                SketchBooleanOperation::Subtract => {
                    let mut reversed = poly;
                    reversed.reverse();
                    subpaths.push(reversed);
                }
                SketchBooleanOperation::Intersect => {
                    if let Some(base) = subpaths.first() {
                        let clipped = sutherland_hodgman_clip(base, &poly);
                        subpaths = vec![if clipped.is_empty() { poly } else { clipped }];
                    }
                }
            }
        }

        let mut segments = Vec::new();
        for sp in &subpaths {
            if let Some(first_pt) = sp.first() {
                segments.push(PathSegment::MoveTo(*first_pt));
                for pt in sp.iter().skip(1) {
                    segments.push(PathSegment::LineTo(*pt));
                }
                segments.push(PathSegment::Close);
            }
        }

        VectorPath { segments, subpaths }
    }

    pub fn flatten_shape_group(shape_group: &SketchLayer) -> SketchLayer {
        let evaluated = Self::evaluate_shape_group_path(shape_group);
        let poly = evaluated
            .subpaths
            .first()
            .cloned()
            .unwrap_or_else(|| rect_polygon(SketchRect::new(0.0, 0.0, shape_group.frame.width, shape_group.frame.height)));
        let local_bounds = SketchRect::new(
            0.0,
            0.0,
            shape_group.frame.width.max(1.0),
            shape_group.frame.height.max(1.0),
        );
        let curve_points: Vec<SketchCurvePoint> = poly
            .iter()
            .map(|pt| {
                let unit = SketchPointString::convert_to_unit(*pt, local_bounds);
                SketchCurvePoint::straight(unit, 0.0)
            })
            .collect();

        let mut flattened = SketchLayer::new(
            SketchLayerKind::ShapePath,
            format!("{} (Flattened)", shape_group.name),
            shape_group.frame,
        );
        flattened.style = shape_group.style.clone();
        flattened.points = curve_points;
        flattened.is_closed = true;
        flattened
    }
}

fn rect_polygon(r: SketchRect) -> Vec<Point2D> {
    vec![
        Point2D::new(r.min_x(), r.min_y()),
        Point2D::new(r.max_x(), r.min_y()),
        Point2D::new(r.max_x(), r.max_y()),
        Point2D::new(r.min_x(), r.max_y()),
    ]
}

fn sutherland_hodgman_clip(subject: &[Point2D], clip: &[Point2D]) -> Vec<Point2D> {
    if subject.len() < 3 || clip.len() < 3 {
        return Vec::new();
    }
    let mut output = subject.to_vec();
    for i in 0..clip.len() {
        let a = clip[i];
        let b = clip[(i + 1) % clip.len()];
        let input = output;
        output = Vec::new();
        if input.is_empty() {
            break;
        }
        for j in 0..input.len() {
            let p = input[j];
            let q = input[(j + input.len() - 1) % input.len()];
            let p_in = is_inside_edge(p, a, b);
            let q_in = is_inside_edge(q, a, b);
            if p_in {
                if !q_in {
                    if let Some(inter) = line_intersection(q, p, a, b) {
                        output.push(inter);
                    }
                }
                output.push(p);
            } else if q_in {
                if let Some(inter) = line_intersection(q, p, a, b) {
                    output.push(inter);
                }
            }
        }
    }
    output
}

fn is_inside_edge(p: Point2D, a: Point2D, b: Point2D) -> bool {
    (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= 0.0
}

fn line_intersection(p1: Point2D, p2: Point2D, p3: Point2D, p4: Point2D) -> Option<Point2D> {
    let denom = (p1.x - p2.x) * (p3.y - p4.y) - (p1.y - p2.y) * (p3.x - p4.x);
    if denom.abs() < 1e-9 {
        return None;
    }
    let t = ((p1.x - p3.x) * (p3.y - p4.y) - (p1.y - p3.y) * (p3.x - p4.x)) / denom;
    Some(Point2D::new(
        p1.x + t * (p2.x - p1.x),
        p1.y + t * (p2.y - p1.y),
    ))
}

// MARK: - Smart Layout & Symbol Override Expansion Engine (`MSImmutableInferredGroupLayout`)

pub struct SketchSmartLayoutEngine;

impl SketchSmartLayoutEngine {
    pub fn expand_symbol_instance(
        instance: &SketchLayer,
        document: &SketchDocumentArchive,
    ) -> Option<SketchLayer> {
        if let Some(cached) =
            crate::render::SketchRenderCache::global().cached_expanded_symbol(instance, document)
        {
            return Some(cached);
        }
        let symbol_id = instance.symbol_id.as_deref()?;
        let master = document.symbol_master_for_id(symbol_id)?;

        let mut expanded = master;
        expanded.frame.x = instance.frame.x;
        expanded.frame.y = instance.frame.y;

        let mut width_delta_total = 0.0;
        let mut height_delta_total = 0.0;

        for ov in &instance.override_values {
            Self::apply_override(
                ov,
                &mut expanded.layers,
                &mut width_delta_total,
                &mut height_delta_total,
            );
        }

        if let Some(layout) = &expanded.group_layout {
            if layout.is_smart_layout() {
                let axis = layout.axis.unwrap_or(0);
                let anchor = layout.layout_anchor.unwrap_or(0);
                if axis == 0 && width_delta_total.abs() > 0.5 {
                    let old_width = expanded.frame.width;
                    let new_width = (old_width + width_delta_total).max(layout.min_size.unwrap_or(20.0));
                    let actual_delta = new_width - old_width;
                    expanded.frame.width = new_width;

                    for child in &mut expanded.layers {
                        if (child.frame.width - old_width).abs() < 4.0 && child.frame.x <= 2.0 {
                            child.frame.width = new_width;
                        }
                    }
                    if anchor == 1 {
                        expanded.frame.x -= actual_delta * 0.5;
                    } else if anchor == 2 {
                        expanded.frame.x -= actual_delta;
                    }
                } else if axis == 1 && height_delta_total.abs() > 0.5 {
                    let old_height = expanded.frame.height;
                    let new_height =
                        (old_height + height_delta_total).max(layout.min_size.unwrap_or(20.0));
                    expanded.frame.height = new_height;
                }
            } else {
                expanded.frame.width = instance.frame.width;
                expanded.frame.height = instance.frame.height;
            }
        } else {
            expanded.frame.width = instance.frame.width;
            expanded.frame.height = instance.frame.height;
        }

        crate::render::SketchRenderCache::global()
            .store_expanded_symbol(expanded.clone(), instance, document);
        Some(expanded)
    }

    fn apply_override(
        ov: &SketchOverrideValue,
        layers: &mut [SketchLayer],
        width_delta: &mut f64,
        _height_delta: &mut f64,
    ) {
        let parts: Vec<&str> = ov.override_name.split('_').collect();
        let Some(prop_type) = parts.last().copied() else {
            return;
        };
        let path_part = ov
            .override_name
            .strip_suffix(&format!("_{}", prop_type))
            .unwrap_or(&ov.override_name);
        let target_id = path_part.split('/').last().unwrap_or(path_part);

        for layer in layers.iter_mut() {
            if layer.do_object_id == target_id {
                if prop_type == "stringValue" {
                    let old_text = layer
                        .attributed_string
                        .as_ref()
                        .map(|a| a.string.clone())
                        .unwrap_or_else(|| layer.name.clone());
                    let new_text = ov.value.clone();
                    let font_size = layer
                        .attributed_string
                        .as_ref()
                        .and_then(|a| a.attributes.first())
                        .map(|a| a.font_size)
                        .unwrap_or(14.0);
                    let avg_char_w = font_size * 0.56;
                    let delta_w =
                        ((new_text.chars().count() as isize - old_text.chars().count() as isize)
                            as f64)
                            * avg_char_w;
                    layer.frame.width = (layer.frame.width + delta_w).max(16.0);
                    *width_delta += delta_w;

                    if let Some(attr) = &mut layer.attributed_string {
                        attr.string = new_text.clone();
                        if let Some(first) = attr.attributes.first_mut() {
                            first.length = new_text.encode_utf16().count();
                        }
                    } else {
                        layer.attributed_string = Some(SketchAttributedString::new(
                            new_text,
                            "HelveticaNeue",
                            font_size,
                            SketchColor::BLACK,
                        ));
                    }
                } else if prop_type == "symbolID" {
                    layer.symbol_id = if ov.value.is_empty() {
                        None
                    } else {
                        Some(ov.value.clone())
                    };
                }
            }
            if !layer.layers.is_empty() {
                Self::apply_override(ov, &mut layer.layers, width_delta, _height_delta);
            }
        }
    }
}

// MARK: - Snap & Alignment Guides Engine (`SketchSnapEngine`)

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchSnapGuide {
    pub is_vertical: bool,
    pub position: f64,
    pub start: f64,
    pub end: f64,
    pub label: Option<String>,
}

pub struct SketchSnapEngine;

impl SketchSnapEngine {
    pub const SNAP_THRESHOLD: f64 = 5.0;

    pub fn snap_frame(
        moving_frame: SketchRect,
        siblings: &[SketchLayer],
        excluding_ids: &[String],
    ) -> (SketchRect, Vec<SketchSnapGuide>) {
        let mut adjusted = moving_frame;
        let mut guides = Vec::new();

        for sib in siblings {
            if !sib.is_visible || excluding_ids.contains(&sib.do_object_id) {
                continue;
            }
            let sf = sib.frame;

            let x_candidates = [
                (adjusted.min_x(), sf.min_x()),
                (adjusted.mid_x(), sf.mid_x()),
                (adjusted.max_x(), sf.max_x()),
                (adjusted.min_x(), sf.max_x()),
                (adjusted.max_x(), sf.min_x()),
            ];
            for (m_val, s_val) in x_candidates {
                let diff = s_val - m_val;
                if diff.abs() <= Self::SNAP_THRESHOLD {
                    adjusted.x += diff;
                    guides.push(SketchSnapGuide {
                        is_vertical: true,
                        position: s_val,
                        start: adjusted.min_y().min(sf.min_y()),
                        end: adjusted.max_y().max(sf.max_y()),
                        label: None,
                    });
                    break;
                }
            }

            let y_candidates = [
                (adjusted.min_y(), sf.min_y()),
                (adjusted.mid_y(), sf.mid_y()),
                (adjusted.max_y(), sf.max_y()),
                (adjusted.min_y(), sf.max_y()),
                (adjusted.max_y(), sf.min_y()),
            ];
            for (m_val, s_val) in y_candidates {
                let diff = s_val - m_val;
                if diff.abs() <= Self::SNAP_THRESHOLD {
                    adjusted.y += diff;
                    guides.push(SketchSnapGuide {
                        is_vertical: false,
                        position: s_val,
                        start: adjusted.min_x().min(sf.min_x()),
                        end: adjusted.max_x().max(sf.max_x()),
                        label: None,
                    });
                    break;
                }
            }
        }

        (adjusted, guides)
    }

    pub fn tidy_layers(layers: &mut [SketchLayer], selected_ids: &[String], spacing: f64) {
        let mut indices: Vec<usize> = layers
            .iter()
            .enumerate()
            .filter(|(_, l)| selected_ids.contains(&l.do_object_id))
            .map(|(i, _)| i)
            .collect();
        if indices.len() < 2 {
            return;
        }
        indices.sort_by(|&a, &b| {
            layers[a]
                .frame
                .x
                .partial_cmp(&layers[b].frame.x)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let mut current_x = layers[indices[0]].frame.x;
        let base_y = layers[indices[0]].frame.y;
        for idx in indices {
            layers[idx].frame.x = current_x;
            layers[idx].frame.y = base_y;
            current_x += layers[idx].frame.width + spacing;
        }
    }
}
