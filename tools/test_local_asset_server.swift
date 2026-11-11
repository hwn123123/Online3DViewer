import Foundation
import ImageIO

@main enum LocalAssetServerChecks {
    static func main() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("o3dv-ranges-\(UUID().uuidString)")
        try fm.createDirectory(at: directory,withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let bytes = Data((0..<800000).map { UInt8($0 % 251) })
        try bytes.write(to: directory.appendingPathComponent("model.bin"))
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("test/testfiles/obj/cube_texture.png")
        try fm.copyItem(at: source,to: directory.appendingPathComponent("texture.png"))
        let server = try LocalAssetServer(assets: directory,imports: directory,library: directory)
        let base: URL = try await withCheckedThrowingContinuation { continuation in
            server.start { continuation.resume(with: $0) }
        }
        func request(_ range: String?,head: Bool = false) async throws -> (Data,HTTPURLResponse) {
            var r = URLRequest(url: base.appendingPathComponent("imports/model.bin"))
            r.httpMethod = head ? "HEAD" : "GET"
            if let range { r.setValue(range,forHTTPHeaderField: "Range") }
            let (data,response) = try await URLSession.shared.data(for: r)
            return (data,response as! HTTPURLResponse)
        }
        for (range,a,b) in [("bytes=0-0",0,0),("bytes=15-45",15,45),("bytes=100-",100,799999),("bytes=799990-999999",799990,799999)] {
            let (data,response) = try await request(range)
            precondition(response.statusCode == 206 && data == bytes[a...b],"Incorrect byte range \(range)")
            precondition(response.value(forHTTPHeaderField: "Content-Length") == String(b-a+1))
        }
        for range in ["bytes=9-3","bytes=900000-","bytes=1-3,5-7"] {
            let (_,response) = try await request(range);precondition(response.statusCode == 416)
        }
        let (whole,response) = try await request(nil);precondition(response.statusCode == 200 && whole == bytes)
        let (head,headResponse) = try await request("bytes=1-4",head: true);precondition(head.isEmpty && headResponse.statusCode == 206)
        let (texture,textureResponse) = try await URLSession.shared.data(from: URL(string: "imports/texture.png?o3dvTextureEdge=64",relativeTo: base)!)
        precondition((textureResponse as! HTTPURLResponse).statusCode == 200)
        let image = CGImageSourceCreateWithData(texture as CFData,nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(image,0,nil)! as NSDictionary
        precondition((properties[kCGImagePropertyPixelWidth] as! Int) <= 64 && (properties[kCGImagePropertyPixelHeight] as! Int) <= 64)
        let original = try Data(contentsOf: source), retained = try Data(contentsOf: directory.appendingPathComponent("texture.png"))
        precondition(original == retained)
        print("PASS: exact byte ranges, bounded response lengths, HEAD, invalid ranges, texture display variants, original texture preservation")
        _ = server
    }
}
