import Foundation
import CoreGraphics

// MARK: - Bezier Path Builder (Reconstructed from MSBezierBuilder in SketchModel)

public enum SketchBezierBuilder {
    /// Cubic bezier kappa constant (`1 - 0.5522847498 = 0.4477152502` observed at `0x76328` in `SM_MSBezierBuilder_appendCurveFromPoint_toPoint_toCGPath.c`)
    public static let filletKappaComplement: CGFloat = 0.4477152502

    /// Reconstructs `MSBezierBuilder::pathWithPoints:inRect:shouldClose:pointRadiusBehaviour:` (`0x782f0`)
    /// and `MSBezierBuilder::buildV1CGPath:` (`0x76928`)
    public static func buildCGPath(
        points: [SketchCurvePoint],
        in rect: CGRect,
        isClosed: Bool,
        fixedRadius: Double = 0
    ) -> CGPath {
        let path = CGMutablePath()
        guard !points.isEmpty else { return path }

        if points.count == 1 {
            let p0 = SketchPointString.convertFromUnit(points[0].unitPoint, in: rect)
            path.move(to: p0)
            return path
        }

        // Check if all points are straight and have corner radii (e.g. rectangle/polygon with rounded corners)
        let allStraight = points.allSatisfy { !$0.hasCurveFrom && !$0.hasCurveTo }
        let hasCornerRadius = fixedRadius > 0 || points.contains(where: { $0.cornerRadius > 0 })

        if allStraight && hasCornerRadius && isClosed && points.count >= 3 {
            buildRoundedStraightPolygon(points: points, in: rect, fixedRadius: fixedRadius, into: path)
            return path
        }

        let startPt = SketchPointString.convertFromUnit(points[0].unitPoint, in: rect)
        path.move(to: startPt)

        for i in 1..<points.count {
            appendSegment(from: points[i - 1], to: points[i], in: rect, into: path)
        }

        if isClosed {
            appendSegment(from: points[points.count - 1], to: points[0], in: rect, into: path)
            path.closeSubpath()
        }

        return path
    }

    /// Reconstructs `MSBezierBuilder::appendCurveFromPoint:toPoint:toCGPath:` (`0x76328`)
    private static func appendSegment(
        from p0: SketchCurvePoint,
        to p1: SketchCurvePoint,
        in rect: CGRect,
        into path: CGMutablePath
    ) {
        let start = SketchPointString.convertFromUnit(p0.unitPoint, in: rect)
        let end = SketchPointString.convertFromUnit(p1.unitPoint, in: rect)

        if !p0.hasCurveFrom && !p1.hasCurveTo {
            path.addLine(to: end)
        } else {
            let cp1 = p0.hasCurveFrom ? SketchPointString.convertFromUnit(p0.unitCurveFrom, in: rect) : start
            let cp2 = p1.hasCurveTo ? SketchPointString.convertFromUnit(p1.unitCurveTo, in: rect) : end
            path.addCurve(to: end, control1: cp1, control2: cp2)
        }
    }

    private static func buildRoundedStraightPolygon(
        points: [SketchCurvePoint],
        in rect: CGRect,
        fixedRadius: Double,
        into path: CGMutablePath
    ) {
        let count = points.count
        let coords = points.map { SketchPointString.convertFromUnit($0.unitPoint, in: rect) }
        let maxAllowed = min(rect.width * 0.5, rect.height * 0.5)

        for i in 0..<count {
            let prev = coords[(i - 1 + count) % count]
            let curr = coords[i]
            let next = coords[(i + 1) % count]

            let rawRadius = points[i].cornerRadius > 0 ? CGFloat(points[i].cornerRadius) : CGFloat(fixedRadius)
            let vPrev = CGPoint(x: prev.x - curr.x, y: prev.y - curr.y)
            let vNext = CGPoint(x: next.x - curr.x, y: next.y - curr.y)
            let lenPrev = hypot(vPrev.x, vPrev.y)
            let lenNext = hypot(vNext.x, vNext.y)
            let maxSegRadius = min(lenPrev * 0.5, lenNext * 0.5, maxAllowed)
            let r = min(max(0, rawRadius), maxSegRadius)

            if r <= 0.01 || lenPrev < 0.01 || lenNext < 0.01 {
                if i == 0 {
                    path.move(to: curr)
                } else {
                    path.addLine(to: curr)
                }
                continue
            }

            let tStart = CGPoint(
                x: curr.x + (vPrev.x / lenPrev) * r,
                y: curr.y + (vPrev.y / lenPrev) * r
            )
            let tEnd = CGPoint(
                x: curr.x + (vNext.x / lenNext) * r,
                y: curr.y + (vNext.y / lenNext) * r
            )
            let cp1 = CGPoint(
                x: curr.x + (vPrev.x / lenPrev) * (r * filletKappaComplement),
                y: curr.y + (vPrev.y / lenPrev) * (r * filletKappaComplement)
            )
            let cp2 = CGPoint(
                x: curr.x + (vNext.x / lenNext) * (r * filletKappaComplement),
                y: curr.y + (vNext.y / lenNext) * (r * filletKappaComplement)
            )

            if i == 0 {
                path.move(to: tStart)
            } else {
                path.addLine(to: tStart)
            }
            path.addCurve(to: tEnd, control1: cp1, control2: cp2)
        }
        path.closeSubpath()
    }

    /// Generates an SVG `d` path attribute from a `CGPath`
    public static func svgPathData(from cgPath: CGPath) -> String {
        var parts: [String] = []
        func fmt(_ v: CGFloat) -> String {
            if abs(v - round(v)) < 1e-4 { return String(Int(round(v))) }
            return String(format: "%.2f", Double(v))
        }
        cgPath.applyWithBlock { elemPtr in
            let elem = elemPtr.pointee
            switch elem.type {
            case .moveToPoint:
                let p = elem.points[0]
                parts.append("M\(fmt(p.x)),\(fmt(p.y))")
            case .addLineToPoint:
                let p = elem.points[0]
                parts.append("L\(fmt(p.x)),\(fmt(p.y))")
            case .addQuadCurveToPoint:
                let c = elem.points[0]
                let p = elem.points[1]
                parts.append("Q\(fmt(c.x)),\(fmt(c.y)) \(fmt(p.x)),\(fmt(p.y))")
            case .addCurveToPoint:
                let c1 = elem.points[0]
                let c2 = elem.points[1]
                let p = elem.points[2]
                parts.append("C\(fmt(c1.x)),\(fmt(c1.y)) \(fmt(c2.x)),\(fmt(c2.y)) \(fmt(p.x)),\(fmt(p.y))")
            case .closeSubpath:
                parts.append("Z")
            @unknown default:
                break
            }
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Boolean Operations Engine (Reconstructed from MSPath::booleanOp:withPath: & Clipper.framework)

public enum SketchBooleanEngine {
    /// Reconstructs `MSPath::booleanOp:withPath:` (`0x138c5c` in `SketchModel`)
    /// - `op == .union` (0): Union of paths
    /// - `op == .subtract` (1): Subtract path2 from path1
    /// - `op == .intersect` (2): Intersection of path1 and path2
    /// - `op == .difference` (3): Symmetric difference (XOR) of path1 and path2
    public static func performBooleanOp(
        _ op: SketchBooleanOperation,
        path1: CGPath,
        path2: CGPath
    ) -> CGPath {
        let bounds1 = path1.boundingBoxOfPath
        let bounds2 = path2.boundingBoxOfPath
        let intersects = bounds1.intersects(bounds2)

        // Exact disjoint-bounds fast paths from `SM_MSPath_booleanOp_withPath.c` lines 38-79
        if !intersects {
            switch op {
            case .subtract:
                return path1
            case .intersect:
                return CGMutablePath()
            case .difference, .union, .none:
                let combined = CGMutablePath()
                combined.addPath(path1)
                combined.addPath(path2)
                return combined
            }
        }

        let poly1 = flattenToPolygon(path1)
        let poly2 = flattenToPolygon(path2)
        guard poly1.count >= 3, poly2.count >= 3 else {
            let combined = CGMutablePath()
            combined.addPath(path1)
            combined.addPath(path2)
            return combined
        }

        switch op {
        case .intersect:
            let clipped = sutherlandHodgmanClip(subject: poly1, clip: poly2)
            return polygonToCGPath(clipped)
        case .union:
            let loops = booleanPolygonContours(poly1: poly1, poly2: poly2, op: .union)
            return contoursToCGPath(loops)
        case .subtract:
            let loops = booleanPolygonContours(poly1: poly1, poly2: poly2, op: .subtract)
            return contoursToCGPath(loops)
        case .difference:
            let combined = CGMutablePath()
            combined.addPath(path1)
            combined.addPath(path2)
            return combined
        case .none:
            let combined = CGMutablePath()
            combined.addPath(path1)
            combined.addPath(path2)
            return combined
        }
    }

    /// Combines two layers into a `shapeGroup` or flattens a `shapeGroup` into a single `shapePath`
    public static func combineLayers(
        _ layer1: SketchLayer,
        _ layer2: SketchLayer,
        operation: SketchBooleanOperation
    ) -> SketchLayer {
        let rect1 = layer1.frame.cgRect
        let rect2 = layer2.frame.cgRect
        let unionRect = rect1.union(rect2)

        var sub1 = layer1
        sub1.frame.cgRect = CGRect(
            x: rect1.origin.x - unionRect.origin.x,
            y: rect1.origin.y - unionRect.origin.y,
            width: rect1.width,
            height: rect1.height
        )
        sub1.booleanOperation = .none

        var sub2 = layer2
        sub2.frame.cgRect = CGRect(
            x: rect2.origin.x - unionRect.origin.x,
            y: rect2.origin.y - unionRect.origin.y,
            width: rect2.width,
            height: rect2.height
        )
        sub2.booleanOperation = operation

        return SketchLayer(
            kind: .shapeGroup,
            name: "\(operation.title) (\(layer1.name) + \(layer2.name))",
            frame: SketchRect(
                x: Double(unionRect.origin.x),
                y: Double(unionRect.origin.y),
                width: Double(unionRect.width),
                height: Double(unionRect.height)
            ),
            style: layer1.style,
            layers: [sub1, sub2],
            booleanOperation: operation
        )
    }

    /// Evaluates the effective `CGPath` of a `shapeGroup` in its local coordinates
    public static func evaluateShapeGroupPath(_ group: SketchLayer) -> CGPath {
        guard !group.layers.isEmpty else {
            return SketchBezierBuilder.buildCGPath(
                points: group.points,
                in: CGRect(origin: .zero, size: group.frame.cgRect.size),
                isClosed: group.isClosed,
                fixedRadius: group.fixedRadius
            )
        }
        var currentPath: CGPath? = nil
        for child in group.layers where child.isVisible {
            let childRect = child.frame.cgRect
            let childPath = SketchBezierBuilder.buildCGPath(
                points: child.points,
                in: childRect,
                isClosed: child.isClosed,
                fixedRadius: child.fixedRadius
            )
            if let existing = currentPath {
                let op = child.booleanOperation == .none ? .union : child.booleanOperation
                currentPath = performBooleanOp(op, path1: existing, path2: childPath)
            } else {
                currentPath = childPath
            }
        }
        return currentPath ?? CGMutablePath()
    }

    /// Flattens a `shapeGroup` into a single `shapePath` layer with unit-normalized `curvePoint`s
    public static func flattenShapeGroup(_ group: SketchLayer) -> SketchLayer {
        let evaluatedPath = evaluateShapeGroupPath(group)
        let poly = flattenToPolygon(evaluatedPath)
        let bounds = evaluatedPath.boundingBoxOfPath
        let targetRect = bounds.isEmpty ? group.frame.cgRect : CGRect(
            x: group.frame.x + Double(bounds.origin.x),
            y: group.frame.y + Double(bounds.origin.y),
            width: Double(max(bounds.width, 1)),
            height: Double(max(bounds.height, 1))
        )
        let localBounds = bounds.isEmpty ? CGRect(origin: .zero, size: group.frame.cgRect.size) : bounds
        let curvePoints = poly.map { pt -> SketchCurvePoint in
            let unit = SketchPointString.convertToUnit(pt, in: localBounds)
            return SketchCurvePoint(point: unit, curveMode: .straight)
        }
        return SketchLayer(
            kind: .shapePath,
            name: "\(group.name) (Flattened)",
            frame: SketchRect(
                x: Double(targetRect.origin.x),
                y: Double(targetRect.origin.y),
                width: Double(targetRect.width),
                height: Double(targetRect.height)
            ),
            style: group.style,
            points: curvePoints,
            isClosed: true
        )
    }

    // MARK: - Polygon Helpers

    public static func flattenToPolygon(_ path: CGPath, stepsPerCurve: Int = 12) -> [CGPoint] {
        var pts: [CGPoint] = []
        var current: CGPoint = .zero
        path.applyWithBlock { elemPtr in
            let elem = elemPtr.pointee
            switch elem.type {
            case .moveToPoint:
                current = elem.points[0]
                pts.append(current)
            case .addLineToPoint:
                current = elem.points[0]
                pts.append(current)
            case .addQuadCurveToPoint:
                let c = elem.points[0]
                let end = elem.points[1]
                for i in 1...stepsPerCurve {
                    let t = CGFloat(i) / CGFloat(stepsPerCurve)
                    let mt = 1 - t
                    let x = mt * mt * current.x + 2 * mt * t * c.x + t * t * end.x
                    let y = mt * mt * current.y + 2 * mt * t * c.y + t * t * end.y
                    pts.append(CGPoint(x: x, y: y))
                }
                current = end
            case .addCurveToPoint:
                let c1 = elem.points[0]
                let c2 = elem.points[1]
                let end = elem.points[2]
                for i in 1...stepsPerCurve {
                    let t = CGFloat(i) / CGFloat(stepsPerCurve)
                    let mt = 1 - t
                    let x = mt*mt*mt*current.x + 3*mt*mt*t*c1.x + 3*mt*t*t*c2.x + t*t*t*end.x
                    let y = mt*mt*mt*current.y + 3*mt*mt*t*c1.y + 3*mt*t*t*c2.y + t*t*t*end.y
                    pts.append(CGPoint(x: x, y: y))
                }
                current = end
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        // Remove duplicate consecutive points
        var cleaned: [CGPoint] = []
        for p in pts {
            if let last = cleaned.last, hypot(last.x - p.x, last.y - p.y) < 1e-4 {
                continue
            }
            cleaned.append(p)
        }
        if cleaned.count > 1, let first = cleaned.first, let last = cleaned.last, hypot(first.x - last.x, first.y - last.y) < 1e-4 {
            cleaned.removeLast()
        }
        return cleaned
    }

    private static func sutherlandHodgmanClip(subject: [CGPoint], clip: [CGPoint]) -> [CGPoint] {
        guard clip.count >= 3 else { return [] }
        var output = subject
        // Ensure clip winding is consistent
        let area = signedPolygonArea(clip)
        let orderedClip = area < 0 ? Array(clip.reversed()) : clip

        for i in 0..<orderedClip.count {
            let a = orderedClip[i]
            let b = orderedClip[(i + 1) % orderedClip.count]
            let input = output
            output.removeAll()
            guard !input.isEmpty else { break }

            for j in 0..<input.count {
                let p = input[j]
                let q = input[(j + 1) % input.count]
                let pIn = isInsideEdge(point: p, edgeStart: a, edgeEnd: b)
                let qIn = isInsideEdge(point: q, edgeStart: a, edgeEnd: b)

                if pIn && qIn {
                    output.append(q)
                } else if pIn && !qIn {
                    if let inter = lineIntersection(p, q, a, b) {
                        output.append(inter)
                    }
                } else if !pIn && qIn {
                    if let inter = lineIntersection(p, q, a, b) {
                        output.append(inter)
                    }
                    output.append(q)
                }
            }
        }
        return output
    }

    private static func booleanPolygonContours(
        poly1: [CGPoint],
        poly2: [CGPoint],
        op: SketchBooleanOperation
    ) -> [[CGPoint]] {
        let p1Path = polygonToCGPath(poly1)
        let p2Path = polygonToCGPath(poly2)

        // Subdivide edges at intersections and retain boundary points satisfying the boolean predicate
        let sub1 = subdividePolygonEdges(poly1, against: poly2)
        let sub2 = subdividePolygonEdges(poly2, against: poly1)

        switch op {
        case .union:
            let out1 = sub1.filter { !p2Path.contains($0) || isOnBoundary($0, of: poly2) }
            let out2 = sub2.filter { !p1Path.contains($0) || isOnBoundary($0, of: poly1) }
            if out1.count + out2.count >= 3 {
                return [orderBoundaryPoints(out1 + out2)]
            }
            return [poly1, poly2]
        case .subtract:
            let out1 = sub1.filter { !p2Path.contains($0) || isOnBoundary($0, of: poly2) }
            let in2 = sub2.filter { p1Path.contains($0) }
            if out1.count + in2.count >= 3 {
                return [orderBoundaryPoints(out1 + in2)]
            }
            return [poly1]
        default:
            return [poly1, poly2]
        }
    }

    private static func subdividePolygonEdges(_ poly: [CGPoint], against other: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for i in 0..<poly.count {
            let a = poly[i]
            let b = poly[(i + 1) % poly.count]
            result.append(a)
            var hits: [(CGFloat, CGPoint)] = []
            for j in 0..<other.count {
                let c = other[j]
                let d = other[(j + 1) % other.count]
                if let (t, u, pt) = segmentIntersection(a, b, c, d),
                   t > 0.001, t < 0.999, u >= -0.001, u <= 1.001 {
                    hits.append((t, pt))
                }
            }
            hits.sort { $0.0 < $1.0 }
            for (_, pt) in hits {
                result.append(pt)
            }
        }
        return result
    }

    private static func isOnBoundary(_ pt: CGPoint, of poly: [CGPoint]) -> Bool {
        for i in 0..<poly.count {
            let a = poly[i]
            let b = poly[(i + 1) % poly.count]
            let d = hypot(b.x - a.x, b.y - a.y)
            guard d > 1e-6 else { continue }
            let cross = abs((pt.x - a.x) * (b.y - a.y) - (pt.y - a.y) * (b.x - a.x)) / d
            let dot = (pt.x - a.x) * (b.x - a.x) + (pt.y - a.y) * (b.y - a.y)
            if cross < 0.5 && dot >= -0.5 && dot <= d * d + 0.5 {
                return true
            }
        }
        return false
    }

    private static func orderBoundaryPoints(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count >= 3 else { return pts }
        let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
        let cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        return pts.sorted { a, b in
            atan2(a.y - cy, a.x - cx) < atan2(b.y - cy, b.x - cx)
        }
    }

    private static func signedPolygonArea(_ poly: [CGPoint]) -> CGFloat {
        var area: CGFloat = 0
        for i in 0..<poly.count {
            let p = poly[i]
            let q = poly[(i + 1) % poly.count]
            area += (p.x * q.y - q.x * p.y)
        }
        return area * 0.5
    }

    private static func isInsideEdge(point p: CGPoint, edgeStart a: CGPoint, edgeEnd b: CGPoint) -> Bool {
        return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= -1e-5
    }

    private static func lineIntersection(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint) -> CGPoint? {
        let denom = (p1.x - p2.x) * (p3.y - p4.y) - (p1.y - p2.y) * (p3.x - p4.x)
        guard abs(denom) > 1e-9 else { return nil }
        let a = p1.x * p2.y - p1.y * p2.x
        let b = p3.x * p4.y - p3.y * p4.x
        let x = (a * (p3.x - p4.x) - (p1.x - p2.x) * b) / denom
        let y = (a * (p3.y - p4.y) - (p1.y - p2.y) * b) / denom
        return CGPoint(x: x, y: y)
    }

    private static func segmentIntersection(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> (CGFloat, CGFloat, CGPoint)? {
        let r = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let s = CGPoint(x: d.x - c.x, y: d.y - c.y)
        let rxs = r.x * s.y - r.y * s.x
        guard abs(rxs) > 1e-8 else { return nil }
        let qp = CGPoint(x: c.x - a.x, y: c.y - a.y)
        let t = (qp.x * s.y - qp.y * s.x) / rxs
        let u = (qp.x * r.y - qp.y * r.x) / rxs
        let pt = CGPoint(x: a.x + t * r.x, y: a.y + t * r.y)
        return (t, u, pt)
    }

    private static func polygonToCGPath(_ poly: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = poly.first else { return path }
        path.move(to: first)
        for pt in poly.dropFirst() {
            path.addLine(to: pt)
        }
        path.closeSubpath()
        return path
    }

    private static func contoursToCGPath(_ contours: [[CGPoint]]) -> CGPath {
        let path = CGMutablePath()
        for poly in contours where poly.count >= 3 {
            path.addPath(polygonToCGPath(poly))
        }
        return path
    }
}

// MARK: - Smart Layout & Symbol Override Engine (Reconstructed from SketchModel.BatchedOverrides & MSImmutableInferredGroupLayout)

public enum SketchSmartLayoutEngine {
    /// Expands a `symbolInstance` against its `symbolMaster`, applying `overrideValues` and computing Smart Layout resizing!
    public static func expandSymbolInstance(
        _ instance: SketchLayer,
        in document: SketchDocumentArchive
    ) -> SketchLayer? {
        guard instance.kind == .symbolInstance,
              let symID = instance.symbolID else {
            return nil
        }

        if let cached = SketchRenderCache.shared.cachedExpandedSymbol(for: instance, in: document) {
            return cached
        }

        guard var master = SketchRenderCache.shared.symbolMaster(forSymbolID: symID, in: document) else {
            return nil
        }

        // Map overrideName ("<layerID>_stringValue") -> value
        var textOverrides: [String: String] = [:]
        for ov in instance.overrideValues {
            if ov.overrideName.hasSuffix("_stringValue") {
                let targetID = String(ov.overrideName.dropLast("_stringValue".count))
                // Support nested paths like "UUID1/UUID2"
                let leafID = targetID.split(separator: "/").last.map(String.init) ?? targetID
                textOverrides[leafID] = ov.value
            }
        }

        // Apply text overrides and track width/height deltas for Smart Layout
        var totalWidthDelta: Double = 0
        let totalHeightDelta: Double = 0

        func applyOverrides(to layers: inout [SketchLayer]) {
            for i in layers.indices {
                if layers[i].kind == .text, let newText = textOverrides[layers[i].do_objectID] {
                    let oldText = layers[i].attributedString?.string ?? ""
                    if newText != oldText {
                        let fontSize = layers[i].attributedString?.attributes.first?.fontSize ?? 16
                        let avgCharWidth = fontSize * 0.58
                        let oldEstWidth = max(layers[i].frame.width, Double(oldText.count) * avgCharWidth)
                        let newEstWidth = max(24.0, Double(newText.count) * avgCharWidth)
                        let deltaW = newEstWidth - oldEstWidth
                        totalWidthDelta += deltaW
                        layers[i].frame.width = max(24.0, layers[i].frame.width + deltaW)

                        if var attr = layers[i].attributedString {
                            attr.string = newText
                            if !attr.attributes.isEmpty {
                                attr.attributes[0].length = (newText as NSString).length
                            }
                            layers[i].attributedString = attr
                        } else {
                            layers[i].attributedString = SketchAttributedString(string: newText)
                        }
                    }
                }
                if !layers[i].layers.isEmpty {
                    applyOverrides(to: &layers[i].layers)
                }
            }
        }

        applyOverrides(to: &master.layers)

        // Apply Smart Layout (`MSImmutableInferredGroupLayout`)
        if let gl = master.groupLayout, gl.isSmartLayout {
            let axis = gl.axis ?? 0
            if axis == 0 && abs(totalWidthDelta) > 0.5 {
                // Horizontal Smart Layout: expand background/container layers to match text growth
                master.frame.width = max(gl.minSize ?? 20, master.frame.width + totalWidthDelta)
                for i in master.layers.indices where master.layers[i].kind != .text {
                    master.layers[i].frame.width = max(20, master.layers[i].frame.width + totalWidthDelta)
                }
            } else if axis == 1 && abs(totalHeightDelta) > 0.5 {
                master.frame.height = max(gl.minSize ?? 20, master.frame.height + totalHeightDelta)
                for i in master.layers.indices where master.layers[i].kind != .text {
                    master.layers[i].frame.height = max(20, master.layers[i].frame.height + totalHeightDelta)
                }
            }
        }

        master.frame.x = instance.frame.x
        master.frame.y = instance.frame.y
        SketchRenderCache.shared.storeExpandedSymbol(master, for: instance, in: document)
        return master
    }
}

// MARK: - Snapping & Alignment Engine (Reconstructed from SketchControllers.SnapTarget / SnapRegion / AlignmentSettings)

public struct SketchSnapGuide: Equatable, Identifiable, Sendable {
    public var id: String { "\(isVertical)-\(position)" }
    public var isVertical: Bool
    public var position: Double
    public var start: Double
    public var end: Double
}

public enum SketchSnapEngine {
    public static let defaultSnapDistance: Double = 5.0

    public static func snapFrame(
        _ proposed: SketchRect,
        against siblings: [SketchLayer],
        excluding excludedIDs: Set<String>,
        snapDistance: Double = defaultSnapDistance
    ) -> (snapped: SketchRect, guides: [SketchSnapGuide]) {
        var result = proposed
        var guides: [SketchSnapGuide] = []

        var bestDX: Double? = nil
        var bestVGuide: SketchSnapGuide? = nil
        var bestDY: Double? = nil
        var bestHGuide: SketchSnapGuide? = nil

        let propXAnchors = [proposed.x, proposed.x + proposed.width * 0.5, proposed.x + proposed.width]
        let propYAnchors = [proposed.y, proposed.y + proposed.height * 0.5, proposed.y + proposed.height]

        for sib in siblings where !excludedIDs.contains(sib.do_objectID) && sib.isVisible {
            let sxAnchors = [sib.frame.x, sib.frame.x + sib.frame.width * 0.5, sib.frame.x + sib.frame.width]
            let syAnchors = [sib.frame.y, sib.frame.y + sib.frame.height * 0.5, sib.frame.y + sib.frame.height]

            for px in propXAnchors {
                for sx in sxAnchors {
                    let diff = sx - px
                    if abs(diff) <= snapDistance && (bestDX == nil || abs(diff) < abs(bestDX!)) {
                        bestDX = diff
                        bestVGuide = SketchSnapGuide(
                            isVertical: true,
                            position: sx,
                            start: min(proposed.y, sib.frame.y),
                            end: max(proposed.y + proposed.height, sib.frame.y + sib.frame.height)
                        )
                    }
                }
            }

            for py in propYAnchors {
                for sy in syAnchors {
                    let diff = sy - py
                    if abs(diff) <= snapDistance && (bestDY == nil || abs(diff) < abs(bestDY!)) {
                        bestDY = diff
                        bestHGuide = SketchSnapGuide(
                            isVertical: false,
                            position: sy,
                            start: min(proposed.x, sib.frame.x),
                            end: max(proposed.x + proposed.width, sib.frame.x + sib.frame.width)
                        )
                    }
                }
            }
        }

        if let dx = bestDX, let vg = bestVGuide {
            result.x += dx
            guides.append(vg)
        }
        if let dy = bestDY, let hg = bestHGuide {
            result.y += dy
            guides.append(hg)
        }

        return (result, guides)
    }

    /// Implements `tidy:` action selector from `out/ib-sketch-all.json`
    public static func tidyLayers(_ layers: inout [SketchLayer], selectedIDs: Set<String>, spacing: Double = 8.0) {
        let indices = layers.indices.filter { selectedIDs.contains(layers[$0].do_objectID) }
        guard indices.count >= 2 else { return }
        let sortedByX = indices.sorted { layers[$0].frame.x < layers[$1].frame.x }
        let sortedByY = indices.sorted { layers[$0].frame.y < layers[$1].frame.y }

        let spanX = (layers[sortedByX.last!].frame.x - layers[sortedByX.first!].frame.x)
        let spanY = (layers[sortedByY.last!].frame.y - layers[sortedByY.first!].frame.y)

        if spanX >= spanY {
            var currentX = layers[sortedByX.first!].frame.x
            let topY = layers[sortedByX.first!].frame.y
            for idx in sortedByX {
                layers[idx].frame.x = currentX
                layers[idx].frame.y = topY
                currentX += layers[idx].frame.width + spacing
            }
        } else {
            var currentY = layers[sortedByY.first!].frame.y
            let leftX = layers[sortedByY.first!].frame.x
            for idx in sortedByY {
                layers[idx].frame.x = leftX
                layers[idx].frame.y = currentY
                currentY += layers[idx].frame.height + spacing
            }
        }
    }
}
