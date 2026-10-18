import SwiftUI
import AppKit
import OpenSketchCore

public struct InfiniteCanvasView: View {
    @ObservedObject public var viewModel: SketchDocumentViewModel
    @State private var dragStartCanvasPoint: CGPoint?
    @State private var dragCurrentCanvasPoint: CGPoint?
    @State private var initialSelectedFrame: SketchRect?
    @State private var activeResizeHandle: ResizeHandle?
    @State private var activeCurvePointIndex: Int?
    @State private var activeCurveComponent: CurveComponent?
    @State private var selectedPointIndex: Int = 0
    @State private var dragOverrideLayerID: String?
    @State private var dragOverrideFrame: SketchRect?
    @State private var localSnapGuides: [SketchSnapGuide] = []

    public init(viewModel: SketchDocumentViewModel) {
        self.viewModel = viewModel
    }

    public enum ResizeHandle: Int, CaseIterable {
        case topLeft = 0
        case topCenter
        case topRight
        case middleLeft
        case middleRight
        case bottomLeft
        case bottomCenter
        case bottomRight
    }

    public enum CurveComponent {
        case point
        case curveFrom
        case curveTo
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                CanvasRepresentable(
                    viewModel: viewModel,
                    creationPreviewRect: currentCreationRect,
                    selectedPointIndex: selectedPointIndex,
                    dragOverrideLayerID: dragOverrideLayerID,
                    dragOverrideFrame: dragOverrideFrame,
                    localSnapGuides: localSnapGuides
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .gesture(canvasDragGesture(in: geo.size))
                .simultaneousGesture(
                    TapGesture(count: 2)
                        .onEnded {
                            handleDoubleClick()
                        }
                )

                canvasHUD()
            }
            .clipped()
            .background(Color(nsColor: NSColor(calibratedWhite: 0.94, alpha: 1.0)))
        }
    }

    private var currentCreationRect: CGRect? {
        guard let start = dragStartCanvasPoint,
              let current = dragCurrentCanvasPoint,
              isCreationTool(viewModel.currentTool) else {
            return nil
        }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: max(2, abs(current.x - start.x)),
            height: max(2, abs(current.y - start.y))
        )
    }

    private func isCreationTool(_ tool: SketchToolMode) -> Bool {
        switch tool {
        case .artboard, .rectangle, .roundedRect, .oval, .polygon, .star, .triangle, .line, .vector, .text, .slice:
            return true
        case .select, .editPoints:
            return false
        }
    }

    private func screenToCanvas(_ pt: CGPoint) -> CGPoint {
        let z = CGFloat(viewModel.zoomScale)
        return CGPoint(
            x: (pt.x - viewModel.panOffset.width) / z,
            y: (pt.y - viewModel.panOffset.height) / z
        )
    }

    private func canvasToScreen(_ pt: CGPoint) -> CGPoint {
        let z = CGFloat(viewModel.zoomScale)
        return CGPoint(
            x: pt.x * z + viewModel.panOffset.width,
            y: pt.y * z + viewModel.panOffset.height
        )
    }

    private func handleDoubleClick() {
        guard let layer = viewModel.primarySelectedLayer else { return }
        if !layer.points.isEmpty {
            viewModel.currentTool = (viewModel.currentTool == .editPoints) ? .select : .editPoints
            selectedPointIndex = 0
        } else if layer.kind == .symbolInstance,
                  let symID = layer.symbolID,
                  let master = viewModel.archive.symbolMaster(forSymbolID: symID) {
            for (idx, page) in viewModel.archive.pages.enumerated() {
                if viewModel.findLayer(id: master.do_objectID, in: page.layers) != nil {
                    viewModel.selectPage(at: idx)
                    viewModel.selectedLayerIDs = [master.do_objectID]
                    break
                }
            }
        }
    }

    private func canvasDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let startCanvas = screenToCanvas(value.startLocation)
                let currentCanvas = screenToCanvas(value.location)

                if dragStartCanvasPoint == nil {
                    dragStartCanvasPoint = startCanvas

                    if isCreationTool(viewModel.currentTool) {
                        dragCurrentCanvasPoint = currentCanvas
                        return
                    }

                    // Check if editing bezier points first
                    if viewModel.currentTool == .editPoints,
                       let hit = hitTestCurvePoint(at: value.startLocation) {
                        activeCurvePointIndex = hit.index
                        activeCurveComponent = hit.component
                        selectedPointIndex = hit.index
                        return
                    }

                    // Check if clicking a resize handle of current selection
                    if let handle = hitTestResizeHandle(at: value.startLocation) {
                        activeResizeHandle = handle
                        initialSelectedFrame = viewModel.primarySelectedLayer?.frame
                        return
                    }

                    // Otherwise hit-test layer on canvas
                    let hits = hitTestLayers(in: viewModel.currentPage, canvasPoint: startCanvas)
                    if let topHit = hits.first {
                        if NSEvent.modifierFlags.contains(.shift) {
                            if viewModel.selectedLayerIDs.contains(topHit.do_objectID) {
                                viewModel.selectedLayerIDs.remove(topHit.do_objectID)
                            } else {
                                viewModel.selectedLayerIDs.insert(topHit.do_objectID)
                            }
                        } else if !viewModel.selectedLayerIDs.contains(topHit.do_objectID) {
                            viewModel.selectedLayerIDs = [topHit.do_objectID]
                        }
                        initialSelectedFrame = topHit.frame
                    } else {
                        viewModel.selectedLayerIDs.removeAll()
                        if viewModel.currentTool == .editPoints {
                            viewModel.currentTool = .select
                        }
                        initialSelectedFrame = nil
                    }
                }

                dragCurrentCanvasPoint = currentCanvas

                if let ptIndex = activeCurvePointIndex, let comp = activeCurveComponent {
                    updateCurvePoint(index: ptIndex, component: comp, canvasPoint: currentCanvas)
                    return
                }

                if let handle = activeResizeHandle, let initFrame = initialSelectedFrame {
                    resizeSelectedLayer(handle: handle, initialFrame: initFrame, start: startCanvas, current: currentCanvas)
                    return
                }

                // Drag selected layer using local canvas override (zero whole-workspace SwiftUI diffing during drag)
                if viewModel.currentTool == .select,
                   let initFrame = initialSelectedFrame,
                   let selectedID = viewModel.selectedLayerIDs.first,
                   abs(value.translation.width) + abs(value.translation.height) > 2.0 {
                    let dx = Double(currentCanvas.x - startCanvas.x)
                    let dy = Double(currentCanvas.y - startCanvas.y)
                    let proposed = SketchRect(
                        x: round(initFrame.x + dx),
                        y: round(initFrame.y + dy),
                        width: initFrame.width,
                        height: initFrame.height,
                        constrainProportions: initFrame.constrainProportions
                    )

                    let siblings = collectSiblingLayers(in: viewModel.currentPage, excluding: selectedID)
                    let snap = SketchSnapEngine.snapFrame(
                        proposed,
                        against: siblings,
                        excluding: viewModel.selectedLayerIDs
                    )
                    localSnapGuides = snap.guides
                    dragOverrideLayerID = selectedID
                    dragOverrideFrame = SketchRect(
                        x: round(snap.snapped.x),
                        y: round(snap.snapped.y),
                        width: initFrame.width,
                        height: initFrame.height,
                        constrainProportions: initFrame.constrainProportions
                    )
                }
            }
            .onEnded { _ in
                if let overrideID = dragOverrideLayerID, let overrideFrame = dragOverrideFrame {
                    viewModel.updateLayer(id: overrideID, recordUndo: true) { layer in
                        layer.frame = overrideFrame
                    }
                }

                defer {
                    dragStartCanvasPoint = nil
                    dragCurrentCanvasPoint = nil
                    initialSelectedFrame = nil
                    activeResizeHandle = nil
                    activeCurvePointIndex = nil
                    activeCurveComponent = nil
                    dragOverrideLayerID = nil
                    dragOverrideFrame = nil
                    localSnapGuides = []
                    viewModel.activeSnapGuides = []
                }

                if let rect = currentCreationRect {
                    let finalPt = CGPoint(x: round(rect.origin.x), y: round(rect.origin.y))
                    viewModel.insertShape(for: viewModel.currentTool, at: finalPt)
                    if let createdID = viewModel.selectedLayerIDs.first, rect.width > 12, rect.height > 12 {
                        viewModel.updateLayer(id: createdID, recordUndo: false) { layer in
                            layer.frame.width = Double(round(rect.width))
                            layer.frame.height = Double(round(rect.height))
                        }
                    }
                }
            }
    }

    private func hitTestLayers(in page: SketchLayer, canvasPoint: CGPoint) -> [SketchLayer] {
        var hits: [SketchLayer] = []
        func walk(_ list: [SketchLayer], origin: CGPoint) {
            for layer in list.reversed() where layer.isVisible && !layer.isLocked {
                let absRect = CGRect(
                    x: origin.x + CGFloat(layer.frame.x),
                    y: origin.y + CGFloat(layer.frame.y),
                    width: CGFloat(layer.frame.width),
                    height: CGFloat(layer.frame.height)
                )
                if !layer.layers.isEmpty && layer.kind != .shapeGroup && layer.kind != .symbolInstance {
                    walk(layer.layers, origin: absRect.origin)
                }
                if absRect.contains(canvasPoint) {
                    hits.append(layer)
                }
            }
        }
        walk(page.layers, origin: .zero)
        return hits
    }

    private func collectSiblingLayers(in page: SketchLayer, excluding id: String) -> [SketchLayer] {
        var out: [SketchLayer] = []
        for top in page.layers {
            if top.do_objectID != id { out.append(top) }
            for child in top.layers where child.do_objectID != id {
                out.append(child)
            }
        }
        return out
    }

    private func hitTestResizeHandle(at screenPoint: CGPoint) -> ResizeHandle? {
        guard let selectedID = viewModel.selectedLayerIDs.first,
              let absRect = absoluteCanvasRect(of: selectedID, in: viewModel.currentPage) else {
            return nil
        }
        for (handle, canvasPt) in handlePositions(for: absRect) {
            let sPt = canvasToScreen(canvasPt)
            if hypot(sPt.x - screenPoint.x, sPt.y - screenPoint.y) <= 8.0 {
                return handle
            }
        }
        return nil
    }

    private func hitTestCurvePoint(at screenPoint: CGPoint) -> (index: Int, component: CurveComponent)? {
        guard let layer = viewModel.primarySelectedLayer,
              !layer.points.isEmpty,
              let absRect = absoluteCanvasRect(of: layer.do_objectID, in: viewModel.currentPage) else {
            return nil
        }
        for (idx, cp) in layer.points.enumerated() {
            let pNorm = cp.unitPoint
            let pCanvas = CGPoint(x: absRect.minX + pNorm.x * absRect.width, y: absRect.minY + pNorm.y * absRect.height)
            let pScreen = canvasToScreen(pCanvas)
            if hypot(pScreen.x - screenPoint.x, pScreen.y - screenPoint.y) <= 8.0 {
                return (idx, .point)
            }
            if cp.hasCurveFrom {
                let cfNorm = cp.unitCurveFrom
                let cfCanvas = CGPoint(x: absRect.minX + cfNorm.x * absRect.width, y: absRect.minY + cfNorm.y * absRect.height)
                let cfScreen = canvasToScreen(cfCanvas)
                if hypot(cfScreen.x - screenPoint.x, cfScreen.y - screenPoint.y) <= 7.0 {
                    return (idx, .curveFrom)
                }
            }
            if cp.hasCurveTo {
                let ctNorm = cp.unitCurveTo
                let ctCanvas = CGPoint(x: absRect.minX + ctNorm.x * absRect.width, y: absRect.minY + ctNorm.y * absRect.height)
                let ctScreen = canvasToScreen(ctCanvas)
                if hypot(ctScreen.x - screenPoint.x, ctScreen.y - screenPoint.y) <= 7.0 {
                    return (idx, .curveTo)
                }
            }
        }
        return nil
    }

    private func updateCurvePoint(index: Int, component: CurveComponent, canvasPoint: CGPoint) {
        guard let layer = viewModel.primarySelectedLayer,
              let absRect = absoluteCanvasRect(of: layer.do_objectID, in: viewModel.currentPage),
              absRect.width > 0, absRect.height > 0 else {
            return
        }
        let ux = min(1.5, max(-0.5, (canvasPoint.x - absRect.minX) / absRect.width))
        let uy = min(1.5, max(-0.5, (canvasPoint.y - absRect.minY) / absRect.height))
        let newUnit = CGPoint(x: ux, y: uy)

        viewModel.updateLayer(id: layer.do_objectID, recordUndo: false) { l in
            guard index < l.points.count else { return }
            switch component {
            case .point:
                let oldPt = l.points[index].unitPoint
                let dx = ux - oldPt.x
                let dy = uy - oldPt.y
                l.points[index].unitPoint = newUnit
                let cf = l.points[index].unitCurveFrom
                let ct = l.points[index].unitCurveTo
                l.points[index].unitCurveFrom = CGPoint(x: cf.x + dx, y: cf.y + dy)
                l.points[index].unitCurveTo = CGPoint(x: ct.x + dx, y: ct.y + dy)
            case .curveFrom:
                l.points[index].unitCurveFrom = newUnit
                l.points[index].hasCurveFrom = true
                if l.points[index].curveMode == SketchCurveMode.mirrored.rawValue {
                    let p = l.points[index].unitPoint
                    l.points[index].unitCurveTo = CGPoint(x: 2 * p.x - ux, y: 2 * p.y - uy)
                    l.points[index].hasCurveTo = true
                }
            case .curveTo:
                l.points[index].unitCurveTo = newUnit
                l.points[index].hasCurveTo = true
                if l.points[index].curveMode == SketchCurveMode.mirrored.rawValue {
                    let p = l.points[index].unitPoint
                    l.points[index].unitCurveFrom = CGPoint(x: 2 * p.x - ux, y: 2 * p.y - uy)
                    l.points[index].hasCurveFrom = true
                }
            }
        }
    }

    private func resizeSelectedLayer(handle: ResizeHandle, initialFrame: SketchRect, start: CGPoint, current: CGPoint) {
        guard let selectedID = viewModel.selectedLayerIDs.first else { return }
        let dx = Double(current.x - start.x)
        let dy = Double(current.y - start.y)
        var x = initialFrame.x
        var y = initialFrame.y
        var w = initialFrame.width
        var h = initialFrame.height

        switch handle {
        case .topLeft:
            x += dx; y += dy; w -= dx; h -= dy
        case .topCenter:
            y += dy; h -= dy
        case .topRight:
            y += dy; w += dx; h -= dy
        case .middleLeft:
            x += dx; w -= dx
        case .middleRight:
            w += dx
        case .bottomLeft:
            x += dx; w -= dx; h += dy
        case .bottomCenter:
            h += dy
        case .bottomRight:
            w += dx; h += dy
        }

        w = max(4, round(w))
        h = max(4, round(h))
        x = round(x)
        y = round(y)

        dragOverrideLayerID = selectedID
        dragOverrideFrame = SketchRect(
            x: x,
            y: y,
            width: w,
            height: h,
            constrainProportions: initialFrame.constrainProportions
        )
    }

    private func handlePositions(for rect: CGRect) -> [(ResizeHandle, CGPoint)] {
        [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topCenter, CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.middleLeft, CGPoint(x: rect.minX, y: rect.midY)),
            (.middleRight, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomCenter, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
    }

    private func absoluteCanvasRect(of id: String, in layer: SketchLayer, parentOrigin: CGPoint = .zero) -> CGRect? {
        for child in layer.layers {
            let origin = CGPoint(x: parentOrigin.x + child.frame.cgRect.minX, y: parentOrigin.y + child.frame.cgRect.minY)
            if child.do_objectID == id {
                return CGRect(origin: origin, size: child.frame.cgRect.size)
            }
            if let found = absoluteCanvasRect(of: id, in: child, parentOrigin: origin) {
                return found
            }
        }
        return nil
    }

    @ViewBuilder
    private func canvasHUD() -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack {
                if viewModel.currentTool == .editPoints, let layer = viewModel.primarySelectedLayer {
                    HStack(spacing: 8) {
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                            .foregroundColor(.orange)
                        Text("Vector Point Editor: \(layer.name) (\(layer.points.count) pts)")
                            .font(.system(size: 11, weight: .semibold))
                        Button("Finish Editing") {
                            viewModel.currentTool = .select
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial)
                    .cornerRadius(6)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        _ = viewModel.runPerformanceChecks()
                        viewModel.showPerfInspectorPopover = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "speedometer")
                                .foregroundColor(.green)
                            Text("Perf Checks")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Run 6 Automated Canvas & Archive Performance Checks")

                    Divider().frame(height: 12)

                    Button(action: { viewModel.zoomOut() }) {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    Text("\(Int(round(viewModel.zoomScale * 100)))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .frame(width: 44)
                    Button(action: { viewModel.zoomIn() }) {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    Divider().frame(height: 12)
                    Button("100%") {
                        viewModel.actualSize()
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial)
                .cornerRadius(6)
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)

            if viewModel.showPerfInspectorPopover, let report = viewModel.lastPerfReport {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: report.allPassed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(report.allPassed ? .green : .orange)
                        Text("OpenSketch Performance Suite (\(report.passedCount)/\(report.totalChecks) Passed)")
                            .font(.system(size: 12, weight: .bold))
                        Spacer()
                        Button("Re-run") {
                            _ = viewModel.runPerformanceChecks()
                        }
                        .controlSize(.mini)
                        Button {
                            viewModel.showPerfInspectorPopover = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    Divider()
                    ForEach(report.checks) { check in
                        HStack(spacing: 8) {
                            Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(check.passed ? .green : .red)
                                .font(.system(size: 11))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(check.title)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(check.detail)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.2f / %.0f ms", check.measuredMs, check.budgetMs))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(check.passed ? .primary : .red)
                        }
                    }
                }
                .padding(10)
                .frame(width: 440)
                .background(.regularMaterial)
                .cornerRadius(8)
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
                .padding(.trailing, 10)
            }

            Spacer()
        }
    }
}

// MARK: - AppKit NSView backed CoreGraphics Interactive Canvas

private struct CanvasRepresentable: NSViewRepresentable {
    @ObservedObject var viewModel: SketchDocumentViewModel
    var creationPreviewRect: CGRect?
    var selectedPointIndex: Int
    var dragOverrideLayerID: String?
    var dragOverrideFrame: SketchRect?
    var localSnapGuides: [SketchSnapGuide]

    func makeNSView(context: Context) -> InteractiveCanvasNSView {
        let view = InteractiveCanvasNSView()
        view.viewModel = viewModel
        view.syncTransformFromViewModel()
        return view
    }

    func updateNSView(_ nsView: InteractiveCanvasNSView, context: Context) {
        nsView.viewModel = viewModel
        nsView.creationPreviewRect = creationPreviewRect
        nsView.selectedPointIndex = selectedPointIndex
        nsView.dragOverrideLayerID = dragOverrideLayerID
        nsView.dragOverrideFrame = dragOverrideFrame
        nsView.localSnapGuides = localSnapGuides
        if !nsView.isActivelyScrollingOrZooming {
            nsView.syncTransformFromViewModel()
        }
        nsView.needsDisplay = true
    }
}

final class InteractiveCanvasNSView: NSView {
    weak var viewModel: SketchDocumentViewModel?
    var creationPreviewRect: CGRect?
    var selectedPointIndex: Int = 0
    var dragOverrideLayerID: String?
    var dragOverrideFrame: SketchRect?
    var localSnapGuides: [SketchSnapGuide] = []

    var livePanOffset: CGSize = CGSize(width: 40, height: 40)
    var liveZoomScale: Double = 1.0
    var isActivelyScrollingOrZooming: Bool = false
    private var gestureSyncWorkItem: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func syncTransformFromViewModel() {
        guard let vm = viewModel else { return }
        livePanOffset = vm.panOffset
        liveZoomScale = vm.zoomScale
    }

    private func scheduleViewModelSync(for event: NSEvent) {
        gestureSyncWorkItem?.cancel()
        let isEnded = (event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended || event.momentumPhase == .cancelled)
        if isEnded {
            commitLiveTransformToViewModel()
        } else {
            let item = DispatchWorkItem { [weak self] in
                self?.commitLiveTransformToViewModel()
            }
            gestureSyncWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: item)
        }
    }

    private func commitLiveTransformToViewModel() {
        isActivelyScrollingOrZooming = false
        guard let vm = viewModel else { return }
        if vm.panOffset != livePanOffset {
            vm.panOffset = livePanOffset
        }
        if abs(vm.zoomScale - liveZoomScale) > 0.0001 {
            vm.zoomScale = liveZoomScale
        }
    }

    override func scrollWheel(with event: NSEvent) {
        isActivelyScrollingOrZooming = true
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let delta = Double(event.scrollingDeltaY) * 0.01
            liveZoomScale = min(8.0, max(0.1, liveZoomScale + delta))
        } else {
            livePanOffset.width += event.scrollingDeltaX
            livePanOffset.height += event.scrollingDeltaY
        }
        needsDisplay = true
        scheduleViewModelSync(for: event)
    }

    override func magnify(with event: NSEvent) {
        isActivelyScrollingOrZooming = true
        liveZoomScale = min(8.0, max(0.1, liveZoomScale * (1.0 + Double(event.magnification))))
        needsDisplay = true
        scheduleViewModelSync(for: event)
    }

    private func applyDragOverride(to list: inout [SketchLayer], id: String, frame: SketchRect) -> Bool {
        for i in list.indices {
            if list[i].do_objectID == id {
                list[i].frame = frame
                return true
            }
            if !list[i].layers.isEmpty {
                if applyDragOverride(to: &list[i].layers, id: id, frame: frame) {
                    return true
                }
            }
        }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let vm = viewModel else {
            return
        }

        let frameStart = CFAbsoluteTimeGetCurrent()
        var page = vm.currentPage
        if let overrideID = dragOverrideLayerID, let overrideFrame = dragOverrideFrame {
            _ = applyDragOverride(to: &page.layers, id: overrideID, frame: overrideFrame)
        }

        let pan = isActivelyScrollingOrZooming ? livePanOffset : vm.panOffset
        let zoom = CGFloat(isActivelyScrollingOrZooming ? liveZoomScale : vm.zoomScale)

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: bounds)

        // 1. Canvas background (#F0F0F2)
        ctx.setFillColor(CGColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1.0))
        ctx.fill(bounds)

        // Optional pixel grid
        if vm.showPixelGrid {
            drawCanvasGrid(in: ctx, viewport: bounds.size, zoom: zoom, pan: pan)
        }

        // 2. Render page layers in canvas coordinate space with Viewport Frustum Culling
        ctx.saveGState()
        ctx.translateBy(x: pan.width, y: pan.height)
        ctx.scaleBy(x: zoom, y: zoom)

        let visibleCanvasRect = CGRect(
            x: -pan.width / zoom,
            y: -pan.height / zoom,
            width: bounds.width / zoom,
            height: bounds.height / zoom
        )
        var frameStats = SketchFrameRenderStats()

        SketchCoreGraphicsRenderer.renderLayer(
            page,
            in: vm.archive,
            context: ctx,
            includeArtboardChrome: true,
            visibleCanvasRect: visibleCanvasRect,
            stats: &frameStats
        )

        // 3. Draw selection bounding boxes + 8 resize handles
        for selectedID in vm.selectedLayerIDs {
            if let absRect = findAbsoluteRect(id: selectedID, in: page) {
                drawSelectionBox(absRect, zoom: zoom, in: ctx)
            }
        }

        // 4. Draw magenta snapping alignment guides (#F53163)
        let guides = localSnapGuides.isEmpty ? vm.activeSnapGuides : localSnapGuides
        if !guides.isEmpty {
            ctx.setStrokeColor(CGColor(srgbRed: 0.96, green: 0.19, blue: 0.39, alpha: 0.95))
            ctx.setLineWidth(1.0 / zoom)
            for guide in guides {
                if guide.isVertical {
                    ctx.move(to: CGPoint(x: guide.position, y: guide.start))
                    ctx.addLine(to: CGPoint(x: guide.position, y: guide.end))
                } else {
                    ctx.move(to: CGPoint(x: guide.start, y: guide.position))
                    ctx.addLine(to: CGPoint(x: guide.end, y: guide.position))
                }
                ctx.strokePath()
            }
        }

        // 5. Draw creation preview rectangle if dragging a new shape
        if let preview = creationPreviewRect {
            ctx.setStrokeColor(CGColor(srgbRed: 0.09, green: 0.56, blue: 0.98, alpha: 0.9))
            ctx.setFillColor(CGColor(srgbRed: 0.09, green: 0.56, blue: 0.98, alpha: 0.12))
            ctx.setLineWidth(1.5 / zoom)
            ctx.fill(preview)
            ctx.stroke(preview)
        }

        // 6. Draw Bezier curve handles if in vector point editing mode
        if vm.currentTool == .editPoints,
           let layer = vm.primarySelectedLayer,
           !layer.points.isEmpty,
           let absRect = findAbsoluteRect(id: layer.do_objectID, in: page) {
            drawBezierOverlay(points: layer.points, in: absRect, selectedIndex: selectedPointIndex, zoom: zoom, context: ctx)
        }

        ctx.restoreGState()

        // 7. Draw Rulers if enabled
        if vm.showRulers {
            drawRulers(in: ctx, viewport: bounds.size, zoom: zoom, pan: pan)
        }

        // 8. Record frame timing & draw lightweight CoreGraphics FPS/telemetry pill in bottom-right
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - frameStart) * 1000.0
        SketchPerformanceMonitor.shared.recordFrame(durationMs: elapsedMs, stats: frameStats)
        drawTelemetryPill(in: ctx, viewport: bounds.size, elapsedMs: elapsedMs, stats: frameStats)
    }

    private func drawTelemetryPill(in ctx: CGContext, viewport: CGSize, elapsedMs: Double, stats: SketchFrameRenderStats) {
        let snap = SketchPerformanceMonitor.shared.currentSnapshot()
        let text = String(
            format: "%.0f FPS  •  %.2f ms/f (P95 %.2f ms)  •  Drawn: %d / Culled: %d  •  Cache Hits: %d",
            snap.estimatedFPS,
            elapsedMs,
            snap.p95FrameMs,
            stats.drawnLayers,
            stats.culledLayers,
            snap.bitmapCacheHits + snap.symbolCacheHits
        )
        let pillWidth: CGFloat = 480
        let pillHeight: CGFloat = 22
        let pillRect = CGRect(
            x: max(24, viewport.width - pillWidth - 12),
            y: max(24, viewport.height - pillHeight - 10),
            width: pillWidth,
            height: pillHeight
        )
        ctx.saveGState()
        let path = CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.setFillColor(CGColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.82))
        ctx.addPath(path)
        ctx.fillPath()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        let dotColor = (elapsedMs <= 8.5)
            ? NSColor(srgbRed: 0.20, green: 0.84, blue: 0.45, alpha: 1.0)
            : NSColor(srgbRed: 0.98, green: 0.65, blue: 0.15, alpha: 1.0)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let dotAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: dotColor
        ]
        let combined = NSMutableAttributedString(string: "● ", attributes: dotAttrs)
        combined.append(NSAttributedString(string: text, attributes: attrs))
        combined.draw(at: CGPoint(x: pillRect.minX + 8, y: pillRect.minY + 4))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    private func drawSelectionBox(_ rect: CGRect, zoom: CGFloat, in ctx: CGContext) {
        let accent = CGColor(srgbRed: 0.08, green: 0.52, blue: 0.98, alpha: 1.0)
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1.2 / zoom)
        ctx.stroke(rect)

        let hSize = 6.0 / zoom
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
            CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        for pt in corners {
            let box = CGRect(x: pt.x - hSize * 0.5, y: pt.y - hSize * 0.5, width: hSize, height: hSize)
            ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
            ctx.fill(box)
            ctx.stroke(box)
        }
    }

    private func drawCanvasGrid(in ctx: CGContext, viewport: CGSize, zoom: CGFloat, pan: CGSize) {
        let step = max(10.0, 20.0 * zoom)
        ctx.setStrokeColor(CGColor(gray: 0.86, alpha: 0.6))
        ctx.setLineWidth(0.5)
        var x = pan.width.truncatingRemainder(dividingBy: step)
        while x < viewport.width {
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: viewport.height))
            x += step
        }
        var y = pan.height.truncatingRemainder(dividingBy: step)
        while y < viewport.height {
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: viewport.width, y: y))
            y += step
        }
        ctx.strokePath()
    }

    private func drawRulers(in ctx: CGContext, viewport: CGSize, zoom: CGFloat, pan: CGSize) {
        let rulerThickness: CGFloat = 18.0
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 0.95))
        ctx.fill(CGRect(x: 0, y: 0, width: viewport.width, height: rulerThickness))
        ctx.fill(CGRect(x: 0, y: 0, width: rulerThickness, height: viewport.height))

        ctx.setStrokeColor(CGColor(gray: 0.78, alpha: 1.0))
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 0, y: rulerThickness))
        ctx.addLine(to: CGPoint(x: viewport.width, y: rulerThickness))
        ctx.move(to: CGPoint(x: rulerThickness, y: 0))
        ctx.addLine(to: CGPoint(x: rulerThickness, y: viewport.height))
        ctx.strokePath()
    }

    private func findAbsoluteRect(id: String, in layer: SketchLayer, origin: CGPoint = .zero) -> CGRect? {
        for child in layer.layers {
            let childOrigin = CGPoint(x: origin.x + child.frame.cgRect.minX, y: origin.y + child.frame.cgRect.minY)
            if child.do_objectID == id {
                return CGRect(origin: childOrigin, size: child.frame.cgRect.size)
            }
            if let found = findAbsoluteRect(id: id, in: child, origin: childOrigin) {
                return found
            }
        }
        return nil
    }

    private func drawBezierOverlay(
        points: [SketchCurvePoint],
        in rect: CGRect,
        selectedIndex: Int,
        zoom: CGFloat,
        context: CGContext
    ) {
        let handleColor = CGColor(srgbRed: 0.96, green: 0.45, blue: 0.12, alpha: 1.0)
        let activeColor = CGColor(srgbRed: 0.09, green: 0.56, blue: 0.98, alpha: 1.0)
        let r = 4.5 / zoom

        for (idx, cp) in points.enumerated() {
            let pNorm = cp.unitPoint
            let p = CGPoint(x: rect.minX + pNorm.x * rect.width, y: rect.minY + pNorm.y * rect.height)

            if cp.hasCurveFrom {
                let cfNorm = cp.unitCurveFrom
                let cf = CGPoint(x: rect.minX + cfNorm.x * rect.width, y: rect.minY + cfNorm.y * rect.height)
                context.setStrokeColor(handleColor)
                context.setLineWidth(1.0 / zoom)
                context.move(to: p)
                context.addLine(to: cf)
                context.strokePath()
                let dot = CGRect(x: cf.x - r * 0.8, y: cf.y - r * 0.8, width: r * 1.6, height: r * 1.6)
                context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
                context.fillEllipse(in: dot)
                context.strokeEllipse(in: dot)
            }

            if cp.hasCurveTo {
                let ctNorm = cp.unitCurveTo
                let ct = CGPoint(x: rect.minX + ctNorm.x * rect.width, y: rect.minY + ctNorm.y * rect.height)
                context.setStrokeColor(handleColor)
                context.setLineWidth(1.0 / zoom)
                context.move(to: p)
                context.addLine(to: ct)
                context.strokePath()
                let dot = CGRect(x: ct.x - r * 0.8, y: ct.y - r * 0.8, width: r * 1.6, height: r * 1.6)
                context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
                context.fillEllipse(in: dot)
                context.strokeEllipse(in: dot)
            }

            let box = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            context.setFillColor(selectedIndex == idx ? activeColor : CGColor(gray: 1.0, alpha: 1.0))
            context.setStrokeColor(activeColor)
            context.setLineWidth(1.5 / zoom)
            context.fillEllipse(in: box)
            context.strokeEllipse(in: box)
        }
    }
}
