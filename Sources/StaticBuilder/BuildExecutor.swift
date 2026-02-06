import Foundation
import Logging

/// Executes builds directly inside the container.
/// Flow: clone repo → checkout ref → run build command (or skip for static sites) → validate output → upload to S3.
///
/// The worker itself runs inside a container with all build tools pre-installed
/// (Node.js, Python, Hugo, etc.), so no Docker-in-Docker is needed.
struct BuildExecutor: Sendable {
    let config: Config
    let logger: Logger
    let s3Uploader: S3Uploader

    struct BuildResult: Sendable {
        let success: Bool
        let artifactLocation: String?
        let errorMessage: String?
        let logSnippet: String?
    }

    /// Sentinel value indicating that no build step is needed (static site).
    /// The site's files are uploaded directly from the output directory.
    private static let staticBuildCommands: Set<String> = [
        "", "none", "static", "skip"
    ]

    /// Whether this build command means "just upload files, don't run anything".
    private func isStaticSite(_ buildCommand: String) -> Bool {
        Self.staticBuildCommands.contains(buildCommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Run the full build pipeline for a single command.
    func execute(_ cmd: BuildCommand) async throws -> BuildResult {
        let buildDir = "\(config.workDir)/\(cmd.id)"

        defer {
            // Clean up work directory
            try? FileManager.default.removeItem(atPath: buildDir)
        }

        // 1. Create work directory
        try FileManager.default.createDirectory(atPath: buildDir, withIntermediateDirectories: true)

        // 2. Clone repository
        logger.info("[\(cmd.id)] Cloning \(cmd.repositoryUrl) branch=\(cmd.branch)")
        let cloneResult = await shell(
            "git", "clone", "--depth=1", "--branch", cmd.branch,
            cmd.repositoryUrl, "\(buildDir)/repo"
        )
        guard cloneResult.exitCode == 0 else {
            logger.error("[\(cmd.id)] git clone failed (exit \(cloneResult.exitCode)):\n\(cloneResult.output)")
            return BuildResult(
                success: false, artifactLocation: nil,
                errorMessage: "git clone failed (exit \(cloneResult.exitCode))",
                logSnippet: cloneResult.lastLines(50)
            )
        }
        logger.info("[\(cmd.id)] Clone succeeded")

        // 3. Checkout specific commit if provided
        if let sha = cmd.commitSha {
            logger.info("[\(cmd.id)] Checking out commit \(sha)")
            let checkoutResult = await shell(
                "git", "-C", "\(buildDir)/repo", "checkout", sha
            )
            guard checkoutResult.exitCode == 0 else {
                logger.error("[\(cmd.id)] git checkout failed (exit \(checkoutResult.exitCode)):\n\(checkoutResult.output)")
                return BuildResult(
                    success: false, artifactLocation: nil,
                    errorMessage: "git checkout \(sha) failed (exit \(checkoutResult.exitCode))",
                    logSnippet: checkoutResult.lastLines(50)
                )
            }
        }

        // 4. Run build command — or skip for static sites
        let repoDir = "\(buildDir)/repo"
        if isStaticSite(cmd.buildCommand) {
            logger.info("[\(cmd.id)] Static site — skipping build step")
        } else {
            logger.info("[\(cmd.id)] Running build: \(cmd.buildCommand)")
            let buildResult = await shell(
                "sh", "-c", "cd \(repoDir) && \(cmd.buildCommand)"
            )
            if !buildResult.output.isEmpty {
                logger.info("[\(cmd.id)] Build output:\n\(buildResult.output)")
            }
            guard buildResult.exitCode == 0 else {
                logger.error("[\(cmd.id)] Build command failed (exit \(buildResult.exitCode))")
                return BuildResult(
                    success: false, artifactLocation: nil,
                    errorMessage: "Build command failed (exit \(buildResult.exitCode))",
                    logSnippet: buildResult.lastLines(100)
                )
            }
            logger.info("[\(cmd.id)] Build command succeeded")
        }

        // 5. Determine and validate output directory
        //    For static sites with outputDirectory "." or empty, use the repo root
        let outputDir = cmd.outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputPath: String
        if outputDir.isEmpty || outputDir == "." {
            outputPath = repoDir
        } else {
            outputPath = "\(repoDir)/\(outputDir)"
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            logger.error("[\(cmd.id)] Output directory '\(cmd.outputDirectory)' not found after build")
            return BuildResult(
                success: false, artifactLocation: nil,
                errorMessage: "Output directory '\(cmd.outputDirectory)' not found after build",
                logSnippet: nil
            )
        }

        // 6. Upload artifacts to S3
        guard let artifactId = cmd.artifactId else {
            logger.error("[\(cmd.id)] No artifactId provided in build command")
            return BuildResult(
                success: false, artifactLocation: nil,
                errorMessage: "No artifactId provided in build command",
                logSnippet: nil
            )
        }

        logger.info("[\(cmd.id)] Uploading artifacts to S3 under \(artifactId)/")
        do {
            let location = try await s3Uploader.upload(localPath: outputPath, artifactId: artifactId)
            logger.info("[\(cmd.id)] Build succeeded, artifacts at \(location)")
            return BuildResult(
                success: true,
                artifactLocation: location,
                errorMessage: nil,
                logSnippet: nil
            )
        } catch {
            logger.error("[\(cmd.id)] S3 upload failed: \(error)")
            return BuildResult(
                success: false, artifactLocation: nil,
                errorMessage: "S3 upload failed: \(error)",
                logSnippet: nil
            )
        }
    }
}

// MARK: - Shell helper

struct ShellResult: Sendable {
    let exitCode: Int32
    let output: String

    func lastLines(_ n: Int) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).joined(separator: "\n")
    }
}

func shell(_ args: String...) async -> ShellResult {
    await withCheckedContinuation { continuation in
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            // Read all data BEFORE waitUntilExit to avoid pipe buffer deadlock
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let output = String(data: data, encoding: .utf8) ?? ""
            continuation.resume(returning: ShellResult(
                exitCode: process.terminationStatus,
                output: output
            ))
        } catch {
            continuation.resume(returning: ShellResult(
                exitCode: -1,
                output: "Failed to launch process: \(error)"
            ))
        }
    }
}
