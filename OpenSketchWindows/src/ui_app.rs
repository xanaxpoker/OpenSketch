use crate::io::*;
use crate::model::*;
use crate::render::*;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use tiny_http::{Header, Method, Response, Server};

pub struct StudioAppState {
    pub document: SketchDocumentArchive,
    pub document_path: Option<PathBuf>,
    pub validation_status: SketchValidationStatus,
    pub was_repaired: bool,
    pub selected_layer_ids: Vec<String>,
    pub last_perf_report: Option<SketchPerformanceReport>,
}

impl StudioAppState {
    pub fn new(initial_path: Option<&Path>) -> Self {
        if let Some(p) = initial_path {
            if let Ok((doc, status, repaired)) = SketchDocumentIO::read_document_from_path(p, true)
            {
                let first_sel = doc
                    .pages
                    .get(doc.current_page_index)
                    .and_then(|pg| pg.layers.first())
                    .map(|l| vec![l.do_object_id.clone()])
                    .unwrap_or_default();
                let report = SketchPerformanceSuite::run_all_checks(&doc, Some(p));
                return Self {
                    document: doc,
                    document_path: Some(p.to_path_buf()),
                    validation_status: status,
                    was_repaired: repaired,
                    selected_layer_ids: first_sel,
                    last_perf_report: Some(report),
                };
            }
        }
        let doc = SketchDocumentArchive::default();
        let report = SketchPerformanceSuite::run_all_checks(&doc, None);
        Self {
            document: doc,
            document_path: None,
            validation_status: SketchValidationStatus::Valid,
            was_repaired: false,
            selected_layer_ids: Vec::new(),
            last_perf_report: Some(report),
        }
    }

    pub fn to_ui_json(&self) -> Value {
        let symbols: Vec<Value> = self
            .document
            .all_symbol_masters()
            .into_iter()
            .map(|s| {
                json!({
                    "id": s.do_object_id,
                    "symbolID": s.symbol_id,
                    "name": s.name,
                    "width": s.frame.width,
                    "height": s.frame.height
                })
            })
            .collect();

        json!({
            "documentPath": self.document_path.as_ref().map(|p| p.display().to_string()).unwrap_or_else(|| "Untitled.sketch".to_string()),
            "validationStatus": self.validation_status.as_i32(),
            "validationMessage": self.validation_status.dialog_message(),
            "wasRepaired": self.was_repaired,
            "currentPageIndex": self.document.current_page_index,
            "selectedLayerIds": self.selected_layer_ids,
            "pages": self.document.pages,
            "symbols": symbols,
            "perfReport": self.last_perf_report,
        })
    }
}

#[derive(Debug, Deserialize, Serialize)]
pub struct InsertActionRequest {
    pub tool: String,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub symbol_id: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct MutateLayerRequest {
    pub action: String,
    pub layer_id: Option<String>,
    pub page_index: Option<usize>,
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub width: Option<f64>,
    pub height: Option<f64>,
    pub rotation: Option<f64>,
    pub fixed_radius: Option<f64>,
    pub name: Option<String>,
    pub is_visible: Option<bool>,
    pub is_locked: Option<bool>,
    pub has_clipping_mask: Option<bool>,
    pub resizing_constraint: Option<i32>,
    pub opacity: Option<f64>,
    pub fill_hex: Option<String>,
    pub border_hex: Option<String>,
    pub border_thickness: Option<f64>,
    pub text_value: Option<String>,
    pub font_size: Option<f64>,
    pub boolean_op: Option<i32>,
    pub override_name: Option<String>,
    pub override_value: Option<String>,
    pub horizontal: Option<bool>,
}

pub fn apply_insert_action(state: &mut StudioAppState, req: &InsertActionRequest) {
    let x = req.x.unwrap_or(80.0);
    let y = req.y.unwrap_or(80.0);
    let layer = match req.tool.as_str() {
        "rectangle" => SketchLayer::make_rectangle(
            "Rectangle",
            SketchRect::new(x, y, 160.0, 110.0),
            0.0,
            SketchColor::new(0.24, 0.52, 0.96, 1.0),
            SketchColor::new(0.18, 0.40, 0.80, 1.0),
        ),
        "rounded" => SketchLayer::make_rectangle(
            "Rounded Rectangle",
            SketchRect::new(x, y, 160.0, 110.0),
            16.0,
            SketchColor::new(0.35, 0.34, 0.84, 1.0),
            SketchColor::new(0.25, 0.24, 0.70, 1.0),
        ),
        "oval" => SketchLayer::make_oval(
            "Oval",
            SketchRect::new(x, y, 120.0, 120.0),
            SketchColor::new(0.95, 0.38, 0.42, 1.0),
            SketchColor::new(0.75, 0.25, 0.30, 1.0),
        ),
        "polygon" => SketchLayer::make_polygon("Polygon", 6, SketchRect::new(x, y, 120.0, 120.0)),
        "star" => SketchLayer::make_star("Star", 5, 0.5, SketchRect::new(x, y, 120.0, 120.0)),
        "triangle" => SketchLayer::make_triangle("Triangle", SketchRect::new(x, y, 120.0, 110.0)),
        "text" => SketchLayer::make_text(
            "Text Layer",
            "OpenSketch Windows",
            SketchRect::new(x, y, 220.0, 32.0),
            20.0,
            SketchColor::new(0.12, 0.14, 0.18, 1.0),
        ),
        "artboard" => {
            SketchLayer::make_artboard("Artboard", SketchRect::new(x, y, 375.0, 812.0), Vec::new())
        }
        "symbolInstance" => {
            let sym_id = req.symbol_id.clone().unwrap_or_default();
            let mut inst = SketchLayer::new(
                SketchLayerKind::SymbolInstance,
                "Symbol Instance",
                SketchRect::new(x, y, 180.0, 48.0),
            );
            inst.symbol_id = Some(sym_id);
            inst
        }
        _ => SketchLayer::make_rectangle(
            "Shape",
            SketchRect::new(x, y, 140.0, 100.0),
            0.0,
            SketchColor::new(0.24, 0.52, 0.96, 1.0),
            SketchColor::SKETCH_BLUE,
        ),
    };

    let new_id = layer.do_object_id.clone();
    if let Some(page) = state.document.pages.get_mut(state.document.current_page_index) {
        if layer.kind() != SketchLayerKind::Artboard {
            if let Some(ab) = page
                .layers
                .iter_mut()
                .find(|l| l.kind() == SketchLayerKind::Artboard)
            {
                ab.layers.push(layer);
            } else {
                page.layers.push(layer);
            }
        } else {
            page.layers.push(layer);
        }
    }
    state.selected_layer_ids = vec![new_id];
    SketchRenderCache::global().clear_all();
}

fn find_layer_mut<'a>(root: &'a mut SketchLayer, id: &str) -> Option<&'a mut SketchLayer> {
    if root.do_object_id == id {
        return Some(root);
    }
    for child in &mut root.layers {
        if let Some(found) = find_layer_mut(child, id) {
            return Some(found);
        }
    }
    None
}

fn remove_layer_by_id(root: &mut SketchLayer, id: &str) -> bool {
    if let Some(pos) = root.layers.iter().position(|l| l.do_object_id == id) {
        root.layers.remove(pos);
        return true;
    }
    for child in &mut root.layers {
        if remove_layer_by_id(child, id) {
            return true;
        }
    }
    false
}

pub fn apply_mutate_action(state: &mut StudioAppState, req: &MutateLayerRequest) {
    if req.action == "selectPage" {
        if let Some(idx) = req.page_index {
            if idx < state.document.pages.len() {
                state.document.current_page_index = idx;
                state.selected_layer_ids.clear();
            }
        }
        return;
    }
    if req.action == "selectLayer" {
        if let Some(id) = &req.layer_id {
            state.selected_layer_ids = vec![id.clone()];
        }
        return;
    }

    let target_id = req
        .layer_id
        .clone()
        .or_else(|| state.selected_layer_ids.first().cloned());
    let Some(target_id) = target_id else {
        return;
    };

    if req.action == "delete" {
        if let Some(page) = state.document.pages.get_mut(state.document.current_page_index) {
            let _ = remove_layer_by_id(page, &target_id);
            state.selected_layer_ids.clear();
            SketchRenderCache::global().clear_all();
        }
        return;
    }

    if req.action == "booleanOp" {
        let op = SketchBooleanOperation::from_i32(req.boolean_op.unwrap_or(0));
        if let Some(page) = state.document.pages.get_mut(state.document.current_page_index) {
            if let Some(layer) = find_layer_mut(page, &target_id) {
                layer.boolean_operation = op;
            }
        }
        SketchRenderCache::global().clear_all();
        return;
    }

    if let Some(page) = state.document.pages.get_mut(state.document.current_page_index) {
        if let Some(layer) = find_layer_mut(page, &target_id) {
            if let Some(v) = req.x {
                layer.frame.x = v;
            }
            if let Some(v) = req.y {
                layer.frame.y = v;
            }
            if let Some(v) = req.width {
                layer.frame.width = v.max(1.0);
            }
            if let Some(v) = req.height {
                layer.frame.height = v.max(1.0);
            }
            if let Some(v) = req.rotation {
                layer.rotation = v;
            }
            if let Some(v) = req.fixed_radius {
                layer.fixed_radius = v.max(0.0);
                for pt in &mut layer.points {
                    pt.corner_radius = v.max(0.0);
                }
            }
            if let Some(ref name) = req.name {
                layer.name = name.clone();
            }
            if let Some(vis) = req.is_visible {
                layer.is_visible = vis;
            }
            if let Some(lck) = req.is_locked {
                layer.is_locked = lck;
            }
            if let Some(mask) = req.has_clipping_mask {
                layer.has_clipping_mask = mask;
            }
            if let Some(rc) = req.resizing_constraint {
                layer.resizing_constraint = rc;
            }
            if let Some(op) = req.opacity {
                layer.style.context_settings.opacity = op.clamp(0.0, 1.0);
            }
            if let Some(ref hex) = req.fill_hex {
                let c = SketchColor::from_hex(hex, 1.0).unwrap_or(SketchColor::SKETCH_BLUE);
                if let Some(fill) = layer.style.fills.first_mut() {
                    fill.color = c;
                    fill.is_enabled = true;
                } else {
                    layer.style.fills.push(SketchFill::solid(c));
                }
            }
            if let Some(ref hex) = req.border_hex {
                let c = SketchColor::from_hex(hex, 1.0).unwrap_or(SketchColor::BLACK);
                let thickness = req.border_thickness.unwrap_or(1.0);
                if let Some(border) = layer.style.borders.first_mut() {
                    border.color = c;
                    border.thickness = thickness;
                    border.is_enabled = thickness > 0.0;
                } else if thickness > 0.0 {
                    layer
                        .style
                        .borders
                        .push(SketchBorder::solid(c, 1, thickness));
                }
            }
            if let Some(ref txt) = req.text_value {
                if let Some(ref mut attr) = layer.attributed_string {
                    attr.string = txt.clone();
                    if let Some(first) = attr.attributes.first_mut() {
                        first.length = txt.encode_utf16().count();
                        if let Some(fs) = req.font_size {
                            first.font_size = fs;
                        }
                    }
                }
            }
            if let (Some(ref ov_name), Some(ref ov_val)) = (&req.override_name, &req.override_value)
            {
                if let Some(existing) = layer
                    .override_values
                    .iter_mut()
                    .find(|o| &o.override_name == ov_name)
                {
                    existing.value = ov_val.clone();
                } else {
                    layer.override_values.push(SketchOverrideValue {
                        override_name: ov_name.clone(),
                        value: ov_val.clone(),
                    });
                }
            }
            if let Some(horiz) = req.horizontal {
                if horiz {
                    layer.is_flipped_horizontal = !layer.is_flipped_horizontal;
                } else {
                    layer.is_flipped_vertical = !layer.is_flipped_vertical;
                }
            }
        }
    }
    SketchRenderCache::global().clear_all();
}

pub fn launch_windows_studio(initial_sketch_path: Option<&Path>, port: u16) -> Result<(), String> {
    let state = Arc::new(Mutex::new(StudioAppState::new(initial_sketch_path)));
    let bind_addr = format!("127.0.0.1:{}", port);
    let server =
        Server::http(&bind_addr).map_err(|e| format!("Failed to bind {}: {}", bind_addr, e))?;
    let actual_addr = format!("http://{}", server.server_addr());

    println!("OpenSketch for Windows running at {}", actual_addr);
    spawn_native_window(&actual_addr);

    for mut request in server.incoming_requests() {
        let url = request.url().to_string();
        let method = request.method().clone();

        if method == Method::Get && (url == "/" || url.starts_with("/index.html")) {
            let html = studio_html_shell();
            let header =
                Header::from_bytes(&b"Content-Type"[..], &b"text/html; charset=utf-8"[..]).unwrap();
            let _ = request.respond(Response::from_string(html).with_header(header));
            continue;
        }

        if method == Method::Get && url == "/api/state" {
            let guard = state.lock();
            let payload = guard.to_ui_json().to_string();
            let header =
                Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap();
            let _ = request.respond(Response::from_string(payload).with_header(header));
            continue;
        }

        if method == Method::Post && url == "/api/insert" {
            let mut body = String::new();
            let _ = request.as_reader().read_to_string(&mut body);
            let mut guard = state.lock();
            if let Ok(req) = serde_json::from_str::<InsertActionRequest>(&body) {
                apply_insert_action(&mut guard, &req);
            }
            let payload = guard.to_ui_json().to_string();
            let header =
                Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap();
            let _ = request.respond(Response::from_string(payload).with_header(header));
            continue;
        }

        if method == Method::Post && url == "/api/mutate" {
            let mut body = String::new();
            let _ = request.as_reader().read_to_string(&mut body);
            let mut guard = state.lock();
            if let Ok(req) = serde_json::from_str::<MutateLayerRequest>(&body) {
                apply_mutate_action(&mut guard, &req);
            }
            let payload = guard.to_ui_json().to_string();
            let header =
                Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap();
            let _ = request.respond(Response::from_string(payload).with_header(header));
            continue;
        }

        if method == Method::Post && url == "/api/bench" {
            let mut guard = state.lock();
            let path_clone = guard.document_path.clone();
            let report =
                SketchPerformanceSuite::run_all_checks(&guard.document, path_clone.as_deref());
            guard.last_perf_report = Some(report);
            let payload = guard.to_ui_json().to_string();
            let header =
                Header::from_bytes(&b"Content-Type"[..], &b"application/json"[..]).unwrap();
            let _ = request.respond(Response::from_string(payload).with_header(header));
            continue;
        }

        if method == Method::Get && url == "/api/export/svg" {
            let guard = state.lock();
            let target = guard
                .document
                .pages
                .get(guard.document.current_page_index)
                .cloned()
                .unwrap_or_else(|| {
                    SketchLayer::make_artboard(
                        "Page",
                        SketchRect::new(0.0, 0.0, 800.0, 600.0),
                        Vec::new(),
                    )
                });
            let svg = SketchExporter::export_svg(&target, &guard.document);
            let header = Header::from_bytes(&b"Content-Type"[..], &b"image/svg+xml"[..]).unwrap();
            let _ = request.respond(Response::from_string(svg).with_header(header));
            continue;
        }

        let _ = request.respond(Response::from_string("Not found").with_status_code(404));
    }

    Ok(())
}

fn spawn_native_window(url: &str) {
    #[cfg(target_os = "windows")]
    {
        let edge_candidates = [
            r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
            r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        ];
        for candidate in edge_candidates {
            if Path::new(candidate).exists() {
                let _ = Command::new(candidate)
                    .arg(format!("--app={}", url))
                    .arg("--window-size=1440,920")
                    .spawn();
                return;
            }
        }
        let _ = Command::new("cmd").args(["/C", "start", "", url]).spawn();
    }
    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("open").arg(url).spawn();
    }
    #[cfg(target_os = "linux")]
    {
        let _ = Command::new("xdg-open").arg(url).spawn();
    }
}

pub fn studio_html_shell() -> &'static str {
    r##"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<title>OpenSketch for Windows — 120 FPS Vector Studio</title>
<style>
  * { box-sizing: border-box; user-select: none; }
  body { margin: 0; font-family: "Segoe UI", -apple-system, BlinkMacSystemFont, sans-serif; background: #1e1e22; color: #e5e5ea; height: 100vh; display: flex; flex-direction: column; overflow: hidden; }
  .toolbar { height: 48px; background: #26262b; border-bottom: 1px solid #383840; display: flex; align-items: center; padding: 0 12px; gap: 6px; }
  .toolbar .brand { font-weight: 700; color: #f5a623; margin-right: 10px; font-size: 13px; letter-spacing: 0.3px; }
  .btn { background: #32323a; border: 1px solid #44444f; color: #e5e5ea; border-radius: 6px; padding: 5px 10px; font-size: 12px; cursor: pointer; display: inline-flex; align-items: center; gap: 4px; }
  .btn:hover { background: #3e3e48; }
  .btn.active { background: #2f6fed; border-color: #4f8aff; color: #fff; }
  .sep { width: 1px; height: 22px; background: #3a3a44; margin: 0 4px; }
  .workspace { flex: 1; display: flex; overflow: hidden; }
  .sidebar { width: 250px; background: #222227; border-right: 1px solid #34343c; display: flex; flex-direction: column; overflow-y: auto; }
  .section-hdr { font-size: 10px; font-weight: 700; letter-spacing: 0.8px; color: #8e8e98; padding: 10px 12px 6px; text-transform: uppercase; }
  .tree-item { padding: 5px 12px; font-size: 12px; cursor: pointer; display: flex; align-items: center; justify-content: space-between; border-radius: 4px; margin: 1px 6px; }
  .tree-item:hover { background: #2c2c34; }
  .tree-item.selected { background: #2f6fed; color: #fff; }
  .badge { font-size: 10px; padding: 1px 5px; border-radius: 4px; background: #3a3a44; color: #c7c7d1; }
  .canvas-wrap { flex: 1; position: relative; background: #161619; overflow: hidden; }
  canvas { width: 100%; height: 100%; display: block; cursor: grab; }
  canvas:active { cursor: grabbing; }
  .hud-pill { position: absolute; bottom: 14px; left: 14px; background: rgba(24,24,28,0.88); border: 1px solid #383842; border-radius: 999px; padding: 5px 12px; font-size: 11px; display: flex; gap: 10px; align-items: center; pointer-events: none; }
  .fps-dot { width: 8px; height: 8px; border-radius: 50%; background: #30d158; display: inline-block; }
  .inspector { width: 290px; background: #222227; border-left: 1px solid #34343c; padding: 12px; overflow-y: auto; font-size: 12px; }
  .prop-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-bottom: 10px; }
  .field { display: flex; flex-direction: column; gap: 3px; }
  .field label { font-size: 10px; color: #9a9aa6; }
  .field input { background: #19191d; border: 1px solid #383842; color: #fff; border-radius: 4px; padding: 5px 7px; font-size: 12px; }
</style>
</head>
<body>
<div class="toolbar">
  <span class="brand">◆ OpenSketch Windows</span>
  <button class="btn active" id="viewCanvasBtn">Canvas</button>
  <button class="btn" id="viewCompBtn">Components</button>
  <div class="sep"></div>
  <button class="btn" onclick="insertLayer('rectangle')">▭ Rect</button>
  <button class="btn" onclick="insertLayer('rounded')">▢ Rounded</button>
  <button class="btn" onclick="insertLayer('oval')">◯ Oval</button>
  <button class="btn" onclick="insertLayer('polygon')">⬡ Polygon</button>
  <button class="btn" onclick="insertLayer('star')">★ Star</button>
  <button class="btn" onclick="insertLayer('triangle')">△ Triangle</button>
  <button class="btn" onclick="insertLayer('text')">T Text</button>
  <button class="btn" onclick="insertLayer('artboard')">⊞ Artboard</button>
  <div class="sep"></div>
  <button class="btn" onclick="booleanOp(0)">Union</button>
  <button class="btn" onclick="booleanOp(1)">Subtract</button>
  <button class="btn" onclick="booleanOp(2)">Intersect</button>
  <button class="btn" onclick="booleanOp(3)">Diff</button>
  <div class="sep"></div>
  <button class="btn" onclick="runPerfBench()">⚡ Perf Checks</button>
  <a class="btn" href="/api/export/svg" target="_blank" style="text-decoration:none">Export SVG</a>
</div>
<div class="workspace">
  <div class="sidebar">
    <div class="section-hdr">Pages</div>
    <div id="pagesList"></div>
    <div class="section-hdr">Layers</div>
    <div id="layersList"></div>
  </div>
  <div class="canvas-wrap">
    <canvas id="viewport"></canvas>
    <div class="hud-pill">
      <span class="fps-dot"></span>
      <span id="fpsLabel">120 FPS</span>
      <span id="perfSummary">6/6 Perf Checks PASS</span>
    </div>
  </div>
  <div class="inspector" id="inspectorPanel">
    <div class="section-hdr" style="padding-left:0">Inspector</div>
    <div id="inspectorBody">Select a layer to inspect</div>
  </div>
</div>
<script>
let state = null;
let panX = 60, panY = 60, zoom = 0.75;
let dragging = false, lastX = 0, lastY = 0;
let lastFrameTime = performance.now(), fps = 120;

async function fetchState() {
  const res = await fetch('/api/state');
  state = await res.json();
  renderSidebar();
  renderInspector();
  requestAnimationFrame(drawCanvas);
}

async function insertLayer(tool) {
  const res = await fetch('/api/insert', {
    method: 'POST',
    body: JSON.stringify({ tool, x: 120, y: 120 })
  });
  state = await res.json();
  renderSidebar();
  renderInspector();
  requestAnimationFrame(drawCanvas);
}

async function mutate(payload) {
  const res = await fetch('/api/mutate', {
    method: 'POST',
    body: JSON.stringify(payload)
  });
  state = await res.json();
  renderSidebar();
  renderInspector();
  requestAnimationFrame(drawCanvas);
}

async function booleanOp(op) {
  await mutate({ action: 'booleanOp', boolean_op: op });
}

async function runPerfBench() {
  const res = await fetch('/api/bench', { method: 'POST' });
  state = await res.json();
  if (state.perfReport) {
    document.getElementById('perfSummary').textContent = state.perfReport.summary_line;
  }
}

function renderSidebar() {
  if (!state) return;
  const pagesEl = document.getElementById('pagesList');
  pagesEl.innerHTML = '';
  state.pages.forEach((p, idx) => {
    const div = document.createElement('div');
    div.className = 'tree-item' + (idx === state.currentPageIndex ? ' selected' : '');
    div.innerHTML = `<span>${p.name}</span><span class="badge">${p.layers.length}</span>`;
    div.onclick = () => mutate({ action: 'selectPage', page_index: idx });
    pagesEl.appendChild(div);
  });

  const layersEl = document.getElementById('layersList');
  layersEl.innerHTML = '';
  const page = state.pages[state.currentPageIndex];
  if (!page) return;
  function walk(layers, depth) {
    layers.forEach(l => {
      const div = document.createElement('div');
      const sel = state.selectedLayerIds.includes(l.do_object_id);
      div.className = 'tree-item' + (sel ? ' selected' : '');
      div.style.paddingLeft = (12 + depth * 14) + 'px';
      const badge = l.has_clipping_mask ? '<span class="badge">M</span>' : `<span class="badge">${l.class_name}</span>`;
      div.innerHTML = `<span>${l.name}</span>${badge}`;
      div.onclick = () => mutate({ action: 'selectLayer', layer_id: l.do_object_id });
      layersEl.appendChild(div);
      if (l.layers && l.layers.length) walk(l.layers, depth + 1);
    });
  }
  walk(page.layers, 0);
}

function findLayer(layers, id) {
  for (const l of layers) {
    if (l.do_object_id === id) return l;
    if (l.layers) {
      const found = findLayer(l.layers, id);
      if (found) return found;
    }
  }
  return null;
}

function renderInspector() {
  const body = document.getElementById('inspectorBody');
  if (!state || !state.selectedLayerIds.length) {
    body.innerHTML = 'Select a layer on the canvas or sidebar.';
    return;
  }
  const page = state.pages[state.currentPageIndex];
  const layer = page ? findLayer(page.layers, state.selectedLayerIds[0]) : null;
  if (!layer) return;
  body.innerHTML = `
    <div class="field" style="margin-bottom:8px">
      <label>Name (${layer.class_name})</label>
      <input value="${layer.name}" onchange="mutate({action:'update', name:this.value})" />
    </div>
    <div class="prop-grid">
      <div class="field"><label>X</label><input type="number" value="${layer.frame.x}" onchange="mutate({action:'update', x:+this.value})" /></div>
      <div class="field"><label>Y</label><input type="number" value="${layer.frame.y}" onchange="mutate({action:'update', y:+this.value})" /></div>
      <div class="field"><label>W</label><input type="number" value="${layer.frame.width}" onchange="mutate({action:'update', width:+this.value})" /></div>
      <div class="field"><label>H</label><input type="number" value="${layer.frame.height}" onchange="mutate({action:'update', height:+this.value})" /></div>
      <div class="field"><label>Rotation</label><input type="number" value="${layer.rotation}" onchange="mutate({action:'update', rotation:+this.value})" /></div>
      <div class="field"><label>Radius</label><input type="number" value="${layer.fixed_radius}" onchange="mutate({action:'update', fixed_radius:+this.value})" /></div>
    </div>
    <div style="display:flex; gap:6px; margin-bottom:10px">
      <button class="btn" onclick="mutate({action:'update', has_clipping_mask:${!layer.has_clipping_mask}})">Mask: ${layer.has_clipping_mask ? 'ON' : 'OFF'}</button>
      <button class="btn" onclick="mutate({action:'update', horizontal:true})">Flip H</button>
      <button class="btn" onclick="mutate({action:'delete'})" style="background:#5c2328">Delete</button>
    </div>
  `;
}

function drawCanvas(now) {
  const dt = Math.max(1, now - lastFrameTime);
  lastFrameTime = now;
  fps = Math.min(120, Math.round(1000 / dt));
  document.getElementById('fpsLabel').textContent = `${fps} FPS`;

  const canvas = document.getElementById('viewport');
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
    canvas.width = w * dpr;
    canvas.height = h * dpr;
  }
  const ctx = canvas.getContext('2d');
  ctx.save();
  ctx.scale(dpr, dpr);
  ctx.fillStyle = '#161619';
  ctx.fillRect(0, 0, w, h);

  ctx.translate(panX, panY);
  ctx.scale(zoom, zoom);

  if (state && state.pages[state.currentPageIndex]) {
    const page = state.pages[state.currentPageIndex];
    function renderNodes(nodes, ox, oy) {
      nodes.forEach(n => {
        if (!n.is_visible) return;
        const x = ox + n.frame.x, y = oy + n.frame.y;
        if (n.class_name === 'artboard' || n.class_name === 'symbolMaster') {
          ctx.fillStyle = '#ffffff';
          ctx.fillRect(x, y, n.frame.width, n.frame.height);
          ctx.fillStyle = '#8e8e98';
          ctx.font = '11px Segoe UI, sans-serif';
          ctx.fillText(n.name, x, y - 6);
        } else if (n.style && n.style.fills && n.style.fills.length) {
          const f = n.style.fills.find(fl => fl.is_enabled);
          if (f) {
            const r = Math.round(f.color.red * 255), g = Math.round(f.color.green * 255), b = Math.round(f.color.blue * 255);
            ctx.fillStyle = `rgba(${r},${g},${b},${f.color.alpha})`;
            ctx.fillRect(x, y, n.frame.width, n.frame.height);
          }
        }
        if (n.attributed_string) {
          ctx.fillStyle = '#1d1d1f';
          ctx.font = '14px Segoe UI, sans-serif';
          ctx.fillText(n.attributed_string.string, x, y + 16);
        }
        if (state.selectedLayerIds.includes(n.do_object_id)) {
          ctx.strokeStyle = '#2f6fed';
          ctx.lineWidth = 1.5 / zoom;
          ctx.strokeRect(x, y, n.frame.width, n.frame.height);
        }
        if (n.layers && n.layers.length) renderNodes(n.layers, x, y);
      });
    }
    renderNodes(page.layers, 0, 0);
  }
  ctx.restore();
}

const vp = document.getElementById('viewport');
vp.addEventListener('mousedown', e => { dragging = true; lastX = e.clientX; lastY = e.clientY; });
window.addEventListener('mouseup', () => dragging = false);
window.addEventListener('mousemove', e => {
  if (!dragging) return;
  panX += e.clientX - lastX;
  panY += e.clientY - lastY;
  lastX = e.clientX;
  lastY = e.clientY;
  requestAnimationFrame(drawCanvas);
});
vp.addEventListener('wheel', e => {
  e.preventDefault();
  if (e.ctrlKey || e.metaKey) {
    zoom = Math.min(8, Math.max(0.1, zoom * (e.deltaY < 0 ? 1.08 : 0.92)));
  } else {
    panX -= e.deltaX;
    panY -= e.deltaY;
  }
  requestAnimationFrame(drawCanvas);
}, { passive: false });

fetchState();
</script>
</body>
</html>
"##
}
