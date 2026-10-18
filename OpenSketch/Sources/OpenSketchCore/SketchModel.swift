import Foundation
import CoreGraphics

// MARK: - Generic JSON Value for Lossless Round-Tripping

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n):
            if n.rounded() == n && abs(n) < Double(Int64.max) {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }
    public var intValue: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        if case .number(let n) = self { return n != 0 }
        return nil
    }
    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// High-speed C-backed JSON parser via `JSONSerialization` (avoids throwing/catching 150,000+ `Codable` `DecodingError`s).
    public static func parseObject(from data: Data) -> [String: JSONValue]? {
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = raw as? [String: Any] else {
            return nil
        }
        return convertObject(dict)
    }

    private static func convertAny(_ val: Any) -> JSONValue {
        if let s = val as? String {
            return .string(s)
        } else if let n = val as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            return .number(n.doubleValue)
        } else if let dict = val as? [String: Any] {
            return .object(convertObject(dict))
        } else if let arr = val as? [Any] {
            var out: [JSONValue] = []
            out.reserveCapacity(arr.count)
            for item in arr {
                out.append(convertAny(item))
            }
            return .array(out)
        } else {
            return .null
        }
    }

    private static func convertObject(_ dict: [String: Any]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        out.reserveCapacity(dict.count)
        for (k, v) in dict {
            out[k] = convertAny(v)
        }
        return out
    }
}

// MARK: - Unit Point String Parser ("{0.5, 0.25}")

public enum SketchPointString {
    public static func parse(_ str: String, default fallback: CGPoint = .zero) -> CGPoint {
        guard let commaIdx = str.firstIndex(of: ",") else { return fallback }
        var startIdx = str.startIndex
        while startIdx < commaIdx && (str[startIdx] == "{" || str[startIdx] == " ") {
            startIdx = str.index(after: startIdx)
        }
        var endX = commaIdx
        while endX > startIdx && str[str.index(before: endX)] == " " {
            endX = str.index(before: endX)
        }
        var startY = str.index(after: commaIdx)
        var endY = str.endIndex
        while startY < endY && str[startY] == " " {
            startY = str.index(after: startY)
        }
        while endY > startY {
            let prev = str.index(before: endY)
            if str[prev] == "}" || str[prev] == " " {
                endY = prev
            } else {
                break
            }
        }
        guard let x = Double(str[startIdx..<endX]),
              let y = Double(str[startY..<endY]) else {
            return fallback
        }
        return CGPoint(x: x, y: y)
    }

    public static func format(_ point: CGPoint) -> String {
        func clean(_ v: CGFloat) -> String {
            if abs(v - round(v)) < 1e-9 {
                return String(Int(round(v)))
            }
            return String(format: "%.10g", Double(v))
        }
        return "{\(clean(point.x)), \(clean(point.y))}"
    }

    /// Reconstructs `_BCPointConvertFromUnitCoordinates` from `SketchModel` (`MSBezierBuilder::buildV1CGPath:`)
    public static func convertFromUnit(_ unit: CGPoint, in rect: CGRect) -> CGPoint {
        return CGPoint(
            x: rect.origin.x + unit.x * rect.size.width,
            y: rect.origin.y + unit.y * rect.size.height
        )
    }

    public static func convertToUnit(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        let w = max(rect.size.width, 0.0001)
        let h = max(rect.size.height, 0.0001)
        return CGPoint(
            x: (point.x - rect.origin.x) / w,
            y: (point.y - rect.origin.y) / h
        )
    }
}

// MARK: - Enums Matching SketchModel Constants

/// Matches `MSBooleanOperation` in `MSPath::booleanOp:withPath:` (`0x138c5c` in `SketchModel`)
public enum SketchBooleanOperation: Int, Codable, CaseIterable, Sendable {
    case none = -1
    case union = 0
    case subtract = 1
    case intersect = 2
    case difference = 3

    public var title: String {
        switch self {
        case .none: return "None"
        case .union: return "Union"
        case .subtract: return "Subtract"
        case .intersect: return "Intersect"
        case .difference: return "Difference"
        }
    }
}

/// Matches `MSCurveMode` in `SketchModel` (`MSCurvePoint`)
public enum SketchCurveMode: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case straight = 1
    case mirrored = 2
    case asymmetric = 3
    case disconnected = 4

    public var title: String {
        switch self {
        case .none: return "None"
        case .straight: return "Straight"
        case .mirrored: return "Mirrored"
        case .asymmetric: return "Asymmetric"
        case .disconnected: return "Disconnected"
        }
    }
}

public enum SketchLayerKind: String, Codable, CaseIterable, Sendable {
    case page = "page"
    case artboard = "artboard"
    case symbolMaster = "symbolMaster"
    case symbolInstance = "symbolInstance"
    case group = "group"
    case shapeGroup = "shapeGroup"
    case rectangle = "rectangle"
    case oval = "oval"
    case shapePath = "shapePath"
    case polygon = "polygon"
    case star = "star"
    case triangle = "triangle"
    case text = "text"
    case bitmap = "bitmap"
    case slice = "slice"
    case hotspot = "MSImmutableHotspotLayer"

    public var systemIconName: String {
        switch self {
        case .page: return "doc.richtext"
        case .artboard: return "macwindow"
        case .symbolMaster: return "Command"
        case .symbolInstance: return "suit.diamond"
        case .group: return "folder"
        case .shapeGroup: return "square.on.circle"
        case .rectangle: return "rectangle"
        case .oval: return "circle"
        case .shapePath, .polygon, .star, .triangle: return "scribble"
        case .text: return "textformat"
        case .bitmap: return "photo"
        case .slice: return "scissors"
        case .hotspot: return "link"
        }
    }
}

// MARK: - Geometry & Curve Point

public struct SketchRect: Codable, Equatable, Sendable {
    public var _class: String = "rect"
    public var constrainProportions: Bool
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 100, height: Double = 100, constrainProportions: Bool = false) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.constrainProportions = constrainProportions
    }

    public var cgRect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = Double(newValue.origin.x)
            y = Double(newValue.origin.y)
            width = Double(newValue.size.width)
            height = Double(newValue.size.height)
        }
    }
}

public struct SketchCurvePoint: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(point)-\(curveFrom)-\(curveTo)-\(cornerRadius)" }
    public var _class: String = "curvePoint"
    public var cornerRadius: Double
    public var curveFrom: String
    public var curveTo: String
    public var hasCurveFrom: Bool
    public var hasCurveTo: Bool
    public var curveMode: Int
    public var point: String

    public init(
        point: CGPoint,
        curveFrom: CGPoint? = nil,
        curveTo: CGPoint? = nil,
        hasCurveFrom: Bool = false,
        hasCurveTo: Bool = false,
        curveMode: SketchCurveMode = .straight,
        cornerRadius: Double = 0
    ) {
        self.point = SketchPointString.format(point)
        self.curveFrom = SketchPointString.format(curveFrom ?? point)
        self.curveTo = SketchPointString.format(curveTo ?? point)
        self.hasCurveFrom = hasCurveFrom
        self.hasCurveTo = hasCurveTo
        self.curveMode = curveMode.rawValue
        self.cornerRadius = cornerRadius
    }

    public var unitPoint: CGPoint {
        get { SketchPointString.parse(point) }
        set { point = SketchPointString.format(newValue) }
    }

    public var unitCurveFrom: CGPoint {
        get { SketchPointString.parse(curveFrom, default: unitPoint) }
        set { curveFrom = SketchPointString.format(newValue) }
    }

    public var unitCurveTo: CGPoint {
        get { SketchPointString.parse(curveTo, default: unitPoint) }
        set { curveTo = SketchPointString.format(newValue) }
    }
}

// MARK: - Colors, Gradients & Styling

public struct SketchColor: Codable, Equatable, Sendable {
    public var _class: String = "color"
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double = 0.0, green: Double = 0.48, blue: Double = 1.0, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var hexString: String {
        get {
            let r = Int(round(min(max(red, 0), 1) * 255))
            let g = Int(round(min(max(green, 0), 1) * 255))
            let b = Int(round(min(max(blue, 0), 1) * 255))
            return String(format: "%02X%02X%02X", r, g, b)
        }
        set {
            let clean = newValue.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespacesAndNewlines))
            guard clean.count == 6, let val = Int(clean, radix: 16) else { return }
            self.red = Double((val >> 16) & 0xFF) / 255.0
            self.green = Double((val >> 8) & 0xFF) / 255.0
            self.blue = Double(val & 0xFF) / 255.0
        }
    }

    public static let white = SketchColor(red: 1, green: 1, blue: 1, alpha: 1)
    public static let black = SketchColor(red: 0, green: 0, blue: 0, alpha: 1)
    public static let sketchBlue = SketchColor(red: 0.0078, green: 0.4784, blue: 1.0, alpha: 1.0)
    public static let defaultFill = SketchColor(red: 0.847, green: 0.847, blue: 0.847, alpha: 1.0)
    public static let defaultBorder = SketchColor(red: 0.592, green: 0.592, blue: 0.592, alpha: 1.0)
}

public struct SketchGradientStop: Codable, Equatable, Sendable {
    public var _class: String = "gradientStop"
    public var color: SketchColor
    public var position: Double

    public init(color: SketchColor, position: Double) {
        self.color = color
        self.position = position
    }
}

public struct SketchGradient: Codable, Equatable, Sendable {
    public var _class: String = "gradient"
    public var elipseLength: Double
    public var from: String
    public var to: String
    public var gradientType: Int // 0 = linear, 1 = radial, 2 = angular
    public var stops: [SketchGradientStop]

    public init(
        gradientType: Int = 0,
        from: CGPoint = CGPoint(x: 0.5, y: 0),
        to: CGPoint = CGPoint(x: 0.5, y: 1),
        stops: [SketchGradientStop] = [
            SketchGradientStop(color: .white, position: 0),
            SketchGradientStop(color: .black, position: 1)
        ],
        elipseLength: Double = 1.0
    ) {
        self.gradientType = gradientType
        self.from = SketchPointString.format(from)
        self.to = SketchPointString.format(to)
        self.stops = stops
        self.elipseLength = elipseLength
    }

    public var fromPoint: CGPoint { SketchPointString.parse(from, default: CGPoint(x: 0.5, y: 0)) }
    public var toPoint: CGPoint { SketchPointString.parse(to, default: CGPoint(x: 0.5, y: 1)) }
}

public struct SketchGraphicsContextSettings: Codable, Equatable, Sendable {
    public var _class: String = "graphicsContextSettings"
    public var blendMode: Int
    public var opacity: Double

    public init(blendMode: Int = 0, opacity: Double = 1.0) {
        self.blendMode = blendMode
        self.opacity = opacity
    }
}

public struct SketchFill: Codable, Equatable, Sendable {
    public var _class: String = "fill"
    public var isEnabled: Bool
    public var fillType: Int // 0 = solid color, 1 = gradient, 4 = pattern/image
    public var color: SketchColor
    public var gradient: SketchGradient?
    public var contextSettings: SketchGraphicsContextSettings?
    public var noiseIndex: Int
    public var noiseIntensity: Double
    public var patternFillType: Int
    public var patternTileScale: Double
    public var image: SketchFileReference?

    public init(
        isEnabled: Bool = true,
        fillType: Int = 0,
        color: SketchColor = .defaultFill,
        gradient: SketchGradient? = nil,
        contextSettings: SketchGraphicsContextSettings? = SketchGraphicsContextSettings()
    ) {
        self.isEnabled = isEnabled
        self.fillType = fillType
        self.color = color
        self.gradient = gradient
        self.contextSettings = contextSettings
        self.noiseIndex = 0
        self.noiseIntensity = 0
        self.patternFillType = 1
        self.patternTileScale = 1
    }
}

public struct SketchBorder: Codable, Equatable, Sendable {
    public var _class: String = "border"
    public var isEnabled: Bool
    public var fillType: Int
    public var color: SketchColor
    public var gradient: SketchGradient?
    public var contextSettings: SketchGraphicsContextSettings?
    public var position: Int // 0 = center, 1 = inside, 2 = outside
    public var thickness: Double

    public init(
        isEnabled: Bool = true,
        fillType: Int = 0,
        color: SketchColor = .defaultBorder,
        position: Int = 1,
        thickness: Double = 1.0
    ) {
        self.isEnabled = isEnabled
        self.fillType = fillType
        self.color = color
        self.position = position
        self.thickness = thickness
        self.contextSettings = SketchGraphicsContextSettings()
    }
}

public struct SketchBorderOptions: Codable, Equatable, Sendable {
    public var _class: String = "borderOptions"
    public var isEnabled: Bool
    public var dashPattern: [Double]
    public var lineCapStyle: Int // 0 = butt, 1 = round, 2 = square
    public var lineJoinStyle: Int // 0 = miter, 1 = round, 2 = bevel

    public init(isEnabled: Bool = true, dashPattern: [Double] = [], lineCapStyle: Int = 0, lineJoinStyle: Int = 0) {
        self.isEnabled = isEnabled
        self.dashPattern = dashPattern
        self.lineCapStyle = lineCapStyle
        self.lineJoinStyle = lineJoinStyle
    }
}

public struct SketchShadow: Codable, Equatable, Sendable {
    public var _class: String = "shadow"
    public var isEnabled: Bool
    public var blurRadius: Double
    public var offsetX: Double
    public var offsetY: Double
    public var spread: Double
    public var color: SketchColor
    public var contextSettings: SketchGraphicsContextSettings?

    public init(
        isEnabled: Bool = true,
        color: SketchColor = SketchColor(red: 0, green: 0, blue: 0, alpha: 0.25),
        offsetX: Double = 0,
        offsetY: Double = 2,
        blurRadius: Double = 4,
        spread: Double = 0,
        isInner: Bool = false
    ) {
        self._class = isInner ? "innerShadow" : "shadow"
        self.isEnabled = isEnabled
        self.color = color
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blurRadius = blurRadius
        self.spread = spread
        self.contextSettings = SketchGraphicsContextSettings()
    }
}

public struct SketchBlur: Codable, Equatable, Sendable {
    public var _class: String = "blur"
    public var isEnabled: Bool
    public var center: String
    public var motionAngle: Double
    public var radius: Double
    public var saturation: Double
    public var type: Int // 0 = Gaussian, 1 = Motion, 2 = Zoom, 3 = Background

    public init(isEnabled: Bool = false, radius: Double = 10, type: Int = 0) {
        self.isEnabled = isEnabled
        self.center = "{0.5, 0.5}"
        self.motionAngle = 0
        self.radius = radius
        self.saturation = 1
        self.type = type
    }
}

public struct SketchStyle: Codable, Equatable, Sendable {
    public var _class: String = "style"
    public var do_objectID: String
    public var fills: [SketchFill]
    public var borders: [SketchBorder]
    public var shadows: [SketchShadow]
    public var innerShadows: [SketchShadow]
    public var borderOptions: SketchBorderOptions?
    public var blur: SketchBlur?
    public var contextSettings: SketchGraphicsContextSettings?
    public var miterLimit: Double
    public var startMarkerType: Int
    public var endMarkerType: Int
    public var windingRule: Int // 0 = non-zero, 1 = even-odd
    public var textStyle: SketchTextStyle?

    public init(
        do_objectID: String = UUID().uuidString.uppercased(),
        fills: [SketchFill] = [],
        borders: [SketchBorder] = [],
        shadows: [SketchShadow] = [],
        innerShadows: [SketchShadow] = [],
        borderOptions: SketchBorderOptions? = SketchBorderOptions(),
        blur: SketchBlur? = SketchBlur(),
        contextSettings: SketchGraphicsContextSettings? = SketchGraphicsContextSettings(),
        windingRule: Int = 1
    ) {
        self.do_objectID = do_objectID
        self.fills = fills
        self.borders = borders
        self.shadows = shadows
        self.innerShadows = innerShadows
        self.borderOptions = borderOptions
        self.blur = blur
        self.contextSettings = contextSettings
        self.miterLimit = 10
        self.startMarkerType = 0
        self.endMarkerType = 0
        self.windingRule = windingRule
    }

    /// Reconstructs `MSImmutableStyle::firstEnabledFill` (`0xb4e74` in `SketchModel`)
    public var firstEnabledFill: SketchFill? {
        fills.first(where: { $0.isEnabled })
    }

    /// Reconstructs `MSImmutableStyle::firstEnabledBorder` (`0xb4ed0` in `SketchModel`)
    public var firstEnabledBorder: SketchBorder? {
        borders.first(where: { $0.isEnabled })
    }

    /// Reconstructs `MSImmutableStyle::firstEnabledShadow` (`0xb4dbc` in `SketchModel`)
    public var firstEnabledShadow: SketchShadow? {
        shadows.first(where: { $0.isEnabled })
    }

    /// Reconstructs `MSImmutableStyle::calculateThickestBorder` (`0xb51e8` in `SketchModel`)
    public var thickestBorderThickness: Double {
        borders.filter(\.isEnabled).map(\.thickness).max() ?? 0
    }
}

// MARK: - Typography & Attributed Strings

public struct SketchStringAttribute: Codable, Equatable, Sendable {
    public var _class: String = "stringAttribute"
    public var location: Int
    public var length: Int
    public var fontName: String
    public var fontSize: Double
    public var color: SketchColor
    public var alignment: Int // 0 = left, 1 = right, 2 = center, 3 = justified
    public var kerning: Double?
    public var lineSpacing: Double?
    public var paragraphSpacing: Double?

    public init(
        location: Int = 0,
        length: Int = 0,
        fontName: String = "HelveticaNeue",
        fontSize: Double = 14,
        color: SketchColor = .black,
        alignment: Int = 0,
        kerning: Double? = nil,
        lineSpacing: Double? = nil,
        paragraphSpacing: Double? = nil
    ) {
        self.location = location
        self.length = length
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
        self.alignment = alignment
        self.kerning = kerning
        self.lineSpacing = lineSpacing
        self.paragraphSpacing = paragraphSpacing
    }
}

public struct SketchAttributedString: Codable, Equatable, Sendable {
    public var _class: String = "attributedString"
    public var string: String
    public var attributes: [SketchStringAttribute]

    public init(string: String = "Type something", attributes: [SketchStringAttribute]? = nil) {
        self.string = string
        self.attributes = attributes ?? [
            SketchStringAttribute(location: 0, length: (string as NSString).length, fontName: "HelveticaNeue", fontSize: 16, color: .black)
        ]
    }
}

public struct SketchTextStyle: Codable, Equatable, Sendable {
    public var _class: String = "textStyle"
    public var verticalAlignment: Int
    public var fontName: String
    public var fontSize: Double
    public var textColor: SketchColor
    public var alignment: Int

    public init(fontName: String = "HelveticaNeue", fontSize: Double = 16, textColor: SketchColor = .black, alignment: Int = 0, verticalAlignment: Int = 0) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.textColor = textColor
        self.alignment = alignment
        self.verticalAlignment = verticalAlignment
    }
}

// MARK: - Smart Layout, Symbols & Export Options

/// Matches `MSImmutableInferredGroupLayout` and `MSImmutableFreeformGroupLayout` in `SketchModel`
public struct SketchGroupLayout: Codable, Equatable, Sendable {
    public var _class: String // "MSImmutableFreeformGroupLayout" or "MSImmutableInferredGroupLayout"
    public var axis: Int? // 0 = horizontal, 1 = vertical
    public var layoutAnchor: Int? // 0 = start (Left/Top), 1 = center, 2 = end (Right/Bottom)
    public var maxSize: Double?
    public var minSize: Double?

    public init(isSmartLayout: Bool = false, axis: Int = 0, layoutAnchor: Int = 0, minSize: Double = 0, maxSize: Double = 0) {
        if isSmartLayout {
            self._class = "MSImmutableInferredGroupLayout"
            self.axis = axis
            self.layoutAnchor = layoutAnchor
            self.minSize = minSize
            self.maxSize = maxSize
        } else {
            self._class = "MSImmutableFreeformGroupLayout"
        }
    }

    public var isSmartLayout: Bool {
        _class == "MSImmutableInferredGroupLayout"
    }

    public var displayTitle: String {
        guard isSmartLayout else { return "None (Freeform)" }
        switch (axis ?? 0, layoutAnchor ?? 0) {
        case (0, 0): return "Horizontally: Left to Right"
        case (0, 1): return "Horizontally: From Center"
        case (0, 2): return "Horizontally: Right to Left"
        case (1, 0): return "Vertically: Top to Bottom"
        case (1, 1): return "Vertically: From Middle"
        case (1, 2): return "Vertically: Bottom to Top"
        default: return "Smart Layout"
        }
    }
}

public struct SketchOverrideValue: Codable, Equatable, Identifiable, Sendable {
    public var id: String { overrideName }
    public var _class: String = "overrideValue"
    public var overrideName: String // e.g., "<objectID>_stringValue" or "<objectID>_symbolID"
    public var value: String

    public init(overrideName: String, value: String) {
        self.overrideName = overrideName
        self.value = value
    }
}

public struct SketchOverrideProperty: Codable, Equatable, Sendable {
    public var _class: String = "MSImmutableOverrideProperty"
    public var canOverride: Bool
    public var overrideName: String

    public init(overrideName: String, canOverride: Bool = true) {
        self.overrideName = overrideName
        self.canOverride = canOverride
    }
}

public struct SketchExportFormat: Codable, Equatable, Identifiable, Sendable {
    public var id: String { "\(fileFormat)-\(scale)-\(name ?? "")" }
    public var _class: String = "exportFormat"
    public var absoluteSize: Double
    public var fileFormat: String // "png", "svg", "pdf", "jpg", "eps"
    public var name: String?
    public var namingScheme: Int
    public var scale: Double
    public var visibleScaleType: Int

    public init(scale: Double = 1.0, fileFormat: String = "png", name: String? = "") {
        self.scale = scale
        self.fileFormat = fileFormat
        self.name = name
        self.absoluteSize = 0
        self.namingScheme = 0
        self.visibleScaleType = 0
    }
}

public struct SketchExportOptions: Codable, Equatable, Sendable {
    public var _class: String = "exportOptions"
    public var exportFormats: [SketchExportFormat]
    public var includedLayerIds: [String]
    public var layerOptions: Int
    public var shouldTrim: Bool

    public init(exportFormats: [SketchExportFormat] = [], shouldTrim: Bool = false) {
        self.exportFormats = exportFormats
        self.includedLayerIds = []
        self.layerOptions = 0
        self.shouldTrim = shouldTrim
    }
}

public struct SketchFileReference: Codable, Equatable, Sendable {
    public var _class: String = "MSJSONFileReference"
    public var _ref_class: String
    public var _ref: String

    public init(refClass: String, ref: String) {
        self._ref_class = refClass
        self._ref = ref
    }
}

// MARK: - Unified Sketch Layer Node

public struct SketchLayer: Equatable, Identifiable, Sendable {
    public var id: String { do_objectID }
    public var _class: String
    public var do_objectID: String
    public var name: String
    public var nameIsFixed: Bool
    public var isVisible: Bool
    public var isLocked: Bool
    public var isFlippedHorizontal: Bool
    public var isFlippedVertical: Bool
    public var isFixedToViewport: Bool
    public var rotation: Double
    public var booleanOperation: SketchBooleanOperation
    public var frame: SketchRect
    public var style: SketchStyle
    public var exportOptions: SketchExportOptions
    public var resizingConstraint: Int
    public var resizingType: Int
    public var hasClippingMask: Bool
    public var clippingMaskMode: Int
    public var shouldBreakMaskChain: Bool
    public var layerListExpandedType: Int

    // Container / Artboard / Group properties
    public var layers: [SketchLayer]
    public var hasClickThrough: Bool
    public var groupLayout: SketchGroupLayout?
    public var hasBackgroundColor: Bool
    public var backgroundColor: SketchColor?
    public var includeBackgroundColorInExport: Bool

    // Shape / Vector Path properties
    public var isClosed: Bool
    public var edited: Bool
    public var pointRadiusBehaviour: Int
    public var fixedRadius: Double
    public var points: [SketchCurvePoint]

    // Text properties
    public var attributedString: SketchAttributedString?
    public var textBehaviour: Int // 0 = auto width, 1 = auto height, 2 = fixed size

    // Symbol Master / Instance properties
    public var symbolID: String?
    public var overrideValues: [SketchOverrideValue]
    public var overrideProperties: [SketchOverrideProperty]
    public var allowsOverrides: Bool
    public var scale: Double
    public var horizontalSpacing: Double
    public var verticalSpacing: Double

    // Bitmap properties
    public var imageRef: SketchFileReference?

    // Raw JSON preservation for lossless round-tripping of unmodeled properties
    public var rawJSON: [String: JSONValue]

    public var kind: SketchLayerKind {
        SketchLayerKind(rawValue: _class) ?? .group
    }

    public init(
        kind: SketchLayerKind,
        id: String = UUID().uuidString.uppercased(),
        name: String,
        frame: SketchRect,
        style: SketchStyle = SketchStyle(),
        layers: [SketchLayer] = [],
        points: [SketchCurvePoint] = [],
        isClosed: Bool = true,
        fixedRadius: Double = 0,
        booleanOperation: SketchBooleanOperation = .none,
        attributedString: SketchAttributedString? = nil,
        symbolID: String? = nil,
        overrideValues: [SketchOverrideValue] = [],
        groupLayout: SketchGroupLayout? = nil,
        hasBackgroundColor: Bool = false,
        backgroundColor: SketchColor? = nil
    ) {
        self._class = kind.rawValue
        self.do_objectID = id
        self.name = name
        self.nameIsFixed = false
        self.isVisible = true
        self.isLocked = false
        self.isFlippedHorizontal = false
        self.isFlippedVertical = false
        self.isFixedToViewport = false
        self.rotation = 0
        self.booleanOperation = booleanOperation
        self.frame = frame
        self.style = style
        self.exportOptions = SketchExportOptions()
        self.resizingConstraint = 63
        self.resizingType = 0
        self.hasClippingMask = false
        self.clippingMaskMode = 0
        self.shouldBreakMaskChain = false
        self.layerListExpandedType = 0
        self.layers = layers
        self.hasClickThrough = false
        self.groupLayout = groupLayout
        self.hasBackgroundColor = hasBackgroundColor
        self.backgroundColor = backgroundColor
        self.includeBackgroundColorInExport = true
        self.isClosed = isClosed
        self.edited = false
        self.pointRadiusBehaviour = 1
        self.fixedRadius = fixedRadius
        self.points = points
        self.attributedString = attributedString
        self.textBehaviour = 0
        self.symbolID = symbolID
        self.overrideValues = overrideValues
        self.overrideProperties = []
        self.allowsOverrides = true
        self.scale = 1.0
        self.horizontalSpacing = 0
        self.verticalSpacing = 0
        self.imageRef = nil
        self.rawJSON = [:]
    }

    // MARK: - Factory Presets for Shapes

    public static func makeRectangle(
        name: String = "Rectangle",
        frame: SketchRect = SketchRect(x: 100, y: 100, width: 160, height: 100),
        cornerRadius: Double = 0,
        fillColor: SketchColor = .defaultFill,
        borderColor: SketchColor = .defaultBorder
    ) -> SketchLayer {
        let pts: [SketchCurvePoint] = [
            SketchCurvePoint(point: CGPoint(x: 0, y: 0), curveMode: .straight, cornerRadius: cornerRadius),
            SketchCurvePoint(point: CGPoint(x: 1, y: 0), curveMode: .straight, cornerRadius: cornerRadius),
            SketchCurvePoint(point: CGPoint(x: 1, y: 1), curveMode: .straight, cornerRadius: cornerRadius),
            SketchCurvePoint(point: CGPoint(x: 0, y: 1), curveMode: .straight, cornerRadius: cornerRadius)
        ]
        let style = SketchStyle(
            fills: [SketchFill(isEnabled: true, fillType: 0, color: fillColor)],
            borders: [SketchBorder(isEnabled: true, fillType: 0, color: borderColor, position: 1, thickness: 1)]
        )
        return SketchLayer(
            kind: .rectangle,
            name: name,
            frame: frame,
            style: style,
            points: pts,
            isClosed: true,
            fixedRadius: cornerRadius
        )
    }

    public static func makeOval(
        name: String = "Oval",
        frame: SketchRect = SketchRect(x: 120, y: 120, width: 120, height: 120),
        fillColor: SketchColor = .defaultFill,
        borderColor: SketchColor = .defaultBorder
    ) -> SketchLayer {
        // Kappa for unit circle cubic bezier: 0.5522847498 * 0.5 = 0.2761423749
        let k: CGFloat = 0.2761423749
        let pts: [SketchCurvePoint] = [
            SketchCurvePoint(
                point: CGPoint(x: 0.5, y: 0.0),
                curveFrom: CGPoint(x: 0.5 + k, y: 0.0),
                curveTo: CGPoint(x: 0.5 - k, y: 0.0),
                hasCurveFrom: true, hasCurveTo: true, curveMode: .mirrored
            ),
            SketchCurvePoint(
                point: CGPoint(x: 1.0, y: 0.5),
                curveFrom: CGPoint(x: 1.0, y: 0.5 + k),
                curveTo: CGPoint(x: 1.0, y: 0.5 - k),
                hasCurveFrom: true, hasCurveTo: true, curveMode: .mirrored
            ),
            SketchCurvePoint(
                point: CGPoint(x: 0.5, y: 1.0),
                curveFrom: CGPoint(x: 0.5 - k, y: 1.0),
                curveTo: CGPoint(x: 0.5 + k, y: 1.0),
                hasCurveFrom: true, hasCurveTo: true, curveMode: .mirrored
            ),
            SketchCurvePoint(
                point: CGPoint(x: 0.0, y: 0.5),
                curveFrom: CGPoint(x: 0.0, y: 0.5 - k),
                curveTo: CGPoint(x: 0.0, y: 0.5 + k),
                hasCurveFrom: true, hasCurveTo: true, curveMode: .mirrored
            )
        ]
        let style = SketchStyle(
            fills: [SketchFill(isEnabled: true, fillType: 0, color: fillColor)],
            borders: [SketchBorder(isEnabled: true, fillType: 0, color: borderColor, position: 1, thickness: 1)]
        )
        return SketchLayer(kind: .oval, name: name, frame: frame, style: style, points: pts, isClosed: true)
    }

    public static func makeText(
        name: String = "Text",
        text: String = "Type something",
        frame: SketchRect = SketchRect(x: 100, y: 100, width: 160, height: 28),
        fontSize: Double = 18,
        color: SketchColor = .black
    ) -> SketchLayer {
        let attr = SketchAttributedString(
            string: text,
            attributes: [
                SketchStringAttribute(
                    location: 0,
                    length: (text as NSString).length,
                    fontName: "HelveticaNeue",
                    fontSize: fontSize,
                    color: color
                )
            ]
        )
        var style = SketchStyle()
        style.textStyle = SketchTextStyle(fontName: "HelveticaNeue", fontSize: fontSize, textColor: color)
        return SketchLayer(kind: .text, name: name, frame: frame, style: style, attributedString: attr)
    }

    public static func makeArtboard(
        name: String = "Artboard",
        frame: SketchRect = SketchRect(x: 0, y: 0, width: 400, height: 300),
        layers: [SketchLayer] = []
    ) -> SketchLayer {
        return SketchLayer(
            kind: .artboard,
            name: name,
            frame: frame,
            layers: layers,
            groupLayout: SketchGroupLayout(isSmartLayout: false),
            hasBackgroundColor: true,
            backgroundColor: .white
        )
    }

    public static func makePolygon(
        name: String = "Polygon",
        sides: Int = 6,
        frame: SketchRect = SketchRect(x: 100, y: 100, width: 110, height: 110),
        fillColor: SketchColor = SketchColor(red: 0.16, green: 0.78, blue: 0.55, alpha: 1.0),
        borderColor: SketchColor = SketchColor(red: 0.10, green: 0.58, blue: 0.40, alpha: 1.0)
    ) -> SketchLayer {
        let count = max(3, sides)
        var pts: [SketchCurvePoint] = []
        for i in 0..<count {
            let angle = -Double.pi / 2.0 + (2.0 * Double.pi * Double(i)) / Double(count)
            let ux = 0.5 + 0.5 * cos(angle)
            let uy = 0.5 + 0.5 * sin(angle)
            pts.append(SketchCurvePoint(point: CGPoint(x: ux, y: uy), curveMode: .straight))
        }
        let style = SketchStyle(
            fills: [SketchFill(isEnabled: true, fillType: 0, color: fillColor)],
            borders: [SketchBorder(isEnabled: true, fillType: 0, color: borderColor, position: 1, thickness: 1)]
        )
        return SketchLayer(kind: .polygon, name: name, frame: frame, style: style, points: pts, isClosed: true)
    }

    public static func makeStar(
        name: String = "Star",
        pointsCount: Int = 5,
        innerRadiusRatio: Double = 0.42,
        frame: SketchRect = SketchRect(x: 100, y: 100, width: 110, height: 110),
        fillColor: SketchColor = SketchColor(red: 0.98, green: 0.75, blue: 0.18, alpha: 1.0),
        borderColor: SketchColor = SketchColor(red: 0.85, green: 0.58, blue: 0.05, alpha: 1.0)
    ) -> SketchLayer {
        let count = max(3, pointsCount)
        var pts: [SketchCurvePoint] = []
        for i in 0..<(count * 2) {
            let r = (i % 2 == 0) ? 0.5 : (0.5 * innerRadiusRatio)
            let angle = -Double.pi / 2.0 + (Double.pi * Double(i)) / Double(count)
            let ux = 0.5 + r * cos(angle)
            let uy = 0.5 + r * sin(angle)
            pts.append(SketchCurvePoint(point: CGPoint(x: ux, y: uy), curveMode: .straight))
        }
        let style = SketchStyle(
            fills: [SketchFill(isEnabled: true, fillType: 0, color: fillColor)],
            borders: [SketchBorder(isEnabled: true, fillType: 0, color: borderColor, position: 1, thickness: 1)]
        )
        return SketchLayer(kind: .star, name: name, frame: frame, style: style, points: pts, isClosed: true)
    }

    public static func makeTriangle(
        name: String = "Triangle",
        frame: SketchRect = SketchRect(x: 100, y: 100, width: 110, height: 100),
        fillColor: SketchColor = SketchColor(red: 0.92, green: 0.28, blue: 0.45, alpha: 1.0),
        borderColor: SketchColor = SketchColor(red: 0.75, green: 0.16, blue: 0.32, alpha: 1.0)
    ) -> SketchLayer {
        let pts: [SketchCurvePoint] = [
            SketchCurvePoint(point: CGPoint(x: 0.5, y: 0.0), curveMode: .straight),
            SketchCurvePoint(point: CGPoint(x: 1.0, y: 1.0), curveMode: .straight),
            SketchCurvePoint(point: CGPoint(x: 0.0, y: 1.0), curveMode: .straight)
        ]
        let style = SketchStyle(
            fills: [SketchFill(isEnabled: true, fillType: 0, color: fillColor)],
            borders: [SketchBorder(isEnabled: true, fillType: 0, color: borderColor, position: 1, thickness: 1)]
        )
        return SketchLayer(kind: .triangle, name: name, frame: frame, style: style, points: pts, isClosed: true)
    }
}

// MARK: - Document Archive Container

public struct SketchDocumentArchive: Equatable, Sendable {
    public var meta: [String: JSONValue]
    public var user: [String: JSONValue]
    public var documentJSON: [String: JSONValue]
    public var pages: [SketchLayer]
    public var currentPageIndex: Int
    public var images: [String: Data] // e.g., "images/<sha1>.png" -> Data
    public var previewPNG: Data?

    public init(
        meta: [String: JSONValue] = SketchDocumentArchive.defaultMeta(),
        user: [String: JSONValue] = ["document": .object(["pageListHeight": .number(85), "pageListCollapsed": .number(0)])],
        documentJSON: [String: JSONValue] = [:],
        pages: [SketchLayer] = [
            SketchLayer(
                kind: .page,
                name: "Page 1",
                frame: SketchRect(x: 0, y: 0, width: 0, height: 0),
                layers: [
                    SketchLayer.makeArtboard(
                        name: "Artboard 1",
                        frame: SketchRect(x: 40, y: 40, width: 480, height: 320),
                        layers: [
                            SketchLayer.makeRectangle(
                                name: "Hero Card",
                                frame: SketchRect(x: 40, y: 40, width: 400, height: 240),
                                cornerRadius: 16,
                                fillColor: SketchColor(red: 0.96, green: 0.97, blue: 1.0, alpha: 1.0),
                                borderColor: .sketchBlue
                            ),
                            SketchLayer.makeText(
                                name: "Heading",
                                text: "OpenSketch for macOS",
                                frame: SketchRect(x: 72, y: 80, width: 320, height: 32),
                                fontSize: 24,
                                color: SketchColor(red: 0.1, green: 0.12, blue: 0.18, alpha: 1.0)
                            )
                        ]
                    )
                ]
            )
        ],
        currentPageIndex: Int = 0,
        images: [String: Data] = [:],
        previewPNG: Data? = nil
    ) {
        self.meta = meta
        self.user = user
        self.documentJSON = documentJSON
        self.pages = pages
        self.currentPageIndex = currentPageIndex
        self.images = images
        self.previewPNG = previewPNG
    }

    /// Reconstructs `+[MSArchiveHeader metadataForNewHeader]` (`0xae93c` in `SketchModel`)
    /// Sets `version = 139` (`0x8b`), `compatibilityVersion = 99`, `coeditCompatibilityVersion = 139` (`0x8b`).
    public static func defaultMeta() -> [String: JSONValue] {
        return [
            "commit": .string("ce74b0da7bf09be4d73153fa5cf21922ab1be51d"),
            "pagesAndArtboards": .object([:]),
            "version": .number(139),
            "compatibilityVersion": .number(99),
            "coeditCompatibilityVersion": .number(139),
            "app": .string("com.bohemiancoding.sketch3"),
            "autosaved": .number(0),
            "variant": .string("NONAPPSTORE"),
            "created": .object([
                "commit": .string("ce74b0da7bf09be4d73153fa5cf21922ab1be51d"),
                "appVersion": .string("82.1"),
                "build": .number(137007),
                "app": .string("com.bohemiancoding.sketch3"),
                "compatibilityVersion": .number(99),
                "coeditCompatibilityVersion": .number(139),
                "version": .number(139),
                "variant": .string("NONAPPSTORE")
            ]),
            "saveHistory": .array([.string("NONAPPSTORE.137007")]),
            "appVersion": .string("82.1"),
            "build": .number(137007)
        ]
    }

    /// Finds all `symbolMaster` layers across all pages in the document
    public var allSymbolMasters: [SketchLayer] {
        var masters: [SketchLayer] = []
        func walk(_ layer: SketchLayer) {
            if layer.kind == .symbolMaster {
                masters.append(layer)
            }
            for child in layer.layers {
                walk(child)
            }
        }
        for page in pages {
            walk(page)
        }
        return masters
    }

    public var documentID: String {
        documentJSON["do_objectID"]?.stringValue ?? (pages.first?.do_objectID ?? "default-doc")
    }

    public func symbolMaster(forSymbolID symbolID: String) -> SketchLayer? {
        SketchRenderCache.shared.symbolMaster(forSymbolID: symbolID, in: self)
    }
}
