use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;

// MARK: - 2D Geometry Primitives & Unit Coordinate Point String Parser ("{0.5, 0.25}")

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
pub struct Point2D {
    pub x: f64,
    pub y: f64,
}

impl Point2D {
    pub const ZERO: Point2D = Point2D { x: 0.0, y: 0.0 };
    pub fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

pub struct SketchPointString;

impl SketchPointString {
    pub fn parse(s: &str, fallback: Point2D) -> Point2D {
        let trimmed = s.trim().trim_start_matches('{').trim_end_matches('}');
        let mut parts = trimmed.split(',');
        let Some(xs) = parts.next() else { return fallback };
        let Some(ys) = parts.next() else { return fallback };
        let Ok(x) = xs.trim().parse::<f64>() else { return fallback };
        let Ok(y) = ys.trim().parse::<f64>() else { return fallback };
        Point2D { x, y }
    }

    pub fn format(pt: Point2D) -> String {
        fn clean(v: f64) -> String {
            if (v - v.round()).abs() < 1e-9 {
                format!("{}", v.round() as i64)
            } else {
                format!("{:.10}", v)
                    .trim_end_matches('0')
                    .trim_end_matches('.')
                    .to_string()
            }
        }
        format!("{{{}, {}}}", clean(pt.x), clean(pt.y))
    }

    /// Reconstructs `_BCPointConvertFromUnitCoordinates` from `SketchModel` (`MSBezierBuilder::buildV1CGPath:`)
    pub fn convert_from_unit(unit: Point2D, rect: SketchRect) -> Point2D {
        Point2D {
            x: rect.x + unit.x * rect.width,
            y: rect.y + unit.y * rect.height,
        }
    }

    pub fn convert_to_unit(point: Point2D, rect: SketchRect) -> Point2D {
        let w = rect.width.max(0.0001);
        let h = rect.height.max(0.0001);
        Point2D {
            x: (point.x - rect.x) / w,
            y: (point.y - rect.y) / h,
        }
    }
}

// MARK: - Enums Matching SketchModel Constants

/// Matches `MSBooleanOperation` in `MSPath::booleanOp:withPath:` (`0x138c5c` in `SketchModel`)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(i32)]
pub enum SketchBooleanOperation {
    None = -1,
    Union = 0,
    Subtract = 1,
    Intersect = 2,
    Difference = 3,
}

impl SketchBooleanOperation {
    pub fn from_i32(v: i32) -> Self {
        match v {
            0 => Self::Union,
            1 => Self::Subtract,
            2 => Self::Intersect,
            3 => Self::Difference,
            _ => Self::None,
        }
    }

    pub fn as_i32(self) -> i32 {
        self as i32
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::None => "None",
            Self::Union => "Union",
            Self::Subtract => "Subtract",
            Self::Intersect => "Intersect",
            Self::Difference => "Difference",
        }
    }
}

/// Matches `MSCurveMode` in `SketchModel` (`MSCurvePoint`)
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[repr(i32)]
pub enum SketchCurveMode {
    None = 0,
    Straight = 1,
    Mirrored = 2,
    Asymmetric = 3,
    Disconnected = 4,
}

impl SketchCurveMode {
    pub fn from_i32(v: i32) -> Self {
        match v {
            0 => Self::None,
            1 => Self::Straight,
            2 => Self::Mirrored,
            3 => Self::Asymmetric,
            4 => Self::Disconnected,
            _ => Self::Straight,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SketchLayerKind {
    Page,
    Artboard,
    SymbolMaster,
    SymbolInstance,
    Group,
    ShapeGroup,
    Rectangle,
    Oval,
    ShapePath,
    Polygon,
    Star,
    Triangle,
    Text,
    Bitmap,
    Slice,
    Hotspot,
}

impl SketchLayerKind {
    pub fn from_class_name(cls: &str) -> Self {
        match cls {
            "page" => Self::Page,
            "artboard" => Self::Artboard,
            "symbolMaster" => Self::SymbolMaster,
            "symbolInstance" => Self::SymbolInstance,
            "group" => Self::Group,
            "shapeGroup" => Self::ShapeGroup,
            "rectangle" => Self::Rectangle,
            "oval" => Self::Oval,
            "shapePath" => Self::ShapePath,
            "polygon" => Self::Polygon,
            "star" => Self::Star,
            "triangle" => Self::Triangle,
            "text" => Self::Text,
            "bitmap" => Self::Bitmap,
            "slice" => Self::Slice,
            "MSImmutableHotspotLayer" => Self::Hotspot,
            _ => Self::Group,
        }
    }

    pub fn class_name(self) -> &'static str {
        match self {
            Self::Page => "page",
            Self::Artboard => "artboard",
            Self::SymbolMaster => "symbolMaster",
            Self::SymbolInstance => "symbolInstance",
            Self::Group => "group",
            Self::ShapeGroup => "shapeGroup",
            Self::Rectangle => "rectangle",
            Self::Oval => "oval",
            Self::ShapePath => "shapePath",
            Self::Polygon => "polygon",
            Self::Star => "star",
            Self::Triangle => "triangle",
            Self::Text => "text",
            Self::Bitmap => "bitmap",
            Self::Slice => "slice",
            Self::Hotspot => "MSImmutableHotspotLayer",
        }
    }
}

// MARK: - Geometry & Curve Point

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct SketchRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
    pub constrain_proportions: bool,
}

impl Default for SketchRect {
    fn default() -> Self {
        Self {
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 100.0,
            constrain_proportions: false,
        }
    }
}

impl SketchRect {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self {
            x,
            y,
            width,
            height,
            constrain_proportions: false,
        }
    }

    pub fn min_x(&self) -> f64 {
        self.x
    }
    pub fn min_y(&self) -> f64 {
        self.y
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.width * 0.5
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.height * 0.5
    }

    pub fn intersects(&self, other: &SketchRect) -> bool {
        self.min_x() <= other.max_x()
            && self.max_x() >= other.min_x()
            && self.min_y() <= other.max_y()
            && self.max_y() >= other.min_y()
    }

    pub fn inset_by(&self, dx: f64, dy: f64) -> SketchRect {
        SketchRect::new(
            self.x + dx,
            self.y + dy,
            (self.width - 2.0 * dx).max(0.0),
            (self.height - 2.0 * dy).max(0.0),
        )
    }

    pub fn offset_by(&self, dx: f64, dy: f64) -> SketchRect {
        SketchRect::new(self.x + dx, self.y + dy, self.width, self.height)
    }

    pub fn union(&self, other: &SketchRect) -> SketchRect {
        let min_x = self.min_x().min(other.min_x());
        let min_y = self.min_y().min(other.min_y());
        let max_x = self.max_x().max(other.max_x());
        let max_y = self.max_y().max(other.max_y());
        SketchRect::new(min_x, min_y, max_x - min_x, max_y - min_y)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchCurvePoint {
    pub corner_radius: f64,
    pub curve_from: String,
    pub curve_to: String,
    pub has_curve_from: bool,
    pub has_curve_to: bool,
    pub curve_mode: i32,
    pub point: String,
}

impl SketchCurvePoint {
    pub fn new(
        point: Point2D,
        curve_from: Option<Point2D>,
        curve_to: Option<Point2D>,
        has_curve_from: bool,
        has_curve_to: bool,
        curve_mode: SketchCurveMode,
        corner_radius: f64,
    ) -> Self {
        Self {
            point: SketchPointString::format(point),
            curve_from: SketchPointString::format(curve_from.unwrap_or(point)),
            curve_to: SketchPointString::format(curve_to.unwrap_or(point)),
            has_curve_from,
            has_curve_to,
            curve_mode: curve_mode as i32,
            corner_radius,
        }
    }

    pub fn straight(point: Point2D, corner_radius: f64) -> Self {
        Self::new(
            point,
            None,
            None,
            false,
            false,
            SketchCurveMode::Straight,
            corner_radius,
        )
    }

    pub fn unit_point(&self) -> Point2D {
        SketchPointString::parse(&self.point, Point2D::ZERO)
    }

    pub fn unit_curve_from(&self) -> Point2D {
        SketchPointString::parse(&self.curve_from, self.unit_point())
    }

    pub fn unit_curve_to(&self) -> Point2D {
        SketchPointString::parse(&self.curve_to, self.unit_point())
    }
}

// MARK: - Colors, Gradients & Styling

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct SketchColor {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub alpha: f64,
}

impl SketchColor {
    pub const fn new(red: f64, green: f64, blue: f64, alpha: f64) -> Self {
        Self {
            red,
            green,
            blue,
            alpha,
        }
    }

    pub const WHITE: SketchColor = SketchColor::new(1.0, 1.0, 1.0, 1.0);
    pub const BLACK: SketchColor = SketchColor::new(0.0, 0.0, 0.0, 1.0);
    pub const SKETCH_BLUE: SketchColor = SketchColor::new(0.0078, 0.4784, 1.0, 1.0);
    pub const DEFAULT_FILL: SketchColor = SketchColor::new(0.847, 0.847, 0.847, 1.0);
    pub const DEFAULT_BORDER: SketchColor = SketchColor::new(0.592, 0.592, 0.592, 1.0);

    pub fn hex_string(&self) -> String {
        let r = (self.red.clamp(0.0, 1.0) * 255.0).round() as u8;
        let g = (self.green.clamp(0.0, 1.0) * 255.0).round() as u8;
        let b = (self.blue.clamp(0.0, 1.0) * 255.0).round() as u8;
        format!("{:02X}{:02X}{:02X}", r, g, b)
    }

    pub fn from_hex(hex: &str, alpha: f64) -> Option<Self> {
        let clean = hex.trim().trim_start_matches('#');
        if clean.len() != 6 {
            return None;
        }
        let val = u32::from_str_radix(clean, 16).ok()?;
        Some(Self {
            red: ((val >> 16) & 0xFF) as f64 / 255.0,
            green: ((val >> 8) & 0xFF) as f64 / 255.0,
            blue: (val & 0xFF) as f64 / 255.0,
            alpha,
        })
    }

    pub fn to_rgba8(&self) -> [u8; 4] {
        [
            (self.red.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.green.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.blue.clamp(0.0, 1.0) * 255.0).round() as u8,
            (self.alpha.clamp(0.0, 1.0) * 255.0).round() as u8,
        ]
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchGradientStop {
    pub color: SketchColor,
    pub position: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchGradient {
    pub gradient_type: i32,
    pub from: String,
    pub to: String,
    pub elipse_length: f64,
    pub stops: Vec<SketchGradientStop>,
}

impl SketchGradient {
    pub fn from_point(&self) -> Point2D {
        SketchPointString::parse(&self.from, Point2D::new(0.5, 0.0))
    }

    pub fn to_point(&self) -> Point2D {
        SketchPointString::parse(&self.to, Point2D::new(0.5, 1.0))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct SketchGraphicsContextSettings {
    pub blend_mode: i32,
    pub opacity: f64,
}

impl Default for SketchGraphicsContextSettings {
    fn default() -> Self {
        Self {
            blend_mode: 0,
            opacity: 1.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchFill {
    pub is_enabled: bool,
    pub fill_type: i32,
    pub color: SketchColor,
    pub gradient: Option<SketchGradient>,
    pub context_settings: SketchGraphicsContextSettings,
    pub noise_index: i32,
    pub noise_intensity: f64,
    pub pattern_fill_type: i32,
    pub pattern_tile_scale: f64,
}

impl SketchFill {
    pub fn solid(color: SketchColor) -> Self {
        Self {
            is_enabled: true,
            fill_type: 0,
            color,
            gradient: None,
            context_settings: SketchGraphicsContextSettings::default(),
            noise_index: 0,
            noise_intensity: 0.0,
            pattern_fill_type: 1,
            pattern_tile_scale: 1.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchBorder {
    pub is_enabled: bool,
    pub fill_type: i32,
    pub color: SketchColor,
    pub gradient: Option<SketchGradient>,
    pub context_settings: SketchGraphicsContextSettings,
    pub position: i32, // 0 = center, 1 = inside, 2 = outside
    pub thickness: f64,
}

impl SketchBorder {
    pub fn solid(color: SketchColor, position: i32, thickness: f64) -> Self {
        Self {
            is_enabled: true,
            fill_type: 0,
            color,
            gradient: None,
            context_settings: SketchGraphicsContextSettings::default(),
            position,
            thickness,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchBorderOptions {
    pub is_enabled: bool,
    pub dash_pattern: Vec<f64>,
    pub line_cap_style: i32,
    pub line_join_style: i32,
}

impl Default for SketchBorderOptions {
    fn default() -> Self {
        Self {
            is_enabled: true,
            dash_pattern: Vec::new(),
            line_cap_style: 0,
            line_join_style: 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchShadow {
    pub is_enabled: bool,
    pub blur_radius: f64,
    pub offset_x: f64,
    pub offset_y: f64,
    pub spread: f64,
    pub color: SketchColor,
    pub context_settings: SketchGraphicsContextSettings,
    pub is_inner: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchBlur {
    pub is_enabled: bool,
    pub center: String,
    pub motion_angle: f64,
    pub radius: f64,
    pub saturation: f64,
    pub blur_type: i32,
}

impl Default for SketchBlur {
    fn default() -> Self {
        Self {
            is_enabled: false,
            center: "{0.5, 0.5}".to_string(),
            motion_angle: 0.0,
            radius: 10.0,
            saturation: 1.0,
            blur_type: 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchStyle {
    pub do_object_id: String,
    pub fills: Vec<SketchFill>,
    pub borders: Vec<SketchBorder>,
    pub shadows: Vec<SketchShadow>,
    pub inner_shadows: Vec<SketchShadow>,
    pub border_options: SketchBorderOptions,
    pub blur: SketchBlur,
    pub context_settings: SketchGraphicsContextSettings,
    pub miter_limit: f64,
    pub start_marker_type: i32,
    pub end_marker_type: i32,
    pub winding_rule: i32,
}

impl Default for SketchStyle {
    fn default() -> Self {
        Self {
            do_object_id: new_sketch_id(),
            fills: Vec::new(),
            borders: Vec::new(),
            shadows: Vec::new(),
            inner_shadows: Vec::new(),
            border_options: SketchBorderOptions::default(),
            blur: SketchBlur::default(),
            context_settings: SketchGraphicsContextSettings::default(),
            miter_limit: 10.0,
            start_marker_type: 0,
            end_marker_type: 0,
            winding_rule: 1,
        }
    }
}

impl SketchStyle {
    pub fn first_enabled_fill(&self) -> Option<&SketchFill> {
        self.fills.iter().find(|f| f.is_enabled)
    }

    pub fn first_enabled_border(&self) -> Option<&SketchBorder> {
        self.borders.iter().find(|b| b.is_enabled)
    }

    pub fn first_enabled_shadow(&self) -> Option<&SketchShadow> {
        self.shadows.iter().find(|s| s.is_enabled)
    }
}

// MARK: - Typography, Smart Layout, Overrides & Export Options

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchStringAttribute {
    pub location: usize,
    pub length: usize,
    pub font_name: String,
    pub font_size: f64,
    pub color: SketchColor,
    pub alignment: i32,
    pub kerning: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchAttributedString {
    pub string: String,
    pub attributes: Vec<SketchStringAttribute>,
}

impl SketchAttributedString {
    pub fn new(string: impl Into<String>, font_name: &str, font_size: f64, color: SketchColor) -> Self {
        let s = string.into();
        let len = s.encode_utf16().count();
        Self {
            string: s,
            attributes: vec![SketchStringAttribute {
                location: 0,
                length: len,
                font_name: font_name.to_string(),
                font_size,
                color,
                alignment: 0,
                kerning: None,
            }],
        }
    }
}

/// Matches `MSImmutableInferredGroupLayout` and `MSImmutableFreeformGroupLayout` in `SketchModel`
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchGroupLayout {
    pub class_name: String,
    pub axis: Option<i32>,          // 0 = horizontal, 1 = vertical
    pub layout_anchor: Option<i32>, // 0 = start (Left/Top), 1 = center, 2 = end (Right/Bottom)
    pub min_size: Option<f64>,
    pub max_size: Option<f64>,
}

impl SketchGroupLayout {
    pub fn freeform() -> Self {
        Self {
            class_name: "MSImmutableFreeformGroupLayout".to_string(),
            axis: None,
            layout_anchor: None,
            min_size: None,
            max_size: None,
        }
    }

    pub fn smart(axis: i32, layout_anchor: i32) -> Self {
        Self {
            class_name: "MSImmutableInferredGroupLayout".to_string(),
            axis: Some(axis),
            layout_anchor: Some(layout_anchor),
            min_size: Some(0.0),
            max_size: Some(0.0),
        }
    }

    pub fn is_smart_layout(&self) -> bool {
        self.class_name == "MSImmutableInferredGroupLayout"
    }

    pub fn display_title(&self) -> &'static str {
        if !self.is_smart_layout() {
            return "None (Freeform)";
        }
        match (self.axis.unwrap_or(0), self.layout_anchor.unwrap_or(0)) {
            (0, 0) => "Horizontally: Left to Right",
            (0, 1) => "Horizontally: From Center",
            (0, 2) => "Horizontally: Right to Left",
            (1, 0) => "Vertically: Top to Bottom",
            (1, 1) => "Vertically: From Middle",
            (1, 2) => "Vertically: Bottom to Top",
            _ => "Smart Layout",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchOverrideValue {
    pub override_name: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchOverrideProperty {
    pub override_name: String,
    pub can_override: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchExportFormat {
    pub scale: f64,
    pub file_format: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct SketchExportOptions {
    pub export_formats: Vec<SketchExportFormat>,
    pub should_trim: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchFileReference {
    pub ref_class: String,
    pub ref_path: String,
}

// MARK: - Unified Sketch Layer Node

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchLayer {
    pub class_name: String,
    pub do_object_id: String,
    pub name: String,
    pub name_is_fixed: bool,
    pub is_visible: bool,
    pub is_locked: bool,
    pub is_flipped_horizontal: bool,
    pub is_flipped_vertical: bool,
    pub is_fixed_to_viewport: bool,
    pub rotation: f64,
    pub boolean_operation: SketchBooleanOperation,
    pub frame: SketchRect,
    pub style: SketchStyle,
    pub export_options: SketchExportOptions,
    pub resizing_constraint: i32,
    pub resizing_type: i32,
    pub has_clipping_mask: bool,
    pub clipping_mask_mode: i32,
    pub should_break_mask_chain: bool,
    pub layer_list_expanded_type: i32,
    pub layers: Vec<SketchLayer>,
    pub has_click_through: bool,
    pub group_layout: Option<SketchGroupLayout>,
    pub has_background_color: bool,
    pub background_color: Option<SketchColor>,
    pub include_background_color_in_export: bool,
    pub is_closed: bool,
    pub edited: bool,
    pub point_radius_behaviour: i32,
    pub fixed_radius: f64,
    pub points: Vec<SketchCurvePoint>,
    pub attributed_string: Option<SketchAttributedString>,
    pub text_behaviour: i32,
    pub symbol_id: Option<String>,
    pub override_values: Vec<SketchOverrideValue>,
    pub override_properties: Vec<SketchOverrideProperty>,
    pub allows_overrides: bool,
    pub scale: f64,
    pub horizontal_spacing: f64,
    pub vertical_spacing: f64,
    pub image_ref: Option<SketchFileReference>,
    pub raw_json: Map<String, Value>,
}

impl SketchLayer {
    pub fn new(kind: SketchLayerKind, name: impl Into<String>, frame: SketchRect) -> Self {
        Self {
            class_name: kind.class_name().to_string(),
            do_object_id: new_sketch_id(),
            name: name.into(),
            name_is_fixed: false,
            is_visible: true,
            is_locked: false,
            is_flipped_horizontal: false,
            is_flipped_vertical: false,
            is_fixed_to_viewport: false,
            rotation: 0.0,
            boolean_operation: SketchBooleanOperation::None,
            frame,
            style: SketchStyle::default(),
            export_options: SketchExportOptions::default(),
            resizing_constraint: 63,
            resizing_type: 0,
            has_clipping_mask: false,
            clipping_mask_mode: 0,
            should_break_mask_chain: false,
            layer_list_expanded_type: 0,
            layers: Vec::new(),
            has_click_through: false,
            group_layout: None,
            has_background_color: false,
            background_color: None,
            include_background_color_in_export: true,
            is_closed: true,
            edited: false,
            point_radius_behaviour: 1,
            fixed_radius: 0.0,
            points: Vec::new(),
            attributed_string: None,
            text_behaviour: 0,
            symbol_id: None,
            override_values: Vec::new(),
            override_properties: Vec::new(),
            allows_overrides: true,
            scale: 1.0,
            horizontal_spacing: 0.0,
            vertical_spacing: 0.0,
            image_ref: None,
            raw_json: Map::new(),
        }
    }

    pub fn kind(&self) -> SketchLayerKind {
        SketchLayerKind::from_class_name(&self.class_name)
    }

    pub fn make_rectangle(
        name: &str,
        frame: SketchRect,
        corner_radius: f64,
        fill_color: SketchColor,
        border_color: SketchColor,
    ) -> Self {
        let mut layer = Self::new(SketchLayerKind::Rectangle, name, frame);
        layer.fixed_radius = corner_radius;
        layer.points = vec![
            SketchCurvePoint::straight(Point2D::new(0.0, 0.0), corner_radius),
            SketchCurvePoint::straight(Point2D::new(1.0, 0.0), corner_radius),
            SketchCurvePoint::straight(Point2D::new(1.0, 1.0), corner_radius),
            SketchCurvePoint::straight(Point2D::new(0.0, 1.0), corner_radius),
        ];
        layer.style.fills = vec![SketchFill::solid(fill_color)];
        layer.style.borders = vec![SketchBorder::solid(border_color, 1, 1.0)];
        layer
    }

    pub fn make_oval(
        name: &str,
        frame: SketchRect,
        fill_color: SketchColor,
        border_color: SketchColor,
    ) -> Self {
        let k = 0.2761423749;
        let mut layer = Self::new(SketchLayerKind::Oval, name, frame);
        layer.points = vec![
            SketchCurvePoint::new(
                Point2D::new(0.5, 0.0),
                Some(Point2D::new(0.5 + k, 0.0)),
                Some(Point2D::new(0.5 - k, 0.0)),
                true,
                true,
                SketchCurveMode::Mirrored,
                0.0,
            ),
            SketchCurvePoint::new(
                Point2D::new(1.0, 0.5),
                Some(Point2D::new(1.0, 0.5 + k)),
                Some(Point2D::new(1.0, 0.5 - k)),
                true,
                true,
                SketchCurveMode::Mirrored,
                0.0,
            ),
            SketchCurvePoint::new(
                Point2D::new(0.5, 1.0),
                Some(Point2D::new(0.5 - k, 1.0)),
                Some(Point2D::new(0.5 + k, 1.0)),
                true,
                true,
                SketchCurveMode::Mirrored,
                0.0,
            ),
            SketchCurvePoint::new(
                Point2D::new(0.0, 0.5),
                Some(Point2D::new(0.0, 0.5 - k)),
                Some(Point2D::new(0.0, 0.5 + k)),
                true,
                true,
                SketchCurveMode::Mirrored,
                0.0,
            ),
        ];
        layer.style.fills = vec![SketchFill::solid(fill_color)];
        layer.style.borders = vec![SketchBorder::solid(border_color, 1, 1.0)];
        layer
    }

    pub fn make_polygon(name: &str, sides: usize, frame: SketchRect) -> Self {
        let count = sides.max(3);
        let mut layer = Self::new(SketchLayerKind::Polygon, name, frame);
        for i in 0..count {
            let angle = -std::f64::consts::FRAC_PI_2
                + (2.0 * std::f64::consts::PI * (i as f64)) / (count as f64);
            let ux = 0.5 + 0.5 * angle.cos();
            let uy = 0.5 + 0.5 * angle.sin();
            layer
                .points
                .push(SketchCurvePoint::straight(Point2D::new(ux, uy), 0.0));
        }
        layer.style.fills = vec![SketchFill::solid(SketchColor::new(0.16, 0.78, 0.55, 1.0))];
        layer.style.borders = vec![SketchBorder::solid(
            SketchColor::new(0.10, 0.58, 0.40, 1.0),
            1,
            1.0,
        )];
        layer
    }

    pub fn make_star(name: &str, points_count: usize, inner_ratio: f64, frame: SketchRect) -> Self {
        let count = points_count.max(3);
        let mut layer = Self::new(SketchLayerKind::Star, name, frame);
        for i in 0..(count * 2) {
            let r = if i % 2 == 0 { 0.5 } else { 0.5 * inner_ratio };
            let angle = -std::f64::consts::FRAC_PI_2
                + (std::f64::consts::PI * (i as f64)) / (count as f64);
            let ux = 0.5 + r * angle.cos();
            let uy = 0.5 + r * angle.sin();
            layer
                .points
                .push(SketchCurvePoint::straight(Point2D::new(ux, uy), 0.0));
        }
        layer.style.fills = vec![SketchFill::solid(SketchColor::new(0.98, 0.75, 0.18, 1.0))];
        layer.style.borders = vec![SketchBorder::solid(
            SketchColor::new(0.85, 0.58, 0.05, 1.0),
            1,
            1.0,
        )];
        layer
    }

    pub fn make_triangle(name: &str, frame: SketchRect) -> Self {
        let mut layer = Self::new(SketchLayerKind::Triangle, name, frame);
        layer.points = vec![
            SketchCurvePoint::straight(Point2D::new(0.5, 0.0), 0.0),
            SketchCurvePoint::straight(Point2D::new(1.0, 1.0), 0.0),
            SketchCurvePoint::straight(Point2D::new(0.0, 1.0), 0.0),
        ];
        layer.style.fills = vec![SketchFill::solid(SketchColor::new(0.92, 0.28, 0.45, 1.0))];
        layer.style.borders = vec![SketchBorder::solid(
            SketchColor::new(0.75, 0.16, 0.32, 1.0),
            1,
            1.0,
        )];
        layer
    }

    pub fn make_text(
        name: &str,
        text: &str,
        frame: SketchRect,
        font_size: f64,
        color: SketchColor,
    ) -> Self {
        let mut layer = Self::new(SketchLayerKind::Text, name, frame);
        layer.attributed_string = Some(SketchAttributedString::new(
            text,
            "HelveticaNeue",
            font_size,
            color,
        ));
        layer
    }

    pub fn make_artboard(name: &str, frame: SketchRect, layers: Vec<SketchLayer>) -> Self {
        let mut layer = Self::new(SketchLayerKind::Artboard, name, frame);
        layer.layers = layers;
        layer.group_layout = Some(SketchGroupLayout::freeform());
        layer.has_background_color = true;
        layer.background_color = Some(SketchColor::WHITE);
        layer
    }
}

// MARK: - Document Archive Container & Versioned Preset Archive

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchDocumentArchive {
    pub meta: Map<String, Value>,
    pub user: Map<String, Value>,
    pub document_json: Map<String, Value>,
    pub pages: Vec<SketchLayer>,
    pub current_page_index: usize,
    #[serde(skip)]
    pub images: HashMap<String, Vec<u8>>,
    #[serde(skip)]
    pub preview_png: Option<Vec<u8>>,
}

impl Default for SketchDocumentArchive {
    fn default() -> Self {
        let mut page = SketchLayer::new(
            SketchLayerKind::Page,
            "Page 1",
            SketchRect::new(0.0, 0.0, 0.0, 0.0),
        );
        page.layers = vec![SketchLayer::make_artboard(
            "Artboard 1",
            SketchRect::new(40.0, 40.0, 480.0, 320.0),
            vec![
                SketchLayer::make_rectangle(
                    "Hero Card",
                    SketchRect::new(40.0, 40.0, 400.0, 240.0),
                    16.0,
                    SketchColor::new(0.96, 0.97, 1.0, 1.0),
                    SketchColor::SKETCH_BLUE,
                ),
                SketchLayer::make_text(
                    "Heading",
                    "OpenSketch for Windows",
                    SketchRect::new(72.0, 80.0, 320.0, 32.0),
                    24.0,
                    SketchColor::new(0.1, 0.12, 0.18, 1.0),
                ),
            ],
        )];
        let mut user = Map::new();
        user.insert(
            "document".to_string(),
            json!({ "pageListHeight": 85, "pageListCollapsed": 0 }),
        );
        Self {
            meta: Self::default_meta(),
            user,
            document_json: Map::new(),
            pages: vec![page],
            current_page_index: 0,
            images: HashMap::new(),
            preview_png: None,
        }
    }
}

impl SketchDocumentArchive {
    /// Reconstructs `+[MSArchiveHeader metadataForNewHeader]` (`0xae93c` in `SketchModel`)
    /// Sets `version = 139` (`0x8b`), `compatibilityVersion = 99`, `coeditCompatibilityVersion = 139` (`0x8b`).
    pub fn default_meta() -> Map<String, Value> {
        let val = json!({
            "commit": "ce74b0da7bf09be4d73153fa5cf21922ab1be51d",
            "pagesAndArtboards": {},
            "version": 139,
            "compatibilityVersion": 99,
            "coeditCompatibilityVersion": 139,
            "app": "com.bohemiancoding.sketch3",
            "autosaved": 0,
            "variant": "NONAPPSTORE",
            "created": {
                "commit": "ce74b0da7bf09be4d73153fa5cf21922ab1be51d",
                "appVersion": "82.1",
                "build": 137007,
                "app": "com.bohemiancoding.sketch3",
                "compatibilityVersion": 99,
                "coeditCompatibilityVersion": 139,
                "version": 139,
                "variant": "NONAPPSTORE"
            },
            "saveHistory": ["NONAPPSTORE.137007"],
            "appVersion": "82.1",
            "build": 137007
        });
        val.as_object().cloned().unwrap_or_default()
    }

    pub fn document_id(&self) -> String {
        self.document_json
            .get("do_objectID")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(|| {
                self.pages
                    .first()
                    .map(|p| p.do_object_id.clone())
                    .unwrap_or_else(|| "default-doc".to_string())
            })
    }

    pub fn all_symbol_masters(&self) -> Vec<SketchLayer> {
        let mut masters = Vec::new();
        fn walk(layer: &SketchLayer, out: &mut Vec<SketchLayer>) {
            if layer.kind() == SketchLayerKind::SymbolMaster {
                out.push(layer.clone());
            }
            for child in &layer.layers {
                walk(child, out);
            }
        }
        for page in &self.pages {
            walk(page, &mut masters);
        }
        masters
    }

    pub fn symbol_master_for_id(&self, symbol_id: &str) -> Option<SketchLayer> {
        crate::render::SketchRenderCache::global().symbol_master(symbol_id, self)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchVersionedPresetArchive {
    pub version: i64,
    pub meta: Map<String, Value>,
    pub archive_root: Map<String, Value>,
    pub colors: Vec<SketchColor>,
    pub gradients: Vec<SketchGradient>,
}

pub fn new_sketch_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0x8210_0001);
    let seq = COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("82137007-4A2B-4C9E-9F00-{:012X}", seq)
}
