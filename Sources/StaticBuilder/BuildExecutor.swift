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

    /// Callback for streaming log lines during a build.
    typealias LogCallback = @Sendable (String) async -> Void

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
    /// - Parameter onLog: Optional callback invoked for each line of output (for live streaming).
    func execute(_ cmd: BuildCommand, onLog: LogCallback? = nil) async throws -> BuildResult {
        let buildDir = "\(config.workDir)/\(cmd.id)"

        defer {
            // Clean up work directory
            try? FileManager.default.removeItem(atPath: buildDir)
        }

        // 1. Create work directory
        try FileManager.default.createDirectory(atPath: buildDir, withIntermediateDirectories: true)

        // 2. Clone repository
        let cloneMsg = "Cloning \(cmd.repositoryUrl) (branch: \(cmd.branch))..."
        logger.info("[\(cmd.id)] \(cloneMsg)")
        await onLog?(cloneMsg)

        let cloneResult = await streamingShell(
            args: ["git", "clone", "--depth=1", "--branch", cmd.branch, cmd.repositoryUrl, "\(buildDir)/repo"],
            onLine: onLog
        )
        guard cloneResult.exitCode == 0 else {
            let errMsg = "git clone failed (exit \(cloneResult.exitCode))"
            logger.error("[\(cmd.id)] \(errMsg)")
            await onLog?("ERROR: \(errMsg)")
            return BuildResult(
                success: false, artifactLocation: nil,
                errorMessage: errMsg,
                logSnippet: cloneResult.lastLines(50)
            )
        }
        await onLog?("Clone completed successfully.")

        // 3. Checkout specific commit if provided
        if let sha = cmd.commitSha {
            let checkoutMsg = "Checking out commit \(sha)..."
            logger.info("[\(cmd.id)] \(checkoutMsg)")
            await onLog?(checkoutMsg)

            let checkoutResult = await streamingShell(
                args: ["git", "-C", "\(buildDir)/repo", "checkout", sha],
                onLine: onLog
            )
            guard checkoutResult.exitCode == 0 else {
                let errMsg = "git checkout \(sha) failed (exit \(checkoutResult.exitCode))"
                logger.error("[\(cmd.id)] \(errMsg)")
                await onLog?("ERROR: \(errMsg)")
                return BuildResult(
                    success: false, artifactLocation: nil,
                    errorMessage: errMsg,
                    logSnippet: checkoutResult.lastLines(50)
                )
            }
        }

        // 4. Run build command — or skip for static sites
        let repoDir = "\(buildDir)/repo"
        if isStaticSite(cmd.buildCommand) {
            let msg = "No build step required — uploading files directly."
            logger.info("[\(cmd.id)] \(msg)")
            await onLog?(msg)
        } else {
            let buildMsg = "Running build command: \(cmd.buildCommand)"
            logger.info("[\(cmd.id)] \(buildMsg)")
            await onLog?(buildMsg)

            let buildResult = await streamingShell(
                args: ["sh", "-c", "cd \(repoDir) && \(cmd.buildCommand)"],
                onLine: onLog
            )
            guard buildResult.exitCode == 0 else {
                let errMsg = "Build command failed (exit \(buildResult.exitCode))"
                logger.error("[\(cmd.id)] \(errMsg)")
                await onLog?("ERROR: \(errMsg)")
                return BuildResult(
                    success: false, artifactLocation: nil,
                    errorMessage: errMsg,
                    logSnippet: buildResult.lastLines(100)
                )
            }
            await onLog?("Build completed successfully.")
        }

        // 5. Determine and validate output directory
        let outputDir = cmd.outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputPath: String
        if outputDir.isEmpty || outputDir == "." {
            outputPath = repoDir
        } else {
            outputPath = "\(repoDir)/\(outputDir)"
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            let errMsg = "Output directory '\(cmd.outputDirectory)' not found after build"
            logger.error("[\(cmd.id)] \(errMsg)")
            await onLog?("ERROR: \(errMsg)")
            return BuildResult(
                success: false, artifactLocation: nil,
                errorMessage: errMsg,
                logSnippet: nil
            )
        }

        // 6. Upload artifacts to S3
        guard let artifactId = cmd.artifactId else {
            let errMsg = "No artifactId provided in build command"
            logger.error("[\(cmd.id)] \(errMsg)")
            await onLog?("ERROR: \(errMsg)")
            return BuildResult(
                success: false, artifactLocation: nil,
                errorMessage: errMsg,
                logSnippet: nil
            )
        }

        let uploadMsg = "Uploading artifacts to S3..."
        logger.info("[\(cmd.id)] \(uploadMsg)")
        await onLog?(uploadMsg)

        do {
            let location = try await s3Uploader.upload(localPath: outputPath, artifactId: artifactId)
            let doneMsg = "Deploy complete! Artifacts at \(location)"
            logger.info("[\(cmd.id)] \(doneMsg)")
            await onLog?(doneMsg)
            return BuildResult(
                success: true,
                artifactLocation: location,
                errorMessage: nil,
                logSnippet: nil
            )
        } catch {
            let errMsg = "S3 upload failed: \(error)"
            logger.error("[\(cmd.id)] \(errMsg)")
            await onLog?("ERROR: \(errMsg)")
            return BuildResult(
                success: false, artifactLocation: nil,
                errorMessage: errMsg,
                logSnippet: nil
            )
        }
    }
}

// MARK: - Shell helpers

struct ShellResult: Sendable {
    let exitCode: Int32
    let output: String

    func lastLines(_ n: Int) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(n).joined(separator: "\n")
    }
}

/// Non-streaming shell execution (used by tests or when no log callback is needed).
func shell(_ args: String...) async -> ShellResult {
    await streamingShell(args: args, onLine: nil)
}

/// Streaming shell execution that invokes `onLine` for each line of combined stdout+stderr.
func streamingShell(args: [String], onLine: (@Sendable (String) async -> Void)?) async -> ShellResult {
    await withCheckedContinuation { continuation in
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()

            // Read output line-by-line for streaming
            if let onLine = onLine {
                Task {
                    let handle = pipe.fileHandleForReading
                    var accumulated = Data()
                    var allOutput = ""

                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        accumulated.append(chunk)

                        // Process complete lines
                        while let range = accumulated.range(of: Data("\n".utf8)) {
                            let lineData = accumulated.subdata(in: accumulated.startIndex..<range.lowerBound)
                            accumulated.removeSubrange(accumulated.startIndex..<range.upperBound)
                            if let line = String(data: lineData, encoding: .utf8) {
                                allOutput += line + "\n"
                                await onLine(line)
                            }
                        }
                    }

                    // Flush remaining partial line
                    if !accumulated.isEmpty, let line = String(data: accumulated, encoding: .utf8), !line.isEmpty {
                        allOutput += line
                        await onLine(line)
                    }

                    process.waitUntilExit()
                    continuation.resume(returning: ShellResult(
                        exitCode: process.terminationStatus,
                        output: allOutput
                    ))
                }
            } else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: ShellResult(
                    exitCode: process.terminationStatus,
                    output: output
                ))
            }
        } catch {
            continuation.resume(returning: ShellResult(
                exitCode: -1,
                output: "Failed to launch process: \(error)"
            ))
        }
    }
}
