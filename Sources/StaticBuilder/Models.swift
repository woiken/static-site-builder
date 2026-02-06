import Foundation

/// Mirrors the Kotlin `BuildCommand` model exactly.
struct BuildCommand: Codable, Sendable {
    let id: String
    let siteId: String
    let repositoryUrl: String
    let branch: String
    let buildCommand: String
    let outputDirectory: String
    let commitSha: String?
    let triggeredBy: String
    let status: String
    let createdAt: String
    let artifactId: String?
}

/// Status values matching the API service schema.
enum BuildStatus: String, Sendable {
    case queued = "QUEUED"
    case running = "RUNNING"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case canceled = "CANCELED"
}

/// Message published back to the API service via the results queue.
struct BuildStatusUpdate: Codable, Sendable {
    let buildId: String
    let siteId: String
    let status: String
    let artifactLocation: String?
    let errorMessage: String?
    let logSnippet: String?
    let timestamp: String
}
