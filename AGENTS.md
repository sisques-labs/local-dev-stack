# AGENTS.md

Guidance for AI coding agents working in this repository.

## What this repo is

`local-dev-stack` is a shared local development environment for NestJS
services cloned from `sisques-labs/nestjs-template`, defined as a single
Docker Compose stack. It provides PostgreSQL, Kafka, Redis, and an
OpenTelemetry observability stack (OTel Collector + Jaeger + Prometheus).

**This repo contains no application code.** Every file here is
infrastructure configuration: `docker-compose.yml`, service config under
`docker/`, and documentation. Do not add NestJS/application source here —
that belongs in service repos cloned from `nestjs-template`, which connect
to this stack over the network, they don't live inside it.

Read `README.md` first for the full picture (what's running, why, ports,
how services connect). This file only covers conventions for making
changes.

## Repository layout

```
docker-compose.yml           # the whole stack: Postgres, Redis, Kafka, Kafka UI,
                              # Jaeger, OTel Collector, Prometheus
docker/postgres/init-db.sh   # creates one DB per service on first Postgres boot
docker/otel/otel-collector-config.yaml
docker/otel/prometheus.yml
.env.example                 # documented defaults for every port/credential
README.md
```

## Core conventions

- **Pin every image version.** Never use `:latest`. When bumping a version,
  update it in `docker-compose.yml` and mention the old → new version in
  the commit message.
- **Fixed project name.** `docker-compose.yml` sets `name: local-dev-stack`
  at the top — don't remove it. It keeps container/network/volume names
  stable regardless of the checkout directory.
- **One shared network, fixed name.** All services join
  `local-dev-stack-net` (declared with an explicit `name:` under the
  top-level `networks:` key). Other repos are expected to join this network
  by name (`external: true` or `docker network connect`) — don't rename it
  without checking `README.md` for what depends on it.
- **No real credentials, ever.** Everything in `.env.example` and the
  `environment:` blocks in `docker-compose.yml` must stay local-dev-only
  defaults. Never introduce a secret, even a placeholder-looking one that
  happens to be real.
- **Document every port.** If you add a service or change a published
  port, update both the `Ports used` table in `README.md` and
  `.env.example`.
- **One Postgres instance, not one per service.** Don't add a second
  `postgres` service for a new database — add the database name to the
  `DATABASES` array in `docker/postgres/init-db.sh` instead (see
  `README.md` → "Adding a new service's database" for why editing that
  array doesn't retroactively affect an already-initialized volume).

## Validating a change

There's no test suite — this is Compose + config files. Validate changes
by actually running the stack:

```bash
# 1. Config is syntactically valid
docker compose config -q

# 2. Full stack comes up and stays up (not crash-looping)
docker compose up -d
sleep 15
docker compose ps          # every service should be "Up" (Postgres/Redis "healthy")

# 3. Check logs for the specific service you touched
docker compose logs <service> --tail 60

# 4. Clean up — don't leave a modified stack running or dangling volumes
docker compose down -v
```

If you touched `docker/postgres/init-db.sh`, you must verify it against a
**fresh** volume — `docker-entrypoint-initdb.d` scripts only run once, so
`docker compose up -d postgres` against an existing volume will silently
skip your change ("PostgreSQL Database directory appears to contain a
database; Skipping initialization"). Always `docker compose down -v` first,
then check the new database exists with:

```bash
docker compose exec -T postgres psql -U devuser -d postgres -l
```

If you touched the OTel/Jaeger/Prometheus config, confirm the pipeline
end-to-end, not just that containers started:

```bash
curl -s http://localhost:9090/api/v1/targets   # otel-collector target should be "up"
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8889/metrics  # 200
```

If you touched Kafka config, confirm the broker actually accepts topic
operations (a container can report "Up" while KRaft storage formatting
failed and it's about to crash-loop):

```bash
docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh \
  --create --topic smoke-test --bootstrap-server localhost:9092 \
  --partitions 1 --replication-factor 1
```

## Commit conventions

This repo follows [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <short summary>
```

- Common types here: `feat` (new service/tool added to the stack), `fix`
  (broken config, crash loop, wrong port), `chore` (version bumps, cleanup),
  `docs` (README/AGENTS.md only).
- Scope is usually the service touched, e.g. `feat(redis): add shared redis
  instance`, `fix(kafka): fix crash loop from root-owned volume`.
- Keep commits focused on one service/concern at a time — e.g. don't bundle
  a Kafka version bump with an unrelated Postgres change.

## Branching / PRs

- `main` is always expected to be a working stack — don't merge a change
  you haven't brought up with `docker compose up -d` per the validation
  steps above.
- Use short-lived feature branches named `<type>/<short-description>`,
  matching the commit type prefix, e.g. `feat/add-redis`,
  `fix/kafka-volume-permissions`.
- PR description should state what was validated (which of the steps above
  were run) — "updated the compose file" without confirming it actually
  starts is not enough given this repo has no CI test suite to catch that.
