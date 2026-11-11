import Foundation
@main enum GltfTestServer {
    static func main() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let server=try LocalAssetServer(assets:root.appendingPathComponent("build/ios/WebAssets"),imports:root,library:root)
        server.start { result in
            switch result {
            case .success(let url):
                try? Data(url.absoluteString.utf8).write(to:root.appendingPathComponent("build/ios/gltf-stream-tests/server-url.txt"))
                print(url.absoluteString)
            case .failure(let error):print(error);exit(1)
            }
        }
        withExtendedLifetime(server) { dispatchMain() }
    }
}
