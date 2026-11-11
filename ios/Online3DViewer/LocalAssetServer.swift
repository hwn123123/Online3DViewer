import Foundation
import Network

/// Serves bundled WebAssembly and user-selected files to WKWebView on loopback only.
/// No listener is exposed to Wi-Fi, and no remote conversion service is used.
final class LocalAssetServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.hwn.Online3DViewer.assets", qos: .userInitiated)
    private let assets: URL
    private let imports: URL
    private let library: URL

    init(assets: URL, imports: URL, library: URL? = nil) throws {
        self.assets = assets.standardizedFileURL
        self.imports = imports.standardizedFileURL
        self.library = (library ?? imports).standardizedFileURL
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        var completed = false
        listener.stateUpdateHandler = { [weak self] state in
            guard !completed else { return }
            switch state {
            case .ready:
                if let port = self?.listener.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") {
                    completed = true
                    completion(.success(url))
                }
            case .failed(let error):
                completed = true
                completion(.failure(error))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let data { request.append(data) }
            if request.count > 65536 { self.sendError(connection, status: "431 Request Header Fields Too Large"); return }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, request: request)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, accumulated: request)
            }
        }
    }

    private func respond(_ connection: NWConnection, request: Data) {
        guard let line = String(data: request, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
            sendError(connection, status: "400 Bad Request"); return
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD",
              let components = URLComponents(string: String(parts[1])) else {
            sendError(connection, status: "405 Method Not Allowed"); return
        }
        let requestedPath = components.path
        guard !requestedPath.contains("\0"), !requestedPath.split(separator: "/").contains("..") else {
            sendError(connection, status: "403 Forbidden"); return
        }
        let root: URL
        let relative: String
        if requestedPath.hasPrefix("/imports/") {
            root = imports
            relative = String(requestedPath.dropFirst("/imports/".count))
        } else if requestedPath.hasPrefix("/library/") {
            root = library
            relative = String(requestedPath.dropFirst("/library/".count))
        } else {
            root = assets
            relative = requestedPath == "/" ? "index.html" : String(requestedPath.drop(while: { $0 == "/" }))
        }
        var file = root.appendingPathComponent(relative).standardizedFileURL
        if requestedPath.hasPrefix("/imports/"),file.path.hasPrefix(imports.path+"/"),
           let value = components.queryItems?.first(where: { $0.name == "o3dvTextureEdge" })?.value,let edge = Int(value) {
            guard let variant = TextureVariant.prepare(file,maxEdge: edge) else { sendError(connection,status: "415 Unsupported Texture");return }
            file = variant
        }
        guard file.path.hasPrefix(root.path + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: file) else {
            sendError(connection, status: "404 Not Found"); return
        }
        // The manifest is replaced atomically while conversion runs. Read the
        // size from this open handle so Content-Length always matches its inode.
        let length: UInt64
        do {
            length = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
        } catch {
            try? handle.close()
            sendError(connection, status: "500 Internal Server Error"); return
        }
        let policy = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' data: blob:; worker-src 'self' blob:; object-src 'none'; frame-src 'none'; base-uri 'self'"
        var start: UInt64 = 0, end = length > 0 ? length - 1 : 0
        var ranged = false
        if let rangeLine = String(data: request,encoding: .utf8)?.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("range:") }) {
            let value = rangeLine.dropFirst(6).trimmingCharacters(in: .whitespaces)
            let bounds = value.hasPrefix("bytes=") ? String(value.dropFirst(6)).split(separator: "-",omittingEmptySubsequences: false) : []
            guard bounds.count == 2,let lower = UInt64(bounds[0]),lower < length,
                  bounds[1].isEmpty || UInt64(bounds[1]) != nil else { try? handle.close();sendError(connection,status: "416 Range Not Satisfiable");return }
            start = lower;end = min(UInt64(bounds[1]) ?? end,end)
            guard end >= start else { try? handle.close();sendError(connection,status: "416 Range Not Satisfiable");return }
            ranged = true
            do { try handle.seek(toOffset: start) } catch { try? handle.close();sendError(connection,status: "500 Internal Server Error");return }
        }
        let count = length == 0 ? 0 : end-start+1
        let rangeHeader = ranged ? "Content-Range: bytes \(start)-\(end)/\(length)\r\n" : ""
        let headers = "HTTP/1.1 \(ranged ? "206 Partial Content" : "200 OK")\r\nContent-Type: \(mimeType(file.pathExtension))\r\nContent-Length: \(count)\r\nAccept-Ranges: bytes\r\n\(rangeHeader)Cache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: \(policy)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil, parts[0] != "HEAD", let self else {
                try? handle.close(); connection.cancel(); return
            }
            self.sendFile(connection, handle: handle,remaining: count)
        })
    }

    private func sendFile(_ connection: NWConnection, handle: FileHandle,remaining: UInt64) {
        do {
            guard remaining > 0,let data = try handle.read(upToCount: Int(min(remaining,256*1024))), !data.isEmpty else {
                try? handle.close()
                connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { try? handle.close(); connection.cancel(); return }
                self.sendFile(connection, handle: handle,remaining: remaining-UInt64(data.count))
            })
        } catch { try? handle.close(); connection.cancel() }
    }

    private func sendError(_ connection: NWConnection, status: String) {
        let body = Data(status.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js": return "application/javascript"
        case "css": return "text/css"
        case "wasm": return "application/wasm"
        case "json", "gltf": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return "application/octet-stream"
        }
    }

    deinit { listener.cancel() }
}
