import SwiftUI
import AppKit
import OpenSketchCore

public struct MainWorkspaceView: View {
    @ObservedObject public var viewModel: SketchDocumentViewModel

    public init(viewModel: SketchDocumentViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            sketchToolbar
            Divider()
            HStack(spacing: 0) {
                leftSidebar
                Divider()
                if viewModel.showComponentsView {
                    ComponentsLibraryView(viewModel: viewModel)
                } else {
                    InfiniteCanvasView(viewModel: viewModel)
                }
                Divider()
                InspectorView(viewModel: viewModel)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 1180, minHeight: 740)
    }

    // MARK: - Top Sketch 82.1 Toolbar

    private var sketchToolbar: some View {
        HStack(spacing: 10) {
            // Canvas vs Components View Toggle (MSComponentsPaneController in Sketch 82.1)
            Picker("", selection: $viewModel.showComponentsView) {
                Text("Canvas").tag(false)
                Text("Components").tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 148)

            Menu {
                ForEach(SketchToolMode.allCases) { tool in
                    Button {
                        viewModel.currentTool = tool
                    } label: {
                        Label(tool.rawValue, systemImage: tool.iconName)
                    }
                }
            } label: {
                Label("Insert: \(viewModel.currentTool.rawValue)", systemImage: "plus.square.fill")
            }
            .frame(width: 145)

            HStack(spacing: 2) {
                ForEach(SketchToolMode.allCases) { tool in
                    Button {
                        viewModel.currentTool = tool
                    } label: {
                        Image(systemName: tool.iconName)
                            .frame(width: 24, height: 22)
                            .background(viewModel.currentTool == tool ? Color.accentColor.opacity(0.2) : Color.clear)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.borderless)
                    .help(tool.rawValue)
                }
            }

            Divider().frame(height: 20)

            // Create Symbol
            Button {
                viewModel.createSymbolFromSelection()
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "sparkles.rectangle.stack")
                    Text("Create Symbol").font(.system(size: 9))
                }
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.selectedLayerIDs.isEmpty)

            // Group
            Button {
                viewModel.groupSelectedLayers()
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "folder.badge.plus")
                    Text("Group").font(.system(size: 9))
                }
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.selectedLayerIDs.isEmpty)

            // Edit Vector Points
            Button {
                viewModel.currentTool = (viewModel.currentTool == .editPoints) ? .select : .editPoints
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                    Text("Edit").font(.system(size: 9))
                }
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.primarySelectedLayer?.points.isEmpty ?? true)

            Divider().frame(height: 20)

            // Boolean Operations: Union (0), Subtract (1), Intersect (2), Difference (3)
            HStack(spacing: 8) {
                toolbarBooleanButton(title: "Union", icon: "square.on.square", op: .union)
                toolbarBooleanButton(title: "Subtract", icon: "minus.square", op: .subtract)
                toolbarBooleanButton(title: "Intersect", icon: "square.grid.2x2", op: .intersect)
                toolbarBooleanButton(title: "Difference", icon: "xmark.square", op: .difference)
            }

            Spacer()

            // File Open / Save / Export / Perf Checks Controls
            HStack(spacing: 6) {
                Button {
                    _ = viewModel.runPerformanceChecks()
                    viewModel.showPerfInspectorPopover = true
                } label: {
                    Label("Perf Checks", systemImage: "speedometer")
                }
                .controlSize(.small)
                .help("Run 6 Automated Canvas & Archive Performance Checks")

                Button("Open…") {
                    openSketchDocumentPanel()
                }
                .controlSize(.small)

                Button("Save…") {
                    saveSketchDocumentPanel()
                }
                .controlSize(.small)

                Menu("Export…") {
                    Button("Export Artboard/Page as SVG…") { exportPanel(format: "svg") }
                    Button("Export Artboard/Page as PNG (2x)…") { exportPanel(format: "png") }
                    Button("Export Artboard/Page as PDF…") { exportPanel(format: "pdf") }
                    Divider()
                    Button("Copy Selected SVG Code") { viewModel.copySVGToPasteboard() }
                    Button("Copy Selected CSS Attributes") { viewModel.copyCSSToPasteboard() }
                }
                .controlSize(.small)
                .frame(width: 90)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func toolbarBooleanButton(title: String, icon: String, op: SketchBooleanOperation) -> some View {
        Button {
            viewModel.performBooleanOperation(op)
        } label: {
            VStack(spacing: 1) {
                Image(systemName: icon)
                Text(title).font(.system(size: 9))
            }
        }
        .buttonStyle(.borderless)
        .disabled(viewModel.selectedLayerIDs.isEmpty)
        .help("\(title) (booleanOperation = \(op.rawValue))")
    }

    // MARK: - Left Sidebar (Pages + Search Layers + Layer List Tree)

    private var leftSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // PAGES Header
            HStack {
                Text("PAGES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    viewModel.addPage()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Add New Page")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            // Pages List
            VStack(spacing: 2) {
                ForEach(Array(viewModel.archive.pages.enumerated()), id: \.element.do_objectID) { idx, page in
                    let isSelectedPage = (viewModel.archive.currentPageIndex == idx)
                    HStack {
                        Image(systemName: page.name == "Symbols" ? "sparkles.rectangle.stack" : "doc.plaintext")
                            .font(.system(size: 11))
                            .foregroundColor(isSelectedPage ? .white : .secondary)
                        Text(page.name)
                            .font(.system(size: 12, weight: isSelectedPage ? .semibold : .regular))
                            .foregroundColor(isSelectedPage ? .white : .primary)
                        Spacer()
                        Text("\(page.layers.count)")
                            .font(.system(size: 10))
                            .foregroundColor(isSelectedPage ? .white.opacity(0.8) : .secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelectedPage ? Color.accentColor : Color.clear)
                    .cornerRadius(5)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.selectPage(at: idx)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 6)

            Divider()

            // Search Layers Bar (matches MSFilterBarView in BCLayerList)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                TextField("Search Layers", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Layer List Tree
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(viewModel.currentPage.layers.reversed(), id: \.do_objectID) { layer in
                        LayerTreeRowView(
                            layer: layer,
                            depth: 0,
                            viewModel: viewModel
                        )
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
        }
        .frame(width: 235)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Bottom Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(viewModel.lastValidationStatus == .valid ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(viewModel.statusBannerMessage ?? "This document does not use a color profile.")
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            if let fileURL = viewModel.fileURL {
                Text(fileURL.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text("Validation status: \(viewModel.lastValidationStatus.rawValue)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Native macOS File Dialogs

    private func openSketchDocumentPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open .sketch Document"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            try? viewModel.loadDocument(from: url, allowRepairOrNewer: true)
        }
    }

    private func saveSketchDocumentPanel() {
        let panel = NSSavePanel()
        panel.title = "Save .sketch Document"
        panel.nameFieldStringValue = viewModel.fileURL?.lastPathComponent ?? "Untitled.sketch"
        if panel.runModal() == .OK, let url = panel.url {
            try? viewModel.saveDocument(to: url)
        }
    }

    private func exportPanel(format: String) {
        let panel = NSSavePanel()
        panel.title = "Export as \(format.uppercased())"
        let target = viewModel.primarySelectedLayer ?? viewModel.currentPage.layers.first ?? viewModel.currentPage
        let baseName = target.name.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(baseName).\(format)"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                switch format {
                case "svg":
                    let svg = SketchExporter.exportSVG(layer: target, in: viewModel.archive)
                    try Data(svg.utf8).write(to: url)
                case "png":
                    if let png = SketchExporter.exportPNG(layer: target, in: viewModel.archive, scale: 2.0) {
                        try png.write(to: url)
                    }
                case "pdf":
                    if let pdf = SketchExporter.exportPDF(layer: target, in: viewModel.archive) {
                        try pdf.write(to: url)
                    }
                default:
                    break
                }
                viewModel.statusBannerMessage = "Exported \(url.lastPathComponent)"
            } catch {
                viewModel.statusBannerMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Recursive Layer Tree Row (BCLayerList equivalent)

private struct LayerTreeRowView: View {
    let layer: SketchLayer
    let depth: Int
    @ObservedObject var viewModel: SketchDocumentViewModel
    @State private var isExpanded: Bool

    init(layer: SketchLayer, depth: Int, viewModel: SketchDocumentViewModel) {
        self.layer = layer
        self.depth = depth
        self.viewModel = viewModel
        self._isExpanded = State(initialValue: depth == 0)
    }

    private var isSelected: Bool {
        viewModel.selectedLayerIDs.contains(layer.do_objectID)
    }

    private var matchesSearch: Bool {
        let q = viewModel.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true }
        if layer.name.lowercased().contains(q) { return true }
        for child in layer.layers {
            if child.name.lowercased().contains(q) { return true }
        }
        return false
    }

    var body: some View {
        if matchesSearch {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Spacer().frame(width: CGFloat(depth * 14))

                    if !layer.layers.isEmpty {
                        Button {
                            isExpanded.toggle()
                        } label: {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(isSelected ? .white : .secondary)
                                .frame(width: 12)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Spacer().frame(width: 12)
                    }

                    Image(systemName: layer.kind.systemIconName)
                        .font(.system(size: 11))
                        .foregroundColor(iconColor(for: layer))

                    Text(layer.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .white : (layer.isVisible ? .primary : .secondary))
                        .lineLimit(1)

                    Spacer()

                    if layer.hasClippingMask {
                        Text("M")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.25))
                            .cornerRadius(3)
                    }

                    if layer.booleanOperation != .none {
                        Text(String(layer.booleanOperation.title.prefix(1)))
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(3)
                    }

                    Button {
                        viewModel.updateLayer(id: layer.do_objectID) {
                            $0.isLocked.toggle()
                        }
                    } label: {
                        Image(systemName: layer.isLocked ? "lock.fill" : "lock.open")
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? .white.opacity(0.85) : (layer.isLocked ? .orange : .secondary.opacity(0.4)))
                    }
                    .buttonStyle(.borderless)

                    Button {
                        viewModel.updateLayer(id: layer.do_objectID) {
                            $0.isVisible.toggle()
                        }
                    } label: {
                        Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                            .font(.system(size: 10))
                            .foregroundColor(isSelected ? .white.opacity(0.85) : (layer.isVisible ? .secondary.opacity(0.4) : .orange))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.clear)
                .cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.shift) {
                        if viewModel.selectedLayerIDs.contains(layer.do_objectID) {
                            viewModel.selectedLayerIDs.remove(layer.do_objectID)
                        } else {
                            viewModel.selectedLayerIDs.insert(layer.do_objectID)
                        }
                    } else {
                        viewModel.selectedLayerIDs = [layer.do_objectID]
                    }
                }
                .contextMenu {
                    Button("Duplicate") {
                        viewModel.selectedLayerIDs = [layer.do_objectID]
                        viewModel.duplicateSelectedLayers()
                    }
                    Button("Group Selection") {
                        viewModel.groupSelectedLayers()
                    }
                    if layer.kind == .group {
                        Button("Ungroup") {
                            viewModel.selectedLayerIDs = [layer.do_objectID]
                            viewModel.ungroupSelectedLayers()
                        }
                    }
                    if layer.kind == .shapeGroup {
                        Button("Flatten to Path") {
                            viewModel.selectedLayerIDs = [layer.do_objectID]
                            viewModel.flattenSelectedLayer()
                        }
                    }
                    Button(layer.hasClippingMask ? "Disable Mask" : "Use as Mask") {
                        viewModel.selectedLayerIDs = [layer.do_objectID]
                        viewModel.toggleMaskOnSelectedLayer()
                    }
                    Button("Create Symbol") {
                        viewModel.selectedLayerIDs = [layer.do_objectID]
                        viewModel.createSymbolFromSelection()
                    }
                    Divider()
                    Button("Copy CSS Attributes") {
                        viewModel.selectedLayerIDs = [layer.do_objectID]
                        viewModel.copyCSSToPasteboard()
                    }
                    Button("Copy SVG Code") {
                        viewModel.selectedLayerIDs = [layer.do_objectID]
                        viewModel.copySVGToPasteboard()
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        viewModel.selectedLayerIDs = [layer.do_objectID]
                        viewModel.deleteSelectedLayers()
                    }
                }

                if isExpanded && !layer.layers.isEmpty {
                    ForEach(layer.layers.reversed(), id: \.do_objectID) { child in
                        LayerTreeRowView(
                            layer: child,
                            depth: depth + 1,
                            viewModel: viewModel
                        )
                    }
                }
            }
        }
    }

    private func iconColor(for l: SketchLayer) -> Color {
        if isSelected { return .white }
        if l.kind == .symbolMaster || l.kind == .symbolInstance {
            return .purple
        }
        if l.kind == .artboard {
            return .accentColor
        }
        return .secondary
    }
}

// MARK: - Components Library View (Reconstructs MSComponentsPaneController & MSVersionedArchiveReader Preset Swatches)

private struct ComponentsLibraryView: View {
    @ObservedObject var viewModel: SketchDocumentViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Document Components & Preset Assets")
                            .font(.system(size: 16, weight: .bold))
                        Text("\(viewModel.archive.allSymbolMasters.count) Symbols • \(viewModel.presetAssets.colors.count) Color Presets (MSVersionedArchiveReader v\(viewModel.presetAssets.version))")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Return to Canvas") {
                        viewModel.showComponentsView = false
                    }
                    .controlSize(.small)
                }

                Divider()

                Text("DOCUMENT SYMBOLS")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                    ForEach(viewModel.archive.allSymbolMasters, id: \.do_objectID) { master in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "sparkles.rectangle.stack")
                                    .foregroundColor(.purple)
                                Text(master.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Spacer()
                            }

                            Text(master.groupLayout?.displayTitle ?? "Freeform")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)

                            Text("\(Int(master.frame.width)) × \(Int(master.frame.height)) pt • \(master.layers.count) child layers")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)

                            HStack {
                                Button("Insert Instance") {
                                    if let sid = master.symbolID {
                                        viewModel.insertSymbolInstance(symbolID: sid)
                                    }
                                }
                                .controlSize(.small)

                                Spacer()

                                Button("Edit Master") {
                                    viewModel.selectedLayerIDs = [master.do_objectID]
                                    viewModel.showComponentsView = false
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(12)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.purple.opacity(0.25), lineWidth: 1)
                        )
                    }
                }

                Divider()

                Text("COLOR PRESETS (assets.sketchpreset — MSVersionedArchiveReader)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                    ForEach(Array(viewModel.presetAssets.colors.enumerated()), id: \.offset) { _, color in
                        Button {
                            if let selected = viewModel.primarySelectedLayer {
                                viewModel.updateLayer(id: selected.do_objectID) { layer in
                                    if layer.style.fills.isEmpty {
                                        layer.style.fills.append(SketchFill(isEnabled: true, fillType: 0, color: color))
                                    } else {
                                        layer.style.fills[0].color = color
                                        layer.style.fills[0].isEnabled = true
                                    }
                                }
                                viewModel.statusBannerMessage = "Applied preset color #\(color.hexString) to '\(selected.name)'."
                            }
                        } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(cgColor: SketchCoreGraphicsRenderer.cgColor(from: color)))
                                    .frame(width: 22, height: 22)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                                Text("#\(color.hexString)")
                                    .font(.system(size: 11, design: .monospaced))
                                Spacer()
                            }
                            .padding(6)
                            .background(Color(nsColor: .windowBackgroundColor))
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
