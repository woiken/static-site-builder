# Woiken Static Builder

Swift build worker that consumes build commands from RabbitMQ, executes static site builds inside Docker containers, and publishes status updates back to the API service via a results queue.

**The worker has no database access.** All persistence is owned by the API service.

## Architecture

```
[API Service (Kotlin)]                        [Build Worker (Swift)]
        |                                              |
        |  POST /api/sites/{id}/builds                 |
        |  → insert QUEUED row in builds table         |
        |  → publish BuildCommand to RabbitMQ          |
        |     (site-build-commands queue)               |
        |                                              |
        |                                 consume ←----|
        |                                 git clone     |
        |                                 docker build  |
        |                                 copy artifacts|
        |                                              |
        |     (site-build-results queue)                |
        |  ← consume status updates                    |
        |  → update builds table                       |
        |     (RUNNING / SUCCEEDED / FAILED)           |
```

Two queues:
- **`site-build-commands`** — API → Worker (build instructions)
- **`site-build-results`** — Worker → API (status updates)

## Prerequisites

- Swift 6.0+
- Docker (for sandboxed build execution)
- Running RabbitMQ (from `static-site-service/docker-compose.yml`)

## Setup

1. Start the infrastructure:
   ```bash
   cd /Users/niklas/IdeaProjects/static-site-service
   docker-compose up -d postgres rabbitmq
   ```

2. Copy and configure environment:
   ```bash
   cp .env.example .env
   ```

3. Build:
   ```bash
   swift build
   ```

4. Run:
   ```bash
   swift run StaticBuilder
   ```

   Or with config check:
   ```bash
   swift run StaticBuilder --show-config
   ```

## Configuration

All config via environment variables (see `.env.example`):

| Variable | Default | Description |
|---|---|---|
| `RABBITMQ_HOST` | `localhost` | RabbitMQ host |
| `RABBITMQ_PORT` | `5672` | RabbitMQ port |
| `RABBITMQ_USER` | `static_site` | RabbitMQ username |
| `RABBITMQ_PASSWORD` | `static_site` | RabbitMQ password |
| `RABBITMQ_QUEUE` | `site-build-commands` | Commands queue (consume from) |
| `RABBITMQ_RESULTS_QUEUE` | `site-build-results` | Results queue (publish to) |
| `WORK_DIR` | `/tmp/static-builder/work` | Temporary clone/build directory |
| `ARTIFACT_DIR` | `/tmp/static-builder/artifacts` | Output artifact storage |
| `BUILD_DOCKER_IMAGE` | `node:20-alpine` | Docker image for builds |
| `PREFETCH_COUNT` | `1` | RabbitMQ prefetch count |
| `MAX_RETRIES` | `3` | Max retry attempts |

## Build Lifecycle

1. **API service** enqueues `BuildCommand` → `site-build-commands` + `QUEUED` row in `builds` table
2. **Worker** consumes command
3. **Worker** publishes `RUNNING` status → `site-build-results`
4. **Worker** clones repo, checks out commit, runs build in Docker (`--memory=512m --cpus=1 --network=none`)
5. **Worker** validates output directory, copies artifacts
6. **Worker** publishes `SUCCEEDED` or `FAILED` status → `site-build-results`
7. **Worker** ACKs the command message (only after result published)
8. **API service** consumes status update, updates `builds` table

### Error Handling

- **Decode errors** (malformed JSON): sent to dead-letter queue (`site-build-commands.dlq`), message ACKed
- **Transient errors** (RabbitMQ down, etc.): NACKed with requeue
- **Build failures** (clone fail, build fail, missing output): `FAILED` status published, message ACKed

## Testing

```bash
swift test
```

## Local E2E Test

```bash
# 1. Start infra
cd /Users/niklas/IdeaProjects/static-site-service
docker-compose up -d

# 2. Start API service (in one terminal)
./gradlew run

# 3. Start worker (in another terminal)
cd /Users/niklas/Developer/woiken-static-builder
swift run StaticBuilder

# 4. Create a site and trigger build
TOKEN=$(cd /Users/niklas/IdeaProjects/static-site-service && bash dev/generate-test-token.sh)

# Create site
curl -s -X POST http://localhost:8085/api/sites \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"test-site","repositoryUrl":"https://github.com/example/repo.git"}' | jq .

# Trigger build (use the siteId from above)
curl -s -X POST http://localhost:8085/api/sites/{siteId}/builds \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{}' | jq .

# Poll build status
curl -s http://localhost:8085/api/builds/{buildId} \
  -H "Authorization: Bearer $TOKEN" | jq .
```
