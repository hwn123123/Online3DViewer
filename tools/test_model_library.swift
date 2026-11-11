import Foundation

/// Standalone checks for storage ownership, deduplication and interrupted imports.
@main
enum ModelLibraryChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try condition() == false { throw NSError(domain: "LibraryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("o3dv-library-check-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        let originals = temporary.appendingPathComponent("originals")
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        let source = originals.appendingPathComponent("part.3dm")
        let original = Data(repeating: 7, count: 3 * 1024 * 1024)
        try original.write(to: source)
        let root = temporary.appendingPathComponent("Library")
        let cacheRoot = temporary.appendingPathComponent("Cache")
        let store = try ModelLibraryStore(root: root, cacheRoot: cacheRoot)
        func prepare(_ urls: [URL]) throws -> PreparedLibraryImport {
            try LibraryImportWorker.prepare(urls: urls, incoming: store.incoming, cancellation: ImportCancellation()) { _, _ in }
        }
        let (first, duplicate) = try store.adopt(prepare([source]))
        try require(!duplicate && store.items.count == 1, "First import was not saved")
        try require(try Data(contentsOf: store.sourceURLs(first)[0]) == original, "Stored model differs from source")
        let (second, repeated) = try store.adopt(prepare([source]))
        try require(repeated && first.id == second.id && store.items.count == 1, "Repeated import duplicated the model")
        try require(try fm.contentsOfDirectory(at: store.incoming, includingPropertiesForKeys: nil).isEmpty, "Duplicate import left temporary files")
        try Data([1, 2, 3]).write(to: source)
        let (changed, _) = try store.adopt(prepare([source]))
        try require(changed.id != first.id && store.items.count == 2, "Changed contents reused a stale model")
        let restarted = try ModelLibraryStore(root: root, cacheRoot: cacheRoot)
        try require(restarted.items == store.items, "Library did not survive a restart")
        let folder = "\(first.id)/stream-test"
        let cache = cacheRoot.appendingPathComponent(folder)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: cache.appendingPathComponent("object.bin"))
        let manifest: [String: Any] = ["format": "o3dv-stream-1", "complete": true, "objectCount": 1,
                                      "objects": [["available": true, "url": "object.bin", "bytes": 32]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: cache.appendingPathComponent("manifest.json"))
        try store.update(first.id) { $0.cacheFolder = folder; $0.cacheBytes = 32 }
        try require(ModelLibraryStore.validCache(item: store.item(first.id)!, cacheRoot: cacheRoot) != nil, "Complete cache was rejected")
        var oldPartial = manifest
        oldPartial["unsupported"] = [["type":"Unsupported", "id":"block-reference"]]
        try JSONSerialization.data(withJSONObject: oldPartial).write(to: cache.appendingPathComponent("manifest.json"))
        try require(ModelLibraryStore.validCache(item: store.item(first.id)!, cacheRoot: cacheRoot) == nil, "Old incomplete 3DM cache hid newly supported block references")
        oldPartial["reader"] = "opennurbs-instances-1"
        try JSONSerialization.data(withJSONObject: oldPartial).write(to: cache.appendingPathComponent("manifest.json"))
        try require(ModelLibraryStore.validCache(item: store.item(first.id)!, cacheRoot: cacheRoot) != nil, "Current cache with explicit unsupported geometry was rebuilt repeatedly")
        let drawingSource = originals.appendingPathComponent("drawing.dwg")
        try Data("AC1032fixture".utf8).write(to: drawingSource)
        let (drawing, _) = try store.adopt(prepare([drawingSource]))
        let drawingFolder = "\(drawing.id)/stream-cad"
        let drawingCache = cacheRoot.appendingPathComponent(drawingFolder)
        try fm.createDirectory(at: drawingCache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 32).write(to: drawingCache.appendingPathComponent("object.bin"))
        try store.update(drawing.id) { $0.cacheFolder = drawingFolder; $0.cacheBytes = 32 }
        var drawingManifest = manifest
        drawingManifest["reader"] = "cad-stream-1"
        try JSONSerialization.data(withJSONObject: drawingManifest).write(to: drawingCache.appendingPathComponent("manifest.json"))
        try require(ModelLibraryStore.validCache(item: store.item(drawing.id)!, cacheRoot: cacheRoot) == nil, "Old CAD cache concealed newly supported text and dimensions")
        drawingManifest["reader"] = "cad-stream-2"
        try JSONSerialization.data(withJSONObject: drawingManifest).write(to: drawingCache.appendingPathComponent("manifest.json"))
        try require(ModelLibraryStore.validCache(item: store.item(drawing.id)!, cacheRoot: cacheRoot) == nil, "CAD cache without leader support was reused")
        drawingManifest["reader"] = "cad-stream-3"
        try JSONSerialization.data(withJSONObject: drawingManifest).write(to: drawingCache.appendingPathComponent("manifest.json"))
        try require(ModelLibraryStore.validCache(item: store.item(drawing.id)!, cacheRoot: cacheRoot) == nil, "CAD cache without hatch support was reused")
        drawingManifest["reader"] = "cad-stream-4"
        try JSONSerialization.data(withJSONObject: drawingManifest).write(to: drawingCache.appendingPathComponent("manifest.json"))
        try require(ModelLibraryStore.validCache(item: store.item(drawing.id)!, cacheRoot: cacheRoot) != nil, "Current CAD cache was rejected")
        var texturedManifest = manifest
        texturedManifest["materials"] = [["texture": ["url": "texture.png"]]]
        try JSONSerialization.data(withJSONObject: texturedManifest).write(to: cache.appendingPathComponent("manifest.json"))
        try require(ModelLibraryStore.validCache(item: store.item(first.id)!, cacheRoot: cacheRoot) == nil, "Cache with a missing texture was reused")
        try Data([1, 2, 3]).write(to: cache.appendingPathComponent("texture.png"))
        try require(ModelLibraryStore.validCache(item: store.item(first.id)!, cacheRoot: cacheRoot) != nil, "Complete textured cache was rejected")
        try Data([1]).write(to: cache.appendingPathComponent("object.bin"))
        try require(ModelLibraryStore.validCache(item: store.item(first.id)!, cacheRoot: cacheRoot) == nil, "Corrupt cache was reused")
        try fm.removeItem(at: cacheRoot.appendingPathComponent(first.id))
        try require(fm.fileExists(atPath: store.sourceURLs(first)[0].path), "Clearing cache removed the model")
        try store.remove(first.id)
        try require(!fm.fileExists(atPath: store.modelDirectory(first.id).path), "Deleting a model retained its owned source")
        try require(try Data(contentsOf: source) == Data([1, 2, 3]), "Deleting a model changed the external original")
        let cancelSource = originals.appendingPathComponent("cancel.3dm")
        try original.write(to: cancelSource)
        let cancellation = ImportCancellation()
        do {
            _ = try LibraryImportWorker.prepare(urls: [cancelSource], incoming: store.incoming, cancellation: cancellation) { _, _ in cancellation.cancel() }
            throw NSError(domain: "LibraryChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cancellation was ignored"])
        } catch is CancellationError {}
        try require(try fm.contentsOfDirectory(at: store.incoming, includingPropertiesForKeys: nil).isEmpty, "Cancelled import left temporary data")
        let material = originals.appendingPathComponent("part.mtl")
        try Data("newmtl material".utf8).write(to: material)
        for invalid in [[material], [source, drawingSource], [originals.appendingPathComponent("scene.max")], [originals.appendingPathComponent("scene.blend")]] {
            do {
                _ = try LibraryImportWorker.prepare(urls: invalid, incoming: store.incoming, cancellation: ImportCancellation()) { _, _ in }
                throw NSError(domain: "LibraryChecks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid selection was accepted"])
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadUnsupportedScheme.rawValue {
                try require(!error.localizedDescription.isEmpty, "Selection error did not explain the next step")
            }
            try require(try fm.contentsOfDirectory(at: store.incoming, includingPropertiesForKeys: nil).isEmpty, "Rejected selection left temporary data")
        }
        let (bundle, _) = try store.adopt(prepare([material, source]))
        try require(bundle.files == ["part.3dm", "part.mtl"], "Model and companion files were not kept together")
        try require(try Data(contentsOf: cancelSource) == original, "Cancellation changed the original")
        print("PASS: persistence, content deduplication, changed-file invalidation, cache validation, cache/source separation, owned deletion, cancellable streaming import, companion files.")
    }
}
