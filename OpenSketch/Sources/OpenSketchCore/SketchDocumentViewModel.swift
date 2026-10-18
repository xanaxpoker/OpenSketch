import Foundation
import CoreGraphics
import AppKit
import Combine

public enum SketchToolMode: String, CaseIterable, Identifiable, Sendable {
    case select = "Select"
    case artboard = "Artboard"
    case rectangle = "Rectangle"
    case roundedRect = "Rounded"
    case oval = "Oval"
    case polygon = "Polygon"
    case star = "Star"
    case triangle = "Triangle"
    case line = "Line"
    case vector = "Vector"
    case text = "Text"
    case slice = "Slice"
    case editPoints = "Edit Points"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .select: return "cursorarrow"
        case .artboard: return "macwindow.badge.plus"
        case .rectangle: return "rectangle"
        case .roundedRect: return "rectangle.roundedtop"
        case .oval: return "circle"
        case .polygon: return "hexagon"
        case .star: return "star"
        case .triangle: return "triangle"
        case .line: return "line.diagonal"
        case .vector: return "scribble"
        case .text: return "textformat"
        case .slice: return "scissors"
        case .editPoints: return "point.topleft.down.curvedto.point.bottomright.up"
        }
    }
}

public enum SketchAlignmentAction: String, CaseIterable, Sendable {
    case left = "alignLayersLeft:"
    case center = "alignLayersCenter:"
    case right = "alignLayersRight:"
    case top = "alignLayersTop:"
    case middle = "alignLayersMiddle:"
    case bottom = "alignLayersBottom:"
    case distributeHorizontally = "distributeHorizontally:"
    case distributeVertically = "distributeVertically:"
}

@MainActor
public final class SketchDocumentViewModel: ObservableObject {
    @Published public var archive: SketchDocumentArchive
    @Published public var fileURL: URL?
    @Published public var lastValidationStatus: SketchValidationStatus = .valid
    @Published public var wasRepairedOnOpen: Bool = false
    @Published public var statusBannerMessage: String?

    @Published public var selectedLayerIDs: Set<String> = []
    @Published public var expandedLayerIDs: Set<String> = []
    @Published public var searchQuery: String = ""
    @Published public var currentTool: SketchToolMode = .select
    @Published public var showComponentsView: Bool = false
    @Published public var presetAssets: SketchVersionedPresetArchive = SketchVersionedPresetArchive(
        colors: [
            SketchColor(red: 0.816, green: 0.008, blue: 0.106, alpha: 1.0),
            SketchColor(red: 0.961, green: 0.651, blue: 0.137, alpha: 1.0),
            SketchColor(red: 0.973, green: 0.906, blue: 0.110, alpha: 1.0),
            SketchColor(red: 0.494, green: 0.827, blue: 0.129, alpha: 1.0),
            SketchColor(red: 0.290, green: 0.565, blue: 0.886, alpha: 1.0),
            SketchColor(red: 0.565, green: 0.075, blue: 0.996, alpha: 1.0),
            SketchColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0),
            SketchColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ]
    )

    @Published public var zoomScale: Double = 1.0
    @Published public var panOffset: CGSize = CGSize(width: 40, height: 40)
    @Published public var showRulers: Bool = true
    @Published public var showPixelGrid: Bool = false
    @Published public var showAlignmentGuides: Bool = true
    @Published public var activeSnapGuides: [SketchSnapGuide] = []
    @Published public var tidySpacing: Double = 8.0
    @Published public var lastPerfReport: SketchPerformanceReport?
    @Published public var showPerfInspectorPopover: Bool = false

    private var undoStack: [SketchDocumentArchive] = []
    private var redoStack: [SketchDocumentArchive] = []

    public init(archive: SketchDocumentArchive = SketchDocumentArchive(), fileURL: URL? = nil) {
        self.archive = archive
        self.fileURL = fileURL
        let presetURL = URL(fileURLWithPath: "/Applications/Sketch.app/Contents/Resources/assets.sketchpreset")
        if let loadedPresets = try? SketchDocumentIO.readVersionedPresetArchive(at: presetURL),
           !loadedPresets.colors.isEmpty {
            self.presetAssets = loadedPresets
        }
        expandTopLevelContainers()
    }

    public func runPerformanceChecks() -> SketchPerformanceReport {
        let report = SketchPerformanceSuite.runAllChecks(on: archive, archiveURL: fileURL)
        self.lastPerfReport = report
        self.statusBannerMessage = report.summaryLine
        return report
    }

    public var currentPage: SketchPageAlias {
        get {
            guard !archive.pages.isEmpty else {
                return SketchLayer(kind: .page, name: "Page 1", frame: SketchRect())
            }
            let idx = min(max(0, archive.currentPageIndex), archive.pages.count - 1)
            return archive.pages[idx]
        }
        set {
            guard !archive.pages.isEmpty else {
                archive.pages = [newValue]
                archive.currentPageIndex = 0
                return
            }
            let idx = min(max(0, archive.currentPageIndex), archive.pages.count - 1)
            archive.pages[idx] = newValue
            SketchRenderCache.shared.invalidateDocumentSymbols(documentID: archive.documentID)
        }
    }

    public typealias SketchPageAlias = SketchLayer

    // MARK: - File Open / Save / Repair

    public func loadDocument(from url: URL, allowRepairOrNewer: Bool = true) throws {
        let (doc, status, repaired) = try SketchDocumentIO.readDocument(at: url, allowRepairOrNewer: allowRepairOrNewer)
        recordUndoSnapshot()
        SketchRenderCache.shared.clearAll()
        self.archive = doc
        self.fileURL = url
        self.lastValidationStatus = status
        self.wasRepairedOnOpen = repaired
        self.selectedLayerIDs.removeAll()
        expandTopLevelContainers()

        if repaired {
            statusBannerMessage = "Opened with repaired metadata (MSDocumentZippedJSONReader -repair)."
        } else if status == .newerVersionWarning {
            statusBannerMessage = "Opened newer document version (validation status 4)."
        } else if status == .legacyUnsupported {
            statusBannerMessage = "Opened legacy document version <= 87 (validation status 3)."
        } else {
            statusBannerMessage = "This document does not use a color profile."
        }
    }

    public func saveDocument(to url: URL? = nil) throws {
        let target = url ?? fileURL
        guard let dest = target else { return }
        try SketchDocumentIO.writeDocument(archive, to: dest, isAutosave: false)
        self.fileURL = dest
        self.statusBannerMessage = "Saved \(dest.lastPathComponent) (format v139)."
    }

    // MARK: - Undo / Redo

    public func recordUndoSnapshot() {
        undoStack.append(archive)
        if undoStack.count > 40 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(archive)
        archive = prev
        SketchRenderCache.shared.invalidateDocumentSymbols(documentID: archive.documentID)
    }

    public func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(archive)
        archive = next
        SketchRenderCache.shared.invalidateDocumentSymbols(documentID: archive.documentID)
    }

    // MARK: - Page Management (`nextPage:`, `previousPage:`)

    public func selectPage(at index: Int) {
        guard index >= 0 && index < archive.pages.count else { return }
        archive.currentPageIndex = index
        selectedLayerIDs.removeAll()
        expandTopLevelContainers()
    }

    public func addPage(name: String? = nil) {
        recordUndoSnapshot()
        let pageName = name ?? "Page \(archive.pages.count + 1)"
        let newPage = SketchLayer(
            kind: .page,
            name: pageName,
            frame: SketchRect(),
            layers: [
                SketchLayer.makeArtboard(
                    name: "Artboard 1",
                    frame: SketchRect(x: 60, y: 60, width: 480, height: 320)
                )
            ]
        )
        archive.pages.append(newPage)
        archive.currentPageIndex = archive.pages.count - 1
        selectedLayerIDs.removeAll()
        expandTopLevelContainers()
    }

    public func deleteCurrentPage() {
        guard archive.pages.count > 1 else { return }
        recordUndoSnapshot()
        archive.pages.remove(at: archive.currentPageIndex)
        archive.currentPageIndex = max(0, archive.currentPageIndex - 1)
        selectedLayerIDs.removeAll()
    }

    // MARK: - Layer Lookup & Mutation Helpers

    public var primarySelectedLayer: SketchLayer? {
        guard let firstID = selectedLayerIDs.first else { return nil }
        return findLayer(id: firstID, in: currentPage.layers)
    }

    public var selectedLayers: [SketchLayer] {
        var found: [SketchLayer] = []
        func collect(_ list: [SketchLayer]) {
            for item in list {
                if selectedLayerIDs.contains(item.do_objectID) {
                    found.append(item)
                }
                if !item.layers.isEmpty {
                    collect(item.layers)
                }
            }
        }
        collect(currentPage.layers)
        return found
    }

    public func findLayer(id: String, in list: [SketchLayer]) -> SketchLayer? {
        for item in list {
            if item.do_objectID == id { return item }
            if let sub = findLayer(id: id, in: item.layers) { return sub }
        }
        return nil
    }

    public func updateLayer(id: String, recordUndo: Bool = true, transform: (inout SketchLayer) -> Void) {
        if recordUndo {
            recordUndoSnapshot()
        }
        var page = currentPage
        _ = mutateLayerInList(id: id, list: &page.layers, transform: transform)
        currentPage = page
    }

    private func mutateLayerInList(id: String, list: inout [SketchLayer], transform: (inout SketchLayer) -> Void) -> Bool {
        for i in list.indices {
            if list[i].do_objectID == id {
                transform(&list[i])
                return true
            }
            if !list[i].layers.isEmpty {
                if mutateLayerInList(id: id, list: &list[i].layers, transform: transform) {
                    return true
                }
            }
        }
        return false
    }

    public func expandTopLevelContainers() {
        for layer in currentPage.layers {
            expandedLayerIDs.insert(layer.do_objectID)
        }
    }

    // MARK: - Layer Creation & Canvas Insertion

    public func insertLayer(_ newLayer: SketchLayer, intoArtboardID: String? = nil) {
        recordUndoSnapshot()
        var page = currentPage
        if let targetID = intoArtboardID ?? selectedLayerIDs.first,
           mutateLayerInList(id: targetID, list: &page.layers, transform: { container in
               if [.artboard, .symbolMaster, .group, .shapeGroup].contains(container.kind) {
                   container.layers.append(newLayer)
               }
           }),
           findLayer(id: newLayer.do_objectID, in: page.layers) != nil {
            currentPage = page
            selectedLayerIDs = [newLayer.do_objectID]
            expandedLayerIDs.insert(targetID)
            currentTool = .select
            return
        }
        // Otherwise insert into first artboard or page root
        if let firstArtboardIdx = page.layers.firstIndex(where: { $0.kind == .artboard || $0.kind == .symbolMaster }) {
            page.layers[firstArtboardIdx].layers.append(newLayer)
            expandedLayerIDs.insert(page.layers[firstArtboardIdx].do_objectID)
        } else {
            page.layers.append(newLayer)
        }
        currentPage = page
        selectedLayerIDs = [newLayer.do_objectID]
        currentTool = .select
    }

    public func insertShape(for tool: SketchToolMode, at point: CGPoint = CGPoint(x: 80, y: 80)) {
        switch tool {
        case .artboard:
            let maxX = currentPage.layers.map { $0.frame.x + $0.frame.width }.max() ?? 0
            let ab = SketchLayer.makeArtboard(
                name: "Artboard \(currentPage.layers.count + 1)",
                frame: SketchRect(x: maxX + 60, y: 40, width: 375, height: 667)
            )
            recordUndoSnapshot()
            var page = currentPage
            page.layers.append(ab)
            currentPage = page
            selectedLayerIDs = [ab.do_objectID]
            expandedLayerIDs.insert(ab.do_objectID)
            currentTool = .select

        case .rectangle:
            let rect = SketchLayer.makeRectangle(
                name: "Rectangle",
                frame: SketchRect(x: Double(point.x), y: Double(point.y), width: 140, height: 90),
                cornerRadius: 0,
                fillColor: SketchColor(red: 0.01, green: 0.48, blue: 1.0, alpha: 1.0),
                borderColor: SketchColor(red: 0.0, green: 0.35, blue: 0.85, alpha: 1.0)
            )
            insertLayer(rect)

        case .roundedRect:
            let rrect = SketchLayer.makeRectangle(
                name: "Rounded Rectangle",
                frame: SketchRect(x: Double(point.x), y: Double(point.y), width: 150, height: 52),
                cornerRadius: 12,
                fillColor: .sketchBlue,
                borderColor: .sketchBlue
            )
            insertLayer(rrect)

        case .oval:
            let oval = SketchLayer.makeOval(
                name: "Oval",
                frame: SketchRect(x: Double(point.x), y: Double(point.y), width: 100, height: 100),
                fillColor: SketchColor(red: 0.96, green: 0.56, blue: 0.12, alpha: 1.0),
                borderColor: SketchColor(red: 0.85, green: 0.42, blue: 0.05, alpha: 1.0)
            )
            insertLayer(oval)

        case .polygon:
            let poly = SketchLayer.makePolygon(
                name: "Polygon",
                sides: 6,
                frame: SketchRect(x: Double(point.x), y: Double(point.y), width: 100, height: 100)
            )
            insertLayer(poly)

        case .star:
            let star = SketchLayer.makeStar(
                name: "Star",
                pointsCount: 5,
                frame: SketchRect(x: Double(point.x), y: Double(point.y), width: 100, height: 100)
            )
            insertLayer(star)

        case .triangle:
            let tri = SketchLayer.makeTriangle(
                name: "Triangle",
                frame: SketchRect(x: Double(point.x), y: Double(point.y), width: 100, height: 90)
            )
            insertLayer(tri)

        case .line:
            let pts = [
                SketchCurvePoint(point: CGPoint(x: 0, y: 0.5), curveMode: .straight),
                SketchCurvePoint(point: CGPoint(x: 1, y: 0.5), curveMode: .straight)
            ]
            let style = SketchStyle(
                fills: [],
                borders: [SketchBorder(isEnabled: true, fillType: 0, color: .sketchBlue, position: 0, thickness: 2)]
            )
            let line = SketchLayer(
                kind: .shapePath,
                name: "Line",
                frame: SketchRect(x: Double(point.x), y: Double(point.y), width: 160, height: 12),
                style: style,
                points: pts,
                isClosed: false
            )
            insertLayer(line)

        case .vector:
            let pts = [
                SketchCurvePoint(point: CGPoint(x: 0.0, y: 0.8), curveMode: .straight),
                SketchCurvePoint(
                    point: CGPoint(x: 0.5, y: 0.1),
                    curveFrom: CGPoint(x: 0.7, y: 0.1),
                    curveTo: CGPoint(x: 0.3, y: 0.1),
                    hasCurveFrom: true, hasCurveTo: true, curveMode: .mirrored
                ),
                SketchCurvePoint(point: CGPoint(x: 1.0, y: 0.8), curveMode: .straight)
            ]
            let style = SketchStyle(
                fills: [SketchFill(isEnabled: true, fillType: 0, color: SketchColor(red: 0.56, green: 0.27, blue: 0.93, alpha: 0.2))],
                borders: [SketchBorder(isEnabled: true, fillType: 0, color: SketchColor(red: 0.56, green: 0.27, blue: 0.93, alpha: 1.0), position: 0, thickness: 2)]
            )
            let vec = SketchLayer(
                kind: .shapePath,
                name: "Path",
                frame: SketchRect(x: Double(point.x), y: Double(point.y), width: 140, height: 90),
                style: style,
                points: pts,
                isClosed: true
            )
            insertLayer(vec)

        case .text:
            let txt = SketchLayer.makeText(
                name: "Text Layer",
                text: "Edit Me",
                frame: SketchRect(x: Double(point.x), y: Double(point.y), width: 120, height: 28),
                fontSize: 18,
                color: .black
            )
            insertLayer(txt)

        case .slice:
            var slice = SketchLayer(
                kind: .slice,
                name: "Slice",
                frame: SketchRect(x: Double(point.x), y: Double(point.y), width: 120, height: 120)
            )
            slice.exportOptions.exportFormats = [SketchExportFormat(scale: 1, fileFormat: "png")]
            insertLayer(slice)

        case .select, .editPoints:
            break
        }
    }

    // MARK: - Selection Actions (`delete:`, `duplicate:`, `group:`, `ungroup:`, `maskWithShape:`, `flipHorizontal:`, `flipVertical:`)

    public func deleteSelectedLayers() {
        guard !selectedLayerIDs.isEmpty else { return }
        recordUndoSnapshot()
        var page = currentPage
        func removeSelected(from list: inout [SketchLayer]) {
            list.removeAll { selectedLayerIDs.contains($0.do_objectID) }
            for i in list.indices {
                removeSelected(from: &list[i].layers)
            }
        }
        removeSelected(from: &page.layers)
        currentPage = page
        selectedLayerIDs.removeAll()
    }

    public func duplicateSelectedLayers() {
        let targets = selectedLayers
        guard !targets.isEmpty else { return }
        for item in targets {
            var copy = cloneWithFreshIDs(item)
            copy.name = "\(item.name) Copy"
            copy.frame.x += 16
            copy.frame.y += 16
            insertLayer(copy)
        }
    }

    private func cloneWithFreshIDs(_ layer: SketchLayer) -> SketchLayer {
        var copy = layer
        copy.do_objectID = UUID().uuidString.uppercased()
        copy.layers = layer.layers.map { cloneWithFreshIDs($0) }
        return copy
    }

    public func groupSelectedLayers() {
        let selected = selectedLayers
        guard selected.count >= 1 else { return }
        recordUndoSnapshot()
        let unionRect = selected.map(\.frame.cgRect).reduce(selected[0].frame.cgRect) { $0.union($1) }
        let adjustedChildren: [SketchLayer] = selected.map { child in
            var c = child
            c.frame.x -= Double(unionRect.origin.x)
            c.frame.y -= Double(unionRect.origin.y)
            return c
        }
        let group = SketchLayer(
            kind: .group,
            name: "Group",
            frame: SketchRect(
                x: Double(unionRect.origin.x),
                y: Double(unionRect.origin.y),
                width: Double(unionRect.width),
                height: Double(unionRect.height)
            ),
            layers: adjustedChildren,
            groupLayout: SketchGroupLayout(isSmartLayout: false)
        )
        deleteSelectedLayers()
        insertLayer(group)
    }

    public func ungroupSelectedLayers() {
        guard let grp = primarySelectedLayer, grp.kind == .group else { return }
        recordUndoSnapshot()
        let promoted: [SketchLayer] = grp.layers.map { child in
            var c = child
            c.frame.x += grp.frame.x
            c.frame.y += grp.frame.y
            return c
        }
        var page = currentPage
        func replaceGroup(in list: inout [SketchLayer]) -> Bool {
            if let idx = list.firstIndex(where: { $0.do_objectID == grp.do_objectID }) {
                list.remove(at: idx)
                list.insert(contentsOf: promoted, at: idx)
                return true
            }
            for i in list.indices {
                if replaceGroup(in: &list[i].layers) { return true }
            }
            return false
        }
        if replaceGroup(in: &page.layers) {
            currentPage = page
            selectedLayerIDs = Set(promoted.map(\.do_objectID))
        }
    }

    public func toggleMaskOnSelectedLayer() {
        guard let target = primarySelectedLayer else { return }
        updateLayer(id: target.do_objectID) {
            $0.hasClippingMask.toggle()
        }
    }

    public func flipSelectedLayers(horizontal: Bool) {
        let ids = selectedLayerIDs
        guard !ids.isEmpty else { return }
        recordUndoSnapshot()
        for id in ids {
            updateLayer(id: id, recordUndo: false) {
                if horizontal {
                    $0.isFlippedHorizontal.toggle()
                } else {
                    $0.isFlippedVertical.toggle()
                }
            }
        }
    }

    public func insertSymbolInstance(symbolID: String) {
        guard let master = archive.symbolMaster(forSymbolID: symbolID) else { return }
        let inst = SketchLayer(
            kind: .symbolInstance,
            name: master.name,
            frame: SketchRect(x: 40, y: 40, width: master.frame.width, height: master.frame.height),
            symbolID: symbolID
        )
        insertLayer(inst)
        showComponentsView = false
        statusBannerMessage = "Inserted Symbol instance '\(master.name)'."
    }

    // MARK: - Alignment & Tidy (`alignLayersLeft:`, `tidy:`, etc.)

    public func alignSelectedLayers(_ action: SketchAlignmentAction) {
        let selected = selectedLayers
        guard selected.count >= 2 else { return }
        recordUndoSnapshot()

        let minX = selected.map(\.frame.x).min() ?? 0
        let maxX = selected.map { $0.frame.x + $0.frame.width }.max() ?? 0
        let midX = (minX + maxX) * 0.5
        let minY = selected.map(\.frame.y).min() ?? 0
        let maxY = selected.map { $0.frame.y + $0.frame.height }.max() ?? 0
        let midY = (minY + maxY) * 0.5

        for item in selected {
            updateLayer(id: item.do_objectID, recordUndo: false) { layer in
                switch action {
                case .left: layer.frame.x = minX
                case .center: layer.frame.x = midX - layer.frame.width * 0.5
                case .right: layer.frame.x = maxX - layer.frame.width
                case .top: layer.frame.y = minY
                case .middle: layer.frame.y = midY - layer.frame.height * 0.5
                case .bottom: layer.frame.y = maxY - layer.frame.height
                case .distributeHorizontally, .distributeVertically:
                    break
                }
            }
        }

        if action == .distributeHorizontally || action == .distributeVertically {
            tidySelectedLayers()
        }
    }

    public func tidySelectedLayers() {
        recordUndoSnapshot()
        var page = currentPage
        func tidyRecursive(in list: inout [SketchLayer]) {
            SketchSnapEngine.tidyLayers(&list, selectedIDs: selectedLayerIDs, spacing: tidySpacing)
            for i in list.indices {
                tidyRecursive(in: &list[i].layers)
            }
        }
        tidyRecursive(in: &page.layers)
        currentPage = page
    }

    // MARK: - Boolean Operations (`booleanUnion:`, `booleanSubtract:`, `booleanIntersect:`, `booleanDifference:`, `flatten:`)

    public func performBooleanOperation(_ op: SketchBooleanOperation) {
        let selected = selectedLayers
        guard selected.count >= 2 else {
            if let single = primarySelectedLayer {
                updateLayer(id: single.do_objectID) { $0.booleanOperation = op }
            }
            return
        }
        recordUndoSnapshot()
        let combined = SketchBooleanEngine.combineLayers(selected[0], selected[1], operation: op)
        let idsToRemove: Set<String> = [selected[0].do_objectID, selected[1].do_objectID]
        var page = currentPage
        func replacePair(in list: inout [SketchLayer]) -> Bool {
            let matchingIndices = list.indices.filter { idsToRemove.contains(list[$0].do_objectID) }
            if matchingIndices.count == 2 {
                let firstIdx = matchingIndices[0]
                list.removeAll { idsToRemove.contains($0.do_objectID) }
                list.insert(combined, at: min(firstIdx, list.count))
                return true
            }
            for i in list.indices {
                if replacePair(in: &list[i].layers) { return true }
            }
            return false
        }
        if replacePair(in: &page.layers) {
            currentPage = page
            selectedLayerIDs = [combined.do_objectID]
        }
    }

    public func flattenSelectedLayer() {
        guard let selected = primarySelectedLayer, selected.kind == .shapeGroup else { return }
        recordUndoSnapshot()
        let flattened = SketchBooleanEngine.flattenShapeGroup(selected)
        var page = currentPage
        func replaceGroup(in list: inout [SketchLayer]) -> Bool {
            if let idx = list.firstIndex(where: { $0.do_objectID == selected.do_objectID }) {
                list[idx] = flattened
                return true
            }
            for i in list.indices {
                if replaceGroup(in: &list[i].layers) { return true }
            }
            return false
        }
        if replaceGroup(in: &page.layers) {
            currentPage = page
            selectedLayerIDs = [flattened.do_objectID]
        }
    }

    // MARK: - Symbols & Overrides (`createSymbolAction:`, `detachSymbolInstances:`)

    public func createSymbolFromSelection() {
        guard let target = primarySelectedLayer else { return }
        recordUndoSnapshot()
        let newSymbolID = UUID().uuidString.uppercased()

        var childCopy = cloneWithFreshIDs(target)
        childCopy.frame.x = 0
        childCopy.frame.y = 0

        let master = SketchLayer(
            kind: .symbolMaster,
            name: target.name,
            frame: SketchRect(x: target.frame.x + target.frame.width + 60, y: target.frame.y, width: target.frame.width, height: target.frame.height),
            layers: [childCopy],
            symbolID: newSymbolID,
            groupLayout: SketchGroupLayout(isSmartLayout: true, axis: 0, layoutAnchor: 0),
            hasBackgroundColor: true,
            backgroundColor: .white
        )

        let instance = SketchLayer(
            kind: .symbolInstance,
            name: target.name,
            frame: target.frame,
            symbolID: newSymbolID
        )

        var page = currentPage
        func replaceWithInstance(in list: inout [SketchLayer]) -> Bool {
            if let idx = list.firstIndex(where: { $0.do_objectID == target.do_objectID }) {
                list[idx] = instance
                return true
            }
            for i in list.indices {
                if replaceWithInstance(in: &list[i].layers) { return true }
            }
            return false
        }
        _ = replaceWithInstance(in: &page.layers)
        page.layers.append(master)
        currentPage = page
        selectedLayerIDs = [instance.do_objectID]
        statusBannerMessage = "Created Symbol '\(master.name)' with Horizontal Smart Layout."
    }

    public func detachSelectedSymbolInstance() {
        guard let inst = primarySelectedLayer,
              inst.kind == .symbolInstance,
              let expanded = SketchSmartLayoutEngine.expandSymbolInstance(inst, in: archive) else {
            return
        }
        recordUndoSnapshot()
        let group = SketchLayer(
            kind: .group,
            name: "\(inst.name) (Detached)",
            frame: expanded.frame,
            layers: expanded.layers.map { cloneWithFreshIDs($0) },
            groupLayout: expanded.groupLayout
        )
        var page = currentPage
        func replaceInstance(in list: inout [SketchLayer]) -> Bool {
            if let idx = list.firstIndex(where: { $0.do_objectID == inst.do_objectID }) {
                list[idx] = group
                return true
            }
            for i in list.indices {
                if replaceInstance(in: &list[i].layers) { return true }
            }
            return false
        }
        if replaceInstance(in: &page.layers) {
            currentPage = page
            selectedLayerIDs = [group.do_objectID]
            expandedLayerIDs.insert(group.do_objectID)
        }
    }

    public func updateSymbolOverride(layerID: String, overrideName: String, value: String) {
        updateLayer(id: layerID) { layer in
            if let idx = layer.overrideValues.firstIndex(where: { $0.overrideName == overrideName }) {
                layer.overrideValues[idx].value = value
            } else {
                layer.overrideValues.append(SketchOverrideValue(overrideName: overrideName, value: value))
            }
            // If master uses Smart Layout, update the instance frame dynamically!
            if let expanded = SketchSmartLayoutEngine.expandSymbolInstance(layer, in: archive) {
                layer.frame.width = expanded.frame.width
                layer.frame.height = expanded.frame.height
            }
        }
    }

    // MARK: - Clipboard & Export Helpers (`copySVG:`, `copyCSSAttributes:`)

    public func copySVGToPasteboard() {
        guard let layer = primarySelectedLayer else { return }
        let svg = SketchExporter.exportSVG(layer: layer, in: archive)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(svg, forType: .string)
        statusBannerMessage = "Copied SVG for '\(layer.name)' to clipboard."
    }

    public func copyCSSToPasteboard() {
        guard let layer = primarySelectedLayer else { return }
        let css = SketchExporter.cssAttributes(for: layer)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(css, forType: .string)
        statusBannerMessage = "Copied CSS attributes for '\(layer.name)' to clipboard."
    }

    // MARK: - Zoom & Viewport (`zoomIn:`, `zoomOut:`, `actualSize:`, `zoomToSelection:`)

    public func zoomIn() { zoomScale = min(8.0, zoomScale * 1.25) }
    public func zoomOut() { zoomScale = max(0.1, zoomScale / 1.25) }
    public func actualSize() { zoomScale = 1.0; panOffset = CGSize(width: 40, height: 40) }
}
