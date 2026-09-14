#!/bin/sh
set -x

# Detect app root: /chatwoot (production image) or /app (legacy/dev)
if [ -f "/chatwoot/Gemfile" ]; then
  APP_ROOT="/chatwoot"
elif [ -f "/app/Gemfile" ]; then
  APP_ROOT="/app"
else
  APP_ROOT="/chatwoot"
fi

# Remove a potentially pre-existing server.pid for Rails and clear stale cache.
rm -rf "$APP_ROOT/tmp/pids/server.pid"
rm -rf "$APP_ROOT/tmp/cache/"*

# 0. Default Environment Variables (fallback for standalone/testing if not set in Coolify)
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-e50771f33439c72fbbdd984e14bef71ea08fa679c2fb36b01eb63dc51429276f53f471ead6a1281462ba0e69f15d782f56508ca1584d17f1f7e5417b4c6a791b}"
export ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="${ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY:-19500713ce7287b5d96bb687167ff290c369a591274c473a4b6edea289c1850a}"
export ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="${ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY:-1b3f4c2eebc836debe32fde385eb433c6d8109888f2f90b91c51a7d4563f44d0}"
export ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="${ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT:-609606326f2566aa1792db398a3880d637e512cd0eb73f6b3e63ad3915e917e0}"
export FRONTEND_URL="${FRONTEND_URL:-https://liachat.clickupbot.com}"
export FORCE_SSL="${FORCE_SSL:-true}"
export RAILS_ENV="${RAILS_ENV:-production}"
export RAILS_LOG_TO_STDOUT="${RAILS_LOG_TO_STDOUT:-true}"

# 1. Start embedded Redis if REDIS_URL not configured
if [ -z "$REDIS_URL" ]; then
  echo "Setting up embedded Redis..."
  mkdir -p /data/redis
  chown -R redis:redis /data/redis 2>/dev/null || true
  redis-server --daemonize yes --dir /data/redis --bind 127.0.0.1 --protected-mode no
  export REDIS_URL="redis://127.0.0.1:6379"
  echo "Embedded Redis running at $REDIS_URL"
fi

# 2. Start embedded PostgreSQL if DATABASE_URL and POSTGRES_HOST are not configured
if [ -z "$DATABASE_URL" ] && [ -z "$POSTGRES_HOST" ]; then
  echo "Setting up embedded PostgreSQL..."
  mkdir -p /data/postgres /run/postgresql
  chown -R postgres:postgres /data/postgres /run/postgresql 2>/dev/null || true
  chmod 700 /data/postgres

  # Remove stale postmaster.pid if present from previous shutdown
  rm -f /data/postgres/postmaster.pid

  if [ ! -s "/data/postgres/PG_VERSION" ]; then
    echo "Initializing PostgreSQL data in /data/postgres..."
    su -s /bin/sh -c "initdb -D /data/postgres -E UTF8 --no-locale -U postgres" postgres
    echo "host all all 127.0.0.1/32 trust" >> /data/postgres/pg_hba.conf
    echo "host all all ::1/128 trust" >> /data/postgres/pg_hba.conf
    echo "local all all trust" >> /data/postgres/pg_hba.conf
  fi

  echo "Starting PostgreSQL server..."
  su -s /bin/sh -c "pg_ctl -D /data/postgres -l /data/postgres/server.log -w start -o '-c listen_addresses=127.0.0.1'" postgres

  # Create chatwoot_production database if not exists
  su -s /bin/sh -c "psql -U postgres -tc \"SELECT 1 FROM pg_database WHERE datname = 'chatwoot_production'\" | grep -q 1 || psql -U postgres -c 'CREATE DATABASE chatwoot_production;'" postgres 2>/dev/null || true
  su -s /bin/sh -c "psql -U postgres -c 'CREATE EXTENSION IF NOT EXISTS vector;' -d chatwoot_production" postgres 2>/dev/null || true

  export POSTGRES_HOST="127.0.0.1"
  export POSTGRES_PORT="5432"
  export POSTGRES_USERNAME="postgres"
  export POSTGRES_PASSWORD=""
  export POSTGRES_DATABASE="chatwoot_production"
  export DATABASE_URL="postgresql://postgres@127.0.0.1:5432/chatwoot_production"
  echo "Embedded PostgreSQL ready at $DATABASE_URL"
fi

# 3. If external DATABASE_URL or POSTGRES_HOST is configured, wait for it
if [ "$POSTGRES_HOST" != "127.0.0.1" ] && [ -n "$POSTGRES_HOST" ]; then
  PG_HELPER="$APP_ROOT/docker/entrypoints/helpers/pg_database_url.rb"
  if [ -f "$PG_HELPER" ]; then
    eval $(ruby "$PG_HELPER")
  fi

  until pg_isready -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USERNAME:-postgres}"; do
    echo "Waiting for postgres ($POSTGRES_HOST:${POSTGRES_PORT:-5432}) to become ready..."
    sleep 2
  done
  echo "Database ready to accept connections."

  # Ensure target database and extensions exist (handles legacy volumes initialized with 'chatwoot')
  export PGPASSWORD="${POSTGRES_PASSWORD:-chatwoot}"
  TARGET_DB="${POSTGRES_DATABASE:-chatwoot_production}"
  echo "Verifying database $TARGET_DB on $POSTGRES_HOST..."
  if ! psql -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USERNAME:-postgres}" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$TARGET_DB'" 2>/dev/null | grep -q 1; then
    echo "Database $TARGET_DB does not exist. Creating..."
    psql -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USERNAME:-postgres}" -d postgres -c "CREATE DATABASE \"$TARGET_DB\";" 2>/dev/null || true
  fi

  echo "Ensuring vector extension on $TARGET_DB..."
  psql -h "$POSTGRES_HOST" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USERNAME:-postgres}" -d "$TARGET_DB" -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || true
fi

# 4. In production gems are already installed in the image
if [ "$RAILS_ENV" != "production" ]; then
  bundle check || bundle install
fi

# 5. Automatically prepare database if starting rails server
if [ "$1" = "bundle" ] && [ "$2" = "exec" ] && [ "$3" = "rails" ] && [ "$4" = "s" ]; then
  echo "Preparing database (running db:chatwoot_prepare)..."
  (cd "$APP_ROOT" && bundle exec rails db:chatwoot_prepare) || echo "db:chatwoot_prepare finished or skipped."

  if [ "$DISABLE_EMBEDDED_SIDEKIQ" != "true" ] && [ "$DISABLE_EMBEDDED_SIDEKIQ" != "1" ]; then
    echo "Starting Sidekiq background processor..."
    (cd "$APP_ROOT" && bundle exec sidekiq -C config/sidekiq.yml) &
  else
    echo "Embedded Sidekiq disabled (managed by dedicated service)."
  fi
fi

# Execute the main process of the container
cd "$APP_ROOT"
exec "$@"
