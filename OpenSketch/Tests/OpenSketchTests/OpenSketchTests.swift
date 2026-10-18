import XCTest
@testable import OpenSketchCore

final class OpenSketchTests: XCTestCase {
    let repoRoot = URL(fileURLWithPath: "/Applications/sidetabs/Coding/sketch-re")

    func testMagicByteFormatDetection() throws {
        let zipSampleURL = repoRoot.appendingPathComponent("samples/smart-layout.sketch")
        XCTAssertEqual(try SketchDocumentIO.detectFormat(at: zipSampleURL), .zippedJSON)

        let tempSQLite = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-\(UUID().uuidString).sketch")
        defer { try? FileManager.default.removeItem(at: tempSQLite) }
        try Data("SQLite format 3\0".utf8).write(to: tempSQLite)
        XCTAssertEqual(try SketchDocumentIO.detectFormat(at: tempSQLite), .legacySQLite)
    }

    func testValidationStatusesAndCrashFixAcrossAllSixVariants() throws {
        // v0-control.sketch -> status 0 (.valid)
        let v0Entries = try SketchZipArchive.readEntries(from: repoRoot.appendingPathComponent("samples/variants/v0-control.sketch"))
        XCTAssertEqual(SketchDocumentIO.validate(entries: v0Entries), .valid)

        // v2-no-user-json.sketch -> status 2 (.corruptMetadata) AND safe shareInfo(in:) (fixes Sketch 82.1's nil NSJSONSerialization crash!)
        let v2URL = repoRoot.appendingPathComponent("samples/variants/v2-no-user-json.sketch")
        let v2Entries = try SketchZipArchive.readEntries(from: v2URL)
        XCTAssertEqual(SketchDocumentIO.validate(entries: v2Entries), .corruptMetadata)
        XCTAssertNil(SketchDocumentIO.shareInfo(in: v2Entries))

        // Verify repair mode opens v2-no-user-json.sketch cleanly
        let (repairedV2, statusV2, wasRepairedV2) = try SketchDocumentIO.readDocument(at: v2URL, allowRepairOrNewer: true)
        XCTAssertEqual(statusV2, .corruptMetadata)
        XCTAssertTrue(wasRepairedV2)
        XCTAssertEqual(repairedV2.pages.count, 2)

        // v3-old-version.sketch -> status 3 (.legacyUnsupported, version <= 87)
        let v3Entries = try SketchZipArchive.readEntries(from: repoRoot.appendingPathComponent("samples/variants/v3-old-version.sketch"))
        XCTAssertEqual(SketchDocumentIO.validate(entries: v3Entries), .legacyUnsupported)

        // v4-newer-version.sketch -> status 4 (.newerVersionWarning, version > 139 && compatibilityVersion <= 139)
        let v4Entries = try SketchZipArchive.readEntries(from: repoRoot.appendingPathComponent("samples/variants/v4-newer-version.sketch"))
        XCTAssertEqual(SketchDocumentIO.validate(entries: v4Entries), .newerVersionWarning)

        // v5-newer-compat.sketch -> status 5 (.incompatibleNewer, compatibilityVersion > 139)
        let v5URL = repoRoot.appendingPathComponent("samples/variants/v5-newer-compat.sketch")
        let v5Entries = try SketchZipArchive.readEntries(from: v5URL)
        XCTAssertEqual(SketchDocumentIO.validate(entries: v5Entries), .incompatibleNewer)
        XCTAssertThrowsError(try SketchDocumentIO.readDocument(at: v5URL, allowRepairOrNewer: true))

        // v6-no-meta-json.sketch -> status 2 (.corruptMetadata), repairable via -repair
        let v6URL = repoRoot.appendingPathComponent("samples/variants/v6-no-meta-json.sketch")
        let (repairedV6, statusV6, wasRepairedV6) = try SketchDocumentIO.readDocument(at: v6URL, allowRepairOrNewer: true)
        XCTAssertEqual(statusV6, .corruptMetadata)
        XCTAssertTrue(wasRepairedV6)
        XCTAssertEqual(repairedV6.meta["version"]?.intValue, 139)
        XCTAssertEqual(repairedV6.pages.count, 2)
    }

    func testSmartLayoutDocumentReadAndRoundTripWrite() throws {
        let sampleURL = repoRoot.appendingPathComponent("samples/smart-layout.sketch")
        let (doc, status, wasRepaired) = try SketchDocumentIO.readDocument(at: sampleURL)
        XCTAssertEqual(status, .valid)
        XCTAssertFalse(wasRepaired)
        XCTAssertEqual(doc.meta["version"]?.intValue, 134)
        XCTAssertEqual(doc.pages.count, 2)

        let symbols = doc.allSymbolMasters
        XCTAssertEqual(symbols.count, 46)

        // Check Smart Layout groupLayout on symbolMasters
        let inferredMasters = symbols.filter { $0.groupLayout?.isSmartLayout == true }
        XCTAssertEqual(inferredMasters.count, 21)

        // Write out to temporary file (upgrades header to Sketch 82.1 format v139) and read back
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-\(UUID().uuidString).sketch")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try SketchDocumentIO.writeDocument(doc, to: tempURL)
        let (reloaded, reloadStatus, _) = try SketchDocumentIO.readDocument(at: tempURL)
        XCTAssertEqual(reloadStatus, .valid)
        XCTAssertEqual(reloaded.meta["version"]?.intValue, 139)
        XCTAssertEqual(reloaded.pages.count, 2)
        XCTAssertEqual(reloaded.allSymbolMasters.count, 46)
    }

    func testBezierBuilderAndCornerFilletKappa() {
        XCTAssertEqual(SketchBezierBuilder.filletKappaComplement, 0.4477152502, accuracy: 1e-9)
        let rectLayer = SketchLayer.makeRectangle(
            name: "Rounded",
            frame: SketchRect(x: 10, y: 20, width: 120, height: 60),
            cornerRadius: 12
        )
        let path = SketchBezierBuilder.buildCGPath(
            points: rectLayer.points,
            in: CGRect(x: 0, y: 0, width: 120, height: 60),
            isClosed: rectLayer.isClosed,
            fixedRadius: rectLayer.fixedRadius
        )
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.boundingBoxOfPath.width, 120, accuracy: 1.0)
        XCTAssertEqual(path.boundingBoxOfPath.height, 60, accuracy: 1.0)

        let svgD = SketchBezierBuilder.svgPathData(from: path)
        XCTAssertTrue(svgD.contains("M"))
        XCTAssertTrue(svgD.contains("C"))
        XCTAssertTrue(svgD.hasSuffix("Z"))
    }

    func testBooleanOperationsEngine() {
        let a = SketchLayer.makeRectangle(name: "Rect A", frame: SketchRect(x: 0, y: 0, width: 100, height: 100))
        let b = SketchLayer.makeRectangle(name: "Rect B", frame: SketchRect(x: 50, y: 50, width: 100, height: 100))

        for op in [SketchBooleanOperation.union, .subtract, .intersect, .difference] {
            let group = SketchBooleanEngine.combineLayers(a, b, operation: op)
            XCTAssertEqual(group.kind, .shapeGroup)
            XCTAssertEqual(group.layers.count, 2)
            XCTAssertEqual(group.layers[1].booleanOperation, op)

            let evaluated = SketchBooleanEngine.evaluateShapeGroupPath(group)
            XCTAssertFalse(evaluated.isEmpty)
        }

        let unionGroup = SketchBooleanEngine.combineLayers(a, b, operation: .union)
        let flattened = SketchBooleanEngine.flattenShapeGroup(unionGroup)
        XCTAssertEqual(flattened.kind, .shapePath)
        XCTAssertFalse(flattened.points.isEmpty)
    }

    func testSmartLayoutDynamicSymbolOverrideExpansion() throws {
        let sampleURL = repoRoot.appendingPathComponent("samples/smart-layout.sketch")
        let (doc, _, _) = try SketchDocumentIO.readDocument(at: sampleURL)

        let page1 = doc.pages[0]
        let artboard = try XCTUnwrap(page1.layers.first)
        var instance = try XCTUnwrap(artboard.layers.first(where: { $0.kind == .symbolInstance }))
        let originalWidth = instance.frame.width

        let master = try XCTUnwrap(instance.symbolID.flatMap { doc.symbolMaster(forSymbolID: $0) })
        let textChild = try XCTUnwrap(master.layers.first(where: { $0.kind == .text }))

        instance.overrideValues = [
            SketchOverrideValue(
                overrideName: "\(textChild.do_objectID)_stringValue",
                value: "Super Long Override Button Label For Smart Layout"
            )
        ]

        let resolved = try XCTUnwrap(SketchSmartLayoutEngine.expandSymbolInstance(instance, in: doc))
        XCTAssertGreaterThan(resolved.frame.width, originalWidth)
    }

    func testSVGAndPNGAndPDFAndCSSExporters() throws {
        let sampleURL = repoRoot.appendingPathComponent("samples/smart-layout.sketch")
        let (doc, _, _) = try SketchDocumentIO.readDocument(at: sampleURL)
        let firstPage = try XCTUnwrap(doc.pages.first)
        let firstArtboard = try XCTUnwrap(firstPage.layers.first)

        let svg = SketchExporter.exportSVG(layer: firstArtboard, in: doc)
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains("Created with OpenSketch."))

        let png = try XCTUnwrap(SketchExporter.exportPNG(layer: firstArtboard, in: doc, scale: 1.0))
        XCTAssertGreaterThan(png.count, 500)

        let pdf = try XCTUnwrap(SketchExporter.exportPDF(layer: firstArtboard, in: doc))
        XCTAssertGreaterThan(pdf.count, 500)

        if let symMaster = doc.allSymbolMasters.first,
           let bgShape = symMaster.layers.first {
            let css = SketchExporter.cssAttributes(for: bgShape)
            XCTAssertTrue(css.contains("width:"))
            XCTAssertTrue(css.contains("background:"))
        }
    }

    // MARK: - 7. Automated Performance Regression Suite (6 Checks)

    func testPerformanceChecksSuite() throws {
        SketchRenderCache.shared.clearAll()
        let sampleSmartLayoutURL = repoRoot.appendingPathComponent("samples/smart-layout.sketch")
        let (doc, _, _) = try SketchDocumentIO.readDocument(at: sampleSmartLayoutURL)
        let report = SketchPerformanceSuite.runAllChecks(on: doc, archiveURL: sampleSmartLayoutURL)

        XCTAssertEqual(report.totalChecks, 6)
        for check in report.checks {
            XCTAssertTrue(
                check.passed,
                "Performance check '\(check.name)' exceeded budget: \(check.measuredMs) ms > \(check.budgetMs) ms (\(check.detail))"
            )
        }
        XCTAssertTrue(report.allPassed)
        XCTAssertGreaterThan(SketchRenderCache.shared.bitmapCacheHits, 0)
        XCTAssertGreaterThan(SketchRenderCache.shared.symbolCacheHits, 0)
    }

    // MARK: - 8. MSVersionedArchiveReader (.sketchpreset) + Polygon/Star/Triangle + Clipping Masks

    func testVersionedPresetArchiveAndPolygonStarTriangleMasking() throws {
        // 1. Test MSVersionedArchiveReader (meta.json + archive.json)
        let sketchPresetURL = URL(fileURLWithPath: "/Applications/Sketch.app/Contents/Resources/assets.sketchpreset")
        if FileManager.default.fileExists(atPath: sketchPresetURL.path) {
            let preset = try SketchDocumentIO.readVersionedPresetArchive(at: sketchPresetURL)
            XCTAssertGreaterThan(preset.version, 0)
            XCTAssertFalse(preset.colors.isEmpty)
        } else {
            let syntheticEntries: [String: Data] = [
                "meta.json": Data("{\"version\":139}".utf8),
                "archive.json": Data("{\"root\":{\"colorAssets\":[{\"color\":{\"red\":0.1,\"green\":0.5,\"blue\":0.9,\"alpha\":1.0}}]}}".utf8)
            ]
            let preset = try SketchDocumentIO.readVersionedPresetArchive(fromEntries: syntheticEntries)
            XCTAssertEqual(preset.version, 139)
            XCTAssertEqual(preset.colors.count, 1)
        }

        // 2. Test Polygon, Star, Triangle, and Clipping Mask rendering
        var maskLayer = SketchLayer.makePolygon(name: "HexMask", sides: 6, frame: SketchRect(x: 10, y: 10, width: 80, height: 80))
        maskLayer.hasClippingMask = true
        let starLayer = SketchLayer.makeStar(name: "StarChild", pointsCount: 5, frame: SketchRect(x: 20, y: 20, width: 60, height: 60))
        var triangleLayer = SketchLayer.makeTriangle(name: "UnmaskedTriangle", frame: SketchRect(x: 40, y: 40, width: 60, height: 60))
        triangleLayer.shouldBreakMaskChain = true

        XCTAssertEqual(maskLayer.points.count, 6)
        XCTAssertEqual(starLayer.points.count, 10)
        XCTAssertEqual(triangleLayer.points.count, 3)

        let artboard = SketchLayer.makeArtboard(
            name: "MaskTestArtboard",
            frame: SketchRect(x: 0, y: 0, width: 120, height: 120),
            layers: [maskLayer, starLayer, triangleLayer]
        )
        let doc = SketchDocumentArchive(pages: [
            SketchLayer(kind: .page, name: "Page 1", frame: SketchRect(), layers: [artboard])
        ])
        let png = try XCTUnwrap(SketchExporter.exportPNG(layer: artboard, in: doc, scale: 1.0))
        XCTAssertGreaterThan(png.count, 200)
    }
}

