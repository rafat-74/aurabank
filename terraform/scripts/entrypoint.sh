#!/bin/sh
###############################################################################
# AuraBank – Service Entrypoint
# Reads DB credentials from AWS Secrets Manager (injected as env vars)
# and constructs the DATABASE_URL before starting uvicorn.
#
# Add to each service Dockerfile:
#   COPY entrypoint.sh /entrypoint.sh
#   RUN chmod +x /entrypoint.sh
#   ENTRYPOINT ["/entrypoint.sh"]
###############################################################################

set -e

# DB_SECRET_JSON is injected by ECS from Secrets Manager
# Format: {"username": "...", "password": "...", "dbname": "...", "schema": "..."}
if [ -n "${DB_SECRET_JSON}" ]; then
  DB_USER=$(echo "${DB_SECRET_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['username'])")
  DB_PASS=$(echo "${DB_SECRET_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['password'])")
  DB_SCHEMA=$(echo "${DB_SECRET_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('schema', 'public'))")

  # Build DATABASE_URL with schema in search_path for isolation
  export DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:${DB_PORT}/${DB_NAME}?options=-csearch_path%3D${DB_SCHEMA},public"
  echo "[entrypoint] DATABASE_URL constructed for schema: ${DB_SCHEMA}"
else
  echo "[entrypoint] WARNING: DB_SECRET_JSON not set, using DATABASE_URL as-is"
fi

# JWT_SECRET_JSON is injected by ECS from Secrets Manager
# Format: {"jwt_secret": "..."}
if [ -n "${JWT_SECRET_JSON}" ]; then
  export JWT_SECRET=$(echo "${JWT_SECRET_JSON}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['jwt_secret'])")
  echo "[entrypoint] JWT_SECRET loaded from Secrets Manager"
fi

# Start the application
exec "$@"
