#!/bin/bash
# Creates one database per service on first container startup.
#
# IMPORTANT: scripts under docker-entrypoint-initdb.d only run the very
# first time the Postgres container starts on an EMPTY data volume. Adding
# a new entry here does NOT create the database for an already-running
# stack — see README.md ("Añadir la base de datos de un nuevo servicio").
set -e

# One database name per line. Keep this list sorted/alphabetical.
DATABASES=(
  "nestjs_template_db"
)

for db in "${DATABASES[@]}"; do
  echo "Ensuring database '$db' exists..."
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    SELECT 'CREATE DATABASE $db'
    WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db')\gexec
EOSQL
done
