import SwiftUI

struct OpenRequest {
    let id = UUID()
    let urls: [URL]
    var isStream = false
}

struct ModelLoadProgress {
    var title: String
    var detail: String = ""
    var fraction: Double?
}

struct ViewerPreferences: Equatable {
    var background = "light"
    var navigation = "free"
    var projection = "perspective"
    var memory = "automatic"
    var keepAwake = false

    static func load() -> ViewerPreferences {
        let defaults = UserDefaults.standard
        var result = ViewerPreferences()
        if let value = defaults.string(forKey: "viewer.background"), ["light", "dark"].contains(value) { result.background = value }
        if let value = defaults.string(forKey: "viewer.navigation"), ["free", "fixed"].contains(value) { result.navigation = value }
        if let value = defaults.string(forKey: "viewer.projection"), ["perspective", "orthographic"].contains(value) { result.projection = value }
        if let value = defaults.string(forKey: "viewer.memory"), ["automatic", "economy"].contains(value) { result.memory = value }
        result.keepAwake = defaults.bool(forKey: "viewer.keepAwake")
        return result
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(background, forKey: "viewer.background")
        defaults.set(navigation, forKey: "viewer.navigation")
        defaults.set(projection, forKey: "viewer.projection")
        defaults.set(memory, forKey: "viewer.memory")
        defaults.set(keepAwake, forKey: "viewer.keepAwake")
    }
}

@MainActor
final class ViewerModel: ObservableObject {
    @Published var baseURL: URL?
    @Published var request: OpenRequest?
    @Published var webViewID = UUID()
    @Published var ready = false
    @Published var title = "模型库"
    @Published var error: String?
    @Published var canReimportAfterError = false
    @Published var showingImporter = false
    @Published var showingLibrary = true
    @Published var loadProgress: ModelLoadProgress?
    @Published var statusText: String?
    @Published var coverageIssues: [String] = []
    @Published var cadDisplayWarnings: [String] = []
    @Published var missingFiles: [String] = []
    @Published var libraryItems: [LibraryItem] = []
    @Published var cacheBytes: Int64 = 0
    @Published var storageBusy = false
    @Published var streamLayers: [StreamLayer] = []
    @Published var streamObjects: [StreamObjectInfo] = []
    @Published var layerVisibility: [Int: Bool] = [:]
    @Published var selectedObject: StreamObjectDetails?
    @Published var memoryPolicy: [String:Int] = [:]
    @Published var updatingView = false
    @Published var foreground = true
    @Published var preferences = ViewerPreferences.load() {
        didSet {
            preferences.save()
            if preferences.memory != oldValue.memory { sampleMemoryPolicy() }
        }
    }
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var pressureExpires = Date.distantPast
    private(set) var activeItemID: String?
    private(set) var cacheHit = false
    private var server: LocalAssetServer?
    private var library: ModelLibraryStore?
    private let importsDirectory: URL
    private var pendingImportURLs: [URL] = []
    private var pendingScopedURLs: [URL] = []
    private var appliedLaunchRequest = false
    private var importCancellation: ImportCancellation?
    private var nativeCancellation: RhinoReadCancellation?
    private var pendingWork: Task<Void, Never>?
    private var retiredCache: (directory: URL, replacement: String)?
    private var loadID = UUID()
    private var storageID = UUID()
    private var nativeReadComplete = false
    private var nativeWorkFinished = true
    private var displayedManifestURL: String?
    private var nativeReadTitle = "正在读取模型"
    private var objectsRead = 0
    private var objectsDisplayed = 0
    private var readFraction: Double?
    #if DEBUG
    private var auditHasTerminalEvent = false
    private var auditPolicy: [String:Int]?
    private var auditCancelAfterBytes: Int64?
    private var auditCancelAfterDecoderBytes: Int64?
    private var auditDecoderBudgetBytes: UInt?
    #endif

    var isLoading: Bool { loadProgress != nil }
    var sourceBytes: Int64 { libraryItems.reduce(0) { $0 + $1.sourceBytes } }

    init() {
        let fm = FileManager.default
        importsDirectory = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ModelImports", isDirectory: true)
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ModelLibrary", isDirectory: true)
        do {
            let library = try ModelLibraryStore(root: root, cacheRoot: importsDirectory)
            self.library = library
            syncLibrary()
            guard let assets = Bundle.main.url(forResource: "WebAssets", withExtension: nil) else { throw CocoaError(.fileNoSuchFile) }
            let server = try LocalAssetServer(assets: assets, imports: importsDirectory, library: root)
            self.server = server
            server.start { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch result {
                    case .success(let url):
                        self.baseURL = url
                        if !self.pendingImportURLs.isEmpty {
                            let pending = self.pendingImportURLs; self.pendingImportURLs = []
                            let scopes = self.pendingScopedURLs; self.pendingScopedURLs = []
                            self.importFiles(pending)
                            scopes.forEach { $0.stopAccessingSecurityScopedResource() }
                        }
                    case .failure(let error):
                        self.pendingScopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                        self.pendingScopedURLs = []; self.pendingImportURLs = []
                        self.error = "查看器启动失败：\(error.localizedDescription)"
                    }
                }
            }
            refreshStorage()
            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal,.warning,.critical],queue: .main)
            pressure.setEventHandler { [weak self] in
                guard let self, let pressure = self.memoryPressureSource else { return }
                self.setMemoryPressure(pressure.data.contains(.critical) ? 2 : pressure.data.contains(.warning) ? 1 : 0)
            }
            memoryPressureSource = pressure;pressure.activate()
        } catch { self.error = "无法载入模型库：\(error.localizedDescription)" }
    }

    func setMemoryPressure(_ level: Int) {
        pressureExpires = level > 0 ? Date().addingTimeInterval(10) : .distantPast
        NativeMemoryControl.setPressureLevel(level)
        sampleMemoryPolicy()
        if level >= 2, isLoading {
            let name = title
            cancelLoading()
            error = "设备内存压力过高，已停止当前加载。模型副本仍在模型库中。"
            recordEvent("resource_limit",name: name,details: ["reason":"system_memory_pressure"])
        }
    }

    func sampleMemoryPolicy() {
        if Date() > pressureExpires { NativeMemoryControl.setPressureLevel(0) }
        let snapshot = NativeMemoryControl.snapshot()
        var policy = ["geometryBytes": (snapshot["geometryBytes"] as? NSNumber)?.intValue ?? 24*1024*1024,
                      "textureBytes": (snapshot["textureBytes"] as? NSNumber)?.intValue ?? 12*1024*1024,
                      "framePixels": (snapshot["framePixels"] as? NSNumber)?.intValue ?? 1500000]
        if preferences.memory == "economy" {
            policy["geometryBytes"] = min(policy["geometryBytes"]!, 48*1024*1024)
            policy["textureBytes"] = min(policy["textureBytes"]!, 12*1024*1024)
        }
        #if DEBUG
        for (key,value) in auditPolicy ?? [:] { policy[key] = min(policy[key] ?? value,value) }
        #endif
        if memoryPolicy != policy { memoryPolicy = policy }
    }

    func didBecomeReady() {
        ready = true
        guard !appliedLaunchRequest else { return }
        appliedLaunchRequest = true
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        if let argument = arguments.first(where: { $0.hasPrefix("--ui-test-geometry-budget=") }),
           let value = Int(argument.dropFirst("--ui-test-geometry-budget=".count)), value >= 256 * 1024 {
            auditPolicy = ["geometryBytes": value]
            sampleMemoryPolicy()
        }
        if let argument = arguments.first(where: { $0.hasPrefix("--audit-case=") }) {
            openAuditCase(String(argument.dropFirst("--audit-case=".count)))
            return
        }
        if let argument = arguments.first(where: { $0.hasPrefix("--audit-clean=") }) {
            cleanAuditCase(String(argument.dropFirst("--audit-clean=".count)))
            return
        }
        #endif
        if let value = arguments.first(where: { $0.hasPrefix("--library-item=") }) {
            openLibraryItem(String(value.dropFirst("--library-item=".count)))
        } else if request == nil, let argument = arguments.first(where: { $0.hasPrefix("--document=") }) {
            let name = String(argument.dropFirst("--document=".count))
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            importFiles([documents.appendingPathComponent((name as NSString).lastPathComponent)])
        } else if request == nil, let argument = arguments.first(where: { $0.hasPrefix("--sample=") }) {
            openSample(String(argument.dropFirst("--sample=".count)))
        }
    }

    func recordEvent(_ type: String, name: String, details: [String: Any] = [:]) {
        let testRun = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--test-run=") }) ?? ""
        var info = details
        info["libraryID"] = activeItemID ?? ""
        info["cacheHit"] = cacheHit
        info["libraryCount"] = libraryItems.count
        let state: [String: Any] = ["event": type, "name": name, "details": info, "testRun": testRun, "date": ISO8601DateFormatter().string(from: Date())]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: importsDirectory.deletingLastPathComponent().appendingPathComponent("viewer-status.json"), options: .atomic)
            #if DEBUG
            if type == "navigation_benchmark_complete" || type == "navigation_benchmark_failed" {
                try? data.write(to: importsDirectory.deletingLastPathComponent().appendingPathComponent("navigation-benchmark.json"),options: .atomic)
            }
            if type == "audit_cleaned" || type == "audit_cleanup_error" {
                try? data.write(to: importsDirectory.deletingLastPathComponent().appendingPathComponent("format-audit-clean.json"), options: .atomic)
            }
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--audit-case=") }) {
                let failed = ["javascript_error", "native_read_error", "webcontent_terminated", "resource_limit",
                              "no_importable_file", "failed_to_load_file", "import_failed"].contains(type)
                if !auditHasTerminalEvent || failed {
                    try? data.write(to: importsDirectory.deletingLastPathComponent().appendingPathComponent("format-audit-status.json"), options: .atomic)
                    auditHasTerminalEvent = type == "model_loaded" || type == "load_cancelled" || failed
                }
            }
            #endif
        }
    }

    #if DEBUG
    /// An isolated test fixture bypasses the persistent user library.
    private func openAuditCase(_ id: String) {
        guard UUID(uuidString: id) != nil, let baseURL else { return }
        let directory = importsDirectory.appendingPathComponent("FormatAudit/\(id)")
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("case.json"))
            guard let info = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = info["files"] as? [String], !files.isEmpty,
                  files.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else { throw CocoaError(.fileReadCorruptFile) }
            stopCurrentLoad()
            auditPolicy = info["memoryPolicy"] as? [String:Int]
            auditCancelAfterBytes = (info["cancelAfterReadBytes"] as? NSNumber)?.int64Value
            auditCancelAfterDecoderBytes = (info["cancelAfterDecoderBytes"] as? NSNumber)?.int64Value
            auditDecoderBudgetBytes = (info["decoderBudgetBytes"] as? NSNumber)?.uintValue
            sampleMemoryPolicy()
            activeItemID = id; title = (files[0] as NSString).lastPathComponent; showingLibrary = false
            loadProgress = ModelLoadProgress(title: "正在验证模型", detail: title)
            let source = directory.appendingPathComponent("files/\(files[0])")
            if let cache = info["preparedCache"] as? String, cache.hasPrefix("stream-"),
               UUID(uuidString: String(cache.dropFirst("stream-".count))) != nil {
                nativeReadComplete = true
                request = OpenRequest(urls: [baseURL.appendingPathComponent("imports/\(id)/\(cache)/manifest.json")],isStream: true)
                return
            }
            if info["stream"] as? Bool == true {
                nativeReadComplete = true
                request = OpenRequest(urls: [baseURL.appendingPathComponent("imports/FormatAudit/\(id)/files/\(files[0])")],isStream: true)
                return
            }
            if Self.usesNativeStream(source) {
                let bytes = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
                let item = LibraryItem(id: id, name: title, files: files, sourceBytes: bytes, fingerprint: id,
                                       importedAt: Date(), lastOpenedAt: Date())
                startNativeStream(item, file: source, job: loadID)
            } else {
                request = OpenRequest(urls: files.map { baseURL.appendingPathComponent("imports/FormatAudit/\(id)/files/\($0)") })
            }
        } catch {
            loadingFailed("测试副本无法读取：\(error.localizedDescription)")
            recordEvent("native_read_error", name: title, details: ["error": error.localizedDescription])
        }
    }

    private func cleanAuditCase(_ id: String) {
        guard UUID(uuidString: id) != nil else { return }
        let previous = stopCurrentLoad()
        let paths = [importsDirectory.appendingPathComponent("FormatAudit/\(id)"), importsDirectory.appendingPathComponent(id)]
        Task {
            await previous?.value
            do {
                try await Task.detached {
                    for path in paths where FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                }.value
                recordEvent("audit_cleaned", name: id)
            } catch { recordEvent("audit_cleanup_error", name: id, details: ["error": error.localizedDescription]) }
        }
    }
    #endif

    func openSample(_ name: String) {
        guard let assets = Bundle.main.url(forResource: "WebAssets", withExtension: nil) else { return }
        importFiles([assets.appendingPathComponent("assets/models/\(name)")])
    }

    private func syncLibrary() {
        libraryItems = (library?.items ?? []).sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    @discardableResult
    private func stopCurrentLoad() -> Task<Void, Never>? {
        let previous = pendingWork
        importCancellation?.cancel(); nativeCancellation?.cancelled = true
        importCancellation = nil; nativeCancellation = nil; pendingWork = nil
        loadID = UUID()
        request = nil; ready = false; webViewID = UUID()
        if let retired = retiredCache { retiredCache = nil; Task.detached { try? FileManager.default.removeItem(at: retired.directory) } }
        loadProgress = nil; statusText = nil; activeItemID = nil; cacheHit = false
        coverageIssues = []
        cadDisplayWarnings = []
        missingFiles = []
        updatingView = false
        streamLayers = []; streamObjects = []; layerVisibility = [:]; selectedObject = nil
        nativeReadComplete = false; nativeWorkFinished = true; displayedManifestURL = nil
        objectsRead = 0; objectsDisplayed = 0; readFraction = nil
        return previous
    }

    func returnToLibrary() {
        stopCurrentLoad()
        showingLibrary = true; title = "模型库"
        refreshStorage()
    }

    func cancelLoading() {
        let name = title
        let cancelledItem = activeItemID
        stopCurrentLoad()
        showingLibrary = true; title = "模型库"
        recordEvent("load_cancelled", name: name, details: ["cancelledItem": cancelledItem ?? ""])
        refreshStorage()
    }

    func receiveExternalURL(_ url: URL) {
        guard !isLoading && !storageBusy else {
            canReimportAfterError = false
            error = "当前操作尚未完成。请先等待完成或取消，再从文件或其他 App 打开模型。"
            return
        }
        importFiles([url])
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard !storageBusy else { error = "正在整理存储，请完成后再导入。"; return }
        do { try LibraryImportWorker.validateSelection(urls) }
        catch { canReimportAfterError = true; self.error = error.localizedDescription; return }
        guard baseURL != nil, let library else {
            guard pendingImportURLs.isEmpty else { error = "查看器正在启动，请稍后重新选择文件。"; return }
            pendingScopedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
            pendingImportURLs = urls
            return
        }
        let scopes = urls.filter { $0.startAccessingSecurityScopedResource() }
        stopCurrentLoad()
        canReimportAfterError = false
        showingLibrary = true; title = "模型库"
        loadProgress = ModelLoadProgress(title: "正在导入模型", detail: urls.first?.lastPathComponent ?? "")
        let cancellation = ImportCancellation(); importCancellation = cancellation
        let job = loadID, incoming = library.incoming
        pendingWork = Task {
            defer { scopes.forEach { $0.stopAccessingSecurityScopedResource() } }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try LibraryImportWorker.prepare(urls: urls, incoming: incoming, cancellation: cancellation) { completed, total in
                        DispatchQueue.main.async {
                            guard self.loadID == job else { return }
                            self.loadProgress = ModelLoadProgress(title: "正在导入模型",
                                detail: "\(Self.size(completed)) / \(total > 0 ? Self.size(total) : "正在读取")",
                                fraction: total > 0 ? min(1, Double(completed) / Double(total)) : nil)
                        }
                    }
                }.value
                guard loadID == job, !cancellation.cancelled else { try? FileManager.default.removeItem(at: prepared.staging); return }
                let (item, duplicate) = try library.adopt(prepared)
                syncLibrary()
                recordEvent("library_imported", name: item.name, details: ["itemID": item.id, "duplicate": duplicate])
                openLibraryItem(item.id)
            } catch {
                guard loadID == job, !cancellation.cancelled else { return }
                loadProgress = nil
                canReimportAfterError = true
                self.error = "文件导入失败：\(error.localizedDescription)"
                recordEvent("native_read_error", name: urls.first?.lastPathComponent ?? "", details: ["error": error.localizedDescription])
            }
        }
    }

    func openLibraryItem(_ id: String) {
        guard !storageBusy, let library, let item = library.item(id), let baseURL else { return }
        stopCurrentLoad()
        activeItemID = id; showingLibrary = false; title = item.name
        loadProgress = ModelLoadProgress(title: "正在打开模型", detail: "检查本地文件与缓存")
        let job = loadID, cacheRoot = importsDirectory
        let files = library.sourceURLs(item)
        pendingWork = Task {
            let manifest = await Task.detached(priority: .userInitiated) {
                ModelLibraryStore.validCache(item: item, cacheRoot: cacheRoot)
            }.value
            guard loadID == job else { return }
            guard files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                loadingFailed("模型副本不存在，请重新导入。"); return
            }
            do { try library.update(id) { $0.lastOpenedAt = Date() }; syncLibrary() }
            catch { loadingFailed("无法保存打开记录：\(error.localizedDescription)"); return }
            if Self.usesNativeStream(files[0]) {
                if let manifest {
                    cacheHit = true; nativeReadComplete = true
                    loadProgress = ModelLoadProgress(title: "正在显示模型", detail: "使用已保存的分块缓存")
                    var folder = item.cacheFolder!
                    if files[0].pathExtension.lowercased() == "3dm" {
                        let source = manifest.deletingLastPathComponent()
                        let needs = await Task.detached(priority: .userInitiated) { RhinoCacheBatcher.needsBatching(source.path) }.value
                        guard loadID == job else { return }
                        if needs {
                            let cancellation = RhinoReadCancellation(); nativeCancellation = cancellation
                            let newFolder = "\(id)/stream-\(UUID().uuidString)"
                            let destination = cacheRoot.appendingPathComponent(newFolder)
                            loadProgress = ModelLoadProgress(title: "正在优化模型显示", detail: "整理小对象，下次打开可直接使用")
                            do {
                                let bytes = try await Task.detached(priority: .userInitiated) {
                                    try RhinoCacheBatcher.batch(directory: source.path, destination: destination.path, progress: { done, total in
                                        DispatchQueue.main.async {
                                            guard self.loadID == job else { return }
                                            self.loadProgress = ModelLoadProgress(title: "正在优化模型显示", detail: "\(done) / \(total) 个对象",
                                                fraction: total > 0 ? Double(done) / Double(total) : nil)
                                        }
                                    }, cancellation: cancellation)
                                    return ModelLibraryStore.directoryBytes(destination)
                                }.value
                                guard loadID == job, !cancellation.cancelled else { try? FileManager.default.removeItem(at: destination); return }
                                try library.update(id) { $0.cacheFolder = newFolder; $0.cacheBytes = bytes }
                                syncLibrary(); folder = newFolder
                                retiredCache = (source, baseURL.appendingPathComponent("imports/\(newFolder)/manifest.json").absoluteString)
                            } catch {
                                try? FileManager.default.removeItem(at: destination)
                                guard loadID == job, !cancellation.cancelled else { return }
                                recordEvent("cache_optimization_failed", name: item.name, details: ["error": error.localizedDescription])
                            }
                            nativeCancellation = nil
                        }
                    }
                    guard loadID == job else { return }
                    loadProgress = ModelLoadProgress(title: "正在显示模型", detail: "使用已保存的分块缓存")
                    request = OpenRequest(urls: [baseURL.appendingPathComponent("imports/\(folder)/manifest.json")], isStream: true)
                    recordEvent("cache_reused", name: item.name, details: ["cacheFolder": folder, "manifest": manifest.lastPathComponent])
                } else { startNativeStream(item, file: files[0], job: job) }
            } else {
                loadProgress = ModelLoadProgress(title: "正在读取模型", detail: item.name)
                request = OpenRequest(urls: item.files.map { baseURL.appendingPathComponent("library/Models/\(id)/files/\($0)") })
            }
        }
    }

    private static func usesNativeStream(_ file: URL) -> Bool {
        let ext = file.pathExtension.lowercased()
        if ["3dm", "stl", "glb", "gltf", "skp", "skpbak", "dwg", "dxf"].contains(ext) { return true }
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ["obj", "fbx"].contains(ext) && bytes >= 16 * 1024 * 1024
    }

    private func startNativeStream(_ item: LibraryItem, file: URL, job: UUID) {
        guard let baseURL, let library else { return }
        nativeWorkFinished = false
        let folder = "\(item.id)/stream-\(UUID().uuidString)"
        let cache = importsDirectory.appendingPathComponent(folder, isDirectory: true)
        let optimizedFolder = "\(item.id)/stream-\(UUID().uuidString)"
        let optimizedCache = importsDirectory.appendingPathComponent(optimizedFolder, isDirectory: true)
        let manifestURL = baseURL.appendingPathComponent("imports/\(folder)/manifest.json")
        let cancellation = RhinoReadCancellation(); nativeCancellation = cancellation
        #if DEBUG
        if let budget = auditDecoderBudgetBytes { cancellation.decoderBudgetBytes = budget }
        #endif
        let isRhino = file.pathExtension.lowercased() == "3dm"
        let isStl = file.pathExtension.lowercased() == "stl"
        let isGltf = ["glb", "gltf"].contains(file.pathExtension.lowercased())
        let isSkp = ["skp", "skpbak"].contains(file.pathExtension.lowercased())
        let isCad = ["dwg", "dxf"].contains(file.pathExtension.lowercased())
        nativeReadTitle = "正在读取 \(file.pathExtension.uppercased())"
        loadProgress = ModelLoadProgress(title: nativeReadTitle, detail: "读取模型数据")
        pendingWork = Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    do {
                        let report: ([String: Any]) -> Void = { info in
                            DispatchQueue.main.async {
                                guard self.loadID == job else { return }
                                let phase = info["phase"] as? String ?? ""
                                #if DEBUG
                                if let threshold = self.auditCancelAfterDecoderBytes,
                                   (info["decoderAllocationBytes"] as? NSNumber)?.int64Value ?? 0 > threshold {
                                    self.auditCancelAfterDecoderBytes = nil
                                    self.cancelLoading()
                                    return
                                }
                                if let threshold = self.auditCancelAfterBytes, threshold > 0,
                                   (info["bytesRead"] as? NSNumber)?.int64Value ?? 0 >= threshold {
                                    self.auditCancelAfterBytes = nil
                                    self.cancelLoading()
                                    return
                                }
                                #endif
                                self.objectsRead = (info["objects"] as? NSNumber)?.intValue ?? 0
                                if phase == "decoding" { self.nativeReadTitle = isCad ? "正在解析 CAD 图纸" : isSkp ? "正在解析 SKP 模型" : "正在解码压缩模型" }
                                else if isSkp { self.nativeReadTitle = "正在构建显示缓存" }
                                else if isGltf { self.nativeReadTitle = "正在构建显示缓存" }
                                else if isCad { self.nativeReadTitle = "正在构建显示缓存" }
                                if phase == "decoding" { self.readFraction = nil }
                                else if (isRhino || isStl || isGltf || phase == "parsing"), let read = info["bytesRead"] as? NSNumber, let total = info["sourceBytes"] as? NSNumber, total.doubleValue > 0 {
                                    self.readFraction = min(1, max(self.readFraction ?? 0, read.doubleValue / total.doubleValue))
                                } else { self.readFraction = nil }
                                if phase == "ready" {
                                    self.request = OpenRequest(urls: [manifestURL], isStream: true)
                                    if !isRhino && !isStl && !isGltf { self.nativeReadTitle = "正在构建显示缓存"; self.readFraction = nil }
                                }
                                if phase == "complete" { self.nativeReadComplete = true }
                                self.updateNativeProgress()
                            }
                        }
                        if isRhino {
                            try RhinoStreamReader.convert(file: file.path, directory: cache.path, progress: report, cancellation: cancellation)
                        } else if isStl {
                            try StlStreamReader.convert(file: file.path, directory: cache.path, progress: report, cancellation: cancellation)
                        } else if isGltf {
                            try GltfStreamReader.convert(file: file.path, directory: cache.path, progress: report, cancellation: cancellation)
                        } else if isSkp {
                            try SkpStreamReader.convert(file: file.path, directory: cache.path, progress: report, cancellation: cancellation)
                        } else if isCad {
                            try CadStreamReader.convert(file: file.path, directory: cache.path, progress: report, cancellation: cancellation)
                        } else {
                            try MeshStreamReader.convert(file: file.path, directory: cache.path, progress: report, cancellation: cancellation)
                        }
                        if cancellation.cancelled { throw CancellationError() }
                        if isRhino && RhinoCacheBatcher.needsBatching(cache.path) {
                            do {
                                try RhinoCacheBatcher.batch(directory: cache.path, destination: optimizedCache.path, progress: { done, total in
                                    DispatchQueue.main.async {
                                        guard self.loadID == job else { return }
                                        self.loadProgress = ModelLoadProgress(title: "正在优化模型显示", detail: "\(done) / \(total) 个对象",
                                            fraction: total > 0 ? Double(done) / Double(total) : nil)
                                    }
                                }, cancellation: cancellation)
                                if cancellation.cancelled { throw CancellationError() }
                                return (optimizedCache, ModelLibraryStore.directoryBytes(optimizedCache))
                            } catch {
                                try? FileManager.default.removeItem(at: optimizedCache)
                                if cancellation.cancelled { throw CancellationError() }
                            }
                        }
                        return (cache, ModelLibraryStore.directoryBytes(cache))
                    } catch { try? FileManager.default.removeItem(at: cache); try? FileManager.default.removeItem(at: optimizedCache); throw error }
                }.value
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-test-delay-post-read") {
                    try await Task.sleep(for: .seconds(6))
                }
                #endif
                guard loadID == job, !cancellation.cancelled else { try? FileManager.default.removeItem(at: cache); try? FileManager.default.removeItem(at: optimizedCache); return }
                let (finalCache, bytes) = result
                let finalFolder = finalCache == optimizedCache ? optimizedFolder : folder
                let oldFolder = library.item(item.id)?.cacheFolder
                try library.update(item.id) { $0.cacheFolder = finalFolder; $0.cacheBytes = bytes }
                syncLibrary(); refreshStorage()
                if finalCache == optimizedCache {
                    let replacement = baseURL.appendingPathComponent("imports/\(finalFolder)/manifest.json")
                    retiredCache = (cache, replacement.absoluteString)
                    nativeReadComplete = true
                    displayedManifestURL = nil
                    loadProgress = ModelLoadProgress(title: "正在显示模型", detail: "正在启用优化后的显示缓存")
                    request = OpenRequest(urls: [replacement], isStream: true)
                }
                nativeWorkFinished = true
                if finalCache != optimizedCache, displayedManifestURL == request?.urls.first?.absoluteString {
                    modelDidLoad(manifestURL: displayedManifestURL)
                }
                if let oldFolder, oldFolder != finalFolder, oldFolder.hasPrefix(item.id + "/") {
                    let old = importsDirectory.appendingPathComponent(oldFolder)
                    Task.detached { try? FileManager.default.removeItem(at: old) }
                }
            } catch {
                guard loadID == job, !cancellation.cancelled else { return }
                let nativeError = error as NSError
                var message = error.localizedDescription
                if nativeError.domain == "O3DVGLTF", message.contains("缺少模型必需的本地配套文件") {
                    message += "\n\n请重新选择模型和所需的 BIN 等配套文件一起导入；若文件有目录层级，请保留原结构并尝试使用 ZIP。"
                }
                loadingFailed(message)
                let type = ["O3DVMesh", "O3DVSTL", "O3DVGLTF", "O3DVSKP", "O3DVCAD"].contains(nativeError.domain) && nativeError.code == 2 ? "resource_limit" : "native_read_error"
                recordEvent(type,name: item.name,details: ["error":error.localizedDescription,"resources":nativeError.userInfo["resourceDiagnostics"] ?? [:]])
            }
        }
    }

    private func updateNativeProgress(total: Int? = nil) {
        guard loadProgress != nil else { return }
        if nativeReadComplete, let total, total > 0 {
            loadProgress = ModelLoadProgress(title: "正在显示模型", detail: "已显示 \(objectsDisplayed) / \(total) 个对象",
                                            fraction: min(1, Double(objectsDisplayed) / Double(total)))
        } else {
            loadProgress = ModelLoadProgress(title: nativeReadComplete ? "正在显示模型" : nativeReadTitle,
                detail: "已读取 \(objectsRead) 个对象 · 已显示 \(objectsDisplayed) 个", fraction: nativeReadComplete ? nil : readFraction)
        }
    }

    func receiveStreamMessage(_ value: [String: Any]) {
        if value["type"] as? String == "model_loaded", value["stream"] as? Bool != true {
            missingFiles = value["missingFiles"] as? [String] ?? []
            if !missingFiles.isEmpty {
                statusText = "模型已显示 · 缺少配套文件：\(missingFiles.prefix(3).joined(separator: "、"))"
            }
        }
        if value["type"] as? String == "stream_view_progress" {
            updatingView = value["complete"] as? Bool != true
        }
        if let layers = value["layers"] as? [[String: Any]] {
            streamLayers = layers.compactMap { item in
                guard let index = item["index"] as? Int else { return nil }
                return StreamLayer(id: index, name: item["name"] as? String ?? "图层 \(index)", originalVisible: item["visible"] as? Bool ?? true)
            }
        }
        if let objects = value["objects"] as? [[String: Any]] {
            let received = objects.compactMap { item -> StreamObjectInfo? in
                guard let id = item["id"] as? String else { return nil }
                return StreamObjectInfo(id: id, name: item["name"] as? String ?? "", type: item["type"] as? String ?? "", layerIndex: item["layerIndex"] as? Int ?? -1)
            }
            if value["append"] as? Bool == true { streamObjects.append(contentsOf: received) }
            else { streamObjects = received }
        }
        if let displayed = value["displayed"] as? Int, let total = value["total"] as? Int {
            if value["type"] as? String == "stream_view_progress",value["complete"] as? Bool != true {
                if let done = value["visibleDone"] as? Int, let visible = value["visibleTotal"] as? Int, visible > 0 {
                    let previous = value["previousFrameVisible"] as? Bool == true ? " · 暂时保留上一画面" : ""
                    statusText = "正在更新视图 \(min(done, visible)) / \(visible)\(previous)"
                } else {
                    statusText = "正在更新视图…"
                }
            }
            objectsDisplayed = displayed
            updateNativeProgress(total: total)
            if value["complete"] as? Bool == true {
                missingFiles = value["missingFiles"] as? [String] ?? []
                statusText = "已显示 \(displayed) / \(total) 个对象\(cacheHit ? " · 缓存打开" : "")"
                if let sourceCount = value["sourceObjectCount"] as? Int {
                    let unsupported = value["unsupportedCount"] as? Int ?? 0
                    statusText = "已显示 \(max(0, sourceCount - unsupported)) / \(sourceCount) 个对象\(cacheHit ? " · 缓存打开" : "")"
                }
                if let unsupported = value["unsupportedCount"] as? Int, unsupported > 0 { statusText = "已显示 \(displayed) / \(total) 个对象，\(unsupported) 个暂不支持显示" }
                if !missingFiles.isEmpty {
                    statusText = "几何已显示 · 缺少配套文件：\(missingFiles.prefix(3).joined(separator: "、"))"
                } else if let warnings = value["warnings"] as? [String], !warnings.isEmpty {
                    statusText = "几何已显示 · \(warnings[0])"
                }
                if (value["reader"] as? String)?.hasPrefix("cad-stream-") == true {
                    cadDisplayWarnings = value["warnings"] as? [String] ?? []
                }
                if (value["reader"] as? String)?.hasPrefix("cad-stream-") == true, value["coverageComplete"] as? Bool == false {
                    coverageIssues = (value["unsupportedObjects"] as? [[String:Any]] ?? []).map {
                        "\($0["type"] as? String ?? "未知对象")：\(($0["count"] as? NSNumber)?.stringValue ?? "") 项"
                    }
                    statusText = "部分内容已显示 · \(coverageIssues.count) 类内容尚未支持"
                }
            }
        }
        if value["type"] as? String == "stream_selection", let object = value["object"] as? [String: Any] {
            selectedObject = StreamObjectDetails(id: object["id"] as? String ?? "", name: object["name"] as? String ?? "未命名对象", type: object["type"] as? String ?? "", layer: object["layer"] as? String ?? "", material: object["material"] as? String ?? "")
        }
    }

    func receiveLoadProgress(_ value: [String: Any]) {
        guard loadProgress != nil else { return }
        let phase = value["phase"] as? String ?? ""
        let label = ["files": "正在读取文件", "import": "正在解析模型", "display": "正在生成显示数据"][phase] ?? "正在载入模型"
        var fraction: Double?
        if let current = value["current"] as? Double, let total = value["total"] as? Double, total > 0 { fraction = min(1, current / total) }
        loadProgress = ModelLoadProgress(title: label, detail: title, fraction: fraction)
    }

    func modelDidLoad(manifestURL: String? = nil) {
        if let manifestURL {
            guard request?.isStream == true, request?.urls.first?.absoluteString == manifestURL else { return }
            displayedManifestURL = manifestURL
        }
        guard nativeWorkFinished else { return }
        loadProgress = nil
        if let retired = retiredCache, retired.replacement == manifestURL {
            retiredCache = nil
            Task.detached { try? FileManager.default.removeItem(at: retired.directory) }
        }
        if statusText == nil { statusText = "模型已打开" }
        refreshStorage()
    }

    func loadingFailed(_ message: String) {
        // A partially published cache must not keep polling/redrawing after the reader fails.
        stopCurrentLoad()
        showingLibrary = true; title = "模型库"
        canReimportAfterError = true
        error = message
        refreshStorage()
    }

    func thumbnailURL(_ item: LibraryItem) -> URL? { library?.thumbnailURL(item) }
    func saveThumbnail(_ dataURL: String, itemID: String) {
        guard activeItemID == itemID, let library, library.item(itemID) != nil,
              let comma = dataURL.firstIndex(of: ","), let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.8) else { return }
        do {
            try jpeg.write(to: library.modelDirectory(itemID).appendingPathComponent("thumbnail.jpg"), options: .atomic)
            try library.update(itemID) { $0.thumbnailRevision += 1 }
            syncLibrary()
        } catch { recordEvent("thumbnail_error", name: title, details: ["error": error.localizedDescription]) }
    }

    func refreshStorage() {
        let job = UUID(); storageID = job; let root = importsDirectory
        Task {
            let bytes = await Task.detached(priority: .utility) { ModelLibraryStore.directoryBytes(root) }.value
            guard storageID == job else { return }
            cacheBytes = bytes
        }
    }

    func clearCache(for itemID: String? = nil) {
        guard !storageBusy, let library else { return }
        let oldWork = stopCurrentLoad()
        showingLibrary = true; title = "模型库"; storageBusy = true
        let target = itemID.map { importsDirectory.appendingPathComponent($0) } ?? importsDirectory
        Task {
            await oldWork?.value
            do {
                try await Task.detached(priority: .utility) {
                    if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                }.value
                for item in library.items where itemID == nil || item.id == itemID {
                    try library.update(item.id) { $0.cacheFolder = nil; $0.cacheBytes = 0 }
                }
                syncLibrary(); refreshStorage()
                recordEvent("cache_cleared", name: itemID.flatMap { library.item($0)?.name } ?? "全部缓存")
            } catch { self.error = "清理失败：\(error.localizedDescription)" }
            storageBusy = false
        }
    }

    func deleteItem(_ item: LibraryItem) {
        guard !storageBusy, let library else { return }
        let oldWork = stopCurrentLoad()
        showingLibrary = true; title = "模型库"; storageBusy = true
        Task {
            await oldWork?.value
            do { try library.remove(item.id); syncLibrary(); refreshStorage() }
            catch { self.error = "删除失败：\(error.localizedDescription)" }
            storageBusy = false
        }
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
