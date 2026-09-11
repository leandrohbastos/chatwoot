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

# Remove a potentially pre-existing server.pid for Rails.
rm -rf "$APP_ROOT/tmp/pids/server.pid"
rm -rf "$APP_ROOT/tmp/cache/"*

echo "Waiting for postgres to become ready...."

# Let DATABASE_URL env take precedence over individual connection params.
if [ -n "$DATABASE_URL" ] || [ -n "$POSTGRES_HOST" ]; then
  PG_HELPER="$APP_ROOT/docker/entrypoints/helpers/pg_database_url.rb"
  if [ -f "$PG_HELPER" ]; then
    eval $(ruby "$PG_HELPER")
  fi
  PG_READY="pg_isready -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USERNAME"

  until $PG_READY
  do
    echo "Waiting for postgres ($POSTGRES_HOST:$POSTGRES_PORT) to become ready..."
    sleep 2;
  done
  echo "Database ready to accept connections."
else
  echo "WARNING: Neither DATABASE_URL nor POSTGRES_HOST is configured! Please configure database environment variables."
fi

# In production gems are already installed in the image
if [ "$RAILS_ENV" != "production" ]; then
  bundle check || bundle install
fi

# Automatically prepare database if starting rails server
if [ "$1" = "bundle" ] && [ "$2" = "exec" ] && [ "$3" = "rails" ] && [ "$4" = "s" ]; then
  echo "Preparing database (running db:chatwoot_prepare)..."
  (cd "$APP_ROOT" && bundle exec rails db:chatwoot_prepare) || echo "db:chatwoot_prepare finished or skipped."
fi

# Execute the main process of the container
cd "$APP_ROOT"
exec "$@"
