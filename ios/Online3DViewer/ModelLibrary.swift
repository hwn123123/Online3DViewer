import Foundation
import CryptoKit

struct LibraryItem: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let files: [String]
    let sourceBytes: Int64
    let fingerprint: String
    let importedAt: Date
    var lastOpenedAt: Date
    var cacheFolder: String?
    var cacheBytes: Int64 = 0
    var thumbnailRevision: Int = 0
}

final class ImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return value
    }
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func check() throws { if cancelled { throw CancellationError() } }
}

struct PreparedLibraryImport {
    let staging: URL
    let files: [String]
    let bytes: Int64
    let fingerprint: String
}

enum LibraryImportWorker {
    static let modelExtensions: Set<String> = ["3dm", "3ds", "3mf", "amf", "bim", "brep", "dae", "dwg", "dxf", "fbx", "fcstd", "gltf", "glb", "ifc", "iges", "igs", "skp", "skpbak", "step", "stp", "stl", "obj", "off", "ply", "wrl", "zip"]

    static func validateSelection(_ urls: [URL]) throws {
        guard !urls.isEmpty else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "请选择一个模型文件。"])
        }
        let unsupported = urls.filter { ["max", "blend"].contains($0.pathExtension.lowercased()) }
        if let file = unsupported.first {
            let ext = file.pathExtension.uppercased()
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey:
                "暂不支持直接打开 .\(ext) 原始工程文件。请在原软件中导出为 App 支持的格式，再导入。"])
        }
        let models = urls.filter { modelExtensions.contains($0.pathExtension.lowercased()) }
        if models.isEmpty {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey:
                "没有找到可打开的模型文件。请选择模型；材质、贴图和 BIN 等配套文件可同时选择。"])
        }
        if models.count > 1 {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey:
                "一次请选择一个模型文件，可以同时选择它的材质、贴图和 BIN 等配套文件；其他模型请分别导入。"])
        }
    }

    static func prepare(urls: [URL], incoming: URL, cancellation: ImportCancellation,
                        progress: @escaping (Int64, Int64) -> Void) throws -> PreparedLibraryImport {
        let fm = FileManager.default
        try validateSelection(urls)
        let staging = incoming.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            let primary = urls.first(where: { modelExtensions.contains($0.pathExtension.lowercased()) })!
            let ordered = [primary] + urls.filter { $0 != primary }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard Set(ordered.map(\.lastPathComponent)).count == ordered.count else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "选择的文件中有同名文件，请分别导入。"])
            }
            let expected = ordered.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            var hasher = SHA256(), completed: Int64 = 0, lastReport = Date.distantPast
            for url in ordered {
                try cancellation.check()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?, readError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
                    do {
                        try cancellation.check()
                        let attributes = try fm.attributesOfItem(atPath: source.path)
                        guard attributes[.type] as? FileAttributeType == .typeRegular else {
                            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "请选择模型文件，文件夹请先压缩为 ZIP。"])
                        }
                        let name = url.lastPathComponent
                        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                        hasher.update(data: Data("\(name.utf8.count):\(name):\(size):".utf8))
                        let target = staging.appendingPathComponent(name)
                        guard fm.createFile(atPath: target.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: target)
                        defer { try? input.close(); try? output.close() }
                        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                            try cancellation.check()
                            try output.write(contentsOf: data)
                            hasher.update(data: data)
                            completed += Int64(data.count)
                            if Date().timeIntervalSince(lastReport) > 0.1 {
                                progress(completed, expected); lastReport = Date()
                            }
                        }
                    } catch { readError = error }
                }
                if let coordinationError { throw coordinationError }
                if let readError { throw readError }
            }
            try cancellation.check()
            progress(completed, completed)
            return PreparedLibraryImport(staging: staging, files: ordered.map(\.lastPathComponent), bytes: completed,
                                         fingerprint: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }
}

/// Persistent originals and metadata; derived geometry lives separately in Caches.
/// Mutations are made by ViewerModel on the main actor after background I/O finishes.
final class ModelLibraryStore {
    let root: URL
    let cacheRoot: URL
    let incoming: URL
    private(set) var items: [LibraryItem]
    private let fm = FileManager.default
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    init(root: URL, cacheRoot: URL) throws {
        self.root = root; self.cacheRoot = cacheRoot
        incoming = root.appendingPathComponent("Incoming", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("Models"), withIntermediateDirectories: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let index = root.appendingPathComponent("library.json")
        items = fm.fileExists(atPath: index.path) ? try JSONDecoder().decode([LibraryItem].self, from: Data(contentsOf: index)) : []
        guard items.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.files.isEmpty && $0.files.allSatisfy { $0 == ($0 as NSString).lastPathComponent && $0 != "." && $0 != ".." } }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Incoming files belong only to unfinished imports from a previous process.
        for url in (try? fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: url) }
    }

    func item(_ id: String) -> LibraryItem? { items.first { $0.id == id } }
    func modelDirectory(_ id: String) -> URL { root.appendingPathComponent("Models/\(id)", isDirectory: true) }
    func sourceDirectory(_ id: String) -> URL { modelDirectory(id).appendingPathComponent("files", isDirectory: true) }
    func sourceURLs(_ item: LibraryItem) -> [URL] { item.files.map { sourceDirectory(item.id).appendingPathComponent($0) } }
    func thumbnailURL(_ item: LibraryItem) -> URL { modelDirectory(item.id).appendingPathComponent("thumbnail.jpg") }

    func adopt(_ prepared: PreparedLibraryImport) throws -> (LibraryItem, Bool) {
        if let existing = items.first(where: { $0.fingerprint == prepared.fingerprint && sourceURLs($0).allSatisfy { fm.fileExists(atPath: $0.path) } }) {
            try? fm.removeItem(at: prepared.staging)
            return (existing, true)
        }
        let id = UUID().uuidString
        try fm.createDirectory(at: modelDirectory(id), withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: prepared.staging, to: sourceDirectory(id))
            let item = LibraryItem(id: id, name: prepared.files[0], files: prepared.files, sourceBytes: prepared.bytes,
                                   fingerprint: prepared.fingerprint, importedAt: Date(), lastOpenedAt: Date())
            items.append(item)
            do { try save() } catch { items.removeAll { $0.id == id }; throw error }
            return (item, false)
        } catch { try? fm.removeItem(at: modelDirectory(id)); throw error }
    }

    func update(_ id: String, _ body: (inout LibraryItem) -> Void) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let previous = items[index]
        body(&items[index])
        do { try save() } catch { items[index] = previous; throw error }
    }

    func remove(_ id: String) throws {
        let previous = items
        items.removeAll { $0.id == id }
        do { try save() } catch { items = previous; throw error }
        // Only UUID-owned paths under this app's library/cache roots are removed.
        try? fm.removeItem(at: modelDirectory(id))
        try? fm.removeItem(at: cacheRoot.appendingPathComponent(id))
    }

    func save() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: indexURL, options: .atomic)
    }

    static func directoryBytes(_ directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return 0 }
        var bytes: Int64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }

    static func validCache(item: LibraryItem, cacheRoot: URL) -> URL? {
        guard let folder = item.cacheFolder, folder.hasPrefix(item.id + "/"), !folder.split(separator: "/").contains("..") else { return nil }
        let directory = cacheRoot.appendingPathComponent(folder, isDirectory: true)
        let manifest = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["format"] as? String == "o3dv-stream-1", json["complete"] as? Bool == true,
              let objects = json["objects"] as? [[String: Any]], json["objectCount"] as? Int == objects.count else { return nil }
        // Rebuild older partial 3DM caches so newly supported block references appear.
        if let ext=item.files.first.map({ ($0 as NSString).pathExtension.lowercased() }), ["dwg","dxf"].contains(ext),
           json["reader"] as? String != "cad-stream-4" { return nil }
        if item.files.first.map({ ($0 as NSString).pathExtension.lowercased() }) == "3dm",
           json["reader"] as? String != "opennurbs-instances-1",
           let unsupported = json["unsupported"] as? [Any], !unsupported.isEmpty { return nil }
        for object in objects where object["available"] as? Bool == true {
            guard let name = object["url"] as? String, name == (name as NSString).lastPathComponent,
                  let expected = object["bytes"] as? NSNumber,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path),
                  let bytes = attributes[.size] as? NSNumber, bytes == expected else { return nil }
        }
        for material in json["materials"] as? [[String: Any]] ?? [] {
            for key in ["texture", "normalTexture", "bumpTexture"] {
                guard let texture = material[key] as? [String: Any] else { continue }
                guard let name = texture["url"] as? String, name == (name as NSString).lastPathComponent,
                      let values = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { return nil }
            }
        }
        return manifest
    }
}
