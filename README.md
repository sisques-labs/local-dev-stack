# local-dev-stack

A shared local development environment, run via Docker Compose, for the
NestJS services cloned from
[`sisques-labs/nestjs-template`](https://github.com/sisques-labs/nestjs-template).

This repository contains **no application code** — only development
infrastructure: PostgreSQL, Kafka, Redis, and an OpenTelemetry observability
stack (OTel Collector + Jaeger + Prometheus). Services generated from
`nestjs-template` do **not** run their own copies of this infrastructure;
instead, each one connects to this shared stack via environment variables.

## Why a shared stack

Running a full Postgres + Kafka + observability stack per service is slow
to start, wastes resources, and makes cross-service testing (e.g. events
published by one service and consumed by another) harder to set up. This
repo centralizes that infrastructure once, so every service clone just
points at it.

## Prerequisites

- Docker and Docker Compose v2 (`docker compose`, not the legacy
  `docker-compose`).
- Ports 5432, 6379, 8080, 9092, 9090, 16686, 4317, 4318 and 8889 free on
  your machine (see [Ports used](#ports-used) below for how to change any of
  them).

## Getting started

```bash
docker compose up -d
```

Check that every container is up and healthy:

```bash
docker compose ps
```

Stop the stack without losing data:

```bash
docker compose down
```

Stop the stack **and delete all data** (Postgres, Redis, Prometheus — see
the [Kafka persistence](#kafka-persistence) note below for why Kafka isn't
listed):

```bash
docker compose down -v
```

Copy `.env.example` to `.env` if you want to change any port or credential.
If you don't create a `.env` file, the defaults baked into
`docker-compose.yml` are used, so the stack works out of the box.

## What's included

| Component        | Image                                          | Purpose                                            |
|-------------------|------------------------------------------------|-----------------------------------------------------|
| PostgreSQL         | `postgres:16.4-alpine`                        | Single shared instance, one database per service    |
| Redis              | `redis:7.4.0-alpine`                          | Shared cache/session store, no auth (local only)     |
| Kafka              | `apache/kafka:3.8.0`                          | Single-broker cluster, KRaft mode (no Zookeeper)     |
| Kafka UI           | `ghcr.io/kafbat/kafka-ui:v1.0.0`              | Web UI to inspect topics/messages                    |
| Jaeger             | `jaegertracing/all-in-one:1.60`               | Trace collector + UI                                 |
| OTel Collector     | `otel/opentelemetry-collector-contrib:0.108.0`| Receives OTLP, forwards traces to Jaeger, exposes metrics for Prometheus |
| Prometheus         | `prom/prometheus:v2.54.1`                     | Scrapes metrics from the OTel Collector              |

All images are pinned to a specific version — nothing uses `:latest`, so the
stack behaves the same for everyone and doesn't silently change on a
`docker compose pull`.

### PostgreSQL

A single shared Postgres instance, not one instance per service. On first
startup (empty data volume), `docker/postgres/init-db.sh` creates one
database per service from an easy-to-edit list — see
[Adding a new service's database](#adding-a-new-services-database). Data
persists in the named volume `local-dev-stack-postgres-data`.

### Kafka

A single-broker Kafka cluster running in **KRaft mode** (no Zookeeper),
using the official `apache/kafka` image. It exposes two listeners:

- `PLAINTEXT` (`kafka:19092`) — for other containers on the same Docker
  network (this is what your services should use).
- `PLAINTEXT_HOST` (`localhost:9092`) — for tools running directly on your
  host machine, outside Docker.

#### Kafka persistence

Kafka data is **not** persisted in a named volume, unlike Postgres. The
official `apache/kafka` image runs as a non-root user (uid 1000), and a
freshly created named volume is owned by `root` by Docker — the broker
can't write to it and crash-loops on startup. Since persistence for Kafka
wasn't a requirement (unlike Postgres), the simplest and most robust option
was to leave its storage ephemeral, matching Apache Kafka's own official
KRaft example. Practically: topics and messages survive a
`docker compose stop` / `start`, but are lost whenever the Kafka container
is recreated (`docker compose down`, `up -d --force-recreate`, etc.). If you
need durable Kafka data later, add a named volume plus an init step that
`chown`s it to uid 1000 before the broker starts.

### Kafka UI

Uses [`ghcr.io/kafbat/kafka-ui`](https://github.com/kafbat/kafka-ui) rather
than the original `provectuslabs/kafka-ui`. The original project has been
unmaintained since 2023 and has an unpatched CVE; `kafbat/kafka-ui` is the
actively maintained community fork.

### Observability (OpenTelemetry)

Services send traces and metrics via OTLP to the **OTel Collector**
(`otel-collector:4317` gRPC / `:4318` HTTP), not directly to Jaeger or
Prometheus. The collector then:

- forwards traces to **Jaeger** (`jaegertracing/all-in-one`, UI on 16686),
- exposes a Prometheus-compatible metrics endpoint on port 8889, which
  **Prometheus** scrapes every 15s (UI on 9090).

Collector config: `docker/otel/otel-collector-config.yaml`.
Prometheus config: `docker/otel/prometheus.yml`.

## Adding a new service's database

Databases are declared in `docker/postgres/init-db.sh`, in a `DATABASES`
array. To add a new service's database:

1. Add a line to the array, e.g.:

   ```bash
   DATABASES=(
     "nestjs_template_db"
     "billing_service_db"
   )
   ```

2. Apply the change:

   - **Fresh stack, or you can afford to lose current data:**

     ```bash
     docker compose down -v
     docker compose up -d
     ```

   - **Existing stack with data you want to keep** — scripts under
     `docker-entrypoint-initdb.d` only run the very first time Postgres
     starts on an empty data volume, so restarting the container does
     **not** re-run `init-db.sh`. Create the database by hand against the
     running instance instead:

     ```bash
     docker compose exec postgres psql -U devuser -d postgres \
       -c "CREATE DATABASE billing_service_db;"
     ```

## Pointing a nestjs-template service at this stack

Your service needs to be on the same Docker network
(`local-dev-stack-net`) to resolve the internal hostnames (`postgres`,
`kafka`, `redis`, `otel-collector`, etc.). Two ways to do that:

**Option A — the service has its own `docker-compose.yml`:** declare the
network as external instead of creating a new one:

```yaml
networks:
  default:
    name: local-dev-stack-net
    external: true
```

**Option B — a container that's already running:** attach it to the
network manually:

```bash
docker network connect local-dev-stack-net <container-name>
```

Environment variables to set on the service (using the network hostnames,
not `localhost`):

```bash
# The service's own database (created in init-db.sh)
DATABASE_HOST=postgres
DATABASE_PORT=5432
DATABASE_USER=devuser
DATABASE_PASSWORD=devpassword
DATABASE_NAME=nestjs_template_db

# Kafka — internal listener, not the host-published port
KAFKA_BROKERS=kafka:19092

# Redis
REDIS_HOST=redis
REDIS_PORT=6379

# OpenTelemetry — traces/metrics go to the collector, never straight to Jaeger
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317
OTEL_SERVICE_NAME=<your-service-name>
```

If you're running the service directly on the host instead of in Docker
(e.g. `npm run start:dev` outside a container), use `localhost` and the
host-published ports from the table below instead of the internal network
hostnames — e.g. `KAFKA_BROKERS=localhost:9092`,
`OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317`.

## Ports used

| Service         | Host port | Purpose                                     |
|------------------|-----------|-----------------------------------------------|
| PostgreSQL       | 5432      | Database connections                          |
| Redis            | 6379      | Redis connections                             |
| Kafka            | 9092      | Broker (`PLAINTEXT_HOST` listener)            |
| Kafka UI         | 8080      | Web UI to browse topics/messages              |
| Jaeger UI        | 16686     | Web UI for traces                             |
| OTel Collector   | 4317      | OTLP gRPC receiver                            |
| OTel Collector   | 4318      | OTLP HTTP receiver                            |
| OTel Collector   | 8889      | Metrics exposed for Prometheus to scrape      |
| Prometheus       | 9090      | Web UI / API                                  |

When adding a new tool to this stack, pick a free port outside this table
and document it here.

## Network

Every service in this stack shares the Docker network
`local-dev-stack-net`, created with a fixed name so other repositories can
join it (see [Pointing a nestjs-template service at this stack](#pointing-a-nestjs-template-service-at-this-stack))
without depending on this repo's Compose project name.

## Compose project name

`docker-compose.yml` sets a fixed Compose project name (`local-dev-stack`),
so container, network, and volume names stay stable and predictable
regardless of the directory this repo is checked out into.

## Credentials

Everything in `.env.example` is a local-development-only default — no real
secrets. Don't reuse these credentials anywhere outside this stack.
