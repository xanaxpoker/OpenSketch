import Foundation
import zlib

// MARK: - Reader Format & Validation Status (Reconstructed from SketchModel)

/// Matches `+[MSDocumentReader readerForDocumentAtURL:]`
public enum SketchReaderFormat: String, Equatable, Sendable {
    case zippedJSON = "MSDocumentZippedJSONReader"
    case legacySQLite = "MSLegacyDocumentReader"
}

/// Matches `-[MSDocumentZippedJSONReader validate]`
public enum SketchValidationStatus: Int, Equatable, Sendable {
    case valid = 0
    case corruptMetadata = 2        // meta.json or user.json missing
    case legacyUnsupported = 3      // version <= 87
    case newerVersionWarning = 4    // version > 139 && compatibilityVersion <= 139
    case incompatibleNewer = 5      // compatibilityVersion > 139

    public var dialogTitle: String? {
        switch self {
        case .valid:
            return nil
        case .corruptMetadata, .legacyUnsupported:
            return "Unable to Open File"
        case .newerVersionWarning:
            return "Document Created in a Newer Version"
        case .incompatibleNewer:
            return "Incompatible Document Version"
        }
    }

    public var dialogMessage: String? {
        switch self {
        case .valid:
            return nil
        case .corruptMetadata, .legacyUnsupported:
            return "The document may be corrupt or missing some data. Would you like to try to open it anyway?"
        case .newerVersionWarning:
            return "This document was last edited in a newer version of Sketch. Opening it in this version may result in some data being lost."
        case .incompatibleNewer:
            return "This document was created with a newer version of Sketch. Please upgrade Sketch to open this document."
        }
    }

    public var canProceedWithRepairOrConfirmation: Bool {
        switch self {
        case .valid, .corruptMetadata, .legacyUnsupported, .newerVersionWarning:
            return true
        case .incompatibleNewer:
            return false
        }
    }
}

public enum SketchDocumentError: LocalizedError, Equatable {
    case fileNotFound(String)
    case invalidArchive(String)
    case validationFailed(SketchValidationStatus)
    case missingDocumentJSON

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "File not found: \(p)"
        case .invalidArchive(let msg): return "Invalid .sketch archive: \(msg)"
        case .validationFailed(let status): return status.dialogMessage ?? "Validation failed (\(status.rawValue))"
        case .missingDocumentJSON: return "Archive is missing document.json"
        }
    }
}

// MARK: - Pure Swift + zlib PKZIP Reader / Writer (Reconstructing BCJSONZippedDecoder / Encoder)

public struct SketchZipArchive {
    public static func readEntries(from url: URL) throws -> [String: Data] {
        let data = try Data(contentsOf: url)
        return try readEntries(from: data)
    }

    public static func readEntries(from data: Data) throws -> [String: Data] {
        guard data.count >= 22 else {
            throw SketchDocumentError.invalidArchive("Archive too small (\(data.count) bytes)")
        }

        return try data.withUnsafeBytes { (rawBuf: UnsafeRawBufferPointer) -> [String: Data] in
            guard let bytes = rawBuf.bindMemory(to: UInt8.self).baseAddress else {
                return [:]
            }
            let count = rawBuf.count

            // Find End of Central Directory (EOCD) signature 0x06054b50
            var eocdOffset = -1
            let minOffset = max(0, count - 65557)
            for i in stride(from: count - 22, through: minOffset, by: -1) {
                if bytes[i] == 0x50 && bytes[i+1] == 0x4b && bytes[i+2] == 0x05 && bytes[i+3] == 0x06 {
                    eocdOffset = i
                    break
                }
            }
            guard eocdOffset >= 0 else {
                throw SketchDocumentError.invalidArchive("Missing PKZIP End of Central Directory")
            }

            let totalEntries = Int(readUInt16Ptr(bytes, eocdOffset + 10))
            let cdOffset = Int(readUInt32Ptr(bytes, eocdOffset + 16))

            var entries: [String: Data] = [:]
            entries.reserveCapacity(totalEntries)
            var pos = cdOffset
            for _ in 0..<totalEntries {
                guard pos + 46 <= count,
                      bytes[pos] == 0x50, bytes[pos+1] == 0x4b, bytes[pos+2] == 0x01, bytes[pos+3] == 0x02 else {
                    break
                }
                let method = readUInt16Ptr(bytes, pos + 10)
                let compSize = Int(readUInt32Ptr(bytes, pos + 20))
                let uncompSize = Int(readUInt32Ptr(bytes, pos + 24))
                let nameLen = Int(readUInt16Ptr(bytes, pos + 28))
                let extraLen = Int(readUInt16Ptr(bytes, pos + 30))
                let commentLen = Int(readUInt16Ptr(bytes, pos + 32))
                let localHeaderOffset = Int(readUInt32Ptr(bytes, pos + 42))

                let namePtr = UnsafeBufferPointer(start: bytes.advanced(by: pos + 46), count: nameLen)
                let name = String(bytes: namePtr, encoding: .utf8) ?? ""
                pos += 46 + nameLen + extraLen + commentLen

                if name.hasSuffix("/") { continue }

                guard localHeaderOffset + 30 <= count,
                      bytes[localHeaderOffset] == 0x50,
                      bytes[localHeaderOffset+1] == 0x4b,
                      bytes[localHeaderOffset+2] == 0x03,
                      bytes[localHeaderOffset+3] == 0x04 else {
                    continue
                }
                let localNameLen = Int(readUInt16Ptr(bytes, localHeaderOffset + 26))
                let localExtraLen = Int(readUInt16Ptr(bytes, localHeaderOffset + 28))
                let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
                guard dataStart + compSize <= count else { continue }

                let slice = data.subdata(in: dataStart..<(dataStart + compSize))
                if method == 0 {
                    entries[name] = slice
                } else if method == 8 {
                    entries[name] = try inflateRaw(slice, expectedSize: uncompSize)
                }
            }
            return entries
        }
    }

    public static func writeEntries(_ entries: [String: Data], to url: URL) throws {
        let data = try writeEntries(entries)
        try data.write(to: url, options: .atomic)
    }

    public static func writeEntries(_ entries: [String: Data]) throws -> Data {
        var out = Data()
        var centralDirectory = Data()
        let sortedNames = entries.keys.sorted()

        for name in sortedNames {
            guard let rawData = entries[name],
                  let nameData = name.data(using: .utf8) else { continue }
            let localHeaderOffset = UInt32(out.count)
            let crc: UInt32 = rawData.withUnsafeBytes { buf in
                guard let base = buf.bindMemory(to: Bytef.self).baseAddress else { return 0 }
                return UInt32(crc32(0, base, uInt(buf.count)))
            }
            let isAlreadyCompressed = name.hasPrefix("images/") || name.hasPrefix("previews/") || name.hasSuffix(".png")
            let compressed = isAlreadyCompressed ? rawData : (try deflateRaw(rawData))
            let useStore = isAlreadyCompressed || (compressed.count >= rawData.count)
            let payload = useStore ? rawData : compressed
            let method: UInt16 = useStore ? 0 : 8

            // Local file header (0x04034b50)
            appendUInt32(&out, 0x04034b50)
            appendUInt16(&out, 20) // version needed
            appendUInt16(&out, 0)  // flags
            appendUInt16(&out, method)
            appendUInt16(&out, 0)  // mod time
            appendUInt16(&out, 0)  // mod date
            appendUInt32(&out, crc)
            appendUInt32(&out, UInt32(payload.count))
            appendUInt32(&out, UInt32(rawData.count))
            appendUInt16(&out, UInt16(nameData.count))
            appendUInt16(&out, 0)  // extra len
            out.append(nameData)
            out.append(payload)

            // Central directory header (0x02014b50)
            appendUInt32(&centralDirectory, 0x02014b50)
            appendUInt16(&centralDirectory, 20) // version made by
            appendUInt16(&centralDirectory, 20) // version needed
            appendUInt16(&centralDirectory, 0)  // flags
            appendUInt16(&centralDirectory, method)
            appendUInt16(&centralDirectory, 0)  // mod time
            appendUInt16(&centralDirectory, 0)  // mod date
            appendUInt32(&centralDirectory, crc)
            appendUInt32(&centralDirectory, UInt32(payload.count))
            appendUInt32(&centralDirectory, UInt32(rawData.count))
            appendUInt16(&centralDirectory, UInt16(nameData.count))
            appendUInt16(&centralDirectory, 0)  // extra len
            appendUInt16(&centralDirectory, 0)  // comment len
            appendUInt16(&centralDirectory, 0)  // disk start
            appendUInt16(&centralDirectory, 0)  // internal attr
            appendUInt32(&centralDirectory, 0)  // external attr
            appendUInt32(&centralDirectory, localHeaderOffset)
            centralDirectory.append(nameData)
        }

        let cdOffset = UInt32(out.count)
        out.append(centralDirectory)

        // End of Central Directory (0x06054b50)
        appendUInt32(&out, 0x06054b50)
        appendUInt16(&out, 0)
        appendUInt16(&out, 0)
        appendUInt16(&out, UInt16(sortedNames.count))
        appendUInt16(&out, UInt16(sortedNames.count))
        appendUInt32(&out, UInt32(centralDirectory.count))
        appendUInt32(&out, cdOffset)
        appendUInt16(&out, 0)

        return out
    }

    @inline(__always)
    private static func readUInt16Ptr(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    @inline(__always)
    private static func readUInt32Ptr(_ bytes: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        if compressed.isEmpty { return Data() }
        var stream = z_stream()
        let status = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw SketchDocumentError.invalidArchive("zlib inflateInit2 failed (\(status))")
        }
        defer { inflateEnd(&stream) }

        var output = Data(count: max(expectedSize, compressed.count * 2, 4096))
        var totalOut = 0

        try compressed.withUnsafeBytes { (inPtr: UnsafeRawBufferPointer) in
            guard let baseIn = inPtr.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseIn)
            stream.avail_in = uInt(compressed.count)

            while true {
                if totalOut >= output.count {
                    output.count *= 2
                }
                let currentCap = output.count
                let res: Int32 = output.withUnsafeMutableBytes { outPtr in
                    let baseOut = outPtr.bindMemory(to: Bytef.self).baseAddress!
                    stream.next_out = baseOut.advanced(by: totalOut)
                    stream.avail_out = uInt(currentCap - totalOut)
                    return zlib.inflate(&stream, Z_SYNC_FLUSH)
                }
                totalOut = Int(stream.total_out)
                if res == Z_STREAM_END {
                    break
                } else if res != Z_OK {
                    throw SketchDocumentError.invalidArchive("zlib inflate error (\(res))")
                }
                if stream.avail_in == 0 && stream.avail_out > 0 {
                    break
                }
            }
        }
        output.count = totalOut
        return output
    }

    private static func deflateRaw(_ raw: Data) throws -> Data {
        if raw.isEmpty { return Data() }
        var stream = z_stream()
        let status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw SketchDocumentError.invalidArchive("zlib deflateInit2 failed (\(status))")
        }
        defer { deflateEnd(&stream) }

        var output = Data(count: max(raw.count + 64, 1024))
        raw.withUnsafeBytes { (inPtr: UnsafeRawBufferPointer) in
            guard let baseIn = inPtr.bindMemory(to: Bytef.self).baseAddress else { return }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseIn)
            stream.avail_in = uInt(raw.count)

            output.withUnsafeMutableBytes { outPtr in
                let baseOut = outPtr.bindMemory(to: Bytef.self).baseAddress!
                stream.next_out = baseOut
                stream.avail_out = uInt(outPtr.count)
                _ = zlib.deflate(&stream, Z_FINISH)
            }
        }
        output.count = Int(stream.total_out)
        return output
    }
}

// MARK: - Sketch Document Reader & Writer (Reconstructed from MSDocumentReader / MSDocumentZippedJSONReader / MSDocumentWriter)

public enum SketchDocumentIO {
    public static let currentArchiveVersion = 139 // 0x8b in MSDocumentZippedJSONReader -open:
    public static let minimumSupportedVersion = 88 // version <= 87 returns status 3
    public static let defaultCompatibilityVersion = 99

    /// Reconstructs `+[MSDocumentReader readerForDocumentAtURL:]`
    /// Reads the first 4 bytes (`+first4bytesOfFileAtURL:`):
    /// - `PK\x03\x04` -> `.zippedJSON`
    /// - `SQLi` or anything else -> `.legacySQLite`
    public static func detectFormat(at url: URL) throws -> SketchReaderFormat {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        if magic.count == 4 && magic[0] == 0x50 && magic[1] == 0x4b && magic[2] == 0x03 && magic[3] == 0x04 {
            return .zippedJSON
        }
        return .legacySQLite
    }

    /// Reconstructs `-[MSDocumentZippedJSONReader validate]`
    public static func validate(entries: [String: Data]) -> SketchValidationStatus {
        guard let metaData = entries["meta.json"],
              let _ = entries["user.json"],
              let metaObj = JSONValue.parseObject(from: metaData) else {
            return .corruptMetadata // status 2
        }
        let compatVersion = metaObj["compatibilityVersion"]?.intValue ?? 0
        if compatVersion > currentArchiveVersion {
            return .incompatibleNewer // status 5
        }
        let version = metaObj["version"]?.intValue ?? 0
        if version > currentArchiveVersion {
            return .newerVersionWarning // status 4
        }
        if version <= 87 {
            return .legacyUnsupported // status 3
        }
        return .valid // status 0
    }

    /// Safe share lookup that fixes the Sketch 82.1 bug discovered in `-[MSDocumentZippedJSONReader shareFrom:at:]`
    /// (where `nil` data passed to `NSJSONSerialization` threw an uncaught exception).
    public static func shareInfo(in entries: [String: Data]) -> JSONValue? {
        func extractShare(subpath: String, key: String) -> JSONValue? {
            guard let raw = entries[subpath],
                  let dict = JSONValue.parseObject(from: raw),
                  let container = dict[key]?.objectValue,
                  let share = container["cloudShare"] else {
                return nil
            }
            return share
        }
        return extractShare(subpath: "document.json", key: "documentState")
            ?? extractShare(subpath: "user.json", key: "document")
    }

    /// Opens and decodes a `.sketch` file at `url`, optionally repairing missing/corrupt metadata (`-repair`).
    public static func readDocument(
        at url: URL,
        allowRepairOrNewer: Bool = true
    ) throws -> (document: SketchDocumentArchive, validation: SketchValidationStatus, wasRepaired: Bool) {
        let entries = try SketchZipArchive.readEntries(from: url)
        return try readDocument(fromEntries: entries, allowRepairOrNewer: allowRepairOrNewer)
    }

    public static func readDocument(
        fromEntries entries: [String: Data],
        allowRepairOrNewer: Bool = true
    ) throws -> (document: SketchDocumentArchive, validation: SketchValidationStatus, wasRepaired: Bool) {
        let status = validate(entries: entries)
        if status == .incompatibleNewer || (!allowRepairOrNewer && status != .valid) {
            throw SketchDocumentError.validationFailed(status)
        }

        var wasRepaired = false
        let metaDict: [String: JSONValue]
        let userDict: [String: JSONValue]

        if status == .corruptMetadata {
            // Reconstructs `-[MSDocumentZippedJSONReader repair]`
            metaDict = (entries["meta.json"].flatMap { JSONValue.parseObject(from: $0) })
                ?? SketchDocumentArchive.defaultMeta()
            userDict = (entries["user.json"].flatMap { JSONValue.parseObject(from: $0) })
                ?? [:]
            wasRepaired = true
        } else {
            metaDict = (entries["meta.json"].flatMap { JSONValue.parseObject(from: $0) })
                ?? SketchDocumentArchive.defaultMeta()
            userDict = (entries["user.json"].flatMap { JSONValue.parseObject(from: $0) })
                ?? [:]
        }

        guard let docData = entries["document.json"],
              let docDict = JSONValue.parseObject(from: docData) else {
            throw SketchDocumentError.missingDocumentJSON
        }

        let currentPageIndex = docDict["currentPageIndex"]?.intValue ?? 0

        // Resolve `pages` array of `MSJSONFileReference` (`_ref: "pages/<UUID>"`)
        var decodedPages: [SketchLayer] = []
        if let pageRefs = docDict["pages"]?.arrayValue {
            for refVal in pageRefs {
                guard let refObj = refVal.objectValue,
                      let refPath = refObj["_ref"]?.stringValue else { continue }
                let jsonPath = refPath.hasSuffix(".json") ? refPath : "\(refPath).json"
                if let pageData = entries[jsonPath],
                   let pageJSON = JSONValue.parseObject(from: pageData) {
                    decodedPages.append(decodeLayer(from: pageJSON))
                }
            }
        }

        // Also fallback to any `pages/*.json` if `docDict["pages"]` was empty
        if decodedPages.isEmpty {
            for key in entries.keys.sorted() where key.hasPrefix("pages/") && key.hasSuffix(".json") {
                if let pageData = entries[key],
                   let pageJSON = JSONValue.parseObject(from: pageData) {
                    decodedPages.append(decodeLayer(from: pageJSON))
                }
            }
        }

        var images: [String: Data] = [:]
        for (k, v) in entries where k.hasPrefix("images/") {
            images[k] = v
        }
        let preview = entries["previews/preview.png"]

        let archive = SketchDocumentArchive(
            meta: metaDict,
            user: userDict,
            documentJSON: docDict,
            pages: decodedPages,
            currentPageIndex: min(max(0, currentPageIndex), max(0, decodedPages.count - 1)),
            images: images,
            previewPNG: preview
        )
        return (archive, status, wasRepaired)
    }

    /// Reconstructs `-[MSDocumentWriter writeDocumentData:isAutosave:includePreview:error:]`
    /// and `MSJSONZippedArchiver`
    public static func writeDocument(
        _ doc: SketchDocumentArchive,
        to url: URL,
        isAutosave: Bool = false
    ) throws {
        let entries = try encodeDocumentEntries(doc, isAutosave: isAutosave)
        try SketchZipArchive.writeEntries(entries, to: url)
    }

    public static func encodeDocumentEntries(
        _ doc: SketchDocumentArchive,
        isAutosave: Bool = false
    ) throws -> [String: Data] {
        var entries: [String: Data] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        // 1. Encode each page to `pages/<do_objectID>.json` and build `MSJSONFileReference` array
        var pageRefs: [JSONValue] = []
        var pagesAndArtboardsMeta: [String: JSONValue] = [:]

        for page in doc.pages {
            let pageID = page.do_objectID
            let pageSubpath = "pages/\(pageID).json"
            let pageObj = encodeLayer(page)
            entries[pageSubpath] = try encoder.encode(JSONValue.object(pageObj))

            pageRefs.append(.object([
                "_class": .string("MSJSONFileReference"),
                "_ref_class": .string("MSImmutablePage"),
                "_ref": .string("pages/\(pageID)")
            ]))

            var artboardsMeta: [String: JSONValue] = [:]
            for child in page.layers where child.kind == .artboard || child.kind == .symbolMaster {
                artboardsMeta[child.do_objectID] = .object([
                    "name": .string(child.name)
                ])
            }
            pagesAndArtboardsMeta[pageID] = .object([
                "name": .string(page.name),
                "artboards": .object(artboardsMeta)
            ])
        }

        // 2. Encode `document.json`
        var docObj = doc.documentJSON
        if docObj["_class"] == nil { docObj["_class"] = .string("document") }
        if docObj["do_objectID"] == nil { docObj["do_objectID"] = .string(UUID().uuidString.uppercased()) }
        if docObj["colorSpace"] == nil { docObj["colorSpace"] = .number(0) }
        docObj["currentPageIndex"] = .number(Double(doc.currentPageIndex))
        docObj["pages"] = .array(pageRefs)
        if docObj["assets"] == nil {
            docObj["assets"] = .object([
                "_class": .string("assetCollection"),
                "do_objectID": .string(UUID().uuidString.uppercased()),
                "colors": .array([]),
                "gradients": .array([]),
                "images": .array([]),
                "colorAssets": .array([]),
                "gradientAssets": .array([]),
                "exportPresets": .array([]),
                "imageCollection": .object(["_class": .string("imageCollection"), "images": .object([:])])
            ])
        }
        if docObj["layerStyles"] == nil {
            docObj["layerStyles"] = .object(["_class": .string("sharedStyleContainer"), "do_objectID": .string(UUID().uuidString.uppercased()), "objects": .array([])])
        }
        if docObj["layerTextStyles"] == nil {
            docObj["layerTextStyles"] = .object(["_class": .string("sharedTextStyleContainer"), "do_objectID": .string(UUID().uuidString.uppercased()), "objects": .array([])])
        }
        if docObj["layerSymbols"] == nil {
            docObj["layerSymbols"] = .object(["_class": .string("symbolContainer"), "do_objectID": .string(UUID().uuidString.uppercased()), "objects": .array([])])
        }
        if docObj["documentState"] == nil {
            docObj["documentState"] = .object(["_class": .string("documentState")])
        }
        entries["document.json"] = try encoder.encode(JSONValue.object(docObj))

        // 3. Encode `user.json`
        var userObj = doc.user
        if userObj["document"] == nil {
            userObj["document"] = .object(["pageListHeight": .number(85), "pageListCollapsed": .number(0)])
        }
        entries["user.json"] = try encoder.encode(JSONValue.object(userObj))

        // 4. Encode `meta.json` (matching MSDocumentWriter lines 70-107)
        var metaObj = doc.meta.isEmpty ? SketchDocumentArchive.defaultMeta() : doc.meta
        metaObj["version"] = .number(Double(currentArchiveVersion))
        if metaObj["compatibilityVersion"] == nil {
            metaObj["compatibilityVersion"] = .number(Double(defaultCompatibilityVersion))
        }
        metaObj["coeditCompatibilityVersion"] = .number(Double(currentArchiveVersion))
        metaObj["autosaved"] = .number(isAutosave ? 1 : 0)
        metaObj["pagesAndArtboards"] = .object(pagesAndArtboardsMeta)
        var saveHistory = metaObj["saveHistory"]?.arrayValue ?? []
        let tag = JSONValue.string("NONAPPSTORE.137007")
        if !saveHistory.contains(tag) {
            saveHistory.append(tag)
        }
        metaObj["saveHistory"] = .array(saveHistory)
        entries["meta.json"] = try encoder.encode(JSONValue.object(metaObj))

        // 5. Encode images and preview
        for (path, data) in doc.images {
            entries[path] = data
        }
        if let preview = doc.previewPNG {
            entries["previews/preview.png"] = preview
        }

        return entries
    }

    // MARK: - Layer & Style JSON Mapping

    public static func decodeLayer(from dict: [String: JSONValue]) -> SketchLayer {
        let cls = dict["_class"]?.stringValue ?? "group"
        let id = dict["do_objectID"]?.stringValue ?? UUID().uuidString.uppercased()
        let name = dict["name"]?.stringValue ?? cls
        let kind = SketchLayerKind(rawValue: cls) ?? .group

        var frame = SketchRect()
        if let fObj = dict["frame"]?.objectValue {
            frame.x = fObj["x"]?.doubleValue ?? 0
            frame.y = fObj["y"]?.doubleValue ?? 0
            frame.width = fObj["width"]?.doubleValue ?? 0
            frame.height = fObj["height"]?.doubleValue ?? 0
            frame.constrainProportions = fObj["constrainProportions"]?.boolValue ?? false
        }

        let style = decodeStyle(from: dict["style"]?.objectValue)
        let childLayers = (dict["layers"]?.arrayValue ?? []).compactMap { $0.objectValue }.map { decodeLayer(from: $0) }

        var points: [SketchCurvePoint] = []
        if let ptsArr = dict["points"]?.arrayValue {
            for ptVal in ptsArr {
                guard let ptObj = ptVal.objectValue else { continue }
                var cp = SketchCurvePoint(point: .zero)
                cp.point = ptObj["point"]?.stringValue ?? "{0, 0}"
                cp.curveFrom = ptObj["curveFrom"]?.stringValue ?? cp.point
                cp.curveTo = ptObj["curveTo"]?.stringValue ?? cp.point
                cp.hasCurveFrom = ptObj["hasCurveFrom"]?.boolValue ?? false
                cp.hasCurveTo = ptObj["hasCurveTo"]?.boolValue ?? false
                cp.curveMode = ptObj["curveMode"]?.intValue ?? 1
                cp.cornerRadius = ptObj["cornerRadius"]?.doubleValue ?? 0
                points.append(cp)
            }
        }

        var groupLayout: SketchGroupLayout? = nil
        if let glObj = dict["groupLayout"]?.objectValue {
            let glClass = glObj["_class"]?.stringValue ?? "MSImmutableFreeformGroupLayout"
            groupLayout = SketchGroupLayout(
                isSmartLayout: glClass == "MSImmutableInferredGroupLayout",
                axis: glObj["axis"]?.intValue ?? 0,
                layoutAnchor: glObj["layoutAnchor"]?.intValue ?? 0,
                minSize: glObj["minSize"]?.doubleValue ?? 0,
                maxSize: glObj["maxSize"]?.doubleValue ?? 0
            )
        }

        var attributedString: SketchAttributedString? = nil
        if let asObj = dict["attributedString"]?.objectValue {
            let str = asObj["string"]?.stringValue ?? ""
            var attrs: [SketchStringAttribute] = []
            if let attrArr = asObj["attributes"]?.arrayValue {
                for aVal in attrArr {
                    guard let aObj = aVal.objectValue else { continue }
                    let loc = aObj["location"]?.intValue ?? 0
                    let len = aObj["length"]?.intValue ?? (str as NSString).length
                    let inner = aObj["attributes"]?.objectValue ?? [:]
                    let fontObj = inner["MSAttributedStringFontAttribute"]?.objectValue?["attributes"]?.objectValue
                    let fontName = fontObj?["name"]?.stringValue ?? "HelveticaNeue"
                    let fontSize = fontObj?["size"]?.doubleValue ?? 14
                    let colorObj = inner["MSAttributedStringColorAttribute"]?.objectValue
                    let color = decodeColor(from: colorObj, default: .black)
                    let paraObj = inner["paragraphStyle"]?.objectValue
                    let align = paraObj?["alignment"]?.intValue ?? 0
                    let kerning = inner["kerning"]?.doubleValue
                    attrs.append(SketchStringAttribute(
                        location: loc,
                        length: len,
                        fontName: fontName,
                        fontSize: fontSize,
                        color: color,
                        alignment: align,
                        kerning: kerning
                    ))
                }
            }
            attributedString = SketchAttributedString(string: str, attributes: attrs)
        }

        var overrideValues: [SketchOverrideValue] = []
        if let ovArr = dict["overrideValues"]?.arrayValue {
            for ovVal in ovArr {
                guard let ovObj = ovVal.objectValue,
                      let ovName = ovObj["overrideName"]?.stringValue else { continue }
                let valStr = ovObj["value"]?.stringValue ?? ""
                overrideValues.append(SketchOverrideValue(overrideName: ovName, value: valStr))
            }
        }

        var overrideProperties: [SketchOverrideProperty] = []
        if let opArr = dict["overrideProperties"]?.arrayValue {
            for opVal in opArr {
                guard let opObj = opVal.objectValue,
                      let opName = opObj["overrideName"]?.stringValue else { continue }
                let canOv = opObj["canOverride"]?.boolValue ?? true
                overrideProperties.append(SketchOverrideProperty(overrideName: opName, canOverride: canOv))
            }
        }

        var exportFormats: [SketchExportFormat] = []
        if let eoObj = dict["exportOptions"]?.objectValue,
           let efArr = eoObj["exportFormats"]?.arrayValue {
            for efVal in efArr {
                guard let efObj = efVal.objectValue else { continue }
                exportFormats.append(SketchExportFormat(
                    scale: efObj["scale"]?.doubleValue ?? 1.0,
                    fileFormat: efObj["fileFormat"]?.stringValue ?? "png",
                    name: efObj["name"]?.stringValue
                ))
            }
        }

        var layer = SketchLayer(
            kind: kind,
            id: id,
            name: name,
            frame: frame,
            style: style,
            layers: childLayers,
            points: points,
            isClosed: dict["isClosed"]?.boolValue ?? true,
            fixedRadius: dict["fixedRadius"]?.doubleValue ?? 0,
            booleanOperation: SketchBooleanOperation(rawValue: dict["booleanOperation"]?.intValue ?? -1) ?? .none,
            attributedString: attributedString,
            symbolID: dict["symbolID"]?.stringValue,
            overrideValues: overrideValues,
            groupLayout: groupLayout,
            hasBackgroundColor: dict["hasBackgroundColor"]?.boolValue ?? false,
            backgroundColor: dict["backgroundColor"]?.objectValue.map { decodeColor(from: $0, default: .white) }
        )
        layer._class = cls
        layer.nameIsFixed = dict["nameIsFixed"]?.boolValue ?? false
        layer.isVisible = dict["isVisible"]?.boolValue ?? true
        layer.isLocked = dict["isLocked"]?.boolValue ?? false
        layer.isFlippedHorizontal = dict["isFlippedHorizontal"]?.boolValue ?? false
        layer.isFlippedVertical = dict["isFlippedVertical"]?.boolValue ?? false
        layer.isFixedToViewport = dict["isFixedToViewport"]?.boolValue ?? false
        layer.rotation = dict["rotation"]?.doubleValue ?? 0
        layer.resizingConstraint = dict["resizingConstraint"]?.intValue ?? 63
        layer.resizingType = dict["resizingType"]?.intValue ?? 0
        layer.hasClippingMask = dict["hasClippingMask"]?.boolValue ?? false
        layer.clippingMaskMode = dict["clippingMaskMode"]?.intValue ?? 0
        layer.shouldBreakMaskChain = dict["shouldBreakMaskChain"]?.boolValue ?? false
        layer.layerListExpandedType = dict["layerListExpandedType"]?.intValue ?? 0
        layer.hasClickThrough = dict["hasClickThrough"]?.boolValue ?? false
        layer.includeBackgroundColorInExport = dict["includeBackgroundColorInExport"]?.boolValue ?? true
        layer.edited = dict["edited"]?.boolValue ?? false
        layer.pointRadiusBehaviour = dict["pointRadiusBehaviour"]?.intValue ?? 1
        layer.textBehaviour = dict["textBehaviour"]?.intValue ?? 0
        layer.overrideProperties = overrideProperties
        layer.allowsOverrides = dict["allowsOverrides"]?.boolValue ?? true
        layer.scale = dict["scale"]?.doubleValue ?? 1.0
        layer.horizontalSpacing = dict["horizontalSpacing"]?.doubleValue ?? 0
        layer.verticalSpacing = dict["verticalSpacing"]?.doubleValue ?? 0
        layer.exportOptions = SketchExportOptions(
            exportFormats: exportFormats,
            shouldTrim: dict["exportOptions"]?.objectValue?["shouldTrim"]?.boolValue ?? false
        )
        if let imgObj = dict["image"]?.objectValue,
           let ref = imgObj["_ref"]?.stringValue {
            layer.imageRef = SketchFileReference(
                refClass: imgObj["_ref_class"]?.stringValue ?? "MSImageData",
                ref: ref
            )
        }
        var strippedRaw = dict
        for heavyKey in ["layers", "points", "style", "frame", "attributedString", "overrideValues", "overrideProperties", "exportOptions"] {
            strippedRaw.removeValue(forKey: heavyKey)
        }
        layer.rawJSON = strippedRaw
        return layer
    }

    public static func decodeStyle(from dict: [String: JSONValue]?) -> SketchStyle {
        guard let dict = dict else { return SketchStyle() }
        let id = dict["do_objectID"]?.stringValue ?? UUID().uuidString.uppercased()

        let fills: [SketchFill] = (dict["fills"]?.arrayValue ?? []).compactMap { val in
            guard let f = val.objectValue else { return nil }
            var fill = SketchFill(
                isEnabled: f["isEnabled"]?.boolValue ?? true,
                fillType: f["fillType"]?.intValue ?? 0,
                color: decodeColor(from: f["color"]?.objectValue, default: .defaultFill),
                gradient: decodeGradient(from: f["gradient"]?.objectValue),
                contextSettings: decodeContextSettings(from: f["contextSettings"]?.objectValue)
            )
            fill.noiseIndex = f["noiseIndex"]?.intValue ?? 0
            fill.noiseIntensity = f["noiseIntensity"]?.doubleValue ?? 0
            fill.patternFillType = f["patternFillType"]?.intValue ?? 1
            fill.patternTileScale = f["patternTileScale"]?.doubleValue ?? 1
            return fill
        }

        let borders: [SketchBorder] = (dict["borders"]?.arrayValue ?? []).compactMap { val in
            guard let b = val.objectValue else { return nil }
            var border = SketchBorder(
                isEnabled: b["isEnabled"]?.boolValue ?? true,
                fillType: b["fillType"]?.intValue ?? 0,
                color: decodeColor(from: b["color"]?.objectValue, default: .defaultBorder),
                position: b["position"]?.intValue ?? 1,
                thickness: b["thickness"]?.doubleValue ?? 1
            )
            border.gradient = decodeGradient(from: b["gradient"]?.objectValue)
            border.contextSettings = decodeContextSettings(from: b["contextSettings"]?.objectValue)
            return border
        }

        let shadows: [SketchShadow] = (dict["shadows"]?.arrayValue ?? []).compactMap { val in
            decodeShadow(from: val.objectValue, isInner: false)
        }

        let innerShadows: [SketchShadow] = (dict["innerShadows"]?.arrayValue ?? []).compactMap { val in
            decodeShadow(from: val.objectValue, isInner: true)
        }

        var borderOptions = SketchBorderOptions()
        if let bo = dict["borderOptions"]?.objectValue {
            borderOptions.isEnabled = bo["isEnabled"]?.boolValue ?? true
            borderOptions.dashPattern = (bo["dashPattern"]?.arrayValue ?? []).compactMap(\.doubleValue)
            borderOptions.lineCapStyle = bo["lineCapStyle"]?.intValue ?? 0
            borderOptions.lineJoinStyle = bo["lineJoinStyle"]?.intValue ?? 0
        }

        var blur = SketchBlur()
        if let bl = dict["blur"]?.objectValue {
            blur.isEnabled = bl["isEnabled"]?.boolValue ?? false
            blur.center = bl["center"]?.stringValue ?? "{0.5, 0.5}"
            blur.motionAngle = bl["motionAngle"]?.doubleValue ?? 0
            blur.radius = bl["radius"]?.doubleValue ?? 10
            blur.saturation = bl["saturation"]?.doubleValue ?? 1
            blur.type = bl["type"]?.intValue ?? 0
        }

        var style = SketchStyle(
            do_objectID: id,
            fills: fills,
            borders: borders,
            shadows: shadows,
            innerShadows: innerShadows,
            borderOptions: borderOptions,
            blur: blur,
            contextSettings: decodeContextSettings(from: dict["contextSettings"]?.objectValue),
            windingRule: dict["windingRule"]?.intValue ?? 1
        )
        style.miterLimit = dict["miterLimit"]?.doubleValue ?? 10
        style.startMarkerType = dict["startMarkerType"]?.intValue ?? 0
        style.endMarkerType = dict["endMarkerType"]?.intValue ?? 0
        return style
    }

    private static func decodeColor(from dict: [String: JSONValue]?, default fallback: SketchColor) -> SketchColor {
        guard let dict = dict else { return fallback }
        return SketchColor(
            red: dict["red"]?.doubleValue ?? fallback.red,
            green: dict["green"]?.doubleValue ?? fallback.green,
            blue: dict["blue"]?.doubleValue ?? fallback.blue,
            alpha: dict["alpha"]?.doubleValue ?? fallback.alpha
        )
    }

    private static func decodeGradient(from dict: [String: JSONValue]?) -> SketchGradient? {
        guard let dict = dict else { return nil }
        let stops: [SketchGradientStop] = (dict["stops"]?.arrayValue ?? []).compactMap { sVal in
            guard let sObj = sVal.objectValue else { return nil }
            return SketchGradientStop(
                color: decodeColor(from: sObj["color"]?.objectValue, default: .black),
                position: sObj["position"]?.doubleValue ?? 0
            )
        }
        var grad = SketchGradient(
            gradientType: dict["gradientType"]?.intValue ?? 0,
            stops: stops,
            elipseLength: dict["elipseLength"]?.doubleValue ?? 1
        )
        grad.from = dict["from"]?.stringValue ?? "{0.5, 0}"
        grad.to = dict["to"]?.stringValue ?? "{0.5, 1}"
        return grad
    }

    private static func decodeShadow(from dict: [String: JSONValue]?, isInner: Bool) -> SketchShadow? {
        guard let dict = dict else { return nil }
        var sh = SketchShadow(
            isEnabled: dict["isEnabled"]?.boolValue ?? true,
            color: decodeColor(from: dict["color"]?.objectValue, default: SketchColor(red: 0, green: 0, blue: 0, alpha: 0.25)),
            offsetX: dict["offsetX"]?.doubleValue ?? 0,
            offsetY: dict["offsetY"]?.doubleValue ?? 2,
            blurRadius: dict["blurRadius"]?.doubleValue ?? 4,
            spread: dict["spread"]?.doubleValue ?? 0,
            isInner: isInner
        )
        sh.contextSettings = decodeContextSettings(from: dict["contextSettings"]?.objectValue)
        return sh
    }

    private static func decodeContextSettings(from dict: [String: JSONValue]?) -> SketchGraphicsContextSettings {
        guard let dict = dict else { return SketchGraphicsContextSettings() }
        return SketchGraphicsContextSettings(
            blendMode: dict["blendMode"]?.intValue ?? 0,
            opacity: dict["opacity"]?.doubleValue ?? 1.0
        )
    }

    public static func encodeLayer(_ layer: SketchLayer) -> [String: JSONValue] {
        var obj = layer.rawJSON
        obj["_class"] = .string(layer._class)
        obj["do_objectID"] = .string(layer.do_objectID)
        obj["name"] = .string(layer.name)
        obj["nameIsFixed"] = .bool(layer.nameIsFixed)
        obj["isVisible"] = .bool(layer.isVisible)
        obj["isLocked"] = .bool(layer.isLocked)
        obj["isFlippedHorizontal"] = .bool(layer.isFlippedHorizontal)
        obj["isFlippedVertical"] = .bool(layer.isFlippedVertical)
        obj["isFixedToViewport"] = .bool(layer.isFixedToViewport)
        obj["rotation"] = .number(layer.rotation)
        obj["booleanOperation"] = .number(Double(layer.booleanOperation.rawValue))
        obj["resizingConstraint"] = .number(Double(layer.resizingConstraint))
        obj["resizingType"] = .number(Double(layer.resizingType))
        obj["hasClippingMask"] = .bool(layer.hasClippingMask)
        obj["clippingMaskMode"] = .number(Double(layer.clippingMaskMode))
        obj["shouldBreakMaskChain"] = .bool(layer.shouldBreakMaskChain)
        obj["layerListExpandedType"] = .number(Double(layer.layerListExpandedType))

        obj["frame"] = .object([
            "_class": .string("rect"),
            "constrainProportions": .bool(layer.frame.constrainProportions),
            "x": .number(layer.frame.x),
            "y": .number(layer.frame.y),
            "width": .number(layer.frame.width),
            "height": .number(layer.frame.height)
        ])

        obj["style"] = .object(encodeStyle(layer.style))

        obj["exportOptions"] = .object([
            "_class": .string("exportOptions"),
            "includedLayerIds": .array(layer.exportOptions.includedLayerIds.map { .string($0) }),
            "layerOptions": .number(Double(layer.exportOptions.layerOptions)),
            "shouldTrim": .bool(layer.exportOptions.shouldTrim),
            "exportFormats": .array(layer.exportOptions.exportFormats.map { ef in
                .object([
                    "_class": .string("exportFormat"),
                    "absoluteSize": .number(ef.absoluteSize),
                    "fileFormat": .string(ef.fileFormat),
                    "name": .string(ef.name ?? ""),
                    "namingScheme": .number(Double(ef.namingScheme)),
                    "scale": .number(ef.scale),
                    "visibleScaleType": .number(Double(ef.visibleScaleType))
                ])
            })
        ])

        if !layer.layers.isEmpty || [.page, .artboard, .symbolMaster, .group, .shapeGroup].contains(layer.kind) {
            obj["layers"] = .array(layer.layers.map { .object(encodeLayer($0)) })
            obj["hasClickThrough"] = .bool(layer.hasClickThrough)
        }

        if let gl = layer.groupLayout {
            var glDict: [String: JSONValue] = ["_class": .string(gl._class)]
            if gl.isSmartLayout {
                glDict["axis"] = .number(Double(gl.axis ?? 0))
                glDict["layoutAnchor"] = .number(Double(gl.layoutAnchor ?? 0))
                glDict["minSize"] = .number(gl.minSize ?? 0)
                glDict["maxSize"] = .number(gl.maxSize ?? 0)
            }
            obj["groupLayout"] = .object(glDict)
        }

        if layer.kind == .artboard || layer.kind == .symbolMaster {
            obj["hasBackgroundColor"] = .bool(layer.hasBackgroundColor)
            obj["includeBackgroundColorInExport"] = .bool(layer.includeBackgroundColorInExport)
            if let bg = layer.backgroundColor {
                obj["backgroundColor"] = .object(encodeColor(bg))
            }
        }

        if !layer.points.isEmpty {
            obj["isClosed"] = .bool(layer.isClosed)
            obj["edited"] = .bool(layer.edited)
            obj["pointRadiusBehaviour"] = .number(Double(layer.pointRadiusBehaviour))
            obj["fixedRadius"] = .number(layer.fixedRadius)
            obj["points"] = .array(layer.points.map { cp in
                .object([
                    "_class": .string("curvePoint"),
                    "cornerRadius": .number(cp.cornerRadius),
                    "curveFrom": .string(cp.curveFrom),
                    "curveTo": .string(cp.curveTo),
                    "hasCurveFrom": .bool(cp.hasCurveFrom),
                    "hasCurveTo": .bool(cp.hasCurveTo),
                    "curveMode": .number(Double(cp.curveMode)),
                    "point": .string(cp.point)
                ])
            })
        }

        if let attr = layer.attributedString {
            obj["attributedString"] = .object([
                "_class": .string("attributedString"),
                "string": .string(attr.string),
                "attributes": .array(attr.attributes.map { a in
                    .object([
                        "_class": .string("stringAttribute"),
                        "location": .number(Double(a.location)),
                        "length": .number(Double(a.length)),
                        "attributes": .object([
                            "MSAttributedStringFontAttribute": .object([
                                "_class": .string("fontDescriptor"),
                                "attributes": .object([
                                    "name": .string(a.fontName),
                                    "size": .number(a.fontSize)
                                ])
                            ]),
                            "MSAttributedStringColorAttribute": .object(encodeColor(a.color)),
                            "paragraphStyle": .object([
                                "_class": .string("paragraphStyle"),
                                "alignment": .number(Double(a.alignment))
                            ])
                        ])
                    ])
                })
            ])
            obj["textBehaviour"] = .number(Double(layer.textBehaviour))
        }

        if let symID = layer.symbolID {
            obj["symbolID"] = .string(symID)
        }
        if layer.kind == .symbolInstance {
            obj["scale"] = .number(layer.scale)
            obj["horizontalSpacing"] = .number(layer.horizontalSpacing)
            obj["verticalSpacing"] = .number(layer.verticalSpacing)
            obj["overrideValues"] = .array(layer.overrideValues.map { ov in
                .object([
                    "_class": .string("overrideValue"),
                    "overrideName": .string(ov.overrideName),
                    "value": .string(ov.value)
                ])
            })
        }

        return obj
    }

    public static func encodeStyle(_ style: SketchStyle) -> [String: JSONValue] {
        return [
            "_class": .string("style"),
            "do_objectID": .string(style.do_objectID),
            "endMarkerType": .number(Double(style.endMarkerType)),
            "miterLimit": .number(style.miterLimit),
            "startMarkerType": .number(Double(style.startMarkerType)),
            "windingRule": .number(Double(style.windingRule)),
            "contextSettings": .object([
                "_class": .string("graphicsContextSettings"),
                "blendMode": .number(Double(style.contextSettings?.blendMode ?? 0)),
                "opacity": .number(style.contextSettings?.opacity ?? 1.0)
            ]),
            "fills": .array(style.fills.map { f in
                var dict: [String: JSONValue] = [
                    "_class": .string("fill"),
                    "isEnabled": .bool(f.isEnabled),
                    "fillType": .number(Double(f.fillType)),
                    "color": .object(encodeColor(f.color)),
                    "noiseIndex": .number(Double(f.noiseIndex)),
                    "noiseIntensity": .number(f.noiseIntensity),
                    "patternFillType": .number(Double(f.patternFillType)),
                    "patternTileScale": .number(f.patternTileScale),
                    "contextSettings": .object([
                        "_class": .string("graphicsContextSettings"),
                        "blendMode": .number(Double(f.contextSettings?.blendMode ?? 0)),
                        "opacity": .number(f.contextSettings?.opacity ?? 1.0)
                    ])
                ]
                if let grad = f.gradient {
                    dict["gradient"] = .object(encodeGradient(grad))
                }
                return .object(dict)
            }),
            "borders": .array(style.borders.map { b in
                .object([
                    "_class": .string("border"),
                    "isEnabled": .bool(b.isEnabled),
                    "fillType": .number(Double(b.fillType)),
                    "color": .object(encodeColor(b.color)),
                    "position": .number(Double(b.position)),
                    "thickness": .number(b.thickness),
                    "contextSettings": .object([
                        "_class": .string("graphicsContextSettings"),
                        "blendMode": .number(Double(b.contextSettings?.blendMode ?? 0)),
                        "opacity": .number(b.contextSettings?.opacity ?? 1.0)
                    ])
                ])
            }),
            "shadows": .array(style.shadows.map { s in .object(encodeShadow(s, isInner: false)) }),
            "innerShadows": .array(style.innerShadows.map { s in .object(encodeShadow(s, isInner: true)) }),
            "borderOptions": .object([
                "_class": .string("borderOptions"),
                "isEnabled": .bool(style.borderOptions?.isEnabled ?? true),
                "dashPattern": .array((style.borderOptions?.dashPattern ?? []).map { .number($0) }),
                "lineCapStyle": .number(Double(style.borderOptions?.lineCapStyle ?? 0)),
                "lineJoinStyle": .number(Double(style.borderOptions?.lineJoinStyle ?? 0))
            ]),
            "blur": .object([
                "_class": .string("blur"),
                "isEnabled": .bool(style.blur?.isEnabled ?? false),
                "center": .string(style.blur?.center ?? "{0.5, 0.5}"),
                "motionAngle": .number(style.blur?.motionAngle ?? 0),
                "radius": .number(style.blur?.radius ?? 10),
                "saturation": .number(style.blur?.saturation ?? 1),
                "type": .number(Double(style.blur?.type ?? 0))
            ])
        ]
    }

    private static func encodeColor(_ c: SketchColor) -> [String: JSONValue] {
        return [
            "_class": .string("color"),
            "red": .number(c.red),
            "green": .number(c.green),
            "blue": .number(c.blue),
            "alpha": .number(c.alpha)
        ]
    }

    private static func encodeGradient(_ g: SketchGradient) -> [String: JSONValue] {
        return [
            "_class": .string("gradient"),
            "elipseLength": .number(g.elipseLength),
            "from": .string(g.from),
            "to": .string(g.to),
            "gradientType": .number(Double(g.gradientType)),
            "stops": .array(g.stops.map { s in
                .object([
                    "_class": .string("gradientStop"),
                    "color": .object(encodeColor(s.color)),
                    "position": .number(s.position)
                ])
            })
        ]
    }

    private static func encodeShadow(_ s: SketchShadow, isInner: Bool) -> [String: JSONValue] {
        return [
            "_class": .string(isInner ? "innerShadow" : "shadow"),
            "isEnabled": .bool(s.isEnabled),
            "blurRadius": .number(s.blurRadius),
            "offsetX": .number(s.offsetX),
            "offsetY": .number(s.offsetY),
            "spread": .number(s.spread),
            "color": .object(encodeColor(s.color)),
            "contextSettings": .object([
                "_class": .string("graphicsContextSettings"),
                "blendMode": .number(Double(s.contextSettings?.blendMode ?? 0)),
                "opacity": .number(s.contextSettings?.opacity ?? 1.0)
            ])
        ]
    }

    // MARK: - Versioned Preset Archive Reader (`MSVersionedArchiveReader` for `assets.sketchpreset`)

    /// Reconstructs `MSVersionedArchiveReader`, which reads
    /// `.sketchpreset` archives containing `meta.json` + `archive.json` (e.g. `Contents/Resources/assets.sketchpreset`).
    public static func readVersionedPresetArchive(at url: URL) throws -> SketchVersionedPresetArchive {
        let entries = try SketchZipArchive.readEntries(from: url)
        return try readVersionedPresetArchive(fromEntries: entries)
    }

    public static func readVersionedPresetArchive(fromEntries entries: [String: Data]) throws -> SketchVersionedPresetArchive {
        guard let metaData = entries["meta.json"],
              let metaObj = JSONValue.parseObject(from: metaData),
              let archiveData = entries["archive.json"],
              let archiveObj = JSONValue.parseObject(from: archiveData) else {
            throw SketchDocumentError.invalidArchive("Versioned preset archive requires meta.json and archive.json")
        }

        let version = metaObj["version"]?.intValue ?? currentArchiveVersion
        let rootObj = archiveObj["root"]?.objectValue ?? archiveObj

        var colors: [SketchColor] = []
        if let colorAssets = rootObj["colorAssets"]?.arrayValue {
            for item in colorAssets {
                if let cObj = item.objectValue?["color"]?.objectValue {
                    colors.append(decodeColor(from: cObj, default: .sketchBlue))
                }
            }
        }
        if let rawColors = rootObj["colors"]?.arrayValue {
            for item in rawColors {
                if let cObj = item.objectValue {
                    colors.append(decodeColor(from: cObj, default: .sketchBlue))
                }
            }
        }

        var gradients: [SketchGradient] = []
        if let gradAssets = rootObj["gradientAssets"]?.arrayValue {
            for item in gradAssets {
                if let gObj = item.objectValue?["gradient"]?.objectValue,
                   let grad = decodeGradient(from: gObj) {
                    gradients.append(grad)
                }
            }
        }
        if let rawGrads = rootObj["gradients"]?.arrayValue {
            for item in rawGrads {
                if let gObj = item.objectValue,
                   let grad = decodeGradient(from: gObj) {
                    gradients.append(grad)
                }
            }
        }

        return SketchVersionedPresetArchive(
            version: version,
            meta: metaObj,
            archiveRoot: rootObj,
            colors: colors,
            gradients: gradients
        )
    }
}

public struct SketchVersionedPresetArchive: Equatable, Sendable {
    public var version: Int
    public var meta: [String: JSONValue]
    public var archiveRoot: [String: JSONValue]
    public var colors: [SketchColor]
    public var gradients: [SketchGradient]

    public init(
        version: Int = 139,
        meta: [String: JSONValue] = [:],
        archiveRoot: [String: JSONValue] = [:],
        colors: [SketchColor] = [],
        gradients: [SketchGradient] = []
    ) {
        self.version = version
        self.meta = meta
        self.archiveRoot = archiveRoot
        self.colors = colors
        self.gradients = gradients
    }
}

