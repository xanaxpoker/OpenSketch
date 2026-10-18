# REA on Sketch 82.1 — test log

Target: `/Applications/Sketch.app` (82.1, build 137007, universal x86_64+arm64).

Host: macOS 15.7.7 arm64, 24 GB. REA 6.5.0 (`tools/rea-cli`), Ghidra 12.1.4 with a locally built
`mac_arm_64` decompiler, Temurin JDK 25. Run `. env.sh` before using the CLI.

## Layout

| Path | What |
|---|---|
| `env.sh` | Exports GHIDRA_INSTALL_DIR, JAVA_HOME, PATH for `rea` |
| `rea/` | Source clone of morluto/rea (docs) |
| `tools/` | REA CLI, Ghidra, `list_windows` helper |
| `scripts/rea_mcp_daemon.py`, `scripts/rea_call.py` | Persistent `rea mcp` session over a Unix socket |
| `scripts/make_variants.py`, `scripts/probe_variant.py` | .sketch variant generator and UI probe |
| `out/` | REA verification artifacts and UI screenshots |
| `samples/` | Bundled template + crafted validation variants |

## Tool scorecard

| Tool | Result | Time |
|---|---|---|
| list-architectures, inspect-plist, inspect-macho, inspect-signature | OK; universal Mach-O metadata and code signature inspected | ~9 s total |
| trace-dylib-resolution | OK; 12 process roots, 30 images, 2183 edges, 22 rpath-shadowing findings | ~2 s |
| inspect-native-dispatch-metadata (SketchModel) | 647 ObjC class records, 5552 method impls in ~1 s; **partial**: `--max-records` capped at 20000, properties/categories/Swift not reached | 1 s |
| Ghidra via CLI one-shot | Universal binary rejected (clear error); thin arm64 slice OK; **113 s per call** because every CLI call re-imports | 113 s |
| Ghidra via MCP session | First query 110 s, then 20–100 ms per search/decompile/xref | — |
| batch_decompile / procedure_assembly / xrefs / trace_feature / search_bytes | OK; control flow and cross-references verified | ms |
| observe-native-calls (LLDB) | Breakpoints resolved 15/16 at addresses identical to static analysis | 3–9 s |
| observe-native-ui | Needs app launched via LaunchServices (`open`), else `process-identity-unavailable`; then OK: window PNG + 139 AX nodes | 4 s |
| capture-native-ui-scenario | Works mechanically; Sketch's custom layer list returns AXError -25200 yet the action took effect; "Pages" toggle reported success with no visible change | 4 s |
| observe-native-ui with two same-size windows | Fails closed: `ambiguous-window` (matches AX↔CG windows by geometry only) | — |
| decode-interface-builder | 64 nibs/storyboards, 5745 nodes, 2038 edges in 1.8 s; graph **truncated** — only 14 distinct action selectors survived | 1.8 s |
| inspect-asset-catalog | 3 catalogs, 3269 records | 1.8 s |

| Ghidra per-binary first query | SketchModel 110 s, main `Sketch` 203 s, SketchControllers 149 s, Chocolat 44 s | — |
| One document per MCP session | `open_binary` discards the previous target's analysis (`import_mode: ephemeral`); cross-framework work means repeated re-analysis | — |
| xrefs / trace_feature to strings (arm64) | **Missed** code→CFString references (`xrefs` on the CFString object returns `[]`) although static analysis resolves them; `trace_feature` reports `residual_unknowns: []` anyway | ms |
| capture-native-ui-scenario on an NSAlert | Click dismissed the alert, but the step is reported `failed` (`capture-window-missing`) because the after-capture window is gone | 4 s |

Other observations: full `tools/list` is 3.3 MB of schema (207 tools); schema text for UI-scenario
AX paths says "Local filesystem path" (copy-paste description bug); batch_decompile items use
`pseudocode` while other tools use `pseudo_code`.

## Reconstructed: how Sketch 82.1 opens a .sketch file

Static analysis via REA on `SketchModel`, cross-checked against real files:

1. `MSStandardDocumentOpener -open:` → `+[MSDocumentReader readerForDocumentAtURL:]`
2. Reader chosen from the first 4 bytes (`+first4bytesOfFileAtURL:` = `NSFileHandle` + `read(fd, 4)`):
   - `PK\3\4` → `MSDocumentZippedJSONReader` (current format)
   - `SQLi` ("SQLite format 3") → `MSLegacyDocumentReader` (pre-ZIP format)
   - anything else → `MSLegacyDocumentReader` (an `isFolderAtURL:` call's result is discarded — confirmed in assembly)
3. `MSDocumentZippedJSONReader -open:` reads `meta.json` → metadata, sets unarchiver current version
   **139** (`0x8b`) and archive version = `meta.version`; reads `user.json` → UI metadata.
4. `-validate` returns:
   - 2: meta.json or user.json missing
   - 5: `compatibilityVersion` > 139
   - 4: `version` > 139
   - 3: `version` ≤ 87
   - 0: otherwise
5. `-readImmutableDataWithCorruptionDetected:error:` → `MSImmutableDocumentData
   loadDocumentDataWithMetadata:loadBlock:`; the block reads `document.json`. Pages are
   `MSJSONFileReference` entries (`_ref: "pages/<UUID>"`, `_ref_class: MSImmutablePage`).
6. `-repair` synthesizes a fresh `MSArchiveHeader metadataForNewHeader` and an empty user dict.

`MSVersionedArchiveReader` is a different format (meta.json + archive.json): it reads
`Contents/Resources/assets.sketchpreset`, confirmed by unzipping that file.

### Predictions vs. runtime (crafted files, observed with REA UI tools)

| Variant | Predicted | Observed |
|---|---|---|
| compatibilityVersion 140 | status 5 error | ✅ "This document was created with a newer version of Sketch. Please upgrade…" |
| version 140 | status 4 → handleNewerDocument | ✅ "…last edited in a newer version… may result in some data being lost" [Cancel/Open Anyway] |
| version 87 | status 3 → corrupt-metadata prompt | ✅ "Unable to Open File… missing some data" [Don't Open/Try to Open Anyway] |
| user.json removed | status 2 → same prompt | ❌ no prompt, no window — the open dies before `-validate` (see below) |

### Following the miss across binaries

- Main binary (`Sketch`, first query 203 s): `-[MSDocument readFromURL:ofType:error:]` routes Sketch UTIs
  to `-readDocumentFromURL:ofType:error:` (SVG/PDF/EPS/images go to importers). That method uses
  `MSCoEditDocumentOpener` for collaborative docs, otherwise `MSStandardDocumentOpener` with an
  `MSDocumentOpeningContext` delegate.
- `-[MSDocumentOpeningContext shouldOpenDocumentWithCorruptMetadata:]` forwards to
  `+[MSCorruptMetadataWarning shouldOpenDocumentWithCorruptMetadata]` in SketchControllers (149 s),
  which unconditionally runs the "Unable to Open File / missing some data" NSAlert and returns YES only for
  "Try to Open Anyway" (`0x3e9`). That is exactly the v3 dialog, so status 2 would have prompted too.
- Unified log for both v2 launches: `[StateRestoration] _NSPersistentUIExecuteDispatchedBlock Ignoring
  exception: data parameter is nil` (NSInvalidArgumentException). AppKit swallows it, so the document
  silently fails to open. No such fault for the v3/v4/v5 launches.
- Not the ZIP layer: `BCJSONZippedDecoder` (Chocolat, minizip) returns nil + error code 4 "Unable to locate
  … in the archive" for a missing member (its error ivar is sticky across later calls).
- Root cause, in SketchModel:
  - `-[MSDocumentZippedJSONReader share]` checks `shareFrom:@"document.json" at:@"documentState"` and falls back to `shareFrom:@"user.json" at:@"document"`.
  - `-[MSDocumentZippedJSONReader shareFrom:at:]` calls `[unarchiver unarchivedRawDataAtSubpath:path error:&e]` (which returns `nil` when `user.json` is missing) and passes that `nil` `NSData` directly into `+[NSJSONSerialization JSONObjectWithData:options:error:]` without a nil guard, throwing `NSInvalidArgumentException`.
  Local documents have no `documentState.cloudShare`, so the user.json fallback always runs. The share lookup
  (`+[MSDocumentReader shareInfoForDocumentAtURL:]`, selector used by SharedEditing and the main binary) runs
  before the standard opener, so the exception escapes before `-validate` can offer its recovery dialog.
- Differential test: `v6-no-meta-json` (meta.json removed, user.json kept) → share lookup succeeds → status 2
  → "Unable to Open File / missing some data" dialog, and no `data parameter is nil` fault in the log. ✅
- Environment note: `open -a` into an already-running, backgrounded Sketch did nothing for any variant
  (macOS defers the open until the app is activated). Fresh launches were used for all comparisons.
- Shell note: `log` is a zsh builtin; use `/usr/bin/log`.

---

## Full Multi-Framework Discovery & `OpenSketch` Clean-Room Reconstruction

### 1. Exhaustive REA Discovery Across All 15 Binaries & 325 NIBs

| Artifact / Evidence Surface | REA Flow Used | Key Extracted Facts |
|---|---|---|
| Objective-C dispatch metadata (15 binaries) | `rea inspect-native-dispatch-metadata` | **2,884 Objective-C classes**, **18,120 method implementations**, **4,341 ivars** across `Sketch` (1,019 classes), `SketchModel` (647), `SketchControllers` (434), `SketchRendering` (202), `SketchSVG` (146), `SharedEditing` (110), `BCFoundation` (102), `Chocolat` (94), `BCLayerList` (56), `SketchPluginManager` (28), `SketchPDF` (26), `Assistants` (18), `SketchToolSupport` (2), `Clipper`, and `Ekranoplan` |
| Demangled Swift metadata | `rea inspect-macho` + `rea demangle-swift` | **6,254 demangled Swift symbols** across `SketchControllers` (2,671), `SketchRendering` (2,267), `SketchModel` (1,068), and `BCLayerList` (248) |
| Interface Builder UI graph | `rea decode-interface-builder` (6 hardlink batches bypassing the 64-doc Sparkle NIB cap) | **325 Sketch NIBs**, **18,093 UI nodes**, **8,246 outlet/action connections**, and **516 distinct UI action selectors** |
| Static procedure & cross-reference analysis | Persistent `rea mcp` daemon (`scripts/rea_mcp_daemon.py` + `scripts/rea_call.py`) `search_procedures` + `xrefs` | Behavioral specifications for `MSDocumentWriter`, `MSArchiveHeader`, `MSJSONZippedArchiver`, `MSBezierBuilder` (`buildV1CGPath:`, `appendCurveFromPoint:toPoint:toCGPath:` with fillet kappa `0.4477152502`), `MSPath` (`booleanOp:withPath:` codes `0..3`), `MSImmutableSymbolInstance`, `MSImmutableStyle`, `SketchSVGExporter`, `MSExporter`, and `MSPresentationRenderer` |
| Live UI observation | `rea observe-native-ui` + `rea capture-native-ui-scenario` | Live window observation on `samples/smart-layout.sketch` with populated Inspector and Layer List (**287 AX nodes**) |

### 2. Reconstructed `OpenSketch` Native macOS Application (`OpenSketch/`)

Built in Swift 5.10 (`AppKit` + `SwiftUI` + `CoreGraphics` + `zlib`) with zero external dependencies:

- **`OpenSketch/Package.swift`**: Defines `OpenSketchCore`, `OpenSketch` (native macOS app executable), `opensketch-cli`, and `OpenSketchTests`.
- **`OpenSketch/Sources/OpenSketchCore/SketchModel.swift`**: Complete `.sketch` v139 (`0x8b`) data model (`SketchDocumentArchive`, `SketchLayer`, `SketchStyle`, `SketchFill`, `SketchBorder`, `SketchShadow`, `SketchBlur`, `SketchGradient`, `SketchCurvePoint`, `SketchAttributedString`, `SketchGroupLayout`, `SketchOverrideValue`, `SketchExportOptions`, `SketchPointString`, and lossless `JSONValue` round-tripping).
- **`OpenSketch/Sources/OpenSketchCore/SketchDocumentIO.swift`**:
  - Pure-Swift + `zlib` PKZIP reader/writer (`SketchZipArchive`) with zero-copy central directory parsing and `JSONSerialization`-backed `JSONValue.parseObject(from:)`.
  - Magic-byte format detector (`SketchDocumentIO.detectFormat(at:)`: `PK\x03\x04` -> `.zippedJSON`, `SQLi` -> `.legacySQLite`).
  - Archive validator (`SketchDocumentIO.validate(entries:)`) implementing exact status codes `0` (valid), `2` (missing `meta.json`/`user.json`), `3` (`version <= 87`), `4` (`version > 139 && compatibilityVersion <= 139`), and `5` (`compatibilityVersion > 139`).
  - Crash-free `SketchDocumentIO.shareInfo(in:)` that fixes Sketch 82.1's `NSInvalidArgumentException: data parameter is nil` when `user.json` is missing (`samples/variants/v2-no-user-json.sketch`).
  - Automatic `-repair` synthesis (`MSArchiveHeader.metadataForNewHeader` v139 + empty user dictionary).
  - `SketchVersionedPresetArchive` + `SketchDocumentIO.readVersionedPresetArchive(at:)` reconstructing `MSVersionedArchiveReader` (`meta.json` + `archive.json` for `Contents/Resources/assets.sketchpreset`).
- **`OpenSketch/Sources/OpenSketchCore/SketchGeometry.swift`**:
  - `SketchBezierBuilder`: Unit coordinate `[0..1]` conversion (`_BCPointConvertFromUnitCoordinates`), cubic bezier segment construction, corner radius fillet with kappa complement `0.4477152502`, and SVG `<path d="...">` serialization.
  - `SketchBooleanEngine`: Polygon boolean operations (`Union = 0`, `Subtract = 1`, `Intersect = 2`, `Difference = 3`, plus `flattenShapeGroup`).
  - `SketchSmartLayoutEngine`: Recursive `symbolInstance` expansion, `<objectID>_stringValue` override application, and dynamic horizontal/vertical `MSImmutableInferredGroupLayout` resizing.
  - `SketchSnapEngine`: Real-time edge & center snapping guides (`#F53163`) and `tidyLayers` distribution.
- **`OpenSketch/Sources/OpenSketchCore/SketchRenderingEngine.swift`**:
  - `SketchRenderCache`: Thread-safe cache for pre-decoded uncompressed RGBA `CGImage` bitmaps, $O(1)$ `symbolMaster` index, cached Smart Layout expanded `symbolInstance`s, cached boolean/Bezier `CGPath`s, and cached CoreText `CTLine` runs.
  - `SketchCoreGraphicsRenderer`: Renders pages, artboards, `symbolMaster`s, `symbolInstance`s, `shapeGroup`s, bezier paths, polygons, stars, triangles, sibling clipping masks (`hasClippingMask` / `shouldBreakMaskChain`), multi-fills, linear/radial gradients, inside/center/outside borders, shadows, attributed typography, and bitmaps with viewport frustum culling (`visibleCanvasRect`).
  - `SketchPerformanceSuite`: 6-check automated performance benchmark suite (`document_archive_load`, `warm_canvas_frame_render`, `continuous_60_frame_pan_zoom`, `viewport_frustum_culling`, `symbol_master_smart_layout_cache`, `interactive_hit_test_and_snap`).
  - `SketchExporter`: Exports artboards/pages/layers to SVG (`out/opensketch-exported.svg`), 2x PNG (`out/opensketch-exported.png`), vector PDF (`out/opensketch-exported.pdf`), and CSS attributes (`copyCSSAttributes:`).
- **`OpenSketch/Sources/OpenSketch/`** (`OpenSketchApp.swift`, `MainWorkspaceView.swift`, `InfiniteCanvasView.swift`, `InspectorView.swift`):
  - Full macOS workspace with Sketch 82.1 Toolbar (`Canvas | Components` toggle, 11 shape/insert tools including `Rectangle`, `Rounded`, `Oval`, `Polygon`, `Star`, `Triangle`, `Line`, `Vector`, `Text`, `Slice`, `Artboard`, `Create Symbol`, `Group`/`Ungroup`, `Edit Points`, Boolean ops `Union`/`Subtract`/`Intersect`/`Difference`, and `Perf Checks`), Left Sidebar (`PAGES`, `Search Layers`, hierarchical `LayerTreeRowView` with lock/visibility toggles, mask `M` and boolean badges), Center 120Hz `InfiniteCanvasView` (decoupled trackpad scroll/magnify pan/zoom, live CoreGraphics FPS telemetry HUD, rulers, pixel grid, 8-handle resizing, live snapping guides, interactive vector Bezier point/handle editor) & `ComponentsLibraryView` (Document Symbols + `MSVersionedArchiveReader` Color Presets), and Right `InspectorView` (8-button alignment bar, `X/Y/W/H/Rotation/Radius/Tidy`, Resizing Constraints pin/fix-size controls, `Use as Mask`, Artboard background, Smart Layout picker, live Symbol Overrides, Vector Point curve mode editor, Typography, Opacity, Fills, Borders, Shadows, Blur, and `MAKE EXPORTABLE`).

### 3. Verification, Performance Benchmarks & REA Reconstruction Closure

- **Unit & Integration Test Suite (`swift test`)**: **9/9 test cases pass** in `0.75s` in `OpenSketchTests.swift` across `samples/smart-layout.sketch`, `assets.sketchpreset`, and all 6 variants in `samples/variants/v0..v6`.
- **Automated Performance Check Suite (`opensketch-cli bench` / `testPerformanceChecksSuite`)**: **6/6 PASSED** (`out/opensketch-perf-bench.json`):
  1. `document_archive_load`: **42.84 ms** (budget `<= 250 ms`)
  2. `warm_canvas_frame_render`: **2.03 ms / 120 FPS** (budget `<= 8.33 ms`)
  3. `continuous_60_frame_pan_zoom`: **0.85 ms/frame avg, 2.45 ms P95 / 120 FPS** (budget `<= 6.0 ms`)
  4. `viewport_frustum_culling`: **0.49 ms** (budget `<= 4.0 ms`, `109` off-screen layers culled)
  5. `symbol_master_smart_layout_cache`: **2.00 ms** for `1,360` symbol expansions (budget `<= 5.0 ms`)
  6. `interactive_hit_test_and_snap`: **0.26 ms** for `100` drag ticks (budget `<= 4.0 ms`)
- **Live UI Observation (`rea observe-native-ui`)**: Captured `OpenSketch/build/OpenSketch.app` running on `samples/smart-layout.sketch` (**364 AX nodes** in `out/opensketch-ui-perf.json` and window screenshot in `out/opensketch-ui-perf.png`).
- **REA Obligation Ledger (`rea build-reconstruction-obligation-ledger`)**: `status: "ready"`, `5/5` required obligations verified (`out/opensketch-ledger.json`).
- **REA Coverage Evaluation (`rea evaluate-reconstruction-coverage`)**: `boundary_id: "replacement.opensketch"`, `status: "ready"`, `5/5` required surfaces and `5/5` required claims verified with `0` blocking reasons (`out/opensketch-coverage.json`).
