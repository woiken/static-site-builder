import ArgumentParser
import Foundation
import Logging

@main
struct StaticBuilder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "static-builder",
        abstract: "Woiken Static Site Build Worker",
        version: "0.1.0"
    )

    @Flag(name: .long, help: "Print configuration and exit")
    var showConfig = false

    mutating func run() async throws {
        // Bootstrap logging
        LoggingSystem.bootstrap { label in
            var handler = StreamLogHandler.standardError(label: label)
            handler.logLevel = .info
            return handler
        }
        let logger = Logger(label: "cloud.woiken.static-builder")

        let config = Config.fromEnvironment()

        if showConfig {
            print("""
            Static Builder Configuration:
              RabbitMQ:       \(config.rabbitmqHost):\(config.rabbitmqPort)
              Commands queue: \(config.rabbitmqQueue)
              Results queue:  \(config.rabbitmqResultsQueue)
              Work dir:       \(config.workDir)
              Prefetch:       \(config.prefetchCount)
              Max retries:    \(config.maxRetries)
              S3 endpoint:    \(config.s3Endpoint)
              S3 bucket:      \(config.s3Bucket)
              S3 region:      \(config.s3Region)
            """)
            return
        }

        logger.info("Starting Woiken Static Builder worker...")
        logger.info("RabbitMQ: \(config.rabbitmqHost):\(config.rabbitmqPort)")
        logger.info("Commands queue: \(config.rabbitmqQueue)")
        logger.info("Results queue: \(config.rabbitmqResultsQueue)")

        let worker = Worker(config: config, logger: logger)

        // Retry connection loop with backoff
        var attempt = 0
        while true {
            do {
                try await worker.run()
                // If run() returns normally, the consumer stream ended — reconnect
                logger.warning("Consumer stream ended, reconnecting...")
                attempt = 0
            } catch {
                attempt += 1
                let delay = min(UInt64(pow(2.0, Double(attempt))), 30) // max 30s backoff
                logger.error("Worker error (attempt \(attempt)): \(error). Retrying in \(delay)s...")
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }
    }
}
