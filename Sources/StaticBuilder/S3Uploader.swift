import Foundation
import Logging
import SotoS3

/// Uploads build artifacts to S3 (or S3-compatible storage like MinIO).
/// Files are uploaded under `{artifactId}/` prefix in the configured bucket.
struct S3Uploader: Sendable {
    let client: AWSClient
    let s3: S3
    let bucket: String
    let logger: Logger

    init(config: Config, logger: Logger) {
        self.client = AWSClient(
            credentialProvider: .static(
                accessKeyId: config.s3AccessKey,
                secretAccessKey: config.s3SecretKey
            )
        )
        self.s3 = S3(
            client: self.client,
            region: .init(rawValue: config.s3Region),
            endpoint: config.s3Endpoint
        )
        self.bucket = config.s3Bucket
        self.logger = logger
    }

    /// Upload all files from a local directory to S3 under `{artifactId}/`.
    /// Returns the S3 prefix (e.g. `s3://bucket/artifactId/`).
    func upload(localPath: String, artifactId: String) async throws -> String {
        let basePath = URL(fileURLWithPath: localPath)

        // Collect file list synchronously to avoid Swift 6 concurrency issues
        let filesToUpload = try collectFiles(under: basePath)

        var uploadCount = 0
        for (fileURL, relativePath) in filesToUpload {
            let s3Key = "\(artifactId)/\(relativePath)"
            let data = try Data(contentsOf: fileURL)
            let contentType = mimeType(for: fileURL.pathExtension)

            let putRequest = S3.PutObjectRequest(
                body: .init(bytes: data),
                bucket: bucket,
                contentType: contentType,
                key: s3Key
            )
            _ = try await s3.putObject(putRequest)
            uploadCount += 1
            logger.debug("Uploaded \(s3Key) (\(data.count) bytes, \(contentType))")
        }

        let location = "s3://\(bucket)/\(artifactId)/"
        logger.info("Uploaded \(uploadCount) files to \(location)")
        return location
    }

    /// Collect all regular files under a directory, returning (fileURL, relativePath) pairs.
    private func collectFiles(under basePath: URL) throws -> [(URL, String)] {
        let fileManager = FileManager.default
        // Resolve symlinks (e.g. /tmp → /private/tmp on macOS) so paths match
        let resolvedBase = basePath.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(at: resolvedBase, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw S3UploadError.cannotEnumerateDirectory(resolvedBase.path)
        }

        let basePrefix = resolvedBase.path.hasSuffix("/") ? resolvedBase.path : resolvedBase.path + "/"
        var files: [(URL, String)] = []
        for case let fileURL as URL in enumerator {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues.isRegularFile == true else { continue }
            let fullPath = fileURL.resolvingSymlinksInPath().path
            let relativePath = fullPath.hasPrefix(basePrefix) ? String(fullPath.dropFirst(basePrefix.count)) : fullPath
            files.append((fileURL, relativePath))
        }
        return files
    }

    /// Shut down the AWS client. Call once when the worker is done.
    func shutdown() async throws {
        try await client.shutdown()
    }

    /// Map file extensions to MIME types for correct Content-Type headers.
    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs": return "application/javascript"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "xml": return "application/xml"
        case "txt": return "text/plain"
        case "map": return "application/json"
        case "webmanifest": return "application/manifest+json"
        default: return "application/octet-stream"
        }
    }
}

enum S3UploadError: Error, CustomStringConvertible {
    case cannotEnumerateDirectory(String)

    var description: String {
        switch self {
        case .cannotEnumerateDirectory(let path):
            return "Cannot enumerate directory: \(path)"
        }
    }
}
