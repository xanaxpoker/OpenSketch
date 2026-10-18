use crate::model::*;
use flate2::read::DeflateDecoder;
use flate2::write::DeflateEncoder;
use flate2::Compression;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Write};
use std::path::Path;

/// Matches `+[MSDocumentReader readerForDocumentAtURL:]`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SketchReaderFormat {
    ZippedJson,
    LegacySqlite,
}

impl SketchReaderFormat {
    pub fn class_name(self) -> &'static str {
        match self {
            Self::ZippedJson => "MSDocumentZippedJSONReader",
            Self::LegacySqlite => "MSLegacyDocumentReader",
        }
    }
}

/// Matches `-[MSDocumentZippedJSONReader validate]`
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(i32)]
pub enum SketchValidationStatus {
    Valid = 0,
    CorruptMetadata = 2,     // meta.json or user.json missing
    LegacyUnsupported = 3,   // version <= 87
    NewerVersionWarning = 4, // version > 139 && compatibilityVersion <= 139
    IncompatibleNewer = 5,   // compatibilityVersion > 139
}

impl SketchValidationStatus {
    pub fn as_i32(self) -> i32 {
        self as i32
    }

    pub fn dialog_message(self) -> Option<&'static str> {
        match self {
            Self::Valid => None,
            Self::CorruptMetadata | Self::LegacyUnsupported => Some(
                "The document may be corrupt or missing some data. Would you like to try to open it anyway?",
            ),
            Self::NewerVersionWarning => Some(
                "This document was last edited in a newer version of Sketch. Opening it in this version may result in some data being lost.",
            ),
            Self::IncompatibleNewer => Some(
                "This document was created with a newer version of Sketch. Please upgrade Sketch to open this document.",
            ),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SketchDocumentError {
    IoError(String),
    InvalidArchive(String),
    ValidationFailed(SketchValidationStatus),
    MissingDocumentJson,
}

impl std::fmt::Display for SketchDocumentError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::IoError(msg) => write!(f, "I/O error: {}", msg),
            Self::InvalidArchive(msg) => write!(f, "Invalid .sketch archive: {}", msg),
            Self::ValidationFailed(st) => write!(
                f,
                "{}",
                st.dialog_message().unwrap_or("Validation failed")
            ),
            Self::MissingDocumentJson => write!(f, "Archive is missing document.json"),
        }
    }
}

impl std::error::Error for SketchDocumentError {}

// MARK: - Fast PKZIP Central Directory Reader & Writer (`BCJSONZippedDecoder` / `Encoder`)

pub struct SketchZipArchive;

impl SketchZipArchive {
    pub fn read_entries_from_path(path: &Path) -> Result<HashMap<String, Vec<u8>>, SketchDocumentError> {
        let data = std::fs::read(path).map_err(|e| SketchDocumentError::IoError(e.to_string()))?;
        Self::read_entries(&data)
    }

    pub fn read_entries(data: &[u8]) -> Result<HashMap<String, Vec<u8>>, SketchDocumentError> {
        if data.len() < 22 {
            return Err(SketchDocumentError::InvalidArchive(format!(
                "Archive too small ({} bytes)",
                data.len()
            )));
        }

        let min_offset = data.len().saturating_sub(65557);
        let mut eocd_offset = None;
        for i in (min_offset..=data.len() - 22).rev() {
            if data[i] == 0x50 && data[i + 1] == 0x4b && data[i + 2] == 0x05 && data[i + 3] == 0x06
            {
                eocd_offset = Some(i);
                break;
            }
        }
        let eocd = eocd_offset.ok_or_else(|| {
            SketchDocumentError::InvalidArchive("Missing PKZIP End of Central Directory".to_string())
        })?;

        let total_entries = read_u16(data, eocd + 10) as usize;
        let cd_offset = read_u32(data, eocd + 16) as usize;

        let mut entries = HashMap::with_capacity(total_entries);
        let mut pos = cd_offset;
        for _ in 0..total_entries {
            if pos + 46 > data.len()
                || data[pos] != 0x50
                || data[pos + 1] != 0x4b
                || data[pos + 2] != 0x01
                || data[pos + 3] != 0x02
            {
                break;
            }
            let method = read_u16(data, pos + 10);
            let comp_size = read_u32(data, pos + 20) as usize;
            let uncomp_size = read_u32(data, pos + 24) as usize;
            let name_len = read_u16(data, pos + 28) as usize;
            let extra_len = read_u16(data, pos + 30) as usize;
            let comment_len = read_u16(data, pos + 32) as usize;
            let local_header_offset = read_u32(data, pos + 42) as usize;

            if pos + 46 + name_len > data.len() {
                break;
            }
            let name = String::from_utf8_lossy(&data[pos + 46..pos + 46 + name_len]).to_string();
            pos += 46 + name_len + extra_len + comment_len;

            if name.ends_with('/') {
                continue;
            }
            if local_header_offset + 30 > data.len()
                || data[local_header_offset] != 0x50
                || data[local_header_offset + 1] != 0x4b
                || data[local_header_offset + 2] != 0x03
                || data[local_header_offset + 3] != 0x04
            {
                continue;
            }
            let local_name_len = read_u16(data, local_header_offset + 26) as usize;
            let local_extra_len = read_u16(data, local_header_offset + 28) as usize;
            let data_start = local_header_offset + 30 + local_name_len + local_extra_len;
            if data_start + comp_size > data.len() {
                continue;
            }

            let slice = &data[data_start..data_start + comp_size];
            if method == 0 {
                entries.insert(name, slice.to_vec());
            } else if method == 8 {
                let mut decoder = DeflateDecoder::new(slice);
                let mut out = Vec::with_capacity(uncomp_size.max(slice.len()));
                decoder.read_to_end(&mut out).map_err(|e| {
                    SketchDocumentError::InvalidArchive(format!("Deflate error: {}", e))
                })?;
                entries.insert(name, out);
            }
        }

        Ok(entries)
    }

    pub fn write_entries_to_path(
        entries: &HashMap<String, Vec<u8>>,
        path: &Path,
    ) -> Result<(), SketchDocumentError> {
        let bytes = Self::write_entries(entries)?;
        std::fs::write(path, bytes).map_err(|e| SketchDocumentError::IoError(e.to_string()))
    }

    pub fn write_entries(entries: &HashMap<String, Vec<u8>>) -> Result<Vec<u8>, SketchDocumentError> {
        let mut out = Vec::new();
        let mut central_dir = Vec::new();
        let mut names: Vec<&String> = entries.keys().collect();
        names.sort();

        for name in names {
            let raw = &entries[name];
            let name_bytes = name.as_bytes();
            let local_offset = out.len() as u32;
            let crc = crc32fast::hash(raw);

            let is_precompressed = name.starts_with("images/")
                || name.starts_with("previews/")
                || name.ends_with(".png");

            let (payload, method): (Vec<u8>, u16) = if is_precompressed {
                (raw.clone(), 0)
            } else {
                let mut encoder = DeflateEncoder::new(Vec::new(), Compression::default());
                encoder
                    .write_all(raw)
                    .map_err(|e| SketchDocumentError::InvalidArchive(e.to_string()))?;
                let compressed = encoder
                    .finish()
                    .map_err(|e| SketchDocumentError::InvalidArchive(e.to_string()))?;
                if compressed.len() < raw.len() {
                    (compressed, 8)
                } else {
                    (raw.clone(), 0)
                }
            };

            // Local file header (0x04034b50)
            out.extend_from_slice(&0x04034b50u32.to_le_bytes());
            out.extend_from_slice(&20u16.to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&method.to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(&crc.to_le_bytes());
            out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
            out.extend_from_slice(&(raw.len() as u32).to_le_bytes());
            out.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
            out.extend_from_slice(&0u16.to_le_bytes());
            out.extend_from_slice(name_bytes);
            out.extend_from_slice(&payload);

            // Central directory header (0x02014b50)
            central_dir.extend_from_slice(&0x02014b50u32.to_le_bytes());
            central_dir.extend_from_slice(&20u16.to_le_bytes());
            central_dir.extend_from_slice(&20u16.to_le_bytes());
            central_dir.extend_from_slice(&0u16.to_le_bytes());
            central_dir.extend_from_slice(&method.to_le_bytes());
            central_dir.extend_from_slice(&0u16.to_le_bytes());
            central_dir.extend_from_slice(&0u16.to_le_bytes());
            central_dir.extend_from_slice(&crc.to_le_bytes());
            central_dir.extend_from_slice(&(payload.len() as u32).to_le_bytes());
            central_dir.extend_from_slice(&(raw.len() as u32).to_le_bytes());
            central_dir.extend_from_slice(&(name_bytes.len() as u16).to_le_bytes());
            central_dir.extend_from_slice(&0u16.to_le_bytes());
            central_dir.extend_from_slice(&0u16.to_le_bytes());
            central_dir.extend_from_slice(&0u16.to_le_bytes());
            central_dir.extend_from_slice(&0u16.to_le_bytes());
            central_dir.extend_from_slice(&0u32.to_le_bytes());
            central_dir.extend_from_slice(&local_offset.to_le_bytes());
            central_dir.extend_from_slice(name_bytes);
        }

        let cd_offset = out.len() as u32;
        let cd_size = central_dir.len() as u32;
        let count = entries.len() as u16;
        out.extend_from_slice(&central_dir);

        // End of Central Directory (0x06054b50)
        out.extend_from_slice(&0x06054b50u32.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&count.to_le_bytes());
        out.extend_from_slice(&count.to_le_bytes());
        out.extend_from_slice(&cd_size.to_le_bytes());
        out.extend_from_slice(&cd_offset.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());

        Ok(out)
    }
}

#[inline(always)]
fn read_u16(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([bytes[offset], bytes[offset + 1]])
}

#[inline(always)]
fn read_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ])
}

// MARK: - SketchDocumentIO (Reader, Validator, Crash Fix, Repair, Writer & Versioned Preset Reader)

pub struct SketchDocumentIO;

impl SketchDocumentIO {
    pub const CURRENT_ARCHIVE_VERSION: i64 = 139;
    pub const DEFAULT_COMPATIBILITY_VERSION: i64 = 99;

    /// Reconstructs `+[MSDocumentReader readerForDocumentAtURL:]`
    pub fn detect_format(path: &Path) -> Result<SketchReaderFormat, SketchDocumentError> {
        let mut f = File::open(path).map_err(|e| SketchDocumentError::IoError(e.to_string()))?;
        let mut magic = [0u8; 4];
        let n = f
            .read(&mut magic)
            .map_err(|e| SketchDocumentError::IoError(e.to_string()))?;
        if n == 4 && magic == [0x50, 0x4b, 0x03, 0x04] {
            Ok(SketchReaderFormat::ZippedJson)
        } else {
            Ok(SketchReaderFormat::LegacySqlite)
        }
    }

    /// Reconstructs `-[MSDocumentZippedJSONReader validate]`
    pub fn validate(entries: &HashMap<String, Vec<u8>>) -> SketchValidationStatus {
        let Some(meta_bytes) = entries.get("meta.json") else {
            return SketchValidationStatus::CorruptMetadata;
        };
        if !entries.contains_key("user.json") {
            return SketchValidationStatus::CorruptMetadata;
        }
        let Ok(Value::Object(meta_obj)) = serde_json::from_slice::<Value>(meta_bytes) else {
            return SketchValidationStatus::CorruptMetadata;
        };
        let compat_version = meta_obj
            .get("compatibilityVersion")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        if compat_version > Self::CURRENT_ARCHIVE_VERSION {
            return SketchValidationStatus::IncompatibleNewer; // status 5
        }
        let version = meta_obj.get("version").and_then(|v| v.as_i64()).unwrap_or(0);
        if version > Self::CURRENT_ARCHIVE_VERSION {
            return SketchValidationStatus::NewerVersionWarning; // status 4
        }
        if version <= 87 {
            return SketchValidationStatus::LegacyUnsupported; // status 3
        }
        SketchValidationStatus::Valid // status 0
    }

    /// Safe share lookup fixing Sketch 82.1's `NSInvalidArgumentException: data parameter is nil`
    /// discovered in `-[MSDocumentZippedJSONReader shareFrom:at:]` when `user.json` is missing.
    pub fn share_info(entries: &HashMap<String, Vec<u8>>) -> Option<Value> {
        fn extract(entries: &HashMap<String, Vec<u8>>, subpath: &str, key: &str) -> Option<Value> {
            let raw = entries.get(subpath)?;
            let Value::Object(dict) = serde_json::from_slice::<Value>(raw).ok()? else {
                return None;
            };
            let Value::Object(container) = dict.get(key)? else {
                return None;
            };
            container.get("cloudShare").cloned()
        }
        extract(entries, "document.json", "documentState")
            .or_else(|| extract(entries, "user.json", "document"))
    }

    pub fn read_document_from_path(
        path: &Path,
        allow_repair_or_newer: bool,
    ) -> Result<(SketchDocumentArchive, SketchValidationStatus, bool), SketchDocumentError> {
        let entries = SketchZipArchive::read_entries_from_path(path)?;
        Self::read_document_from_entries(&entries, allow_repair_or_newer)
    }

    pub fn read_document_from_entries(
        entries: &HashMap<String, Vec<u8>>,
        allow_repair_or_newer: bool,
    ) -> Result<(SketchDocumentArchive, SketchValidationStatus, bool), SketchDocumentError> {
        let status = Self::validate(entries);
        if status == SketchValidationStatus::IncompatibleNewer
            || (!allow_repair_or_newer && status != SketchValidationStatus::Valid)
        {
            return Err(SketchDocumentError::ValidationFailed(status));
        }

        let mut was_repaired = false;
        let meta_dict = entries
            .get("meta.json")
            .and_then(|b| serde_json::from_slice::<Value>(b).ok())
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_else(|| {
                was_repaired = true;
                SketchDocumentArchive::default_meta()
            });
        let user_dict = entries
            .get("user.json")
            .and_then(|b| serde_json::from_slice::<Value>(b).ok())
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_else(|| {
                was_repaired = true;
                Map::new()
            });
        if status == SketchValidationStatus::CorruptMetadata {
            was_repaired = true;
        }

        let doc_bytes = entries
            .get("document.json")
            .ok_or(SketchDocumentError::MissingDocumentJson)?;
        let Value::Object(doc_dict) = serde_json::from_slice::<Value>(doc_bytes)
            .map_err(|e| SketchDocumentError::InvalidArchive(e.to_string()))?
        else {
            return Err(SketchDocumentError::MissingDocumentJson);
        };

        let current_page_index = doc_dict
            .get("currentPageIndex")
            .and_then(|v| v.as_u64())
            .unwrap_or(0) as usize;

        let mut decoded_pages = Vec::new();
        if let Some(Value::Array(page_refs)) = doc_dict.get("pages") {
            for ref_val in page_refs {
                let Some(ref_path) = ref_val.get("_ref").and_then(|v| v.as_str()) else {
                    continue;
                };
                let json_path = if ref_path.ends_with(".json") {
                    ref_path.to_string()
                } else {
                    format!("{}.json", ref_path)
                };
                if let Some(page_bytes) = entries.get(&json_path) {
                    if let Ok(Value::Object(page_obj)) = serde_json::from_slice::<Value>(page_bytes)
                    {
                        decoded_pages.push(Self::decode_layer(&page_obj));
                    }
                }
            }
        }

        let mut images = HashMap::new();
        for (k, v) in entries {
            if k.starts_with("images/") {
                images.insert(k.clone(), v.clone());
            }
        }
        let preview_png = entries.get("previews/preview.png").cloned();
        let clamped_idx = if decoded_pages.is_empty() {
            0
        } else {
            current_page_index.min(decoded_pages.len() - 1)
        };

        Ok((
            SketchDocumentArchive {
                meta: meta_dict,
                user: user_dict,
                document_json: doc_dict,
                pages: decoded_pages,
                current_page_index: clamped_idx,
                images,
                preview_png,
            },
            status,
            was_repaired,
        ))
    }

    pub fn write_document(
        doc: &SketchDocumentArchive,
        path: &Path,
        is_autosave: bool,
    ) -> Result<(), SketchDocumentError> {
        let entries = Self::encode_document_entries(doc, is_autosave)?;
        SketchZipArchive::write_entries_to_path(&entries, path)
    }

    pub fn encode_document_entries(
        doc: &SketchDocumentArchive,
        is_autosave: bool,
    ) -> Result<HashMap<String, Vec<u8>>, SketchDocumentError> {
        let mut entries = HashMap::new();
        let mut page_refs = Vec::new();
        let mut pages_and_artboards = Map::new();

        for page in &doc.pages {
            let page_id = &page.do_object_id;
            let subpath = format!("pages/{}.json", page_id);
            let page_obj = Self::encode_layer(page);
            let bytes = serde_json::to_vec(&Value::Object(page_obj))
                .map_err(|e| SketchDocumentError::InvalidArchive(e.to_string()))?;
            entries.insert(subpath, bytes);

            page_refs.push(json!({
                "_class": "MSJSONFileReference",
                "_ref_class": "MSImmutablePage",
                "_ref": format!("pages/{}", page_id)
            }));

            let mut artboards_meta = Map::new();
            for child in &page.layers {
                if child.kind() == SketchLayerKind::Artboard
                    || child.kind() == SketchLayerKind::SymbolMaster
                {
                    artboards_meta.insert(child.do_object_id.clone(), json!({ "name": child.name }));
                }
            }
            pages_and_artboards.insert(
                page_id.clone(),
                json!({
                    "name": page.name,
                    "artboards": artboards_meta
                }),
            );
        }

        let mut doc_obj = doc.document_json.clone();
        doc_obj
            .entry("_class".to_string())
            .or_insert_with(|| json!("document"));
        doc_obj
            .entry("do_objectID".to_string())
            .or_insert_with(|| json!(new_sketch_id()));
        doc_obj
            .entry("colorSpace".to_string())
            .or_insert_with(|| json!(0));
        doc_obj.insert("currentPageIndex".to_string(), json!(doc.current_page_index));
        doc_obj.insert("pages".to_string(), Value::Array(page_refs));
        entries.insert(
            "document.json".to_string(),
            serde_json::to_vec(&Value::Object(doc_obj))
                .map_err(|e| SketchDocumentError::InvalidArchive(e.to_string()))?,
        );

        let mut user_obj = doc.user.clone();
        user_obj
            .entry("document".to_string())
            .or_insert_with(|| json!({ "pageListHeight": 85, "pageListCollapsed": 0 }));
        entries.insert(
            "user.json".to_string(),
            serde_json::to_vec(&Value::Object(user_obj))
                .map_err(|e| SketchDocumentError::InvalidArchive(e.to_string()))?,
        );

        let mut meta_obj = if doc.meta.is_empty() {
            SketchDocumentArchive::default_meta()
        } else {
            doc.meta.clone()
        };
        meta_obj.insert("version".to_string(), json!(Self::CURRENT_ARCHIVE_VERSION));
        meta_obj
            .entry("compatibilityVersion".to_string())
            .or_insert_with(|| json!(Self::DEFAULT_COMPATIBILITY_VERSION));
        meta_obj.insert(
            "coeditCompatibilityVersion".to_string(),
            json!(Self::CURRENT_ARCHIVE_VERSION),
        );
        meta_obj.insert("autosaved".to_string(), json!(if is_autosave { 1 } else { 0 }));
        meta_obj.insert(
            "pagesAndArtboards".to_string(),
            Value::Object(pages_and_artboards),
        );
        entries.insert(
            "meta.json".to_string(),
            serde_json::to_vec(&Value::Object(meta_obj))
                .map_err(|e| SketchDocumentError::InvalidArchive(e.to_string()))?,
        );

        for (k, v) in &doc.images {
            entries.insert(k.clone(), v.clone());
        }
        if let Some(preview) = &doc.preview_png {
            entries.insert("previews/preview.png".to_string(), preview.clone());
        }

        Ok(entries)
    }

    /// Reconstructs `MSVersionedArchiveReader` for `.sketchpreset` archives.
    pub fn read_versioned_preset_archive(
        entries: &HashMap<String, Vec<u8>>,
    ) -> Result<SketchVersionedPresetArchive, SketchDocumentError> {
        let meta_bytes = entries.get("meta.json").ok_or_else(|| {
            SketchDocumentError::InvalidArchive("Missing meta.json in preset archive".to_string())
        })?;
        let archive_bytes = entries.get("archive.json").ok_or_else(|| {
            SketchDocumentError::InvalidArchive("Missing archive.json in preset archive".to_string())
        })?;
        let Value::Object(meta_obj) = serde_json::from_slice::<Value>(meta_bytes)
            .map_err(|e| SketchDocumentError::InvalidArchive(e.to_string()))?
        else {
            return Err(SketchDocumentError::InvalidArchive("Invalid meta.json".to_string()));
        };
        let Value::Object(archive_obj) = serde_json::from_slice::<Value>(archive_bytes)
            .map_err(|e| SketchDocumentError::InvalidArchive(e.to_string()))?
        else {
            return Err(SketchDocumentError::InvalidArchive(
                "Invalid archive.json".to_string(),
            ));
        };

        let version = meta_obj
            .get("version")
            .and_then(|v| v.as_i64())
            .unwrap_or(Self::CURRENT_ARCHIVE_VERSION);
        let root_obj = archive_obj
            .get("root")
            .and_then(|v| v.as_object())
            .cloned()
            .unwrap_or(archive_obj);

        let mut colors = Vec::new();
        if let Some(Value::Array(color_assets)) = root_obj.get("colorAssets") {
            for item in color_assets {
                if let Some(c_obj) = item.get("color").and_then(|v| v.as_object()) {
                    colors.push(Self::decode_color(Some(c_obj), SketchColor::SKETCH_BLUE));
                }
            }
        }
        if let Some(Value::Array(raw_colors)) = root_obj.get("colors") {
            for item in raw_colors {
                if let Some(c_obj) = item.as_object() {
                    colors.push(Self::decode_color(Some(c_obj), SketchColor::SKETCH_BLUE));
                }
            }
        }

        let mut gradients = Vec::new();
        if let Some(Value::Array(grad_assets)) = root_obj.get("gradientAssets") {
            for item in grad_assets {
                if let Some(g_obj) = item.get("gradient").and_then(|v| v.as_object()) {
                    if let Some(grad) = Self::decode_gradient(Some(g_obj)) {
                        gradients.push(grad);
                    }
                }
            }
        }

        Ok(SketchVersionedPresetArchive {
            version,
            meta: meta_obj,
            archive_root: root_obj,
            colors,
            gradients,
        })
    }

    // MARK: - Layer & Style JSON Mapping

    pub fn decode_layer(dict: &Map<String, Value>) -> SketchLayer {
        let cls = dict
            .get("_class")
            .and_then(|v| v.as_str())
            .unwrap_or("group");
        let id = dict
            .get("do_objectID")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(new_sketch_id);
        let name = dict
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or(cls)
            .to_string();
        let kind = SketchLayerKind::from_class_name(cls);

        let mut frame = SketchRect::default();
        if let Some(f_obj) = dict.get("frame").and_then(|v| v.as_object()) {
            frame.x = f_obj.get("x").and_then(|v| v.as_f64()).unwrap_or(0.0);
            frame.y = f_obj.get("y").and_then(|v| v.as_f64()).unwrap_or(0.0);
            frame.width = f_obj.get("width").and_then(|v| v.as_f64()).unwrap_or(0.0);
            frame.height = f_obj.get("height").and_then(|v| v.as_f64()).unwrap_or(0.0);
            frame.constrain_proportions = f_obj
                .get("constrainProportions")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
        }

        let style = Self::decode_style(dict.get("style").and_then(|v| v.as_object()));
        let child_layers = dict
            .get("layers")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_object())
                    .map(Self::decode_layer)
                    .collect()
            })
            .unwrap_or_default();

        let mut points = Vec::new();
        if let Some(pts_arr) = dict.get("points").and_then(|v| v.as_array()) {
            for pt_val in pts_arr {
                let Some(pt_obj) = pt_val.as_object() else {
                    continue;
                };
                let pt_str = pt_obj
                    .get("point")
                    .and_then(|v| v.as_str())
                    .unwrap_or("{0, 0}")
                    .to_string();
                let cf_str = pt_obj
                    .get("curveFrom")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&pt_str)
                    .to_string();
                let ct_str = pt_obj
                    .get("curveTo")
                    .and_then(|v| v.as_str())
                    .unwrap_or(&pt_str)
                    .to_string();
                points.push(SketchCurvePoint {
                    point: pt_str,
                    curve_from: cf_str,
                    curve_to: ct_str,
                    has_curve_from: pt_obj
                        .get("hasCurveFrom")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false),
                    has_curve_to: pt_obj
                        .get("hasCurveTo")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false),
                    curve_mode: pt_obj.get("curveMode").and_then(|v| v.as_i64()).unwrap_or(1)
                        as i32,
                    corner_radius: pt_obj
                        .get("cornerRadius")
                        .and_then(|v| v.as_f64())
                        .unwrap_or(0.0),
                });
            }
        }

        let group_layout = dict
            .get("groupLayout")
            .and_then(|v| v.as_object())
            .map(|gl_obj| {
                let gl_cls = gl_obj
                    .get("_class")
                    .and_then(|v| v.as_str())
                    .unwrap_or("MSImmutableFreeformGroupLayout");
                if gl_cls == "MSImmutableInferredGroupLayout" {
                    SketchGroupLayout {
                        class_name: gl_cls.to_string(),
                        axis: Some(gl_obj.get("axis").and_then(|v| v.as_i64()).unwrap_or(0) as i32),
                        layout_anchor: Some(
                            gl_obj
                                .get("layoutAnchor")
                                .and_then(|v| v.as_i64())
                                .unwrap_or(0) as i32,
                        ),
                        min_size: Some(
                            gl_obj.get("minSize").and_then(|v| v.as_f64()).unwrap_or(0.0),
                        ),
                        max_size: Some(
                            gl_obj.get("maxSize").and_then(|v| v.as_f64()).unwrap_or(0.0),
                        ),
                    }
                } else {
                    SketchGroupLayout::freeform()
                }
            });

        let attributed_string = dict
            .get("attributedString")
            .and_then(|v| v.as_object())
            .map(|as_obj| {
                let s = as_obj
                    .get("string")
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();
                let mut attrs = Vec::new();
                if let Some(attr_arr) = as_obj.get("attributes").and_then(|v| v.as_array()) {
                    for a_val in attr_arr {
                        let Some(a_obj) = a_val.as_object() else {
                            continue;
                        };
                        let loc = a_obj.get("location").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
                        let len = a_obj
                            .get("length")
                            .and_then(|v| v.as_u64())
                            .unwrap_or(s.len() as u64) as usize;
                        let inner = a_obj.get("attributes").and_then(|v| v.as_object());
                        let font_obj = inner
                            .and_then(|i| i.get("MSAttributedStringFontAttribute"))
                            .and_then(|f| f.get("attributes"))
                            .and_then(|f| f.as_object());
                        let font_name = font_obj
                            .and_then(|f| f.get("name"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("HelveticaNeue")
                            .to_string();
                        let font_size = font_obj
                            .and_then(|f| f.get("size"))
                            .and_then(|v| v.as_f64())
                            .unwrap_or(14.0);
                        let color_obj = inner
                            .and_then(|i| i.get("MSAttributedStringColorAttribute"))
                            .and_then(|c| c.as_object());
                        let color = Self::decode_color(color_obj, SketchColor::BLACK);
                        attrs.push(SketchStringAttribute {
                            location: loc,
                            length: len,
                            font_name,
                            font_size,
                            color,
                            alignment: 0,
                            kerning: None,
                        });
                    }
                }
                SketchAttributedString {
                    string: s,
                    attributes: attrs,
                }
            });

        let override_values = dict
            .get("overrideValues")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| {
                        let o = v.as_object()?;
                        Some(SketchOverrideValue {
                            override_name: o.get("overrideName")?.as_str()?.to_string(),
                            value: o
                                .get("value")
                                .and_then(|val| val.as_str())
                                .unwrap_or("")
                                .to_string(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        let export_formats = dict
            .get("exportOptions")
            .and_then(|v| v.get("exportFormats"))
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| {
                        let o = v.as_object()?;
                        Some(SketchExportFormat {
                            scale: o.get("scale").and_then(|x| x.as_f64()).unwrap_or(1.0),
                            file_format: o
                                .get("fileFormat")
                                .and_then(|x| x.as_str())
                                .unwrap_or("png")
                                .to_string(),
                            name: o
                                .get("name")
                                .and_then(|x| x.as_str())
                                .unwrap_or("")
                                .to_string(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        let image_ref = dict
            .get("image")
            .and_then(|v| v.as_object())
            .and_then(|img| {
                Some(SketchFileReference {
                    ref_class: img
                        .get("_ref_class")
                        .and_then(|v| v.as_str())
                        .unwrap_or("MSImageData")
                        .to_string(),
                    ref_path: img.get("_ref")?.as_str()?.to_string(),
                })
            });

        let mut stripped_raw = dict.clone();
        for heavy in [
            "layers",
            "points",
            "style",
            "frame",
            "attributedString",
            "overrideValues",
            "overrideProperties",
            "exportOptions",
        ] {
            stripped_raw.remove(heavy);
        }

        let mut layer = SketchLayer::new(kind, name, frame);
        layer.class_name = cls.to_string();
        layer.do_object_id = id;
        layer.name_is_fixed = dict
            .get("nameIsFixed")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        layer.is_visible = dict
            .get("isVisible")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        layer.is_locked = dict
            .get("isLocked")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        layer.is_flipped_horizontal = dict
            .get("isFlippedHorizontal")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        layer.is_flipped_vertical = dict
            .get("isFlippedVertical")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        layer.is_fixed_to_viewport = dict
            .get("isFixedToViewport")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        layer.rotation = dict.get("rotation").and_then(|v| v.as_f64()).unwrap_or(0.0);
        layer.boolean_operation = SketchBooleanOperation::from_i32(
            dict.get("booleanOperation")
                .and_then(|v| v.as_i64())
                .unwrap_or(-1) as i32,
        );
        layer.style = style;
        layer.layers = child_layers;
        layer.points = points;
        layer.is_closed = dict
            .get("isClosed")
            .and_then(|v| v.as_bool())
            .unwrap_or(true);
        layer.fixed_radius = dict
            .get("fixedRadius")
            .and_then(|v| v.as_f64())
            .unwrap_or(0.0);
        layer.resizing_constraint = dict
            .get("resizingConstraint")
            .and_then(|v| v.as_i64())
            .unwrap_or(63) as i32;
        layer.resizing_type = dict
            .get("resizingType")
            .and_then(|v| v.as_i64())
            .unwrap_or(0) as i32;
        layer.has_clipping_mask = dict
            .get("hasClippingMask")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        layer.clipping_mask_mode = dict
            .get("clippingMaskMode")
            .and_then(|v| v.as_i64())
            .unwrap_or(0) as i32;
        layer.should_break_mask_chain = dict
            .get("shouldBreakMaskChain")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        layer.group_layout = group_layout;
        layer.has_background_color = dict
            .get("hasBackgroundColor")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        layer.background_color = dict
            .get("backgroundColor")
            .and_then(|v| v.as_object())
            .map(|c| Self::decode_color(Some(c), SketchColor::WHITE));
        layer.attributed_string = attributed_string;
        layer.symbol_id = dict
            .get("symbolID")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        layer.override_values = override_values;
        layer.export_options = SketchExportOptions {
            export_formats,
            should_trim: false,
        };
        layer.image_ref = image_ref;
        layer.raw_json = stripped_raw;
        layer
    }

    pub fn decode_style(dict: Option<&Map<String, Value>>) -> SketchStyle {
        let Some(dict) = dict else {
            return SketchStyle::default();
        };
        let id = dict
            .get("do_objectID")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .unwrap_or_else(new_sketch_id);

        let fills = dict
            .get("fills")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| {
                        let f = v.as_object()?;
                        Some(SketchFill {
                            is_enabled: f.get("isEnabled").and_then(|x| x.as_bool()).unwrap_or(true),
                            fill_type: f.get("fillType").and_then(|x| x.as_i64()).unwrap_or(0)
                                as i32,
                            color: Self::decode_color(
                                f.get("color").and_then(|x| x.as_object()),
                                SketchColor::DEFAULT_FILL,
                            ),
                            gradient: Self::decode_gradient(
                                f.get("gradient").and_then(|x| x.as_object()),
                            ),
                            context_settings: Self::decode_context_settings(
                                f.get("contextSettings").and_then(|x| x.as_object()),
                            ),
                            noise_index: 0,
                            noise_intensity: 0.0,
                            pattern_fill_type: 1,
                            pattern_tile_scale: 1.0,
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        let borders = dict
            .get("borders")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| {
                        let b = v.as_object()?;
                        Some(SketchBorder {
                            is_enabled: b.get("isEnabled").and_then(|x| x.as_bool()).unwrap_or(true),
                            fill_type: b.get("fillType").and_then(|x| x.as_i64()).unwrap_or(0)
                                as i32,
                            color: Self::decode_color(
                                b.get("color").and_then(|x| x.as_object()),
                                SketchColor::DEFAULT_BORDER,
                            ),
                            gradient: Self::decode_gradient(
                                b.get("gradient").and_then(|x| x.as_object()),
                            ),
                            context_settings: Self::decode_context_settings(
                                b.get("contextSettings").and_then(|x| x.as_object()),
                            ),
                            position: b.get("position").and_then(|x| x.as_i64()).unwrap_or(1) as i32,
                            thickness: b.get("thickness").and_then(|x| x.as_f64()).unwrap_or(1.0),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        let shadows = dict
            .get("shadows")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| Self::decode_shadow(v.as_object(), false))
                    .collect()
            })
            .unwrap_or_default();

        let inner_shadows = dict
            .get("innerShadows")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| Self::decode_shadow(v.as_object(), true))
                    .collect()
            })
            .unwrap_or_default();

        SketchStyle {
            do_object_id: id,
            fills,
            borders,
            shadows,
            inner_shadows,
            border_options: SketchBorderOptions::default(),
            blur: SketchBlur::default(),
            context_settings: Self::decode_context_settings(
                dict.get("contextSettings").and_then(|x| x.as_object()),
            ),
            miter_limit: dict.get("miterLimit").and_then(|x| x.as_f64()).unwrap_or(10.0),
            start_marker_type: 0,
            end_marker_type: 0,
            winding_rule: dict.get("windingRule").and_then(|x| x.as_i64()).unwrap_or(1) as i32,
        }
    }

    fn decode_color(dict: Option<&Map<String, Value>>, fallback: SketchColor) -> SketchColor {
        let Some(dict) = dict else {
            return fallback;
        };
        SketchColor {
            red: dict.get("red").and_then(|v| v.as_f64()).unwrap_or(fallback.red),
            green: dict
                .get("green")
                .and_then(|v| v.as_f64())
                .unwrap_or(fallback.green),
            blue: dict
                .get("blue")
                .and_then(|v| v.as_f64())
                .unwrap_or(fallback.blue),
            alpha: dict
                .get("alpha")
                .and_then(|v| v.as_f64())
                .unwrap_or(fallback.alpha),
        }
    }

    fn decode_gradient(dict: Option<&Map<String, Value>>) -> Option<SketchGradient> {
        let dict = dict?;
        let stops = dict
            .get("stops")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|s| {
                        let o = s.as_object()?;
                        Some(SketchGradientStop {
                            color: Self::decode_color(
                                o.get("color").and_then(|c| c.as_object()),
                                SketchColor::BLACK,
                            ),
                            position: o.get("position").and_then(|p| p.as_f64()).unwrap_or(0.0),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        Some(SketchGradient {
            gradient_type: dict.get("gradientType").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
            from: dict
                .get("from")
                .and_then(|v| v.as_str())
                .unwrap_or("{0.5, 0}")
                .to_string(),
            to: dict
                .get("to")
                .and_then(|v| v.as_str())
                .unwrap_or("{0.5, 1}")
                .to_string(),
            elipse_length: dict
                .get("elipseLength")
                .and_then(|v| v.as_f64())
                .unwrap_or(1.0),
            stops,
        })
    }

    fn decode_shadow(dict: Option<&Map<String, Value>>, is_inner: bool) -> Option<SketchShadow> {
        let dict = dict?;
        Some(SketchShadow {
            is_enabled: dict.get("isEnabled").and_then(|v| v.as_bool()).unwrap_or(true),
            blur_radius: dict.get("blurRadius").and_then(|v| v.as_f64()).unwrap_or(4.0),
            offset_x: dict.get("offsetX").and_then(|v| v.as_f64()).unwrap_or(0.0),
            offset_y: dict.get("offsetY").and_then(|v| v.as_f64()).unwrap_or(2.0),
            spread: dict.get("spread").and_then(|v| v.as_f64()).unwrap_or(0.0),
            color: Self::decode_color(
                dict.get("color").and_then(|c| c.as_object()),
                SketchColor::new(0.0, 0.0, 0.0, 0.25),
            ),
            context_settings: Self::decode_context_settings(
                dict.get("contextSettings").and_then(|c| c.as_object()),
            ),
            is_inner,
        })
    }

    fn decode_context_settings(
        dict: Option<&Map<String, Value>>,
    ) -> SketchGraphicsContextSettings {
        let Some(dict) = dict else {
            return SketchGraphicsContextSettings::default();
        };
        SketchGraphicsContextSettings {
            blend_mode: dict.get("blendMode").and_then(|v| v.as_i64()).unwrap_or(0) as i32,
            opacity: dict.get("opacity").and_then(|v| v.as_f64()).unwrap_or(1.0),
        }
    }

    pub fn encode_layer(layer: &SketchLayer) -> Map<String, Value> {
        let mut obj = layer.raw_json.clone();
        obj.insert("_class".to_string(), json!(layer.class_name));
        obj.insert("do_objectID".to_string(), json!(layer.do_object_id));
        obj.insert("name".to_string(), json!(layer.name));
        obj.insert("nameIsFixed".to_string(), json!(layer.name_is_fixed));
        obj.insert("isVisible".to_string(), json!(layer.is_visible));
        obj.insert("isLocked".to_string(), json!(layer.is_locked));
        obj.insert(
            "isFlippedHorizontal".to_string(),
            json!(layer.is_flipped_horizontal),
        );
        obj.insert(
            "isFlippedVertical".to_string(),
            json!(layer.is_flipped_vertical),
        );
        obj.insert("rotation".to_string(), json!(layer.rotation));
        obj.insert(
            "booleanOperation".to_string(),
            json!(layer.boolean_operation.as_i32()),
        );
        obj.insert(
            "resizingConstraint".to_string(),
            json!(layer.resizing_constraint),
        );
        obj.insert("hasClippingMask".to_string(), json!(layer.has_clipping_mask));
        obj.insert(
            "shouldBreakMaskChain".to_string(),
            json!(layer.should_break_mask_chain),
        );

        obj.insert(
            "frame".to_string(),
            json!({
                "_class": "rect",
                "constrainProportions": layer.frame.constrain_proportions,
                "x": layer.frame.x,
                "y": layer.frame.y,
                "width": layer.frame.width,
                "height": layer.frame.height
            }),
        );

        obj.insert(
            "style".to_string(),
            Value::Object(Self::encode_style(&layer.style)),
        );

        if !layer.layers.is_empty()
            || matches!(
                layer.kind(),
                SketchLayerKind::Page
                    | SketchLayerKind::Artboard
                    | SketchLayerKind::SymbolMaster
                    | SketchLayerKind::Group
                    | SketchLayerKind::ShapeGroup
            )
        {
            let encoded_children: Vec<Value> = layer
                .layers
                .iter()
                .map(|c| Value::Object(Self::encode_layer(c)))
                .collect();
            obj.insert("layers".to_string(), Value::Array(encoded_children));
        }

        if let Some(gl) = &layer.group_layout {
            if gl.is_smart_layout() {
                obj.insert(
                    "groupLayout".to_string(),
                    json!({
                        "_class": gl.class_name,
                        "axis": gl.axis.unwrap_or(0),
                        "layoutAnchor": gl.layout_anchor.unwrap_or(0),
                        "minSize": gl.min_size.unwrap_or(0.0),
                        "maxSize": gl.max_size.unwrap_or(0.0)
                    }),
                );
            } else {
                obj.insert(
                    "groupLayout".to_string(),
                    json!({ "_class": "MSImmutableFreeformGroupLayout" }),
                );
            }
        }

        if !layer.points.is_empty() {
            obj.insert("isClosed".to_string(), json!(layer.is_closed));
            obj.insert("fixedRadius".to_string(), json!(layer.fixed_radius));
            let pts: Vec<Value> = layer
                .points
                .iter()
                .map(|cp| {
                    json!({
                        "_class": "curvePoint",
                        "cornerRadius": cp.corner_radius,
                        "curveFrom": cp.curve_from,
                        "curveTo": cp.curve_to,
                        "hasCurveFrom": cp.has_curve_from,
                        "hasCurveTo": cp.has_curve_to,
                        "curveMode": cp.curve_mode,
                        "point": cp.point
                    })
                })
                .collect();
            obj.insert("points".to_string(), Value::Array(pts));
        }

        if let Some(attr) = &layer.attributed_string {
            let attrs: Vec<Value> = attr
                .attributes
                .iter()
                .map(|a| {
                    json!({
                        "_class": "stringAttribute",
                        "location": a.location,
                        "length": a.length,
                        "attributes": {
                            "MSAttributedStringFontAttribute": {
                                "_class": "fontDescriptor",
                                "attributes": {
                                    "name": a.font_name,
                                    "size": a.font_size
                                }
                            },
                            "MSAttributedStringColorAttribute": Self::encode_color(a.color)
                        }
                    })
                })
                .collect();
            obj.insert(
                "attributedString".to_string(),
                json!({
                    "_class": "attributedString",
                    "string": attr.string,
                    "attributes": attrs
                }),
            );
        }

        if let Some(sym_id) = &layer.symbol_id {
            obj.insert("symbolID".to_string(), json!(sym_id));
        }

        if !layer.override_values.is_empty() {
            let ovs: Vec<Value> = layer
                .override_values
                .iter()
                .map(|ov| {
                    json!({
                        "_class": "overrideValue",
                        "overrideName": ov.override_name,
                        "value": ov.value
                    })
                })
                .collect();
            obj.insert("overrideValues".to_string(), Value::Array(ovs));
        }

        obj
    }

    pub fn encode_style(style: &SketchStyle) -> Map<String, Value> {
        let fills: Vec<Value> = style
            .fills
            .iter()
            .map(|f| {
                json!({
                    "_class": "fill",
                    "isEnabled": f.is_enabled,
                    "fillType": f.fill_type,
                    "color": Self::encode_color(f.color),
                    "contextSettings": {
                        "_class": "graphicsContextSettings",
                        "blendMode": f.context_settings.blend_mode,
                        "opacity": f.context_settings.opacity
                    }
                })
            })
            .collect();

        let borders: Vec<Value> = style
            .borders
            .iter()
            .map(|b| {
                json!({
                    "_class": "border",
                    "isEnabled": b.is_enabled,
                    "fillType": b.fill_type,
                    "color": Self::encode_color(b.color),
                    "position": b.position,
                    "thickness": b.thickness
                })
            })
            .collect();

        let val = json!({
            "_class": "style",
            "do_objectID": style.do_object_id,
            "windingRule": style.winding_rule,
            "contextSettings": {
                "_class": "graphicsContextSettings",
                "blendMode": style.context_settings.blend_mode,
                "opacity": style.context_settings.opacity
            },
            "fills": fills,
            "borders": borders,
            "shadows": []
        });
        val.as_object().cloned().unwrap_or_default()
    }

    fn encode_color(c: SketchColor) -> Value {
        json!({
            "_class": "color",
            "red": c.red,
            "green": c.green,
            "blue": c.blue,
            "alpha": c.alpha
        })
    }
}
