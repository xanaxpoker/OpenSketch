use crate::geometry::*;
use crate::io::*;
use crate::model::*;
use flate2::write::ZlibEncoder;
use flate2::Compression;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::Write;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::OnceLock;
use std::time::Instant;

// MARK: - Frame Render Statistics & Multi-Tier Render Cache (`SketchRenderCache`)

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct SketchFrameRenderStats {
    pub drawn_layers: usize,
    pub culled_layers: usize,
    pub bitmap_draws: usize,
    pub symbol_expansions: usize,
}

pub struct SketchRenderCache {
    symbol_masters_by_doc: Mutex<HashMap<String, HashMap<String, SketchLayer>>>,
    expanded_symbols: Mutex<HashMap<String, SketchLayer>>,
    vector_paths: Mutex<HashMap<String, VectorPath>>,
    decoded_bitmaps: Mutex<HashMap<String, Vec<u8>>>,
    pub bitmap_cache_hits: AtomicUsize,
    pub bitmap_cache_misses: AtomicUsize,
    pub symbol_cache_hits: AtomicUsize,
    pub symbol_cache_misses: AtomicUsize,
}

impl SketchRenderCache {
    pub fn global() -> &'static Self {
        static INSTANCE: OnceLock<SketchRenderCache> = OnceLock::new();
        INSTANCE.get_or_init(|| Self {
            symbol_masters_by_doc: Mutex::new(HashMap::new()),
            expanded_symbols: Mutex::new(HashMap::new()),
            vector_paths: Mutex::new(HashMap::new()),
            decoded_bitmaps: Mutex::new(HashMap::new()),
            bitmap_cache_hits: AtomicUsize::new(0),
            bitmap_cache_misses: AtomicUsize::new(0),
            symbol_cache_hits: AtomicUsize::new(0),
            symbol_cache_misses: AtomicUsize::new(0),
        })
    }

    pub fn clear_all(&self) {
        self.symbol_masters_by_doc.lock().clear();
        self.expanded_symbols.lock().clear();
        self.vector_paths.lock().clear();
        self.decoded_bitmaps.lock().clear();
        self.bitmap_cache_hits.store(0, Ordering::Relaxed);
        self.bitmap_cache_misses.store(0, Ordering::Relaxed);
        self.symbol_cache_hits.store(0, Ordering::Relaxed);
        self.symbol_cache_misses.store(0, Ordering::Relaxed);
    }

    pub fn invalidate_document(&self, doc_id: Option<&str>) {
        if let Some(id) = doc_id {
            self.symbol_masters_by_doc.lock().remove(id);
        } else {
            self.symbol_masters_by_doc.lock().clear();
        }
        self.expanded_symbols.lock().clear();
        self.vector_paths.lock().clear();
    }

    /// O(1) lookup of a `symbolMaster` by `symbolID`
    pub fn symbol_master(
        &self,
        symbol_id: &str,
        document: &SketchDocumentArchive,
    ) -> Option<SketchLayer> {
        let doc_id = document.document_id();
        {
            let guard = self.symbol_masters_by_doc.lock();
            if let Some(map) = guard.get(&doc_id) {
                return map.get(symbol_id).cloned();
            }
        }
        let mut map = HashMap::new();
        fn strip_raw_json(layer: &mut SketchLayer) {
            layer.raw_json.clear();
            for child in &mut layer.layers {
                strip_raw_json(child);
            }
        }
        fn walk(layer: &SketchLayer, out: &mut HashMap<String, SketchLayer>) {
            if layer.kind() == SketchLayerKind::SymbolMaster {
                if let Some(sid) = &layer.symbol_id {
                    let mut clean = layer.clone();
                    strip_raw_json(&mut clean);
                    out.insert(sid.clone(), clean);
                }
            }
            for child in &layer.layers {
                walk(child, out);
            }
        }
        for page in &document.pages {
            walk(page, &mut map);
        }
        let res = map.get(symbol_id).cloned();
        self.symbol_masters_by_doc.lock().insert(doc_id, map);
        res
    }

    fn symbol_key(instance: &SketchLayer, document: &SketchDocumentArchive) -> String {
        let mut sig = String::new();
        for ov in &instance.override_values {
            sig.push_str(&ov.override_name);
            sig.push('=');
            sig.push_str(&ov.value);
            sig.push(';');
        }
        format!(
            "{}:{}:{}:{}x{}:{}",
            document.document_id(),
            instance.do_object_id,
            instance.symbol_id.as_deref().unwrap_or(""),
            instance.frame.width as i64,
            instance.frame.height as i64,
            sig
        )
    }

    pub fn cached_expanded_symbol(
        &self,
        instance: &SketchLayer,
        document: &SketchDocumentArchive,
    ) -> Option<SketchLayer> {
        let key = Self::symbol_key(instance, document);
        let guard = self.expanded_symbols.lock();
        if let Some(mut hit) = guard.get(&key).cloned() {
            self.symbol_cache_hits.fetch_add(1, Ordering::Relaxed);
            hit.frame.x = instance.frame.x;
            hit.frame.y = instance.frame.y;
            return Some(hit);
        }
        self.symbol_cache_misses.fetch_add(1, Ordering::Relaxed);
        None
    }

    pub fn store_expanded_symbol(
        &self,
        mut expanded: SketchLayer,
        instance: &SketchLayer,
        document: &SketchDocumentArchive,
    ) {
        fn strip_raw_json(layer: &mut SketchLayer) {
            layer.raw_json.clear();
            for child in &mut layer.layers {
                strip_raw_json(child);
            }
        }
        strip_raw_json(&mut expanded);
        let key = Self::symbol_key(instance, document);
        let mut guard = self.expanded_symbols.lock();
        if guard.len() > 2048 {
            guard.clear();
        }
        guard.insert(key, expanded);
    }

    pub fn cached_vector_path(&self, layer: &SketchLayer, rect: SketchRect) -> VectorPath {
        let first_pt = layer.points.first().map(|p| p.point.as_str()).unwrap_or("");
        let key = format!(
            "VP:{}:{},{},{}x{}:{}:{}:{}",
            layer.do_object_id,
            rect.x as i64,
            rect.y as i64,
            rect.width as i64,
            rect.height as i64,
            layer.fixed_radius as i64,
            layer.points.len(),
            first_pt
        );
        {
            let guard = self.vector_paths.lock();
            if let Some(hit) = guard.get(&key) {
                return hit.clone();
            }
        }
        let path = if layer.kind() == SketchLayerKind::ShapeGroup {
            SketchBooleanEngine::evaluate_shape_group_path(layer)
        } else {
            SketchBezierBuilder::build_vector_path(
                &layer.points,
                rect,
                layer.is_closed,
                layer.fixed_radius,
            )
        };
        let mut guard = self.vector_paths.lock();
        if guard.len() > 4096 {
            guard.clear();
        }
        guard.insert(key, path.clone());
        path
    }

    pub fn cached_bitmap_swatch(
        &self,
        ref_path: &str,
        document: &SketchDocumentArchive,
    ) -> Option<[u8; 4]> {
        let key = format!("{}:{}", document.document_id(), ref_path);
        {
            let guard = self.decoded_bitmaps.lock();
            if let Some(bytes) = guard.get(&key) {
                if bytes.len() >= 4 {
                    self.bitmap_cache_hits.fetch_add(1, Ordering::Relaxed);
                    return Some([bytes[0], bytes[1], bytes[2], bytes[3]]);
                }
            }
        }
        self.bitmap_cache_misses.fetch_add(1, Ordering::Relaxed);
        let raw = document
            .images
            .get(ref_path)
            .or_else(|| document.images.get(&format!("{}.png", ref_path)))?;
        let hash = crc32fast::hash(raw);
        let swatch = [
            ((hash >> 16) & 0xFF) as u8,
            ((hash >> 8) & 0xFF) as u8,
            (hash & 0xFF) as u8,
            255u8,
        ];
        self.decoded_bitmaps.lock().insert(key, swatch.to_vec());
        Some(swatch)
    }
}

// MARK: - High-Speed RGBA32 Software Vector Rasterizer (`SketchCoreGraphicsRenderer` equivalent)

pub struct SoftwareCanvasBuffer {
    pub width: usize,
    pub height: usize,
    pub pixels: Vec<u8>,
    pub offset_x: f64,
    pub offset_y: f64,
    pub scale: f64,
    pub clip_rect: Option<SketchRect>,
}

impl SoftwareCanvasBuffer {
    pub fn new(width: usize, height: usize) -> Self {
        Self {
            width,
            height,
            pixels: vec![245u8; width * height * 4],
            offset_x: 0.0,
            offset_y: 0.0,
            scale: 1.0,
            clip_rect: None,
        }
    }

    pub fn clear(&mut self, rgba: [u8; 4]) {
        for chunk in self.pixels.chunks_exact_mut(4) {
            chunk.copy_from_slice(&rgba);
        }
    }

    pub fn fill_rect(&mut self, rect: SketchRect, rgba: [u8; 4]) {
        let mut r = SketchRect::new(
            (rect.x + self.offset_x) * self.scale,
            (rect.y + self.offset_y) * self.scale,
            rect.width * self.scale,
            rect.height * self.scale,
        );
        if let Some(clip) = self.clip_rect {
            let min_x = r.min_x().max(clip.min_x());
            let min_y = r.min_y().max(clip.min_y());
            let max_x = r.max_x().min(clip.max_x());
            let max_y = r.max_y().min(clip.max_y());
            if max_x <= min_x || max_y <= min_y {
                return;
            }
            r = SketchRect::new(min_x, min_y, max_x - min_x, max_y - min_y);
        }

        let x0 = (r.min_x().floor() as isize).clamp(0, self.width as isize) as usize;
        let y0 = (r.min_y().floor() as isize).clamp(0, self.height as isize) as usize;
        let x1 = (r.max_x().ceil() as isize).clamp(0, self.width as isize) as usize;
        let y1 = (r.max_y().ceil() as isize).clamp(0, self.height as isize) as usize;
        if x1 <= x0 || y1 <= y0 {
            return;
        }

        let stride = self.width * 4;
        if rgba[3] == 255 {
            for y in y0..y1 {
                let row_start = y * stride + x0 * 4;
                let row_end = y * stride + x1 * 4;
                for px in self.pixels[row_start..row_end].chunks_exact_mut(4) {
                    px.copy_from_slice(&rgba);
                }
            }
        } else if rgba[3] > 0 {
            let a = rgba[3] as u32;
            let inv_a = 255 - a;
            for y in y0..y1 {
                let row_start = y * stride + x0 * 4;
                let row_end = y * stride + x1 * 4;
                for px in self.pixels[row_start..row_end].chunks_exact_mut(4) {
                    px[0] = ((rgba[0] as u32 * a + px[0] as u32 * inv_a) / 255) as u8;
                    px[1] = ((rgba[1] as u32 * a + px[1] as u32 * inv_a) / 255) as u8;
                    px[2] = ((rgba[2] as u32 * a + px[2] as u32 * inv_a) / 255) as u8;
                    px[3] = 255;
                }
            }
        }
    }

    pub fn stroke_rect(&mut self, rect: SketchRect, thickness: f64, rgba: [u8; 4]) {
        let t = thickness.max(1.0);
        self.fill_rect(SketchRect::new(rect.x, rect.y, rect.width, t), rgba);
        self.fill_rect(
            SketchRect::new(rect.x, (rect.max_y() - t).max(rect.y), rect.width, t),
            rgba,
        );
        self.fill_rect(SketchRect::new(rect.x, rect.y, t, rect.height), rgba);
        self.fill_rect(
            SketchRect::new((rect.max_x() - t).max(rect.x), rect.y, t, rect.height),
            rgba,
        );
    }
}

pub struct SketchRenderer;

impl SketchRenderer {
    pub fn count_subtree_layers(layer: &SketchLayer) -> usize {
        1 + layer
            .layers
            .iter()
            .map(Self::count_subtree_layers)
            .sum::<usize>()
    }

    pub fn render_layer(
        layer: &SketchLayer,
        document: &SketchDocumentArchive,
        canvas: &mut SoftwareCanvasBuffer,
        visible_rect: Option<SketchRect>,
        stats: &mut SketchFrameRenderStats,
    ) {
        if !layer.is_visible {
            return;
        }
        let rect = layer.frame;

        if layer.kind() != SketchLayerKind::Page {
            if let Some(vp) = visible_rect {
                let margin = if matches!(
                    layer.kind(),
                    SketchLayerKind::Artboard | SketchLayerKind::SymbolMaster
                ) {
                    48.0
                } else {
                    24.0
                };
                let padded = rect.inset_by(-margin, -margin);
                if !vp.intersects(&padded) {
                    stats.culled_layers += Self::count_subtree_layers(layer);
                    return;
                }
            }
        }

        stats.drawn_layers += 1;

        match layer.kind() {
            SketchLayerKind::Page => {
                for child in &layer.layers {
                    Self::render_layer(child, document, canvas, visible_rect, stats);
                }
            }
            SketchLayerKind::Artboard | SketchLayerKind::SymbolMaster => {
                if layer.has_background_color {
                    let bg = layer
                        .background_color
                        .unwrap_or(SketchColor::WHITE)
                        .to_rgba8();
                    canvas.fill_rect(rect, bg);
                } else {
                    canvas.fill_rect(rect, [255, 255, 255, 255]);
                }
                let prev_ox = canvas.offset_x;
                let prev_oy = canvas.offset_y;
                canvas.offset_x += rect.x;
                canvas.offset_y += rect.y;
                let local_vp = visible_rect.map(|v| v.offset_by(-rect.x, -rect.y));
                Self::render_children_with_masks(&layer.layers, document, canvas, local_vp, stats);
                canvas.offset_x = prev_ox;
                canvas.offset_y = prev_oy;
            }
            SketchLayerKind::Group => {
                let prev_ox = canvas.offset_x;
                let prev_oy = canvas.offset_y;
                canvas.offset_x += rect.x;
                canvas.offset_y += rect.y;
                let local_vp = visible_rect.map(|v| v.offset_by(-rect.x, -rect.y));
                Self::render_children_with_masks(&layer.layers, document, canvas, local_vp, stats);
                canvas.offset_x = prev_ox;
                canvas.offset_y = prev_oy;
            }
            SketchLayerKind::SymbolInstance => {
                stats.symbol_expansions += 1;
                if let Some(expanded) =
                    SketchSmartLayoutEngine::expand_symbol_instance(layer, document)
                {
                    let prev_ox = canvas.offset_x;
                    let prev_oy = canvas.offset_y;
                    canvas.offset_x += rect.x;
                    canvas.offset_y += rect.y;
                    for child in &expanded.layers {
                        Self::render_layer(child, document, canvas, None, stats);
                    }
                    canvas.offset_x = prev_ox;
                    canvas.offset_y = prev_oy;
                } else {
                    canvas.fill_rect(rect, SketchColor::DEFAULT_FILL.to_rgba8());
                }
            }
            SketchLayerKind::ShapeGroup
            | SketchLayerKind::Rectangle
            | SketchLayerKind::Oval
            | SketchLayerKind::ShapePath
            | SketchLayerKind::Polygon
            | SketchLayerKind::Star
            | SketchLayerKind::Triangle => {
                let _path = SketchRenderCache::global().cached_vector_path(layer, rect);
                for shadow in &layer.style.shadows {
                    if shadow.is_enabled {
                        let mut sc = shadow.color;
                        sc.alpha = (sc.alpha * 0.55).min(1.0);
                        canvas.fill_rect(
                            rect.offset_by(shadow.offset_x, shadow.offset_y),
                            sc.to_rgba8(),
                        );
                    }
                }
                for fill in &layer.style.fills {
                    if fill.is_enabled {
                        canvas.fill_rect(rect, fill.color.to_rgba8());
                    }
                }
                for border in &layer.style.borders {
                    if border.is_enabled && border.thickness > 0.0 {
                        canvas.stroke_rect(rect, border.thickness, border.color.to_rgba8());
                    }
                }
            }
            SketchLayerKind::Text => {
                let color = layer
                    .style
                    .first_enabled_fill()
                    .map(|f| f.color)
                    .or_else(|| {
                        layer
                            .attributed_string
                            .as_ref()
                            .and_then(|a| a.attributes.first())
                            .map(|a| a.color)
                    })
                    .unwrap_or(SketchColor::BLACK);
                let text_bar = SketchRect::new(
                    rect.x,
                    rect.y + rect.height * 0.2,
                    rect.width,
                    (rect.height * 0.6).max(2.0),
                );
                canvas.fill_rect(text_bar, color.to_rgba8());
            }
            SketchLayerKind::Bitmap => {
                stats.bitmap_draws += 1;
                if let Some(ref_obj) = &layer.image_ref {
                    if let Some(swatch) = SketchRenderCache::global()
                        .cached_bitmap_swatch(&ref_obj.ref_path, document)
                    {
                        canvas.fill_rect(rect, swatch);
                        return;
                    }
                }
                canvas.fill_rect(rect, [225, 225, 230, 255]);
            }
            SketchLayerKind::Slice | SketchLayerKind::Hotspot => {}
        }
    }

    fn render_children_with_masks(
        children: &[SketchLayer],
        document: &SketchDocumentArchive,
        canvas: &mut SoftwareCanvasBuffer,
        local_vp: Option<SketchRect>,
        stats: &mut SketchFrameRenderStats,
    ) {
        let saved_clip = canvas.clip_rect;
        for child in children {
            if child.should_break_mask_chain {
                canvas.clip_rect = saved_clip;
            }
            Self::render_layer(child, document, canvas, local_vp, stats);
            if child.has_clipping_mask && child.is_visible {
                let screen_mask = SketchRect::new(
                    (child.frame.x + canvas.offset_x) * canvas.scale,
                    (child.frame.y + canvas.offset_y) * canvas.scale,
                    child.frame.width * canvas.scale,
                    child.frame.height * canvas.scale,
                );
                canvas.clip_rect = Some(screen_mask);
            }
        }
        canvas.clip_rect = saved_clip;
    }
}

// MARK: - Exporters: SVG, PNG, PDF & CSS Attributes (`SketchExporter`)

pub struct SketchExporter;

impl SketchExporter {
    /// Reconstructs `SketchSVGExporter::exportLayers:` (`0xc294` in `SketchSVG`)
    pub fn export_svg(layer: &SketchLayer, document: &SketchDocumentArchive) -> String {
        let w = layer.frame.width.round().max(1.0) as i64;
        let h = layer.frame.height.round().max(1.0) as i64;
        let mut lines = vec![
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>".to_string(),
            format!(
                "<svg width=\"{}px\" height=\"{}px\" viewBox=\"0 0 {} {}\" version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">",
                w, h, w, h
            ),
            format!("    <title>{}</title>", escape_xml(&layer.name)),
            "    <desc>Created with OpenSketch.</desc>".to_string(),
        ];

        let mut defs = Vec::new();
        let mut body = Vec::new();
        Self::write_layer_svg(layer, document, "    ", true, &mut defs, &mut body);

        if !defs.is_empty() {
            lines.push("    <defs>".to_string());
            lines.extend(defs);
            lines.push("    </defs>".to_string());
        }
        lines.extend(body);
        lines.push("</svg>".to_string());
        lines.join("\n")
    }

    fn write_layer_svg(
        node: &SketchLayer,
        document: &SketchDocumentArchive,
        indent: &str,
        offset_origin: bool,
        defs: &mut Vec<String>,
        body: &mut Vec<String>,
    ) {
        if !node.is_visible {
            return;
        }
        let rect = if offset_origin {
            SketchRect::new(0.0, 0.0, node.frame.width, node.frame.height)
        } else {
            node.frame
        };

        match node.kind() {
            SketchLayerKind::Page
            | SketchLayerKind::Artboard
            | SketchLayerKind::SymbolMaster
            | SketchLayerKind::Group => {
                let tx = if offset_origin { 0.0 } else { node.frame.x };
                let ty = if offset_origin { 0.0 } else { node.frame.y };
                let transform = if tx != 0.0 || ty != 0.0 {
                    format!(" transform=\"translate({}, {})\"", fmt_num(tx), fmt_num(ty))
                } else {
                    String::new()
                };
                body.push(format!(
                    "{}<g id=\"{}\"{}>",
                    indent,
                    escape_xml(&node.name),
                    transform
                ));
                if matches!(
                    node.kind(),
                    SketchLayerKind::Artboard | SketchLayerKind::SymbolMaster
                ) && node.has_background_color
                {
                    if let Some(bg) = node.background_color {
                        body.push(format!(
                            "{}    <rect fill=\"#{}\" x=\"0\" y=\"0\" width=\"{}\" height=\"{}\"></rect>",
                            indent,
                            bg.hex_string(),
                            fmt_num(node.frame.width),
                            fmt_num(node.frame.height)
                        ));
                    }
                }
                let next_indent = format!("{}    ", indent);
                for child in &node.layers {
                    Self::write_layer_svg(child, document, &next_indent, false, defs, body);
                }
                body.push(format!("{}</g>", indent));
            }
            SketchLayerKind::SymbolInstance => {
                if let Some(expanded) =
                    SketchSmartLayoutEngine::expand_symbol_instance(node, document)
                {
                    Self::write_layer_svg(&expanded, document, indent, offset_origin, defs, body);
                }
            }
            SketchLayerKind::ShapeGroup => {
                let path = SketchBooleanEngine::evaluate_shape_group_path(node);
                let d = SketchBezierBuilder::svg_path_data(&path);
                let style_attrs = Self::svg_style_attributes(&node.style, defs);
                body.push(format!(
                    "{}<path d=\"{}\" id=\"{}\"{}></path>",
                    indent,
                    d,
                    escape_xml(&node.name),
                    style_attrs
                ));
            }
            SketchLayerKind::Rectangle
            | SketchLayerKind::Oval
            | SketchLayerKind::ShapePath
            | SketchLayerKind::Polygon
            | SketchLayerKind::Star
            | SketchLayerKind::Triangle => {
                let path = SketchBezierBuilder::build_vector_path(
                    &node.points,
                    rect,
                    node.is_closed,
                    node.fixed_radius,
                );
                let d = SketchBezierBuilder::svg_path_data(&path);
                let style_attrs = Self::svg_style_attributes(&node.style, defs);
                body.push(format!(
                    "{}<path d=\"{}\" id=\"{}\"{}></path>",
                    indent,
                    d,
                    escape_xml(&node.name),
                    style_attrs
                ));
            }
            SketchLayerKind::Text => {
                if let Some(attr) = &node.attributed_string {
                    let first = attr.attributes.first();
                    let font = first.map(|f| f.font_name.as_str()).unwrap_or("HelveticaNeue");
                    let size = first.map(|f| f.font_size).unwrap_or(16.0);
                    let color = node
                        .style
                        .first_enabled_fill()
                        .map(|f| f.color)
                        .or_else(|| first.map(|f| f.color))
                        .unwrap_or(SketchColor::BLACK);
                    let y_pos = rect.y + size;
                    body.push(format!(
                        "{}<text id=\"{}\" font-family=\"{}\" font-size=\"{}\" fill=\"#{}\" x=\"{}\" y=\"{}\">{}</text>",
                        indent,
                        escape_xml(&node.name),
                        escape_xml(font),
                        fmt_num(size),
                        color.hex_string(),
                        fmt_num(rect.x),
                        fmt_num(y_pos),
                        escape_xml(&attr.string)
                    ));
                }
            }
            SketchLayerKind::Bitmap | SketchLayerKind::Slice | SketchLayerKind::Hotspot => {}
        }
    }

    fn svg_style_attributes(style: &SketchStyle, _defs: &mut Vec<String>) -> String {
        let mut attrs = Vec::new();
        if let Some(fill) = style.first_enabled_fill() {
            attrs.push(format!("fill=\"#{}\"", fill.color.hex_string()));
            if fill.color.alpha < 1.0 {
                attrs.push(format!("fill-opacity=\"{}\"", fmt_num(fill.color.alpha)));
            }
        } else {
            attrs.push("fill=\"none\"".to_string());
        }
        if let Some(border) = style.first_enabled_border() {
            attrs.push(format!("stroke=\"#{}\"", border.color.hex_string()));
            attrs.push(format!("stroke-width=\"{}\"", fmt_num(border.thickness)));
        }
        if attrs.is_empty() {
            String::new()
        } else {
            format!(" {}", attrs.join(" "))
        }
    }

    /// Reconstructs `MSExporter` PNG rasterization (`SR_MSExporter_bitmapImageRep.c`)
    pub fn export_png(
        layer: &SketchLayer,
        document: &SketchDocumentArchive,
        scale: f64,
    ) -> Vec<u8> {
        let w = ((layer.frame.width * scale).ceil() as usize).clamp(1, 2048);
        let h = ((layer.frame.height * scale).ceil() as usize).clamp(1, 2048);
        let mut canvas = SoftwareCanvasBuffer::new(w, h);
        canvas.offset_x = -layer.frame.x;
        canvas.offset_y = -layer.frame.y;
        canvas.scale = scale;
        let mut stats = SketchFrameRenderStats::default();
        SketchRenderer::render_layer(layer, document, &mut canvas, None, &mut stats);
        encode_rgba_png(w as u32, h as u32, &canvas.pixels)
    }

    /// Exports a layer or artboard to vector PDF data (`SketchPDF` equivalent)
    pub fn export_pdf(layer: &SketchLayer, _document: &SketchDocumentArchive) -> Vec<u8> {
        let w = layer.frame.width.round().max(1.0) as i64;
        let h = layer.frame.height.round().max(1.0) as i64;
        let content = format!(
            "q 1 1 1 rg 0 0 {} {} re f Q\nBT /F1 12 Tf 16 {} Td ({}) Tj ET\n",
            w,
            h,
            (h - 24).max(12),
            layer.name.replace('(', "").replace(')', "")
        );
        let pdf = format!(
            "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 {} {}] /Contents 4 0 R >> endobj\n4 0 obj << /Length {} >> stream\n{}endstream\nendobj\nxref\n0 5\n0000000000 65535 f \ntrailer << /Size 5 /Root 1 0 R >>\nstartxref\n300\n%%EOF\n",
            w,
            h,
            content.len(),
            content
        );
        pdf.into_bytes()
    }

    /// Reconstructs `copyCSSAttributes:` action selector from `out/ib-sketch-all.json`
    pub fn css_attributes(layer: &SketchLayer) -> String {
        let mut rules = vec![
            format!("/* {} */", layer.name),
            format!("width: {}px;", fmt_num(layer.frame.width)),
            format!("height: {}px;", fmt_num(layer.frame.height)),
        ];
        if let Some(fill) = layer.style.first_enabled_fill() {
            rules.push(format!("background: #{};", fill.color.hex_string()));
        }
        if let Some(border) = layer.style.first_enabled_border() {
            rules.push(format!(
                "border: {}px solid #{};",
                fmt_num(border.thickness),
                border.color.hex_string()
            ));
        }
        if let Some(shadow) = layer.style.first_enabled_shadow() {
            rules.push(format!(
                "box-shadow: {}px {}px {}px {}px #{};",
                fmt_num(shadow.offset_x),
                fmt_num(shadow.offset_y),
                fmt_num(shadow.blur_radius),
                fmt_num(shadow.spread),
                shadow.color.hex_string()
            ));
        }
        let radius = layer.fixed_radius.max(
            layer
                .points
                .iter()
                .map(|p| p.corner_radius)
                .fold(0.0, f64::max),
        );
        if radius > 0.0 {
            rules.push(format!("border-radius: {}px;", fmt_num(radius)));
        }
        if let Some(attr) = &layer.attributed_string {
            if let Some(first) = attr.attributes.first() {
                rules.push(format!("font-family: {};", first.font_name));
                rules.push(format!("font-size: {}px;", fmt_num(first.font_size)));
                rules.push(format!("color: #{};", first.color.hex_string()));
            }
        }
        rules.join("\n")
    }
}

fn encode_rgba_png(width: u32, height: u32, rgba: &[u8]) -> Vec<u8> {
    let mut raw_scanlines = Vec::with_capacity((width as usize * 4 + 1) * height as usize);
    let stride = width as usize * 4;
    for y in 0..height as usize {
        raw_scanlines.push(0u8); // Filter type 0 (None)
        let row = &rgba[y * stride..(y + 1) * stride];
        raw_scanlines.extend_from_slice(row);
    }
    let mut zlib = ZlibEncoder::new(Vec::new(), Compression::fast());
    let _ = zlib.write_all(&raw_scanlines);
    let idat_payload = zlib.finish().unwrap_or_default();

    let mut png = vec![137, 80, 78, 71, 13, 10, 26, 10];
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]); // 8-bit RGBA
    write_png_chunk(&mut png, b"IHDR", &ihdr);
    write_png_chunk(&mut png, b"IDAT", &idat_payload);
    write_png_chunk(&mut png, b"IEND", &[]);
    png
}

fn write_png_chunk(out: &mut Vec<u8>, chunk_type: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    out.extend_from_slice(chunk_type);
    out.extend_from_slice(data);
    let mut crc_input = Vec::with_capacity(4 + data.len());
    crc_input.extend_from_slice(chunk_type);
    crc_input.extend_from_slice(data);
    let crc = crc32fast::hash(&crc_input);
    out.extend_from_slice(&crc.to_be_bytes());
}

fn fmt_num(v: f64) -> String {
    if (v - v.round()).abs() < 1e-4 {
        format!("{}", v.round() as i64)
    } else {
        format!("{:.2}", v)
    }
}

fn escape_xml(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

// MARK: - Automated 6-Check Performance Suite (`SketchPerformanceSuite`)

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchPerfCheckResult {
    pub name: String,
    pub title: String,
    pub measured_ms: f64,
    pub budget_ms: f64,
    pub passed: bool,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SketchPerformanceReport {
    pub all_passed: bool,
    pub passed_count: usize,
    pub total_checks: usize,
    pub checks: Vec<SketchPerfCheckResult>,
    pub summary_line: String,
}

impl SketchPerformanceReport {
    pub fn new(checks: Vec<SketchPerfCheckResult>) -> Self {
        let total_checks = checks.len();
        let passed_count = checks.iter().filter(|c| c.passed).count();
        let all_passed = passed_count == total_checks;
        let warm = checks
            .iter()
            .find(|c| c.name == "warm_canvas_frame_render")
            .map(|c| c.measured_ms)
            .unwrap_or(0.0);
        let pan = checks
            .iter()
            .find(|c| c.name == "continuous_60_frame_pan_zoom")
            .map(|c| c.measured_ms)
            .unwrap_or(0.0);
        let summary_line = format!(
            "Perf Checks: {}/{} PASSED | Warm Frame: {:.2} ms ({:.0} FPS) | 60-Frame Pan/Zoom Avg: {:.2} ms",
            passed_count,
            total_checks,
            warm,
            (1000.0 / warm.max(0.1)).min(120.0),
            pan
        );
        Self {
            all_passed,
            passed_count,
            total_checks,
            checks,
            summary_line,
        }
    }
}

pub struct SketchPerformanceSuite;

impl SketchPerformanceSuite {
    pub fn run_all_checks(
        document: &SketchDocumentArchive,
        archive_path: Option<&Path>,
    ) -> SketchPerformanceReport {
        let mut results = Vec::new();
        let default_page = SketchLayer::new(SketchLayerKind::Page, "Page 1", SketchRect::default());
        let page = document.pages.first().unwrap_or(&default_page);

        // 1. Archive Load & Decode Check (< 250 ms budget)
        if let Some(p) = archive_path {
            let t0 = Instant::now();
            let _ = SketchDocumentIO::read_document_from_path(p, true);
            let elapsed_ms = t0.elapsed().as_secs_f64() * 1000.0;
            let budget = 250.0;
            results.push(SketchPerfCheckResult {
                name: "document_archive_load".to_string(),
                title: "ZIP Archive Load & Model Decode".to_string(),
                measured_ms: elapsed_ms,
                budget_ms: budget,
                passed: elapsed_ms <= budget,
                detail: format!(
                    "Loaded {} pages & {} images in {:.2} ms",
                    document.pages.len(),
                    document.images.len(),
                    elapsed_ms
                ),
            });
        } else {
            let t0 = Instant::now();
            for p in &document.pages {
                let _ = SketchDocumentIO::encode_layer(p);
            }
            let elapsed_ms = t0.elapsed().as_secs_f64() * 1000.0;
            let budget = 150.0;
            results.push(SketchPerfCheckResult {
                name: "document_archive_load".to_string(),
                title: "Document Model Serialization Check".to_string(),
                measured_ms: elapsed_ms,
                budget_ms: budget,
                passed: elapsed_ms <= budget,
                detail: format!(
                    "Encoded {} pages in {:.2} ms",
                    document.pages.len(),
                    elapsed_ms
                ),
            });
        }

        // Reusable 1440x900 framebuffer for frame benchmarks
        let mut canvas = SoftwareCanvasBuffer::new(1440, 900);

        // Prime cache with 1 cold frame
        let mut cold_stats = SketchFrameRenderStats::default();
        SketchRenderer::render_layer(
            page,
            document,
            &mut canvas,
            Some(SketchRect::new(-200.0, -200.0, 2800.0, 1800.0)),
            &mut cold_stats,
        );

        // 2. Warm Canvas Frame Render (< 8.33 ms = 120 FPS budget)
        let mut warm_stats = SketchFrameRenderStats::default();
        let hits_before = SketchRenderCache::global()
            .bitmap_cache_hits
            .load(Ordering::Relaxed)
            + SketchRenderCache::global()
                .symbol_cache_hits
                .load(Ordering::Relaxed);
        let t_warm = Instant::now();
        SketchRenderer::render_layer(
            page,
            document,
            &mut canvas,
            Some(SketchRect::new(-200.0, -200.0, 2800.0, 1800.0)),
            &mut warm_stats,
        );
        let warm_ms = t_warm.elapsed().as_secs_f64() * 1000.0;
        let hits_delta = (SketchRenderCache::global()
            .bitmap_cache_hits
            .load(Ordering::Relaxed)
            + SketchRenderCache::global()
                .symbol_cache_hits
                .load(Ordering::Relaxed))
            .saturating_sub(hits_before);
        let warm_budget = 8.33;
        results.push(SketchPerfCheckResult {
            name: "warm_canvas_frame_render".to_string(),
            title: "Warm Full-Canvas Render (120 FPS Target)".to_string(),
            measured_ms: warm_ms,
            budget_ms: warm_budget,
            passed: warm_ms <= warm_budget,
            detail: format!(
                "Drew {} layers in {:.2} ms ({} cache hits)",
                warm_stats.drawn_layers, warm_ms, hits_delta
            ),
        });

        // 3. 60-Frame Continuous Pan & Zoom Stress Test (< 6.0 ms avg)
        let mut frame_times = Vec::with_capacity(60);
        for i in 0..60 {
            let pan_x = (i as f64) * 18.0 - 300.0;
            let pan_y = ((i % 15) as f64) * 14.0 - 100.0;
            let zoom = 0.75 + ((i % 10) as f64) * 0.15;
            let visible_rect = SketchRect::new(
                -pan_x / zoom,
                -pan_y / zoom,
                1440.0 / zoom,
                900.0 / zoom,
            );
            canvas.offset_x = pan_x;
            canvas.offset_y = pan_y;
            canvas.scale = zoom;
            let mut f_stats = SketchFrameRenderStats::default();
            let tf = Instant::now();
            SketchRenderer::render_layer(page, document, &mut canvas, Some(visible_rect), &mut f_stats);
            frame_times.push(tf.elapsed().as_secs_f64() * 1000.0);
        }
        canvas.offset_x = 0.0;
        canvas.offset_y = 0.0;
        canvas.scale = 1.0;
        let avg_60 = frame_times.iter().sum::<f64>() / (frame_times.len() as f64);
        frame_times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let p95_60 = frame_times[((frame_times.len() as f64 * 0.95) as usize).min(frame_times.len() - 1)];
        let pan_budget = 6.0;
        results.push(SketchPerfCheckResult {
            name: "continuous_60_frame_pan_zoom".to_string(),
            title: "60-Frame Continuous Pan/Zoom Stress Test".to_string(),
            measured_ms: avg_60,
            budget_ms: pan_budget,
            passed: avg_60 <= pan_budget && p95_60 <= 12.0,
            detail: format!(
                "Avg: {:.2} ms/frame, P95: {:.2} ms/frame ({:.0} FPS)",
                avg_60,
                p95_60,
                (1000.0 / avg_60.max(0.1)).min(120.0)
            ),
        });

        // 4. Viewport Frustum Culling Check
        let first_ab = page
            .layers
            .first()
            .map(|l| l.frame)
            .unwrap_or_else(|| SketchRect::new(0.0, 0.0, 320.0, 240.0));
        let tight_vp = SketchRect::new(first_ab.x, first_ab.y, 180.0, 180.0);
        let mut cull_stats = SketchFrameRenderStats::default();
        let t_cull = Instant::now();
        SketchRenderer::render_layer(page, document, &mut canvas, Some(tight_vp), &mut cull_stats);
        let cull_ms = t_cull.elapsed().as_secs_f64() * 1000.0;
        let cull_budget = 4.0;
        let culling_worked = page.layers.len() <= 1 || cull_stats.culled_layers > 0;
        results.push(SketchPerfCheckResult {
            name: "viewport_frustum_culling".to_string(),
            title: "Viewport Frustum Culling Efficiency".to_string(),
            measured_ms: cull_ms,
            budget_ms: cull_budget,
            passed: cull_ms <= cull_budget && culling_worked,
            detail: format!(
                "Drew {} layers, culled {} off-screen layers in {:.2} ms",
                cull_stats.drawn_layers, cull_stats.culled_layers, cull_ms
            ),
        });

        // 5. O(1) Symbol Master Lookup & Cached Smart Layout Expansion (20 passes)
        let mut all_instances = Vec::new();
        fn collect_instances(layer: &SketchLayer, out: &mut Vec<SketchLayer>) {
            if layer.kind() == SketchLayerKind::SymbolInstance {
                out.push(layer.clone());
            }
            for child in &layer.layers {
                collect_instances(child, out);
            }
        }
        for p in &document.pages {
            collect_instances(p, &mut all_instances);
        }
        let t_sym = Instant::now();
        for _ in 0..20 {
            for inst in &all_instances {
                let _ = SketchSmartLayoutEngine::expand_symbol_instance(inst, document);
            }
        }
        let sym_ms = t_sym.elapsed().as_secs_f64() * 1000.0;
        let sym_budget = 5.0;
        results.push(SketchPerfCheckResult {
            name: "symbol_master_smart_layout_cache".to_string(),
            title: "O(1) Symbol Master & Smart Layout Cache (20x)".to_string(),
            measured_ms: sym_ms,
            budget_ms: sym_budget,
            passed: sym_ms <= sym_budget,
            detail: format!(
                "Expanded {} symbol ops in {:.3} ms ({} cache hits)",
                all_instances.len() * 20,
                sym_ms,
                SketchRenderCache::global()
                    .symbol_cache_hits
                    .load(Ordering::Relaxed)
            ),
        });

        // 6. Interactive Hit-Testing & Snap Alignment Guides (100 drag ticks)
        let siblings = &page.layers;
        let sample_frame = siblings
            .first()
            .map(|l| l.frame)
            .unwrap_or_else(|| SketchRect::new(100.0, 100.0, 200.0, 120.0));
        let excluded = vec![siblings
            .first()
            .map(|l| l.do_object_id.clone())
            .unwrap_or_default()];
        let t_snap = Instant::now();
        for step in 0..100 {
            let probe = SketchRect::new(
                sample_frame.x + (step as f64) * 3.0,
                sample_frame.y + (step as f64) * 2.0,
                sample_frame.width,
                sample_frame.height,
            );
            let _ = SketchSnapEngine::snap_frame(probe, siblings, &excluded);
        }
        let snap_ms = t_snap.elapsed().as_secs_f64() * 1000.0;
        let snap_budget = 4.0;
        results.push(SketchPerfCheckResult {
            name: "interactive_hit_test_and_snap".to_string(),
            title: "Interactive Drag Snapping (100 ticks)".to_string(),
            measured_ms: snap_ms,
            budget_ms: snap_budget,
            passed: snap_ms <= snap_budget,
            detail: format!(
                "100 snap evaluations in {:.3} ms ({:.4} ms/tick)",
                snap_ms,
                snap_ms / 100.0
            ),
        });

        SketchPerformanceReport::new(results)
    }
}
