import AMQPClient
import Foundation
import Logging
import NIOCore
import NIOPosix

/// The main worker loop. Connects to RabbitMQ, consumes build commands,
/// executes them, and publishes status updates back to a results queue
/// for the API service to consume and persist.
struct Worker: Sendable {
    let config: Config
    let logger: Logger

    func run() async throws {
        // --- RabbitMQ connection ---
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let amqpConn = try await AMQPConnection.connect(
            use: eventLoopGroup.next(),
            from: .init(
                connection: .plain,
                server: .init(
                    host: config.rabbitmqHost,
                    port: config.rabbitmqPort,
                    user: config.rabbitmqUser,
                    password: config.rabbitmqPassword
                )
            )
        )
        logger.info("Connected to RabbitMQ at \(config.rabbitmqHost):\(config.rabbitmqPort)")

        let channel = try await amqpConn.openChannel()

        // Declare commands queue (idempotent, matches API publisher)
        let commandsQueue = config.rabbitmqQueue
        try await channel.queueDeclare(name: commandsQueue, durable: true)

        // Declare results queue (API service consumes this)
        let resultsQueue = config.rabbitmqResultsQueue
        try await channel.queueDeclare(name: resultsQueue, durable: true)

        // Declare dead-letter exchange + queue for unprocessable commands
        let dlxExchange = "\(commandsQueue).dlx"
        let dlqName = "\(commandsQueue).dlq"
        try await channel.exchangeDeclare(name: dlxExchange, type: "direct", durable: true)
        try await channel.queueDeclare(name: dlqName, durable: true)
        try await channel.queueBind(queue: dlqName, exchange: dlxExchange, routingKey: commandsQueue)

        // Set prefetch
        try await channel.basicQos(count: config.prefetchCount)

        logger.info("Consuming from '\(commandsQueue)', publishing results to '\(resultsQueue)'")

        let s3Uploader = S3Uploader(config: config, logger: logger)
        let executor = BuildExecutor(config: config, logger: logger, s3Uploader: s3Uploader)

        // Consume messages
        let consumer = try await channel.basicConsume(queue: commandsQueue, noAck: false)
        for try await message in consumer {
            let body = message.body
            guard body.readableBytes > 0 else {
                logger.warning("Received message with empty body, acking and skipping")
                try await channel.basicAck(message: message)
                continue
            }

            let data = Data(body.readableBytesView)

            do {
                let cmd = try JSONDecoder().decode(BuildCommand.self, from: data)
                logger.info("Received build command: id=\(cmd.id) site=\(cmd.siteId)")

                // Publish RUNNING status
                try await publishStatusUpdate(
                    channel: channel, queue: resultsQueue,
                    buildId: cmd.id, siteId: cmd.siteId,
                    status: .running
                )

                // Execute build
                let result = try await executor.execute(cmd)

                // Publish terminal status
                if result.success {
                    try await publishStatusUpdate(
                        channel: channel, queue: resultsQueue,
                        buildId: cmd.id, siteId: cmd.siteId,
                        status: .succeeded,
                        artifactLocation: result.artifactLocation
                    )
                } else {
                    try await publishStatusUpdate(
                        channel: channel, queue: resultsQueue,
                        buildId: cmd.id, siteId: cmd.siteId,
                        status: .failed,
                        errorMessage: result.errorMessage,
                        logSnippet: result.logSnippet
                    )
                }

                // ACK only after result is published
                try await channel.basicAck(message: message)
                logger.info("Build \(cmd.id) completed: \(result.success ? "SUCCEEDED" : "FAILED")")

            } catch let error as DecodingError {
                // Non-retryable: bad message format → DLQ
                logger.error("Failed to decode build command, sending to DLQ: \(error)")
                _ = try await channel.basicPublish(
                    from: body,
                    exchange: dlxExchange,
                    routingKey: commandsQueue
                )
                try await channel.basicAck(message: message)

            } catch {
                // Transient failure: NACK with requeue
                logger.error("Transient error processing build: \(error)")
                try await channel.basicNack(message: message, requeue: true)
            }
        }

        // Cleanup
        try await s3Uploader.shutdown()
        try await amqpConn.close()
    }

    /// Publish a BuildStatusUpdate to the results queue.
    private func publishStatusUpdate(
        channel: AMQPChannel,
        queue: String,
        buildId: String,
        siteId: String,
        status: BuildStatus,
        artifactLocation: String? = nil,
        errorMessage: String? = nil,
        logSnippet: String? = nil
    ) async throws {
        let update = BuildStatusUpdate(
            buildId: buildId,
            siteId: siteId,
            status: status.rawValue,
            artifactLocation: artifactLocation,
            errorMessage: errorMessage,
            logSnippet: logSnippet,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        let jsonData = try JSONEncoder().encode(update)
        var buffer = ByteBufferAllocator().buffer(capacity: jsonData.count)
        buffer.writeBytes(jsonData)
        _ = try await channel.basicPublish(
            from: buffer,
            exchange: "",
            routingKey: queue
        )
        logger.info("Published status update: build=\(buildId) status=\(status.rawValue)")
    }
}
