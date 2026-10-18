import Foundation
import OpenSketchCore

enum CLICommand {
    static func run() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let subcommand = args.first else {
            printUsage()
            return
        }

        switch subcommand {
        case "validate":
            guard args.count >= 2 else { printUsage(); return }
            let path = args[1]
            let url = URL(fileURLWithPath: path)
            let format = (try? SketchDocumentIO.detectFormat(at: url)) ?? .legacySQLite
            if let entries = try? SketchZipArchive.readEntries(from: url) {
                let status = SketchDocumentIO.validate(entries: entries)
                let output: [String: Any] = [
                    "file": path,
                    "format": format.rawValue,
                    "status": status.rawValue,
                    "dialogTitle": status.dialogTitle ?? "Valid",
                    "dialogMessage": status.dialogMessage ?? "Archive is valid",
                    "hasDocumentJSON": entries["document.json"] != nil,
                    "hasMetaJSON": entries["meta.json"] != nil,
                    "hasUserJSON": entries["user.json"] != nil,
                    "pageFileCount": entries.keys.filter { $0.hasPrefix("pages/") && $0.hasSuffix(".json") }.count
                ]
                printJSON(output)
            } else {
                let output: [String: Any] = [
                    "file": path,
                    "format": format.rawValue,
                    "status": SketchValidationStatus.corruptMetadata.rawValue,
                    "dialogTitle": "Not a ZIP archive",
                    "dialogMessage": "Detected reader class \(format.rawValue)"
                ]
                printJSON(output)
            }

        case "info":
            guard args.count >= 2 else { printUsage(); return }
            let path = args[1]
            let repair = args.contains("--repair")
            let url = URL(fileURLWithPath: path)
            do {
                let (doc, status, wasRepaired) = try SketchDocumentIO.readDocument(at: url, allowRepairOrNewer: repair)
                let pageSummaries = doc.pages.map { page -> [String: Any] in
                    [
                        "id": page.do_objectID,
                        "name": page.name,
                        "topLevelLayers": page.layers.count
                    ]
                }
                let output: [String: Any] = [
                    "file": path,
                    "version": doc.meta["version"]?.intValue ?? 139,
                    "app": doc.meta["app"]?.stringValue ?? "com.bohemiancoding.sketch3",
                    "appVersion": doc.meta["appVersion"]?.stringValue ?? "82.1",
                    "build": doc.meta["build"]?.intValue ?? 137007,
                    "validationStatus": status.rawValue,
                    "wasRepaired": wasRepaired,
                    "pages": pageSummaries,
                    "symbolMasterCount": doc.allSymbolMasters.count
                ]
                printJSON(output)
            } catch {
                fputs("Error reading \(path): \(error.localizedDescription)\n", stderr)
                exit(1)
            }

        case "repair":
            guard args.count >= 3 else { printUsage(); return }
            let inPath = args[1]
            let outPath = args[2]
            do {
                let (doc, status, wasRepaired) = try SketchDocumentIO.readDocument(at: URL(fileURLWithPath: inPath), allowRepairOrNewer: true)
                try SketchDocumentIO.writeDocument(doc, to: URL(fileURLWithPath: outPath))
                printJSON([
                    "input": inPath,
                    "output": outPath,
                    "originalStatus": status.rawValue,
                    "wasRepaired": wasRepaired,
                    "repairedPages": doc.pages.count
                ])
            } catch {
                fputs("Error repairing \(inPath): \(error.localizedDescription)\n", stderr)
                exit(1)
            }

        case "export-svg":
            guard args.count >= 3 else { printUsage(); return }
            let inPath = args[1]
            let outPath = args[2]
            do {
                let (doc, _, _) = try SketchDocumentIO.readDocument(at: URL(fileURLWithPath: inPath), allowRepairOrNewer: true)
                guard let firstPage = doc.pages.first else {
                    fputs("No pages found in document\n", stderr)
                    exit(1)
                }
                let target = firstPage.layers.first ?? firstPage
                let svg = SketchExporter.exportSVG(layer: target, in: doc)
                try Data(svg.utf8).write(to: URL(fileURLWithPath: outPath))
                printJSON(["exportedSVG": outPath, "bytes": svg.utf8.count])
            } catch {
                fputs("Export SVG failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }

        case "export-png":
            guard args.count >= 3 else { printUsage(); return }
            let inPath = args[1]
            let outPath = args[2]
            do {
                let (doc, _, _) = try SketchDocumentIO.readDocument(at: URL(fileURLWithPath: inPath), allowRepairOrNewer: true)
                guard let firstPage = doc.pages.first else {
                    fputs("No pages found in document\n", stderr)
                    exit(1)
                }
                let target = firstPage.layers.first ?? firstPage
                guard let png = SketchExporter.exportPNG(layer: target, in: doc, scale: 2.0) else {
                    fputs("Failed to rasterize PNG\n", stderr)
                    exit(1)
                }
                try png.write(to: URL(fileURLWithPath: outPath))
                printJSON(["exportedPNG": outPath, "bytes": png.count])
            } catch {
                fputs("Export PNG failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }

        case "export-pdf":
            guard args.count >= 3 else { printUsage(); return }
            let inPath = args[1]
            let outPath = args[2]
            do {
                let (doc, _, _) = try SketchDocumentIO.readDocument(at: URL(fileURLWithPath: inPath), allowRepairOrNewer: true)
                guard let firstPage = doc.pages.first else {
                    fputs("No pages found in document\n", stderr)
                    exit(1)
                }
                let target = firstPage.layers.first ?? firstPage
                guard let pdf = SketchExporter.exportPDF(layer: target, in: doc) else {
                    fputs("Failed to render PDF\n", stderr)
                    exit(1)
                }
                try pdf.write(to: URL(fileURLWithPath: outPath))
                printJSON(["exportedPDF": outPath, "bytes": pdf.count])
            } catch {
                fputs("Export PDF failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }

        case "bench":
            let path = args.count >= 2 ? args[1] : "/Applications/sidetabs/Coding/sketch-re/samples/smart-layout.sketch"
            let url = URL(fileURLWithPath: path)
            do {
                SketchRenderCache.shared.clearAll()
                let (doc, _, _) = try SketchDocumentIO.readDocument(at: url, allowRepairOrNewer: true)
                let report = SketchPerformanceSuite.runAllChecks(on: doc, archiveURL: url)
                let checksJSON = report.checks.map { c -> [String: Any] in
                    [
                        "name": c.name,
                        "title": c.title,
                        "measuredMs": round(c.measuredMs * 1000) / 1000,
                        "budgetMs": c.budgetMs,
                        "passed": c.passed,
                        "detail": c.detail
                    ]
                }
                printJSON([
                    "file": path,
                    "allPassed": report.allPassed,
                    "passedCount": report.passedCount,
                    "totalChecks": report.totalChecks,
                    "summary": report.summaryLine,
                    "bitmapCacheHits": SketchRenderCache.shared.bitmapCacheHits,
                    "symbolCacheHits": SketchRenderCache.shared.symbolCacheHits,
                    "checks": checksJSON
                ])
                if !report.allPassed {
                    exit(2)
                }
            } catch {
                fputs("Performance benchmark failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }

        default:
            printUsage()
        }
    }

    static func printJSON(_ dict: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    static func printUsage() {
        print("""
        Usage: opensketch-cli <command> [arguments]
        Commands:
          validate <file.sketch>                  Validate .sketch archive (status codes 0, 2, 3, 4, 5)
          info <file.sketch> [--repair]           Inspect .sketch document metadata, pages, and symbols
          repair <in.sketch> <out.sketch>         Repair corrupted/missing-meta .sketch archive
          export-svg <in.sketch> <out.svg>        Export first artboard/page of .sketch archive to SVG
          export-png <in.sketch> <out.png>        Export first artboard/page of .sketch archive to 2x PNG
          export-pdf <in.sketch> <out.pdf>        Export first artboard/page of .sketch archive to vector PDF
          bench [file.sketch]                     Run 6 automated canvas & archive performance checks
        """)
    }
}

CLICommand.run()
