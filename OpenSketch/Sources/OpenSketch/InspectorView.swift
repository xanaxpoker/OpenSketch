import SwiftUI
import AppKit
import OpenSketchCore

public struct InspectorView: View {
    @ObservedObject public var viewModel: SketchDocumentViewModel
    @State private var selectedPointIndex: Int = 0

    public init(viewModel: SketchDocumentViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            alignmentBar
            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                if let layer = viewModel.primarySelectedLayer {
                    VStack(alignment: .leading, spacing: 12) {
                        layerHeaderSection(layer)
                        Divider()
                        geometrySection(layer)

                        if layer.kind == .artboard || layer.kind == .symbolMaster {
                            Divider()
                            artboardSection(layer)
                            Divider()
                            smartLayoutSection(layer)
                        } else if layer.kind == .group {
                            Divider()
                            smartLayoutSection(layer)
                        }

                        if layer.kind == .symbolInstance {
                            Divider()
                            symbolInstanceSection(layer)
                        }

                        if viewModel.currentTool == .editPoints && !layer.points.isEmpty {
                            Divider()
                            vectorPointSection(layer)
                        }

                        if layer.kind == .text {
                            Divider()
                            typographySection(layer)
                        }

                        if layer.kind != .artboard && layer.kind != .page {
                            Divider()
                            styleSection(layer)
                        }

                        Divider()
                        exportSection(layer)
                    }
                    .padding(12)
                } else {
                    canvasInspectorFallback
                }
            }
        }
        .frame(width: 270)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Top Alignment Bar

    private var alignmentBar: some View {
        HStack(spacing: 6) {
            ForEach(SketchAlignmentAction.allCases, id: \.rawValue) { action in
                Button {
                    viewModel.alignSelectedLayers(action)
                } label: {
                    Image(systemName: iconForAlignment(action))
                        .font(.system(size: 12))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .help(action.rawValue)
                .disabled(viewModel.selectedLayerIDs.count < 2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func iconForAlignment(_ action: SketchAlignmentAction) -> String {
        switch action {
        case .left: return "align.horizontal.left"
        case .center: return "align.horizontal.center"
        case .right: return "align.horizontal.right"
        case .top: return "align.vertical.top"
        case .middle: return "align.vertical.center"
        case .bottom: return "align.vertical.bottom"
        case .distributeHorizontally: return "distribute.horizontal"
        case .distributeVertically: return "distribute.vertical"
        }
    }

    // MARK: - Layer Header

    private func layerHeaderSection(_ layer: SketchLayer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: layer.kind.systemIconName)
                    .foregroundColor(.accentColor)
                Text(layer._class.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if layer.kind == .shapeGroup {
                    Button("Flatten") {
                        viewModel.flattenSelectedLayer()
                    }
                    .controlSize(.mini)
                }
                if !layer.points.isEmpty {
                    Button(viewModel.currentTool == .editPoints ? "Finish Points" : "Edit Points") {
                        viewModel.currentTool = (viewModel.currentTool == .editPoints) ? .select : .editPoints
                    }
                    .controlSize(.mini)
                }
            }
            TextField("Layer Name", text: Binding(
                get: { layer.name },
                set: { newName in
                    viewModel.updateLayer(id: layer.do_objectID) { $0.name = newName }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
    }

    // MARK: - Geometry Section (X, Y, W, H, Rotation, Radius, Tidy)

    private func geometrySection(_ layer: SketchLayer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                numericField(label: "X", value: layer.frame.x) { val in
                    viewModel.updateLayer(id: layer.do_objectID) { $0.frame.x = val }
                }
                numericField(label: "Y", value: layer.frame.y) { val in
                    viewModel.updateLayer(id: layer.do_objectID) { $0.frame.y = val }
                }
                Button("Tidy") {
                    viewModel.tidySelectedLayers()
                }
                .controlSize(.small)
                .disabled(viewModel.selectedLayerIDs.count < 2)
            }

            HStack(spacing: 8) {
                numericField(label: "W", value: layer.frame.width) { val in
                    let clamped = max(1, val)
                    viewModel.updateLayer(id: layer.do_objectID) { l in
                        if l.frame.constrainProportions, l.frame.width > 0 {
                            let ratio = l.frame.height / l.frame.width
                            l.frame.height = round(clamped * ratio)
                        }
                        l.frame.width = clamped
                    }
                }
                numericField(label: "H", value: layer.frame.height) { val in
                    let clamped = max(1, val)
                    viewModel.updateLayer(id: layer.do_objectID) { l in
                        if l.frame.constrainProportions, l.frame.height > 0 {
                            let ratio = l.frame.width / l.frame.height
                            l.frame.width = round(clamped * ratio)
                        }
                        l.frame.height = clamped
                    }
                }
                Button {
                    viewModel.updateLayer(id: layer.do_objectID) {
                        $0.frame.constrainProportions.toggle()
                    }
                } label: {
                    Image(systemName: layer.frame.constrainProportions ? "lock.fill" : "lock.open")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Constrain Proportions")
            }

            HStack(spacing: 8) {
                numericField(label: "↻", value: layer.rotation) { val in
                    viewModel.updateLayer(id: layer.do_objectID) { $0.rotation = val }
                }
                if supportsCornerRadius(layer) {
                    numericField(label: "Radius", value: currentCornerRadius(layer)) { val in
                        let r = max(0, val)
                        viewModel.updateLayer(id: layer.do_objectID) { l in
                            l.fixedRadius = r
                            for idx in l.points.indices {
                                l.points[idx].cornerRadius = r
                            }
                            if l.kind == .shapeGroup && !l.layers.isEmpty {
                                l.layers[0].fixedRadius = r
                                for idx in l.layers[0].points.indices {
                                    l.layers[0].points[idx].cornerRadius = r
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 4) {
                    Button {
                        viewModel.updateLayer(id: layer.do_objectID) {
                            $0.isFlippedHorizontal.toggle()
                        }
                    } label: {
                        Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                    .controlSize(.small)
                    .help("Flip Horizontally")

                    Button {
                        viewModel.updateLayer(id: layer.do_objectID) {
                            $0.isFlippedVertical.toggle()
                        }
                    } label: {
                        Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                    }
                    .controlSize(.small)
                    .help("Flip Vertically")
                }
            }

            if layer.kind != .artboard && layer.kind != .symbolMaster && layer.kind != .page {
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("RESIZING & MASK")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Toggle("Use as Mask", isOn: Binding(
                            get: { layer.hasClippingMask },
                            set: { v in
                                viewModel.updateLayer(id: layer.do_objectID) { $0.hasClippingMask = v }
                            }
                        ))
                        .controlSize(.mini)
                        .font(.system(size: 10))
                    }
                    HStack(spacing: 4) {
                        resizingPinButton(layer: layer, label: "←", bit: 32, help: "Pin to Left Edge")
                        resizingPinButton(layer: layer, label: "↑", bit: 4, help: "Pin to Top Edge")
                        resizingPinButton(layer: layer, label: "→", bit: 8, help: "Pin to Right Edge")
                        resizingPinButton(layer: layer, label: "↓", bit: 1, help: "Pin to Bottom Edge")
                        Spacer()
                        resizingPinButton(layer: layer, label: "Fix W", bit: 16, help: "Fix Width on Resize")
                        resizingPinButton(layer: layer, label: "Fix H", bit: 2, help: "Fix Height on Resize")
                    }
                }
            }
        }
    }

    private func resizingPinButton(layer: SketchLayer, label: String, bit: Int, help: String) -> some View {
        // In Sketch's `resizingConstraint` (default 63 = 0b111111), a cleared bit (0) means the constraint is active!
        let isPinned = (layer.resizingConstraint & bit) == 0
        return Button {
            viewModel.updateLayer(id: layer.do_objectID) {
                $0.resizingConstraint ^= bit
            }
        } label: {
            Text(label)
                .font(.system(size: 9, weight: isPinned ? .bold : .regular, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isPinned ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.1))
                .foregroundColor(isPinned ? .accentColor : .primary)
                .cornerRadius(4)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func supportsCornerRadius(_ layer: SketchLayer) -> Bool {
        if layer.kind == .rectangle || layer.kind == .shapePath { return true }
        if layer.kind == .shapeGroup, let first = layer.layers.first {
            return first.kind == .rectangle || first.kind == .shapePath
        }
        return false
    }

    private func currentCornerRadius(_ layer: SketchLayer) -> Double {
        if layer.fixedRadius > 0 { return layer.fixedRadius }
        if let ptR = layer.points.first?.cornerRadius, ptR > 0 { return ptR }
        if let first = layer.layers.first {
            return first.fixedRadius > 0 ? first.fixedRadius : (first.points.first?.cornerRadius ?? 0)
        }
        return 0
    }

    // MARK: - Artboard Section

    private func artboardSection(_ layer: SketchLayer) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ARTBOARD")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            Toggle("Background Color", isOn: Binding(
                get: { layer.hasBackgroundColor },
                set: { enabled in
                    viewModel.updateLayer(id: layer.do_objectID) {
                        $0.hasBackgroundColor = enabled
                        if $0.backgroundColor == nil {
                            $0.backgroundColor = .white
                        }
                    }
                }
            ))
            .controlSize(.small)

            if layer.hasBackgroundColor {
                HStack {
                    ColorPicker("", selection: Binding(
                        get: { Color(cgColor: SketchCoreGraphicsRenderer.cgColor(from: layer.backgroundColor ?? .white)) },
                        set: { newColor in
                            if let ns = NSColor(newColor).usingColorSpace(.sRGB) {
                                viewModel.updateLayer(id: layer.do_objectID) {
                                    $0.backgroundColor = SketchColor(
                                        red: Double(ns.redComponent),
                                        green: Double(ns.greenComponent),
                                        blue: Double(ns.blueComponent),
                                        alpha: Double(ns.alphaComponent)
                                    )
                                }
                            }
                        }
                    ))
                    .labelsHidden()
                    Text((layer.backgroundColor ?? .white).hexString)
                        .font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Toggle("Include in Export", isOn: Binding(
                        get: { layer.includeBackgroundColorInExport },
                        set: { inc in
                            viewModel.updateLayer(id: layer.do_objectID) {
                                $0.includeBackgroundColorInExport = inc
                            }
                        }
                    ))
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Smart Layout Section (MSImmutableInferredGroupLayout)

    private func smartLayoutSection(_ layer: SketchLayer) -> some View {
        let currentMode: Int = {
            guard let gl = layer.groupLayout, gl.isSmartLayout else { return -1 }
            let axis = gl.axis ?? 0
            let anchor = gl.layoutAnchor ?? 0
            return axis * 10 + anchor
        }()

        return VStack(alignment: .leading, spacing: 6) {
            Text("LAYOUT")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            Picker("Smart Layout", selection: Binding(
                get: { currentMode },
                set: { mode in
                    viewModel.updateLayer(id: layer.do_objectID) { l in
                        if mode == -1 {
                            l.groupLayout = SketchGroupLayout(isSmartLayout: false)
                        } else {
                            let axis = mode / 10
                            let anchor = mode % 10
                            l.groupLayout = SketchGroupLayout(isSmartLayout: true, axis: axis, layoutAnchor: anchor)
                        }
                    }
                }
            )) {
                Text("None (Freeform)").tag(-1)
                Divider()
                Text("Horizontally: Left to Right").tag(0)
                Text("Horizontally: Center").tag(1)
                Text("Horizontally: Right to Left").tag(2)
                Divider()
                Text("Vertically: Top to Bottom").tag(10)
                Text("Vertically: Middle").tag(11)
                Text("Vertically: Bottom to Top").tag(12)
            }
            .controlSize(.small)
        }
    }

    // MARK: - Symbol Instance & Live Overrides Section

    private func symbolInstanceSection(_ layer: SketchLayer) -> some View {
        let masters = viewModel.archive.allSymbolMasters
        let currentMaster = layer.symbolID.flatMap { viewModel.archive.symbolMaster(forSymbolID: $0) }
        let textTargets = currentMaster.map { collectOverrideableTextLayers(in: $0) } ?? []

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SYMBOL")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Detach") {
                    viewModel.detachSelectedSymbolInstance()
                }
                .controlSize(.mini)
            }

            if !masters.isEmpty {
                Picker("Master", selection: Binding(
                    get: { layer.symbolID ?? "" },
                    set: { newSymID in
                        viewModel.updateLayer(id: layer.do_objectID) {
                            $0.symbolID = newSymID
                        }
                    }
                )) {
                    ForEach(masters, id: \.do_objectID) { master in
                        Text(master.name).tag(master.symbolID ?? "")
                    }
                }
                .controlSize(.small)
            }

            if !textTargets.isEmpty {
                Text("OVERRIDES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                ForEach(textTargets, id: \.do_objectID) { target in
                    let overrideKey = "\(target.do_objectID)_stringValue"
                    let existingOverride = layer.overrideValues.first(where: { $0.overrideName == overrideKey })?.value
                    let defaultText = target.attributedString?.string ?? target.name

                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        TextField(defaultText, text: Binding(
                            get: { existingOverride ?? defaultText },
                            set: { newText in
                                viewModel.updateSymbolOverride(
                                    layerID: layer.do_objectID,
                                    overrideName: overrideKey,
                                    value: newText
                                )
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func collectOverrideableTextLayers(in layer: SketchLayer) -> [SketchLayer] {
        var out: [SketchLayer] = []
        for child in layer.layers {
            if child.kind == .text {
                out.append(child)
            }
            out.append(contentsOf: collectOverrideableTextLayers(in: child))
        }
        return out
    }

    // MARK: - Vector Point Inspector (MSCurvePoint)

    private func vectorPointSection(_ layer: SketchLayer) -> some View {
        let pts = layer.points
        let idx = min(max(0, selectedPointIndex), max(0, pts.count - 1))
        let currentPt = pts.isEmpty ? nil : pts[idx]

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("VECTOR POINT (\(idx + 1)/\(pts.count))")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Stepper("", value: $selectedPointIndex, in: 0...max(0, pts.count - 1))
                    .labelsHidden()
                    .controlSize(.mini)
            }

            if let cp = currentPt {
                Picker("Point Type", selection: Binding(
                    get: { cp.curveMode },
                    set: { newMode in
                        viewModel.updateLayer(id: layer.do_objectID) { l in
                            guard idx < l.points.count else { return }
                            l.points[idx].curveMode = newMode
                            if newMode == SketchCurveMode.straight.rawValue {
                                l.points[idx].hasCurveFrom = false
                                l.points[idx].hasCurveTo = false
                            } else {
                                let base = l.points[idx].unitPoint
                                l.points[idx].hasCurveFrom = true
                                l.points[idx].hasCurveTo = true
                                l.points[idx].unitCurveFrom = CGPoint(x: base.x + 0.15, y: base.y)
                                l.points[idx].unitCurveTo = CGPoint(x: base.x - 0.15, y: base.y)
                            }
                        }
                    }
                )) {
                    Text("Straight").tag(1)
                    Text("Mirrored").tag(2)
                    Text("Asymmetric").tag(3)
                    Text("Disconnected").tag(4)
                }
                .controlSize(.small)

                numericField(label: "Corner Radius", value: cp.cornerRadius) { newR in
                    viewModel.updateLayer(id: layer.do_objectID) { l in
                        guard idx < l.points.count else { return }
                        l.points[idx].cornerRadius = max(0, newR)
                    }
                }
            }
        }
    }

    // MARK: - Typography Section

    private func typographySection(_ layer: SketchLayer) -> some View {
        let textStr = layer.attributedString?.string ?? layer.name
        let firstAttr = layer.attributedString?.attributes.first
        let fontName = firstAttr?.fontName ?? "HelveticaNeue"
        let fontSize = firstAttr?.fontSize ?? 16.0
        let fontColor = firstAttr?.color ?? .black

        return VStack(alignment: .leading, spacing: 8) {
            Text("TEXT")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)

            TextField("Text Content", text: Binding(
                get: { textStr },
                set: { newVal in
                    viewModel.updateLayer(id: layer.do_objectID) { l in
                        l.name = newVal
                        if l.attributedString != nil {
                            l.attributedString?.string = newVal
                            if !(l.attributedString?.attributes.isEmpty ?? true) {
                                l.attributedString?.attributes[0].length = (newVal as NSString).length
                            }
                        } else {
                            l.attributedString = SketchAttributedString(
                                string: newVal,
                                attributes: [SketchStringAttribute(location: 0, length: (newVal as NSString).length, fontName: fontName, fontSize: fontSize, color: fontColor)]
                            )
                        }
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)

            HStack(spacing: 6) {
                Picker("", selection: Binding(
                    get: { fontName },
                    set: { newFont in
                        updateTextStyle(layerID: layer.do_objectID, fontName: newFont, fontSize: fontSize, color: fontColor)
                    }
                )) {
                    Text("Helvetica Neue").tag("HelveticaNeue")
                    Text("Helvetica Neue Bold").tag("HelveticaNeue-Bold")
                    Text("Helvetica Neue Medium").tag("HelveticaNeue-Medium")
                    Text("SF Pro Display").tag("SFProDisplay-Regular")
                    Text("Menlo").tag("Menlo-Regular")
                    Text("Georgia").tag("Georgia")
                }
                .labelsHidden()
                .controlSize(.small)

                numericField(label: "Size", value: fontSize) { newSize in
                    updateTextStyle(layerID: layer.do_objectID, fontName: fontName, fontSize: max(6, newSize), color: fontColor)
                }
                .frame(width: 72)
            }

            HStack {
                ColorPicker("Text Color", selection: Binding(
                    get: { Color(cgColor: SketchCoreGraphicsRenderer.cgColor(from: fontColor)) },
                    set: { c in
                        if let ns = NSColor(c).usingColorSpace(.sRGB) {
                            let sc = SketchColor(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent), alpha: Double(ns.alphaComponent))
                            updateTextStyle(layerID: layer.do_objectID, fontName: fontName, fontSize: fontSize, color: sc)
                        }
                    }
                ))
                .controlSize(.small)
                Spacer()
                Text(fontColor.hexString)
                    .font(.system(size: 11, design: .monospaced))
            }
        }
    }

    private func updateTextStyle(layerID: String, fontName: String, fontSize: Double, color: SketchColor) {
        viewModel.updateLayer(id: layerID) { layer in
            let str = layer.attributedString?.string ?? layer.name
            layer.attributedString = SketchAttributedString(
                string: str,
                attributes: [
                    SketchStringAttribute(location: 0, length: (str as NSString).length, fontName: fontName, fontSize: fontSize, color: color)
                ]
            )
            layer.style.textStyle = SketchTextStyle(fontName: fontName, fontSize: fontSize, textColor: color)
        }
    }

    // MARK: - Style Section (Opacity, Fills, Borders, Shadows, Blur)

    private func styleSection(_ layer: SketchLayer) -> some View {
        let style = layer.style

        return VStack(alignment: .leading, spacing: 10) {
            // Opacity
            HStack {
                Text("OPACITY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Slider(value: Binding(
                    get: { style.contextSettings?.opacity ?? 1.0 },
                    set: { newOpacity in
                        viewModel.updateLayer(id: layer.do_objectID, recordUndo: false) { l in
                            if l.style.contextSettings == nil { l.style.contextSettings = SketchGraphicsContextSettings() }
                            l.style.contextSettings?.opacity = newOpacity
                        }
                    }
                ), in: 0...1)
                .frame(width: 110)
                Text("\(Int(round((style.contextSettings?.opacity ?? 1.0) * 100)))%")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 38, alignment: .trailing)
            }

            Divider()

            // FILLS
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("FILLS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        viewModel.updateLayer(id: layer.do_objectID) { l in
                            l.style.fills.append(SketchFill(isEnabled: true, fillType: 0, color: .sketchBlue))
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                }

                ForEach(Array(style.fills.enumerated()), id: \.offset) { idx, fill in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { fill.isEnabled },
                            set: { en in
                                viewModel.updateLayer(id: layer.do_objectID) {
                                    $0.style.fills[idx].isEnabled = en
                                }
                            }
                        ))
                        .labelsHidden()
                        .controlSize(.small)

                        ColorPicker("", selection: Binding(
                            get: { Color(cgColor: SketchCoreGraphicsRenderer.cgColor(from: fill.color)) },
                            set: { newC in
                                if let ns = NSColor(newC).usingColorSpace(.sRGB) {
                                    viewModel.updateLayer(id: layer.do_objectID) {
                                        $0.style.fills[idx].color = SketchColor(
                                            red: Double(ns.redComponent),
                                            green: Double(ns.greenComponent),
                                            blue: Double(ns.blueComponent),
                                            alpha: Double(ns.alphaComponent)
                                        )
                                    }
                                }
                            }
                        ))
                        .labelsHidden()

                        Picker("", selection: Binding(
                            get: { fill.fillType },
                            set: { ft in
                                viewModel.updateLayer(id: layer.do_objectID) { l in
                                    l.style.fills[idx].fillType = ft
                                    if ft == 1 && l.style.fills[idx].gradient == nil {
                                        l.style.fills[idx].gradient = SketchGradient(
                                            gradientType: 0,
                                            from: CGPoint(x: 0.5, y: 0),
                                            to: CGPoint(x: 0.5, y: 1),
                                            stops: [
                                                SketchGradientStop(color: fill.color, position: 0.0),
                                                SketchGradientStop(color: SketchColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1.0), position: 1.0)
                                            ]
                                        )
                                    }
                                }
                            }
                        )) {
                            Text("Solid").tag(0)
                            Text("Gradient").tag(1)
                        }
                        .labelsHidden()
                        .controlSize(.mini)
                        .frame(width: 78)

                        Text(fill.color.hexString)
                            .font(.system(size: 10, design: .monospaced))

                        Spacer()

                        Button {
                            viewModel.updateLayer(id: layer.do_objectID) {
                                $0.style.fills.remove(at: idx)
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()

            // BORDERS
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("BORDERS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        viewModel.updateLayer(id: layer.do_objectID) { l in
                            l.style.borders.append(SketchBorder(isEnabled: true, fillType: 0, color: .defaultBorder, position: 1, thickness: 1.0))
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                }

                ForEach(Array(style.borders.enumerated()), id: \.offset) { idx, border in
                    HStack(spacing: 6) {
                        Toggle("", isOn: Binding(
                            get: { border.isEnabled },
                            set: { en in
                                viewModel.updateLayer(id: layer.do_objectID) {
                                    $0.style.borders[idx].isEnabled = en
                                }
                            }
                        ))
                        .labelsHidden()
                        .controlSize(.small)

                        ColorPicker("", selection: Binding(
                            get: { Color(cgColor: SketchCoreGraphicsRenderer.cgColor(from: border.color)) },
                            set: { newC in
                                if let ns = NSColor(newC).usingColorSpace(.sRGB) {
                                    viewModel.updateLayer(id: layer.do_objectID) {
                                        $0.style.borders[idx].color = SketchColor(
                                            red: Double(ns.redComponent),
                                            green: Double(ns.greenComponent),
                                            blue: Double(ns.blueComponent),
                                            alpha: Double(ns.alphaComponent)
                                        )
                                    }
                                }
                            }
                        ))
                        .labelsHidden()

                        Picker("", selection: Binding(
                            get: { border.position },
                            set: { pos in
                                viewModel.updateLayer(id: layer.do_objectID) {
                                    $0.style.borders[idx].position = pos
                                }
                            }
                        )) {
                            Text("Center").tag(0)
                            Text("Inside").tag(1)
                            Text("Outside").tag(2)
                        }
                        .labelsHidden()
                        .controlSize(.mini)
                        .frame(width: 68)

                        numericField(label: "W", value: border.thickness) { w in
                            viewModel.updateLayer(id: layer.do_objectID) {
                                $0.style.borders[idx].thickness = max(0.5, w)
                            }
                        }
                        .frame(width: 58)

                        Button {
                            viewModel.updateLayer(id: layer.do_objectID) {
                                $0.style.borders.remove(at: idx)
                            }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()

            // SHADOWS
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("SHADOWS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        viewModel.updateLayer(id: layer.do_objectID) { l in
                            l.style.shadows.append(SketchShadow(isEnabled: true, offsetX: 0, offsetY: 2, blurRadius: 8, spread: 0))
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                }

                ForEach(Array(style.shadows.enumerated()), id: \.offset) { idx, shadow in
                    HStack(spacing: 4) {
                        Toggle("", isOn: Binding(
                            get: { shadow.isEnabled },
                            set: { en in
                                viewModel.updateLayer(id: layer.do_objectID) {
                                    $0.style.shadows[idx].isEnabled = en
                                }
                            }
                        ))
                        .labelsHidden()
                        .controlSize(.small)

                        ColorPicker("", selection: Binding(
                            get: { Color(cgColor: SketchCoreGraphicsRenderer.cgColor(from: shadow.color)) },
                            set: { newC in
                                if let ns = NSColor(newC).usingColorSpace(.sRGB) {
                                    viewModel.updateLayer(id: layer.do_objectID) {
                                        $0.style.shadows[idx].color = SketchColor(
                                            red: Double(ns.redComponent),
                                            green: Double(ns.greenComponent),
                                            blue: Double(ns.blueComponent),
                                            alpha: Double(ns.alphaComponent)
                                        )
                                    }
                                }
                            }
                        ))
                        .labelsHidden()

                        numericField(label: "X", value: shadow.offsetX) { val in
                            viewModel.updateLayer(id: layer.do_objectID) { $0.style.shadows[idx].offsetX = val }
                        }
                        numericField(label: "Y", value: shadow.offsetY) { val in
                            viewModel.updateLayer(id: layer.do_objectID) { $0.style.shadows[idx].offsetY = val }
                        }
                        numericField(label: "B", value: shadow.blurRadius) { val in
                            viewModel.updateLayer(id: layer.do_objectID) { $0.style.shadows[idx].blurRadius = max(0, val) }
                        }
                        Button {
                            viewModel.updateLayer(id: layer.do_objectID) {
                                $0.style.shadows.remove(at: idx)
                            }
                        } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Divider()

            // BLUR
            HStack {
                Toggle("Blur", isOn: Binding(
                    get: { style.blur?.isEnabled ?? false },
                    set: { en in
                        viewModel.updateLayer(id: layer.do_objectID) { l in
                            if l.style.blur == nil { l.style.blur = SketchBlur(isEnabled: en, radius: 10) }
                            l.style.blur?.isEnabled = en
                        }
                    }
                ))
                .controlSize(.small)
                Spacer()
                if style.blur?.isEnabled ?? false {
                    numericField(label: "Amount", value: style.blur?.radius ?? 10) { r in
                        viewModel.updateLayer(id: layer.do_objectID) {
                            $0.style.blur?.radius = max(0, r)
                        }
                    }
                    .frame(width: 90)
                }
            }
        }
    }

    // MARK: - Export Section (MAKE EXPORTABLE + Copy CSS / SVG)

    private func exportSection(_ layer: SketchLayer) -> some View {
        let formats = layer.exportOptions.exportFormats

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("MAKE EXPORTABLE")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    viewModel.updateLayer(id: layer.do_objectID) { l in
                        let nextScale = Double(l.exportOptions.exportFormats.count + 1)
                        l.exportOptions.exportFormats.append(SketchExportFormat(
                            scale: nextScale,
                            fileFormat: "png",
                            name: nextScale > 1 ? "@\(Int(nextScale))x" : ""
                        ))
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
            }

            ForEach(Array(formats.enumerated()), id: \.offset) { idx, fmt in
                HStack(spacing: 6) {
                    Picker("", selection: Binding(
                        get: { fmt.scale },
                        set: { s in
                            viewModel.updateLayer(id: layer.do_objectID) {
                                $0.exportOptions.exportFormats[idx].scale = s
                            }
                        }
                    )) {
                        Text("1x").tag(1.0)
                        Text("2x").tag(2.0)
                        Text("3x").tag(3.0)
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 52)

                    TextField("Suffix", text: Binding(
                        get: { fmt.name ?? "" },
                        set: { n in
                            viewModel.updateLayer(id: layer.do_objectID) {
                                $0.exportOptions.exportFormats[idx].name = n
                            }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.mini)

                    Picker("", selection: Binding(
                        get: { fmt.fileFormat },
                        set: { ff in
                            viewModel.updateLayer(id: layer.do_objectID) {
                                $0.exportOptions.exportFormats[idx].fileFormat = ff
                            }
                        }
                    )) {
                        Text("PNG").tag("png")
                        Text("SVG").tag("svg")
                        Text("PDF").tag("pdf")
                    }
                    .labelsHidden()
                    .controlSize(.mini)
                    .frame(width: 64)

                    Button {
                        viewModel.updateLayer(id: layer.do_objectID) {
                            $0.exportOptions.exportFormats.remove(at: idx)
                        }
                    } label: {
                        Image(systemName: "trash").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 6) {
                Button("Copy CSS") {
                    viewModel.copyCSSToPasteboard()
                }
                .controlSize(.small)
                Button("Copy SVG") {
                    viewModel.copySVGToPasteboard()
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - Fallback when no layer is selected

    private var canvasInspectorFallback: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DOCUMENT")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            Text("Format: Sketch v\(viewModel.archive.meta["version"]?.intValue ?? 139) (\(viewModel.archive.meta["appVersion"]?.stringValue ?? "82.1"))")
                .font(.system(size: 11))
            Text("Pages: \(viewModel.archive.pages.count)")
                .font(.system(size: 11))
            Text("Symbols: \(viewModel.archive.allSymbolMasters.count)")
                .font(.system(size: 11))
            Divider()
            Toggle("Show Rulers", isOn: $viewModel.showRulers)
                .controlSize(.small)
            Toggle("Show Pixel Grid", isOn: $viewModel.showPixelGrid)
                .controlSize(.small)
        }
        .padding(12)
    }

    // MARK: - Helpers

    private func numericField(label: String, value: Double, onCommit: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            TextField("", value: Binding(
                get: { round(value * 100) / 100 },
                set: { onCommit($0) }
            ), format: .number)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
        }
    }
}
