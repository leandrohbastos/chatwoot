#!/bin/sh
set -x

# Remove a potentially pre-existing server.pid for Rails.
rm -rf /app/tmp/pids/server.pid
rm -rf /app/tmp/cache/*

echo "Waiting for postgres to become ready...."

# Let DATABASE_URL env take precedence over individual connection params.
if [ -n "$DATABASE_URL" ] || [ -n "$POSTGRES_HOST" ]; then
  if [ -f "/app/docker/entrypoints/helpers/pg_database_url.rb" ]; then
    eval $(ruby /app/docker/entrypoints/helpers/pg_database_url.rb)
  elif [ -f "docker/entrypoints/helpers/pg_database_url.rb" ]; then
    eval $(ruby docker/entrypoints/helpers/pg_database_url.rb)
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
  (cd /app && bundle exec rails db:chatwoot_prepare) || echo "db:chatwoot_prepare finished or skipped."
fi

# Execute the main process of the container
cd /app
exec "$@"
