import Testing
@testable import StaticBuilder
import Foundation

@Suite("Models")
struct ModelsTests {
    @Test("BuildCommand decodes from JSON")
    func decodeBuildCommand() throws {
        let json = """
        {
            "id": "build-123",
            "siteId": "site-456",
            "repositoryUrl": "https://github.com/example/repo.git",
            "branch": "main",
            "buildCommand": "npm ci && npm run build",
            "outputDirectory": "dist",
            "commitSha": "abc123",
            "triggeredBy": "testuser",
            "status": "QUEUED",
            "createdAt": "2026-01-01T00:00:00Z",
            "artifactId": "artifact-001"
        }
        """
        let data = json.data(using: .utf8)!
        let cmd = try JSONDecoder().decode(BuildCommand.self, from: data)

        #expect(cmd.id == "build-123")
        #expect(cmd.siteId == "site-456")
        #expect(cmd.repositoryUrl == "https://github.com/example/repo.git")
        #expect(cmd.branch == "main")
        #expect(cmd.buildCommand == "npm ci && npm run build")
        #expect(cmd.outputDirectory == "dist")
        #expect(cmd.commitSha == "abc123")
        #expect(cmd.triggeredBy == "testuser")
        #expect(cmd.status == "QUEUED")
        #expect(cmd.artifactId == "artifact-001")
    }

    @Test("BuildCommand decodes without optional fields")
    func decodeBuildCommandWithoutOptionals() throws {
        let json = """
        {
            "id": "build-789",
            "siteId": "site-101",
            "repositoryUrl": "https://github.com/example/repo.git",
            "branch": "develop",
            "buildCommand": "yarn build",
            "outputDirectory": "build",
            "triggeredBy": "ciuser",
            "status": "QUEUED",
            "createdAt": "2026-01-02T00:00:00Z"
        }
        """
        let data = json.data(using: .utf8)!
        let cmd = try JSONDecoder().decode(BuildCommand.self, from: data)

        #expect(cmd.commitSha == nil)
        #expect(cmd.artifactId == nil)
        #expect(cmd.branch == "develop")
    }

    @Test("BuildCommand encodes to JSON round-trip")
    func encodeBuildCommand() throws {
        let cmd = BuildCommand(
            id: "build-rt",
            siteId: "site-rt",
            repositoryUrl: "https://github.com/test/repo.git",
            branch: "main",
            buildCommand: "make build",
            outputDirectory: "out",
            commitSha: nil,
            triggeredBy: "admin",
            status: BuildStatus.queued.rawValue,
            createdAt: "2026-02-05T00:00:00Z",
            artifactId: "art-123"
        )
        let data = try JSONEncoder().encode(cmd)
        let decoded = try JSONDecoder().decode(BuildCommand.self, from: data)

        #expect(decoded.id == cmd.id)
        #expect(decoded.siteId == cmd.siteId)
        #expect(decoded.status == "QUEUED")
        #expect(decoded.artifactId == "art-123")
    }

    @Test("BuildStatusUpdate encodes all fields")
    func encodeBuildStatusUpdate() throws {
        let update = BuildStatusUpdate(
            buildId: "build-1",
            siteId: "site-1",
            status: BuildStatus.failed.rawValue,
            artifactLocation: nil,
            errorMessage: "npm install failed",
            logSnippet: "ERR! code ENOENT",
            timestamp: "2026-02-05T12:00:00Z"
        )
        let data = try JSONEncoder().encode(update)
        let decoded = try JSONDecoder().decode(BuildStatusUpdate.self, from: data)

        #expect(decoded.buildId == "build-1")
        #expect(decoded.status == "FAILED")
        #expect(decoded.errorMessage == "npm install failed")
        #expect(decoded.logSnippet == "ERR! code ENOENT")
        #expect(decoded.artifactLocation == nil)
    }

    @Test("BuildStatusUpdate encodes success with S3 artifact location")
    func encodeSuccessStatusUpdate() throws {
        let update = BuildStatusUpdate(
            buildId: "build-2",
            siteId: "site-2",
            status: BuildStatus.succeeded.rawValue,
            artifactLocation: "s3://static-site-artifacts/art-456/",
            errorMessage: nil,
            logSnippet: nil,
            timestamp: "2026-02-05T12:05:00Z"
        )
        let data = try JSONEncoder().encode(update)
        let decoded = try JSONDecoder().decode(BuildStatusUpdate.self, from: data)

        #expect(decoded.status == "SUCCEEDED")
        #expect(decoded.artifactLocation == "s3://static-site-artifacts/art-456/")
        #expect(decoded.errorMessage == nil)
    }
}

@Suite("Config")
struct ConfigTests {
    @Test("Config loads defaults when no env vars set")
    func configDefaults() {
        let config = Config.fromEnvironment()
        #expect(config.rabbitmqQueue == "site-build-commands")
        #expect(config.rabbitmqResultsQueue == "site-build-results")
        #expect(config.prefetchCount == 1)
        #expect(config.maxRetries == 3)
        #expect(config.s3Bucket == "static-site-artifacts")
        #expect(config.s3Endpoint == "http://localhost:9002")
    }

    @Test("BuildStatus raw values match API contract")
    func buildStatusValues() {
        #expect(BuildStatus.queued.rawValue == "QUEUED")
        #expect(BuildStatus.running.rawValue == "RUNNING")
        #expect(BuildStatus.succeeded.rawValue == "SUCCEEDED")
        #expect(BuildStatus.failed.rawValue == "FAILED")
        #expect(BuildStatus.canceled.rawValue == "CANCELED")
    }
}

@Suite("BuildExecutor")
struct BuildExecutorTests {
    @Test("Shell helper runs simple command")
    func shellHelper() async {
        let result = await shell("echo", "hello")
        #expect(result.exitCode == 0)
        #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test("Shell helper captures exit code on failure")
    func shellFailure() async {
        let result = await shell("false")
        #expect(result.exitCode != 0)
    }

    @Test("ShellResult.lastLines returns tail of output")
    func lastLines() {
        let result = ShellResult(exitCode: 0, output: "line1\nline2\nline3\nline4\nline5")
        let last3 = result.lastLines(3)
        #expect(last3 == "line3\nline4\nline5")
    }
}
