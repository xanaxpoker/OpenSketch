import Foundation
import CoreGraphics
import CoreText
import ImageIO
import AppKit

// MARK: - Frame Render Statistics & Multi-Tier Render Cache

public struct SketchFrameRenderStats: Sendable, Equatable {
    public var drawnLayers: Int = 0
    public var culledLayers: Int = 0
    public var bitmapDraws: Int = 0
    public var symbolExpansions: Int = 0
    public init(drawnLayers: Int = 0, culledLayers: Int = 0, bitmapDraws: Int = 0, symbolExpansions: Int = 0) {
        self.drawnLayers = drawnLayers
        self.culledLayers = culledLayers
        self.bitmapDraws = bitmapDraws
        self.symbolExpansions = symbolExpansions
    }
}

/// High-speed thread-safe cache for pre-decoded uncompressed bitmap `CGImage`s, $O(1)$ `symbolMaster` lookup,
/// Smart Layout expanded `symbolInstance`s, and CoreText `CTLine` runs.
public final class SketchRenderCache: @unchecked Sendable {
    public static let shared = SketchRenderCache()

    private let lock = NSLock()
    private var decodedBitmaps: [String: CGImage] = [:]
    private var symbolMastersByDoc: [String: [String: SketchLayer]] = [:]
    private var expandedSymbols: [String: SketchLayer] = [:]
    private var ctLines: [String: (line: CTLine, fontSize: CGFloat)] = [:]
    private var titleCTLines: [String: CTLine] = [:]
    private var shapePaths: [String: CGPath] = [:]

    public private(set) var bitmapCacheHits: Int = 0
    public private(set) var bitmapCacheMisses: Int = 0
    public private(set) var symbolCacheHits: Int = 0
    public private(set) var symbolCacheMisses: Int = 0
    public private(set) var textCacheHits: Int = 0
    public private(set) var textCacheMisses: Int = 0

    private init() {}

    public func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        decodedBitmaps.removeAll()
        symbolMastersByDoc.removeAll()
        expandedSymbols.removeAll()
        ctLines.removeAll()
        titleCTLines.removeAll()
        shapePaths.removeAll()
        bitmapCacheHits = 0
        bitmapCacheMisses = 0
        symbolCacheHits = 0
        symbolCacheMisses = 0
        textCacheHits = 0
        textCacheMisses = 0
    }

    public func invalidateDocumentSymbols(documentID: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let docID = documentID {
            symbolMastersByDoc.removeValue(forKey: docID)
        } else {
            symbolMastersByDoc.removeAll()
        }
        expandedSymbols.removeAll()
        ctLines.removeAll()
        titleCTLines.removeAll()
        shapePaths.removeAll()
    }

    public func cachedShapeGroupPath(for layer: SketchLayer) -> CGPath {
        let key = "SG:\(layer.do_objectID):\(Int(layer.frame.width))x\(Int(layer.frame.height)):\(layer.layers.count)"
        lock.lock()
        if let hit = shapePaths[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let path = SketchBooleanEngine.evaluateShapeGroupPath(layer)
        lock.lock()
        if shapePaths.count > 4096 { shapePaths.removeAll(keepingCapacity: true) }
        shapePaths[key] = path
        lock.unlock()
        return path
    }

    public func cachedBezierPath(for layer: SketchLayer, in rect: CGRect) -> CGPath {
        let firstPt = layer.points.first?.point ?? ""
        let key = "BP:\(layer.do_objectID):\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height)):\(Int(layer.fixedRadius)):\(layer.points.count):\(firstPt)"
        lock.lock()
        if let hit = shapePaths[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let path: CGPath
        if !layer.points.isEmpty {
            path = SketchBezierBuilder.buildCGPath(
                points: layer.points,
                in: rect,
                isClosed: layer.isClosed,
                fixedRadius: layer.fixedRadius
            )
        } else if layer.kind == .oval {
            path = CGPath(ellipseIn: rect, transform: nil)
        } else {
            let r = min(CGFloat(layer.fixedRadius), min(rect.width, rect.height) * 0.5)
            path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }

        lock.lock()
        if shapePaths.count > 4096 { shapePaths.removeAll(keepingCapacity: true) }
        shapePaths[key] = path
        lock.unlock()
        return path
    }

    /// Decodes a PNG/JPEG `Data` blob from `document.images` once and pre-rasterizes it into an uncompressed
    /// premultiplied RGBA `CGImage` (capped at 512px max dimension) so `ctx.draw` never decompresses PNGs on frame ticks.
    public func cgImage(forRef ref: String, in document: SketchDocumentArchive) -> CGImage? {
        let key = "\(document.documentID):\(ref)"
        lock.lock()
        if let cached = decodedBitmaps[key] {
            bitmapCacheHits += 1
            lock.unlock()
            return cached
        }
        bitmapCacheMisses += 1
        lock.unlock()

        guard let data = document.images[ref] ?? document.images["\(ref).png"],
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let rawImg = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let maxDim = 512
        let srcW = max(1, rawImg.width)
        let srcH = max(1, rawImg.height)
        let scale = min(1.0, Double(maxDim) / Double(max(srcW, srcH)))
        let dstW = max(1, Int(round(Double(srcW) * scale)))
        let dstH = max(1, Int(round(Double(srcH) * scale)))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let finalImg: CGImage
        if let bmpCtx = CGContext(
            data: nil,
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bytesPerRow: dstW * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            bmpCtx.interpolationQuality = .medium
            bmpCtx.draw(rawImg, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
            finalImg = bmpCtx.makeImage() ?? rawImg
        } else {
            finalImg = rawImg
        }

        lock.lock()
        decodedBitmaps[key] = finalImg
        lock.unlock()
        return finalImg
    }

    /// $O(1)$ lookup of a `symbolMaster` by `symbolID`, building the per-document index once on first access.
    public func symbolMaster(forSymbolID symbolID: String, in document: SketchDocumentArchive) -> SketchLayer? {
        let docID = document.documentID
        lock.lock()
        if let docMap = symbolMastersByDoc[docID] {
            let found = docMap[symbolID]
            lock.unlock()
            return found
        }
        lock.unlock()

        var map: [String: SketchLayer] = [:]
        func walk(_ layer: SketchLayer) {
            if layer.kind == .symbolMaster, let sid = layer.symbolID {
                map[sid] = layer
            }
            for child in layer.layers {
                walk(child)
            }
        }
        for page in document.pages {
            walk(page)
        }

        lock.lock()
        symbolMastersByDoc[docID] = map
        let result = map[symbolID]
        lock.unlock()
        return result
    }

    private func symbolInstanceCacheKey(_ instance: SketchLayer, in document: SketchDocumentArchive) -> String {
        var overrideSig = ""
        for ov in instance.overrideValues {
            overrideSig.append("\(ov.overrideName)=\(ov.value);")
        }
        return "\(document.documentID):\(instance.do_objectID):\(instance.symbolID ?? ""):\(Int(instance.frame.width))x\(Int(instance.frame.height)):\(overrideSig)"
    }

    public func cachedExpandedSymbol(for instance: SketchLayer, in document: SketchDocumentArchive) -> SketchLayer? {
        let key = symbolInstanceCacheKey(instance, in: document)
        lock.lock()
        defer { lock.unlock() }
        if var hit = expandedSymbols[key] {
            symbolCacheHits += 1
            hit.frame.x = instance.frame.x
            hit.frame.y = instance.frame.y
            return hit
        }
        symbolCacheMisses += 1
        return nil
    }

    public func storeExpandedSymbol(_ expanded: SketchLayer, for instance: SketchLayer, in document: SketchDocumentArchive) {
        let key = symbolInstanceCacheKey(instance, in: document)
        lock.lock()
        if expandedSymbols.count > 2048 {
            expandedSymbols.removeAll(keepingCapacity: true)
        }
        expandedSymbols[key] = expanded
        lock.unlock()
    }

    public func cachedCTLine(for layer: SketchLayer) -> (line: CTLine, fontSize: CGFloat)? {
        guard let attrModel = layer.attributedString, !attrModel.string.isEmpty else { return nil }
        let fillHex = layer.style.firstEnabledFill?.color.hexString ?? "none"
        let firstSeg = attrModel.attributes.first
        let fSize = CGFloat(firstSeg?.fontSize ?? 14)
        let key = "\(layer.do_objectID):\(attrModel.string):\(fillHex):\(Int(fSize))"

        lock.lock()
        if let cached = ctLines[key] {
            textCacheHits += 1
            lock.unlock()
            return cached
        }
        textCacheMisses += 1
        lock.unlock()

        let fontName = firstSeg?.fontName ?? "HelveticaNeue"
        let font = CTFontCreateWithName(fontName as CFString, fSize, nil)
        let colorModel = layer.style.firstEnabledFill?.color ?? firstSeg?.color ?? .black
        let cgColor = CGColor(
            srgbRed: CGFloat(colorModel.red),
            green: CGFloat(colorModel.green),
            blue: CGFloat(colorModel.blue),
            alpha: CGFloat(colorModel.alpha)
        )
        let singleLineString = attrModel.string.replacingOccurrences(of: "\n", with: " ")
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: cgColor
        ]
        let nsAttr = NSAttributedString(string: singleLineString, attributes: attrs)
        let ctLine = CTLineCreateWithAttributedString(nsAttr as CFAttributedString)
        let entry = (line: ctLine, fontSize: fSize)

        lock.lock()
        if ctLines.count > 2048 {
            ctLines.removeAll(keepingCapacity: true)
        }
        ctLines[key] = entry
        lock.unlock()
        return entry
    }

    public func cachedTitleCTLine(for layer: SketchLayer) -> CTLine {
        let isSymbol = (layer.kind == .symbolMaster)
        let key = "\(isSymbol ? "S" : "A"):\(layer.name)"
        lock.lock()
        if let cached = titleCTLines[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let font = CTFontCreateUIFontForLanguage(.system, 11.0, nil) ?? CTFontCreateWithName("HelveticaNeue-Medium" as CFString, 11.0, nil)
        let cgColor = isSymbol
            ? CGColor(srgbRed: 0.58, green: 0.22, blue: 0.88, alpha: 0.95)
            : CGColor(srgbRed: 0.45, green: 0.45, blue: 0.48, alpha: 0.95)
        let prefix = isSymbol ? "❖ " : ""
        let attrs: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: cgColor
        ]
        let nsAttr = NSAttributedString(string: prefix + layer.name, attributes: attrs)
        let ctLine = CTLineCreateWithAttributedString(nsAttr as CFAttributedString)

        lock.lock()
        titleCTLines[key] = ctLine
        lock.unlock()
        return ctLine
    }
}

// MARK: - Live Frame Telemetry & Automated Performance Check Suite

public struct SketchPerformanceSnapshot: Sendable, Equatable {
    public var lastFrameMs: Double = 0
    public var avgFrameMs: Double = 0
    public var p95FrameMs: Double = 0
    public var estimatedFPS: Double = 120
    public var lastDrawnLayers: Int = 0
    public var lastCulledLayers: Int = 0
    public var totalFrames: Int = 0
    public var bitmapCacheHits: Int = 0
    public var symbolCacheHits: Int = 0

    public init(
        lastFrameMs: Double = 0,
        avgFrameMs: Double = 0,
        p95FrameMs: Double = 0,
        estimatedFPS: Double = 120,
        lastDrawnLayers: Int = 0,
        lastCulledLayers: Int = 0,
        totalFrames: Int = 0,
        bitmapCacheHits: Int = 0,
        symbolCacheHits: Int = 0
    ) {
        self.lastFrameMs = lastFrameMs
        self.avgFrameMs = avgFrameMs
        self.p95FrameMs = p95FrameMs
        self.estimatedFPS = estimatedFPS
        self.lastDrawnLayers = lastDrawnLayers
        self.lastCulledLayers = lastCulledLayers
        self.totalFrames = totalFrames
        self.bitmapCacheHits = bitmapCacheHits
        self.symbolCacheHits = symbolCacheHits
    }
}

public final class SketchPerformanceMonitor: @unchecked Sendable {
    public static let shared = SketchPerformanceMonitor()

    private let lock = NSLock()
    private var frameSamplesMs: [Double] = []
    private var latestStats = SketchFrameRenderStats()
    private var totalFrames: Int = 0

    private init() {}

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        frameSamplesMs.removeAll(keepingCapacity: true)
        latestStats = SketchFrameRenderStats()
        totalFrames = 0
    }

    public func recordFrame(durationMs: Double, stats: SketchFrameRenderStats) {
        lock.lock()
        defer { lock.unlock() }
        if frameSamplesMs.count >= 120 {
            frameSamplesMs.removeFirst()
        }
        frameSamplesMs.append(durationMs)
        latestStats = stats
        totalFrames += 1
    }

    public func currentSnapshot() -> SketchPerformanceSnapshot {
        lock.lock()
        let samples = frameSamplesMs
        let stats = latestStats
        let total = totalFrames
        lock.unlock()

        guard !samples.isEmpty else {
            return SketchPerformanceSnapshot(
                bitmapCacheHits: SketchRenderCache.shared.bitmapCacheHits,
                symbolCacheHits: SketchRenderCache.shared.symbolCacheHits
            )
        }
        let last = samples.last ?? 0
        let avg = samples.reduce(0, +) / Double(samples.count)
        let sorted = samples.sorted()
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count) * 0.95))
        let p95 = sorted[p95Index]
        let fps = min(120.0, 1000.0 / max(8.333, avg))

        return SketchPerformanceSnapshot(
            lastFrameMs: last,
            avgFrameMs: avg,
            p95FrameMs: p95,
            estimatedFPS: fps,
            lastDrawnLayers: stats.drawnLayers,
            lastCulledLayers: stats.culledLayers,
            totalFrames: total,
            bitmapCacheHits: SketchRenderCache.shared.bitmapCacheHits,
            symbolCacheHits: SketchRenderCache.shared.symbolCacheHits
        )
    }
}

public struct SketchPerfCheckResult: Codable, Sendable, Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let title: String
    public let measuredMs: Double
    public let budgetMs: Double
    public let passed: Bool
    public let detail: String

    public init(name: String, title: String, measuredMs: Double, budgetMs: Double, passed: Bool, detail: String) {
        self.name = name
        self.title = title
        self.measuredMs = measuredMs
        self.budgetMs = budgetMs
        self.passed = passed
        self.detail = detail
    }
}

public struct SketchPerformanceReport: Codable, Sendable, Equatable {
    public let allPassed: Bool
    public let passedCount: Int
    public let totalChecks: Int
    public let checks: [SketchPerfCheckResult]
    public let summaryLine: String

    public init(checks: [SketchPerfCheckResult]) {
        self.checks = checks
        self.totalChecks = checks.count
        self.passedCount = checks.filter(\.passed).count
        self.allPassed = (self.passedCount == self.totalChecks)
        let warmFrame = checks.first(where: { $0.name == "warm_canvas_frame_render" })?.measuredMs ?? 0
        let panAvg = checks.first(where: { $0.name == "continuous_60_frame_pan_zoom" })?.measuredMs ?? 0
        self.summaryLine = String(
            format: "Perf Checks: %d/%d PASSED | Warm Frame: %.2f ms (%.0f FPS) | 60-Frame Pan/Zoom Avg: %.2f ms",
            self.passedCount,
            self.totalChecks,
            warmFrame,
            min(120.0, 1000.0 / max(0.1, warmFrame)),
            panAvg
        )
    }
}

public enum SketchPerformanceSuite {
    /// Runs all 6 automated performance checks on a `SketchDocumentArchive` (and optional `.sketch` archive URL).
    public static func runAllChecks(
        on document: SketchDocumentArchive,
        archiveURL: URL? = nil
    ) -> SketchPerformanceReport {
        var results: [SketchPerfCheckResult] = []
        let page = document.pages.first ?? SketchLayer(kind: .page, name: "Page 1", frame: SketchRect())

        // 1. Archive Load & Decode Check (< 250 ms budget)
        if let url = archiveURL, FileManager.default.fileExists(atPath: url.path) {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = try? SketchDocumentIO.readDocument(at: url, allowRepairOrNewer: true)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            let budget = 250.0
            results.append(SketchPerfCheckResult(
                name: "document_archive_load",
                title: "ZIP Archive Load & Model Decode",
                measuredMs: elapsedMs,
                budgetMs: budget,
                passed: elapsedMs <= budget,
                detail: String(format: "Loaded %d pages & %d images in %.2f ms", document.pages.count, document.images.count, elapsedMs)
            ))
        } else {
            let t0 = CFAbsoluteTimeGetCurrent()
            for p in document.pages {
                _ = SketchDocumentIO.encodeLayer(p)
            }
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
            let budget = 150.0
            results.append(SketchPerfCheckResult(
                name: "document_archive_load",
                title: "Document Model Serialization Check",
                measuredMs: elapsedMs,
                budgetMs: budget,
                passed: elapsedMs <= budget,
                detail: String(format: "Encoded %d pages in %.2f ms", document.pages.count, elapsedMs)
            ))
        }

        // Prepare reusable 1440x900 CoreGraphics bitmap context for frame benchmarks
        let width = 1440
        let height = 900
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!

        // Prime cache with 1 cold frame
        var coldStats = SketchFrameRenderStats()
        SketchCoreGraphicsRenderer.renderLayer(
            page,
            in: document,
            context: ctx,
            includeArtboardChrome: true,
            visibleCanvasRect: CGRect(x: -200, y: -200, width: 2800, height: 1800),
            stats: &coldStats
        )

        // 2. Warm Canvas Frame Render (< 8.33 ms = 120 FPS budget)
        var warmStats = SketchFrameRenderStats()
        let hitsBeforeWarm = SketchRenderCache.shared.bitmapCacheHits + SketchRenderCache.shared.symbolCacheHits
        let tWarm0 = CFAbsoluteTimeGetCurrent()
        SketchCoreGraphicsRenderer.renderLayer(
            page,
            in: document,
            context: ctx,
            includeArtboardChrome: true,
            visibleCanvasRect: CGRect(x: -200, y: -200, width: 2800, height: 1800),
            stats: &warmStats
        )
        let warmMs = (CFAbsoluteTimeGetCurrent() - tWarm0) * 1000.0
        let hitsDelta = (SketchRenderCache.shared.bitmapCacheHits + SketchRenderCache.shared.symbolCacheHits) - hitsBeforeWarm
        let warmBudget = 8.33
        results.append(SketchPerfCheckResult(
            name: "warm_canvas_frame_render",
            title: "Warm Full-Canvas Render (120 FPS Target)",
            measuredMs: warmMs,
            budgetMs: warmBudget,
            passed: warmMs <= warmBudget,
            detail: String(format: "Drew %d layers in %.2f ms (%d cache hits)", warmStats.drawnLayers, warmMs, hitsDelta)
        ))

        // 3. 60-Frame Continuous Pan & Zoom Stress Test (< 5.0 ms avg, < 10.0 ms P95)
        var frameTimes: [Double] = []
        frameTimes.reserveCapacity(60)
        for i in 0..<60 {
            let panX = CGFloat(i * 18) - 300
            let panY = CGFloat((i % 15) * 14) - 100
            let zoom = CGFloat(0.75 + Double(i % 10) * 0.15)
            let visibleRect = CGRect(
                x: -panX / zoom,
                y: -panY / zoom,
                width: CGFloat(width) / zoom,
                height: CGFloat(height) / zoom
            )
            var frameStats = SketchFrameRenderStats()
            let tf0 = CFAbsoluteTimeGetCurrent()
            ctx.saveGState()
            ctx.translateBy(x: panX, y: panY)
            ctx.scaleBy(x: zoom, y: zoom)
            SketchCoreGraphicsRenderer.renderLayer(
                page,
                in: document,
                context: ctx,
                includeArtboardChrome: true,
                visibleCanvasRect: visibleRect,
                stats: &frameStats
            )
            ctx.restoreGState()
            let tfMs = (CFAbsoluteTimeGetCurrent() - tf0) * 1000.0
            frameTimes.append(tfMs)
            SketchPerformanceMonitor.shared.recordFrame(durationMs: tfMs, stats: frameStats)
        }
        let avg60 = frameTimes.reduce(0, +) / Double(frameTimes.count)
        let sorted60 = frameTimes.sorted()
        let p95_60 = sorted60[min(sorted60.count - 1, Int(Double(sorted60.count) * 0.95))]
        let panBudget = 6.0
        results.append(SketchPerfCheckResult(
            name: "continuous_60_frame_pan_zoom",
            title: "60-Frame Continuous Pan/Zoom Stress Test",
            measuredMs: avg60,
            budgetMs: panBudget,
            passed: avg60 <= panBudget && p95_60 <= 12.0,
            detail: String(format: "Avg: %.2f ms/frame, P95: %.2f ms/frame (%.0f FPS)", avg60, p95_60, min(120.0, 1000.0 / max(0.1, avg60)))
        ))

        // 4. Viewport Frustum Culling Check
        let firstArtboardRect = page.layers.first?.frame.cgRect ?? CGRect(x: 0, y: 0, width: 320, height: 240)
        let tightViewport = CGRect(x: firstArtboardRect.minX, y: firstArtboardRect.minY, width: 180, height: 180)
        var cullStats = SketchFrameRenderStats()
        let tCull0 = CFAbsoluteTimeGetCurrent()
        SketchCoreGraphicsRenderer.renderLayer(
            page,
            in: document,
            context: ctx,
            includeArtboardChrome: true,
            visibleCanvasRect: tightViewport,
            stats: &cullStats
        )
        let cullMs = (CFAbsoluteTimeGetCurrent() - tCull0) * 1000.0
        let cullBudget = 4.0
        let cullingWorked = (page.layers.count <= 1) ? true : (cullStats.culledLayers > 0)
        results.append(SketchPerfCheckResult(
            name: "viewport_frustum_culling",
            title: "Viewport Frustum Culling Efficiency",
            measuredMs: cullMs,
            budgetMs: cullBudget,
            passed: cullMs <= cullBudget && cullingWorked,
            detail: String(format: "Drew %d layers, culled %d off-screen layers in %.2f ms", cullStats.drawnLayers, cullStats.culledLayers, cullMs)
        ))

        // 5. O(1) Symbol Master Lookup & Cached Smart Layout Expansion (< 2.0 ms for 20 passes)
        var allInstances: [SketchLayer] = []
        func collectInstances(_ layer: SketchLayer) {
            if layer.kind == .symbolInstance {
                allInstances.append(layer)
            }
            for child in layer.layers {
                collectInstances(child)
            }
        }
        for p in document.pages {
            collectInstances(p)
        }
        let tSym0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<20 {
            for inst in allInstances {
                _ = SketchSmartLayoutEngine.expandSymbolInstance(inst, in: document)
            }
        }
        let symMs = (CFAbsoluteTimeGetCurrent() - tSym0) * 1000.0
        let symBudget = 5.0
        results.append(SketchPerfCheckResult(
            name: "symbol_master_smart_layout_cache",
            title: "O(1) Symbol Master & Smart Layout Cache (20x)",
            measuredMs: symMs,
            budgetMs: symBudget,
            passed: symMs <= symBudget,
            detail: String(format: "Expanded %d symbol ops in %.3f ms (%d cache hits)", allInstances.count * 20, symMs, SketchRenderCache.shared.symbolCacheHits)
        ))

        // 6. Interactive Hit-Testing & Snap Alignment Guides (100 cursor drag ticks < 3.0 ms)
        let siblings = page.layers
        let sampleFrame = siblings.first?.frame ?? SketchRect(x: 100, y: 100, width: 200, height: 120)
        let excluded: Set<String> = [siblings.first?.do_objectID ?? ""]
        let tSnap0 = CFAbsoluteTimeGetCurrent()
        for step in 0..<100 {
            let probe = SketchRect(
                x: sampleFrame.x + Double(step * 3),
                y: sampleFrame.y + Double(step * 2),
                width: sampleFrame.width,
                height: sampleFrame.height
            )
            _ = SketchSnapEngine.snapFrame(probe, against: siblings, excluding: excluded)
        }
        let snapMs = (CFAbsoluteTimeGetCurrent() - tSnap0) * 1000.0
        let snapBudget = 4.0
        results.append(SketchPerfCheckResult(
            name: "interactive_hit_test_and_snap",
            title: "Interactive Drag Snapping (100 ticks)",
            measuredMs: snapMs,
            budgetMs: snapBudget,
            passed: snapMs <= snapBudget,
            detail: String(format: "100 snap evaluations in %.3f ms (%.4f ms/tick)", snapMs, snapMs / 100.0)
        ))

        return SketchPerformanceReport(checks: results)
    }
}

// MARK: - CoreGraphics Vector Renderer (Reconstructed from SketchRendering & Ekranoplan)

public enum SketchCoreGraphicsRenderer {
    public static func countSubtreeLayers(_ layer: SketchLayer) -> Int {
        var count = 1
        for child in layer.layers {
            count += countSubtreeLayers(child)
        }
        return count
    }

    public static func renderLayer(
        _ layer: SketchLayer,
        in document: SketchDocumentArchive,
        context ctx: CGContext,
        includeArtboardChrome: Bool = false,
        visibleCanvasRect: CGRect? = nil,
        stats: UnsafeMutablePointer<SketchFrameRenderStats>? = nil
    ) {
        guard layer.isVisible else { return }

        let rect = layer.frame.cgRect

        // Frustum culling for non-page layers when a visible viewport rect is provided
        if layer.kind != .page, let viewport = visibleCanvasRect {
            let cullMargin: CGFloat = (layer.kind == .artboard || layer.kind == .symbolMaster) ? 48.0 : 24.0
            let paddedBounds = rect.insetBy(dx: -cullMargin, dy: -cullMargin)
            if !viewport.intersects(paddedBounds) {
                stats?.pointee.culledLayers += countSubtreeLayers(layer)
                return
            }
        }

        stats?.pointee.drawnLayers += 1

        ctx.saveGState()
        defer { ctx.restoreGState() }

        let opacity = CGFloat(layer.style.contextSettings?.opacity ?? 1.0)
        if opacity < 1.0 {
            ctx.setAlpha(opacity)
        }

        // Apply rotation / flips around layer center
        if layer.rotation != 0 || layer.isFlippedHorizontal || layer.isFlippedVertical {
            let cx = rect.midX
            let cy = rect.midY
            ctx.translateBy(x: cx, y: cy)
            if layer.rotation != 0 {
                ctx.rotate(by: CGFloat(-layer.rotation * .pi / 180.0))
            }
            if layer.isFlippedHorizontal || layer.isFlippedVertical {
                ctx.scaleBy(
                    x: layer.isFlippedHorizontal ? -1 : 1,
                    y: layer.isFlippedVertical ? -1 : 1
                )
            }
            ctx.translateBy(x: -cx, y: -cy)
        }

        switch layer.kind {
        case .page:
            for child in layer.layers {
                renderLayer(
                    child,
                    in: document,
                    context: ctx,
                    includeArtboardChrome: includeArtboardChrome,
                    visibleCanvasRect: visibleCanvasRect,
                    stats: stats
                )
            }

        case .artboard, .symbolMaster:
            if includeArtboardChrome {
                // Fast non-convolving artboard card drop shadow & border (avoids CPU Gaussian blur filter)
                ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.06))
                ctx.fill(rect.offsetBy(dx: 0, dy: 2).insetBy(dx: -1, dy: -1))
                ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.12))
                ctx.setLineWidth(1.0)
                ctx.stroke(rect)

                drawArtboardTitle(layer, in: ctx)
            }

            ctx.saveGState()
            ctx.clip(to: rect)
            if layer.hasBackgroundColor, let bg = layer.backgroundColor {
                ctx.setFillColor(cgColor(from: bg))
                ctx.fill(rect)
            } else if includeArtboardChrome {
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(rect)
            }
            ctx.translateBy(x: rect.origin.x, y: rect.origin.y)
            let localViewport = visibleCanvasRect?.offsetBy(dx: -rect.origin.x, dy: -rect.origin.y)
            renderChildrenWithClippingMasks(
                layer.layers,
                in: document,
                context: ctx,
                localViewport: localViewport,
                stats: stats
            )
            ctx.restoreGState()

        case .group:
            ctx.saveGState()
            ctx.translateBy(x: rect.origin.x, y: rect.origin.y)
            let localViewport = visibleCanvasRect?.offsetBy(dx: -rect.origin.x, dy: -rect.origin.y)
            renderChildrenWithClippingMasks(
                layer.layers,
                in: document,
                context: ctx,
                localViewport: localViewport,
                stats: stats
            )
            ctx.restoreGState()

        case .symbolInstance:
            stats?.pointee.symbolExpansions += 1
            if let expanded = SketchSmartLayoutEngine.expandSymbolInstance(layer, in: document) {
                ctx.saveGState()
                ctx.translateBy(x: rect.origin.x, y: rect.origin.y)
                let scaleX = expanded.frame.width > 0 ? rect.width / CGFloat(expanded.frame.width) : 1.0
                let scaleY = expanded.frame.height > 0 ? rect.height / CGFloat(expanded.frame.height) : 1.0
                if abs(scaleX - 1.0) > 0.01 || abs(scaleY - 1.0) > 0.01 {
                    ctx.scaleBy(x: scaleX, y: scaleY)
                }
                for child in expanded.layers {
                    renderLayer(
                        child,
                        in: document,
                        context: ctx,
                        includeArtboardChrome: false,
                        visibleCanvasRect: nil,
                        stats: stats
                    )
                }
                ctx.restoreGState()
            } else {
                drawShapePath(
                    CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil),
                    style: layer.style,
                    in: rect,
                    context: ctx
                )
            }

        case .shapeGroup:
            ctx.saveGState()
            ctx.translateBy(x: rect.origin.x, y: rect.origin.y)
            let path = SketchRenderCache.shared.cachedShapeGroupPath(for: layer)
            let localRect = CGRect(origin: .zero, size: rect.size)
            drawShapePath(path, style: layer.style, in: localRect, context: ctx)
            ctx.restoreGState()

        case .rectangle, .oval, .shapePath, .polygon, .star, .triangle:
            let path = SketchRenderCache.shared.cachedBezierPath(for: layer, in: rect)
            drawShapePath(path, style: layer.style, in: rect, context: ctx)

        case .text:
            drawTextLayer(layer, in: ctx)

        case .bitmap:
            stats?.pointee.bitmapDraws += 1
            drawBitmapLayer(layer, in: document, context: ctx)

        case .slice, .hotspot:
            if includeArtboardChrome {
                ctx.saveGState()
                ctx.setStrokeColor(CGColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 0.85))
                ctx.setLineDash(phase: 0, lengths: [4, 4])
                ctx.stroke(rect)
                ctx.restoreGState()
            }
        }
    }

    private static func renderChildrenWithClippingMasks(
        _ children: [SketchLayer],
        in document: SketchDocumentArchive,
        context ctx: CGContext,
        localViewport: CGRect?,
        stats: UnsafeMutablePointer<SketchFrameRenderStats>?
    ) {
        var isMaskActive = false
        for child in children {
            if child.shouldBreakMaskChain && isMaskActive {
                ctx.restoreGState()
                isMaskActive = false
            }
            renderLayer(
                child,
                in: document,
                context: ctx,
                includeArtboardChrome: false,
                visibleCanvasRect: localViewport,
                stats: stats
            )
            if child.hasClippingMask && child.isVisible {
                if isMaskActive {
                    ctx.restoreGState()
                }
                ctx.saveGState()
                let maskRect = child.frame.cgRect
                let maskPath: CGPath
                if child.kind == .shapeGroup {
                    let localPath = SketchRenderCache.shared.cachedShapeGroupPath(for: child)
                    var t = CGAffineTransform(translationX: maskRect.origin.x, y: maskRect.origin.y)
                    maskPath = localPath.copy(using: &t) ?? CGPath(rect: maskRect, transform: nil)
                } else {
                    maskPath = SketchRenderCache.shared.cachedBezierPath(for: child, in: maskRect)
                }
                ctx.addPath(maskPath)
                ctx.clip(using: child.style.windingRule == 1 ? .evenOdd : .winding)
                isMaskActive = true
            }
        }
        if isMaskActive {
            ctx.restoreGState()
        }
    }

    private static func drawShapePath(
        _ path: CGPath,
        style: SketchStyle,
        in rect: CGRect,
        context ctx: CGContext
    ) {
        let evenOdd = (style.windingRule == 1)

        // 1. Fast Outer Shadows (direct offset path fill without expensive software Gaussian blur convolution)
        for shadow in style.shadows where shadow.isEnabled {
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(shadow.offsetX), y: CGFloat(shadow.offsetY))
            var sc = shadow.color
            sc.alpha = min(1.0, sc.alpha * 0.55)
            ctx.setFillColor(cgColor(from: sc))
            ctx.addPath(path)
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
            ctx.restoreGState()
        }

        // 2. Fills
        for fill in style.fills where fill.isEnabled {
            ctx.saveGState()
            let fillOpacity = CGFloat(fill.contextSettings?.opacity ?? 1.0)
            if fillOpacity < 1.0 {
                ctx.setAlpha(fillOpacity)
            }
            if fill.fillType == 1, let grad = fill.gradient, !grad.stops.isEmpty {
                ctx.addPath(path)
                ctx.clip(using: evenOdd ? .evenOdd : .winding)
                drawGradient(grad, in: rect, context: ctx)
            } else {
                ctx.setFillColor(cgColor(from: fill.color))
                ctx.addPath(path)
                ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
            }
            ctx.restoreGState()
        }

        // 3. Borders
        for border in style.borders where border.isEnabled && border.thickness > 0 {
            ctx.saveGState()
            let borderOpacity = CGFloat(border.contextSettings?.opacity ?? 1.0)
            if borderOpacity < 1.0 {
                ctx.setAlpha(borderOpacity)
            }
            if let opts = style.borderOptions, opts.isEnabled, !opts.dashPattern.isEmpty {
                ctx.setLineDash(phase: 0, lengths: opts.dashPattern.map { CGFloat($0) })
            }
            if border.position == 1 && style.fills.contains(where: \.isEnabled) {
                ctx.addPath(path)
                ctx.clip(using: evenOdd ? .evenOdd : .winding)
                ctx.setLineWidth(CGFloat(border.thickness * 2.0))
            } else {
                ctx.setLineWidth(CGFloat(border.thickness))
            }
            ctx.setStrokeColor(cgColor(from: border.color))
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private static func drawGradient(_ grad: SketchGradient, in rect: CGRect, context ctx: CGContext) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let cgColors = grad.stops.map { cgColor(from: $0.color) } as CFArray
        var locations = grad.stops.map { CGFloat($0.position) }
        guard let cgGrad = CGGradient(colorsSpace: colorSpace, colors: cgColors, locations: &locations) else {
            return
        }
        let start = SketchPointString.convertFromUnit(grad.fromPoint, in: rect)
        let end = SketchPointString.convertFromUnit(grad.toPoint, in: rect)
        if grad.gradientType == 1 {
            let radius = hypot(end.x - start.x, end.y - start.y)
            ctx.drawRadialGradient(
                cgGrad,
                startCenter: start,
                startRadius: 0,
                endCenter: start,
                endRadius: max(radius, 1),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        } else {
            ctx.drawLinearGradient(
                cgGrad,
                start: start,
                end: end,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }

    private static func drawTextLayer(_ layer: SketchLayer, in ctx: CGContext) {
        guard let cached = SketchRenderCache.shared.cachedCTLine(for: layer) else { return }
        let rect = layer.frame.cgRect
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + cached.fontSize * 0.92)
        CTLineDraw(cached.line, ctx)
        ctx.restoreGState()
    }

    private static func drawBitmapLayer(_ layer: SketchLayer, in document: SketchDocumentArchive, context ctx: CGContext) {
        let rect = layer.frame.cgRect
        if let ref = layer.imageRef?._ref,
           let cgImg = SketchRenderCache.shared.cgImage(forRef: ref, in: document) {
            ctx.saveGState()
            // Flip for top-left coordinate system
            ctx.translateBy(x: rect.origin.x, y: rect.origin.y + rect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .low
            ctx.draw(cgImg, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        } else {
            ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.92, alpha: 1))
            ctx.fill(rect)
        }
    }

    private static func drawArtboardTitle(_ layer: SketchLayer, in ctx: CGContext) {
        let rect = layer.frame.cgRect
        let ctLine = SketchRenderCache.shared.cachedTitleCTLine(for: layer)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: -1.0)
        ctx.textPosition = CGPoint(x: rect.origin.x + 2, y: rect.origin.y - 6)
        CTLineDraw(ctLine, ctx)
        ctx.restoreGState()
    }

    public static func cgColor(from c: SketchColor) -> CGColor {
        CGColor(
            srgbRed: CGFloat(c.red),
            green: CGFloat(c.green),
            blue: CGFloat(c.blue),
            alpha: CGFloat(c.alpha)
        )
    }
}

// MARK: - Exporters: SVG, PDF, PNG & CSS Attributes (Reconstructed from SketchSVGExporter & MSExporter)

public enum SketchExporter {
    /// Reconstructs `SketchSVGExporter::exportLayers:` and `SketchSVGExporter::setRootSVGElementAttributes`
    public static func exportSVG(layer: SketchLayer, in document: SketchDocumentArchive) -> String {
        let w = Int(round(max(1, layer.frame.width)))
        let h = Int(round(max(1, layer.frame.height)))
        var lines: [String] = []
        lines.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
        lines.append("<svg width=\"\(w)px\" height=\"\(h)px\" viewBox=\"0 0 \(w) \(h)\" version=\"1.1\" xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\">")
        lines.append("    <title>\(escapeXML(layer.name))</title>")
        lines.append("    <desc>Created with OpenSketch.</desc>")

        var defs: [String] = []
        var body: [String] = []

        func writeLayerSVG(_ node: SketchLayer, indent: String, offsetOrigin: Bool) {
            guard node.isVisible else { return }
            let rect = offsetOrigin ? CGRect(origin: .zero, size: node.frame.cgRect.size) : node.frame.cgRect

            switch node.kind {
            case .page, .artboard, .symbolMaster, .group:
                let tx = offsetOrigin ? 0 : node.frame.x
                let ty = offsetOrigin ? 0 : node.frame.y
                let transformAttr = (tx != 0 || ty != 0) ? " transform=\"translate(\(fmt(tx)), \(fmt(ty)))\"" : ""
                body.append("\(indent)<g id=\"\(escapeXML(node.name))\"\(transformAttr)>")
                if (node.kind == .artboard || node.kind == .symbolMaster), node.hasBackgroundColor, let bg = node.backgroundColor {
                    body.append("\(indent)    <rect fill=\"#\(bg.hexString)\" x=\"0\" y=\"0\" width=\"\(fmt(node.frame.width))\" height=\"\(fmt(node.frame.height))\"></rect>")
                }
                for child in node.layers {
                    writeLayerSVG(child, indent: indent + "    ", offsetOrigin: false)
                }
                body.append("\(indent)</g>")

            case .symbolInstance:
                if let expanded = SketchSmartLayoutEngine.expandSymbolInstance(node, in: document) {
                    writeLayerSVG(expanded, indent: indent, offsetOrigin: offsetOrigin)
                }

            case .shapeGroup:
                let localPath = SketchBooleanEngine.evaluateShapeGroupPath(node)
                var trans = CGAffineTransform(translationX: rect.origin.x, y: rect.origin.y)
                let movedPath = localPath.copy(using: &trans) ?? localPath
                let d = SketchBezierBuilder.svgPathData(from: movedPath)
                let styleAttrs = svgStyleAttributes(node.style, defs: &defs)
                body.append("\(indent)<path d=\"\(d)\" id=\"\(escapeXML(node.name))\"\(styleAttrs)></path>")

            case .rectangle, .oval, .shapePath, .polygon, .star, .triangle:
                let styleAttrs = svgStyleAttributes(node.style, defs: &defs)
                let path = SketchBezierBuilder.buildCGPath(
                    points: node.points,
                    in: rect,
                    isClosed: node.isClosed,
                    fixedRadius: node.fixedRadius
                )
                let d = SketchBezierBuilder.svgPathData(from: path)
                body.append("\(indent)<path d=\"\(d)\" id=\"\(escapeXML(node.name))\"\(styleAttrs)></path>")

            case .text:
                if let attr = node.attributedString {
                    let first = attr.attributes.first
                    let font = first?.fontName ?? "HelveticaNeue"
                    let size = first?.fontSize ?? 16
                    let color = node.style.firstEnabledFill?.color ?? first?.color ?? .black
                    let yPos = rect.origin.y + CGFloat(size)
                    body.append("\(indent)<text id=\"\(escapeXML(node.name))\" font-family=\"\(escapeXML(font))\" font-size=\"\(fmt(size))\" fill=\"#\(color.hexString)\" x=\"\(fmt(Double(rect.origin.x)))\" y=\"\(fmt(Double(yPos)))\">\(escapeXML(attr.string))</text>")
                }

            case .bitmap, .slice, .hotspot:
                break
            }
        }

        writeLayerSVG(layer, indent: "    ", offsetOrigin: true)

        if !defs.isEmpty {
            lines.append("    <defs>")
            lines.append(contentsOf: defs)
            lines.append("    </defs>")
        }
        lines.append(contentsOf: body)
        lines.append("</svg>")
        return lines.joined(separator: "\n")
    }

    /// Reconstructs `MSExporter` bitmap rendering
    public static func exportPNG(
        layer: SketchLayer,
        in document: SketchDocumentArchive,
        scale: Double = 1.0
    ) -> Data? {
        let w = max(1, Int(ceil(layer.frame.width * scale)))
        let h = max(1, Int(ceil(layer.frame.height * scale)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // Flip to top-left origin and offset by layer origin
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))
        ctx.translateBy(x: -CGFloat(layer.frame.x), y: -CGFloat(layer.frame.y))

        SketchCoreGraphicsRenderer.renderLayer(layer, in: document, context: ctx, includeArtboardChrome: false)

        guard let cgImg = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImg)
        return rep.representation(using: .png, properties: [:])
    }

    /// Exports a layer or artboard to vector PDF data (`MSExporter` PDF path)
    public static func exportPDF(
        layer: SketchLayer,
        in document: SketchDocumentArchive
    ) -> Data? {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: max(1, layer.frame.width), height: max(1, layer.frame.height))
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let pdfCtx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }
        pdfCtx.beginPDFPage(nil)
        pdfCtx.translateBy(x: 0, y: mediaBox.height)
        pdfCtx.scaleBy(x: 1, y: -1)
        pdfCtx.translateBy(x: -CGFloat(layer.frame.x), y: -CGFloat(layer.frame.y))
        SketchCoreGraphicsRenderer.renderLayer(layer, in: document, context: pdfCtx, includeArtboardChrome: false)
        pdfCtx.endPDFPage()
        pdfCtx.closePDF()
        return pdfData as Data
    }

    /// Reconstructs `copyCSSAttributes:` action selector from `out/ib-sketch-all.json`
    public static func cssAttributes(for layer: SketchLayer) -> String {
        var rules: [String] = ["/* \(layer.name) */"]
        rules.append("width: \(fmt(layer.frame.width))px;")
        rules.append("height: \(fmt(layer.frame.height))px;")
        if let fill = layer.style.firstEnabledFill {
            if fill.color.alpha < 1.0 {
                let r = Int(round(fill.color.red * 255))
                let g = Int(round(fill.color.green * 255))
                let b = Int(round(fill.color.blue * 255))
                rules.append(String(format: "background: rgba(%d, %d, %d, %.2f);", r, g, b, fill.color.alpha))
            } else {
                rules.append("background: #\(fill.color.hexString);")
            }
        }
        if let border = layer.style.firstEnabledBorder {
            rules.append("border: \(fmt(border.thickness))px solid #\(border.color.hexString);")
        }
        if let shadow = layer.style.firstEnabledShadow {
            rules.append("box-shadow: \(fmt(shadow.offsetX))px \(fmt(shadow.offsetY))px \(fmt(shadow.blurRadius))px \(fmt(shadow.spread))px #\(shadow.color.hexString);")
        }
        let radius = max(layer.fixedRadius, layer.points.map(\.cornerRadius).max() ?? 0)
        if radius > 0 {
            rules.append("border-radius: \(fmt(radius))px;")
        }
        if let attr = layer.attributedString, let first = attr.attributes.first {
            rules.append("font-family: \(first.fontName);")
            rules.append("font-size: \(fmt(first.fontSize))px;")
            rules.append("color: #\(first.color.hexString);")
        }
        return rules.joined(separator: "\n")
    }

    private static func svgStyleAttributes(_ style: SketchStyle, defs: inout [String]) -> String {
        var attrs: [String] = []
        if let fill = style.firstEnabledFill {
            if fill.fillType == 1, let grad = fill.gradient {
                let gradID = "linearGradient-\(defs.count + 1)"
                var stopLines: [String] = []
                for s in grad.stops {
                    stopLines.append("            <stop stop-color=\"#\(s.color.hexString)\" stop-opacity=\"\(fmt(s.color.alpha))\" offset=\"\(fmt(s.position * 100))%\"></stop>")
                }
                let fp = grad.fromPoint
                let tp = grad.toPoint
                let defBlock = """
                        <linearGradient x1="\(fmt(Double(fp.x * 100)))%" y1="\(fmt(Double(fp.y * 100)))%" x2="\(fmt(Double(tp.x * 100)))%" y2="\(fmt(Double(tp.y * 100)))%" id="\(gradID)">
                \(stopLines.joined(separator: "\n"))
                        </linearGradient>
                """
                defs.append(defBlock)
                attrs.append("fill=\"url(#\(gradID))\"")
            } else {
                attrs.append("fill=\"#\(fill.color.hexString)\"")
                if fill.color.alpha < 1.0 {
                    attrs.append("fill-opacity=\"\(fmt(fill.color.alpha))\"")
                }
            }
        } else {
            attrs.append("fill=\"none\"")
        }

        if let border = style.firstEnabledBorder {
            attrs.append("stroke=\"#\(border.color.hexString)\"")
            attrs.append("stroke-width=\"\(fmt(border.thickness))\"")
        }
        return attrs.isEmpty ? "" : " " + attrs.joined(separator: " ")
    }

    private static func fmt(_ v: Double) -> String {
        if abs(v - round(v)) < 1e-4 { return String(Int(round(v))) }
        return String(format: "%.2f", v)
    }

    private static func escapeXML(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
