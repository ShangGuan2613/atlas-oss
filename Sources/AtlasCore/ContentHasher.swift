import CryptoKit
import Foundation
import ImageIO

/// Streaming SHA-256 so large files never fully load into memory.
public enum ContentHasher {
    public struct Result: Sendable, Equatable {
        public let hexDigest: String
        public let byteCount: Int64
    }

    public static let chunkSize = 1 << 20 // 1 MiB

    public static func sha256Hex(of url: URL, chunkSize: Int = ContentHasher.chunkSize) throws -> Result {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw AtlasError.io("cannot open \(url.path)")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Result(hexDigest: digest, byteCount: total)
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Cheap metadata probe.
///
/// Pixel dimensions come from ImageIO header parsing — no full decode, so importing a
/// 10k-file folder stays I/O bound. Video dimensions are deferred to P1 (AVFoundation).
public enum MediaProbe {
    public struct FileAttributes: Sendable, Equatable {
        public let byteSize: Int64
        public let createdAt: Date?
        public let modifiedAt: Date?
    }

    public static func fileAttributes(of url: URL) -> FileAttributes {
        let fm = FileManager.default
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        let size = values?.fileSize.map { Int64($0) } ?? DirectoryStats.fileSize(at: url, fileManager: fm)
        return FileAttributes(
            byteSize: size,
            createdAt: values?.creationDate,
            modifiedAt: values?.contentModificationDate
        )
    }

    public static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard let width, let height else { return nil }
        return (width, height)
    }
}
