import SwiftUI
import AppKit
import OpenSketchCore

@main
struct OpenSketchApp: App {
    @NSApplicationDelegateAdaptor(OpenSketchAppDelegate.self) var appDelegate
    @StateObject private var viewModel: SketchDocumentViewModel = {
        let vm = SketchDocumentViewModel()
        let args = CommandLine.arguments.dropFirst()
        if let pathArg = args.first(where: { !$0.hasPrefix("-") && $0.hasSuffix(".sketch") }) {
            let url = URL(fileURLWithPath: pathArg)
            if FileManager.default.fileExists(atPath: url.path) {
                try? vm.loadDocument(from: url, allowRepairOrNewer: true)
                return vm
            }
        }
        let defaultSample = URL(fileURLWithPath: "/Applications/sidetabs/Coding/sketch-re/samples/smart-layout.sketch")
        if FileManager.default.fileExists(atPath: defaultSample.path) {
            try? vm.loadDocument(from: defaultSample, allowRepairOrNewer: true)
            vm.zoomScale = 0.45
            vm.panOffset = CGSize(width: 220, height: 260)
            if let firstPage = vm.archive.pages.first {
                // Select the 'Sample Button' symbolMaster's Rectangle or 'Card' symbolInstance so Inspector shows rich style/symbol controls
                if let sampleBtn = firstPage.layers.first(where: { $0.name == "Sample Button" }),
                   let rectChild = sampleBtn.layers.first(where: { $0.kind == .rectangle || $0.kind == .shapePath }) {
                    vm.selectedLayerIDs = [rectChild.do_objectID]
                } else if let cardInst = firstPage.layers.first(where: { $0.kind == .symbolInstance }) {
                    vm.selectedLayerIDs = [cardInst.do_objectID]
                }
            }
            _ = vm.runPerformanceChecks()
        }
        return vm
    }()

    var body: some Scene {
        WindowGroup(viewModel.fileURL?.lastPathComponent ?? "OpenSketch — Untitled.sketch") {
            MainWorkspaceView(viewModel: viewModel)
        }
        .defaultSize(width: 1440, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Document") {
                    viewModel.archive = SketchDocumentArchive()
                    viewModel.fileURL = nil
                    viewModel.selectedLayerIDs.removeAll()
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Open .sketch Document…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    if panel.runModal() == .OK, let url = panel.url {
                        try? viewModel.loadDocument(from: url, allowRepairOrNewer: true)
                    }
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Save Document") {
                    if let url = viewModel.fileURL {
                        try? viewModel.saveDocument(to: url)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command])
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    viewModel.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!viewModel.canUndo)

                Button("Redo") {
                    viewModel.redo()
                }
                .keyboardShortcut("Z", modifiers: [.command, .shift])
                .disabled(!viewModel.canRedo)
            }

            CommandMenu("Insert") {
                ForEach(SketchToolMode.allCases) { tool in
                    Button(tool.rawValue) {
                        viewModel.currentTool = tool
                    }
                }
            }

            CommandMenu("Layer") {
                Button("Combine -> Union") { viewModel.performBooleanOperation(.union) }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                Button("Combine -> Subtract") { viewModel.performBooleanOperation(.subtract) }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Combine -> Intersect") { viewModel.performBooleanOperation(.intersect) }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Combine -> Difference") { viewModel.performBooleanOperation(.difference) }
                    .keyboardShortcut("x", modifiers: [.command, .option])
                Button("Flatten to Paths") { viewModel.flattenSelectedLayer() }
                Divider()
                Button("Use as Mask") { viewModel.toggleMaskOnSelectedLayer() }
                    .keyboardShortcut("m", modifiers: [.command, .control])
                Button("Flip Horizontally") { viewModel.flipSelectedLayers(horizontal: true) }
                Button("Flip Vertically") { viewModel.flipSelectedLayers(horizontal: false) }
                Divider()
                Button("Create Symbol") { viewModel.createSymbolFromSelection() }
                Button("Detach from Symbol") { viewModel.detachSelectedSymbolInstance() }
                Divider()
                Button("Duplicate") { viewModel.duplicateSelectedLayers() }
                    .keyboardShortcut("d", modifiers: [.command])
                Button("Delete") { viewModel.deleteSelectedLayers() }
                    .keyboardShortcut(.delete, modifiers: [])
            }

            CommandMenu("Arrange") {
                Button("Group Selection") { viewModel.groupSelectedLayers() }
                    .keyboardShortcut("g", modifiers: [.command])
                Button("Ungroup Selection") { viewModel.ungroupSelectedLayers() }
                    .keyboardShortcut("G", modifiers: [.command, .shift])
                Divider()
                Button("Tidy") { viewModel.tidySelectedLayers() }
            }

            CommandMenu("View") {
                Toggle("Show Components View", isOn: $viewModel.showComponentsView)
                    .keyboardShortcut("2", modifiers: [.control])
                Divider()
                Button("Zoom In") { viewModel.zoomIn() }
                    .keyboardShortcut("+", modifiers: [.command])
                Button("Zoom Out") { viewModel.zoomOut() }
                    .keyboardShortcut("-", modifiers: [.command])
                Button("Actual Size (100%)") { viewModel.actualSize() }
                    .keyboardShortcut("0", modifiers: [.command])
                Divider()
                Toggle("Show Rulers", isOn: $viewModel.showRulers)
                    .keyboardShortcut("r", modifiers: [.command, .control])
                Toggle("Show Pixel Grid", isOn: $viewModel.showPixelGrid)
                    .keyboardShortcut("x", modifiers: [.control])
                Divider()
                Button("Run Performance Checks") {
                    _ = viewModel.runPerformanceChecks()
                    viewModel.showPerfInspectorPopover = true
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }
        }
    }
}

final class OpenSketchAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
