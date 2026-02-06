import Foundation

/// Configuration loaded from environment variables with sensible dev defaults.
struct Config: Sendable {
    let rabbitmqHost: String
    let rabbitmqPort: Int
    let rabbitmqUser: String
    let rabbitmqPassword: String
    let rabbitmqQueue: String
    let rabbitmqResultsQueue: String

    let workDir: String
    let prefetchCount: UInt16
    let maxRetries: Int

    let s3Endpoint: String
    let s3Region: String
    let s3Bucket: String
    let s3AccessKey: String
    let s3SecretKey: String

    static func fromEnvironment() -> Config {
        Config(
            rabbitmqHost: env("RABBITMQ_HOST", default: "localhost"),
            rabbitmqPort: Int(env("RABBITMQ_PORT", default: "5672"))!,
            rabbitmqUser: env("RABBITMQ_USER", default: "static_site"),
            rabbitmqPassword: env("RABBITMQ_PASSWORD", default: "static_site"),
            rabbitmqQueue: env("RABBITMQ_QUEUE", default: "site-build-commands"),
            rabbitmqResultsQueue: env("RABBITMQ_RESULTS_QUEUE", default: "site-build-results"),

            workDir: env("WORK_DIR", default: "/tmp/static-builder/work"),
            prefetchCount: UInt16(env("PREFETCH_COUNT", default: "1"))!,
            maxRetries: Int(env("MAX_RETRIES", default: "3"))!,

            s3Endpoint: env("S3_ENDPOINT", default: "http://localhost:9002"),
            s3Region: env("S3_REGION", default: "us-east-1"),
            s3Bucket: env("S3_BUCKET", default: "static-site-artifacts"),
            s3AccessKey: env("S3_ACCESS_KEY", default: "minioadmin"),
            s3SecretKey: env("S3_SECRET_KEY", default: "minioadmin")
        )
    }

    private static func env(_ key: String, default defaultValue: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? defaultValue
    }
}
