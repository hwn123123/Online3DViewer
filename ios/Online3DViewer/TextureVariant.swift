import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

enum TextureVariant {
    /// The original encoded texture stays intact. ImageIO decodes a bounded display variant.
    static func prepare(_ source: URL, maxEdge: Int) -> URL? {
        let edge = min(1024,max(64,maxEdge))
        let attributes = try? source.resourceValues(forKeys: [.fileSizeKey,.contentModificationDateKey])
        let fingerprint = "\(source.lastPathComponent):\(attributes?.fileSize ?? 0):\(attributes?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(edge)"
        let key = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x",$0) }.joined()
        let folder = source.deletingLastPathComponent().appendingPathComponent(".display-textures")
        let target = folder.appendingPathComponent(key+".png")
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary) else { return nil }
        if let properties = CGImageSourceCopyPropertiesAtIndex(imageSource,0,nil) as? [CFString:Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0, width <= edge, height <= edge,
           (attributes?.fileSize ?? Int.max) <= 65536 + edge * edge * 8,
           ["png","jpg","jpeg","webp"].contains(source.pathExtension.lowercased()) {
            // Already bounded: keep original RGB in transparent texels and avoid another color conversion.
            return source
        }
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource,0,[
                kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,
                kCGImageSourceShouldCacheImmediately:true,kCGImageSourceThumbnailMaxPixelSize:edge] as CFDictionary) else { return nil }
        do { try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true) } catch { return nil }
        let temporary = folder.appendingPathComponent(UUID().uuidString+".png")
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL,UTType.png.identifier as CFString,1,nil) else { return nil }
        CGImageDestinationAddImage(destination,image,nil)
        guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: temporary);return nil }
        do { try FileManager.default.moveItem(at: temporary,to: target);return target }
        catch { try? FileManager.default.removeItem(at: temporary);return FileManager.default.fileExists(atPath: target.path) ? target : nil }
    }
}
