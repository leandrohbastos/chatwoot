# pre-build stage
FROM node:24-slim AS node
FROM ruby:3.4.4-slim AS pre-builder

ARG NODE_VERSION="24.13.0"
ARG PNPM_VERSION="10.2.0"
ENV NODE_VERSION=${NODE_VERSION}
ENV PNPM_VERSION=${PNPM_VERSION}

# ARG default to production settings
ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.5.16

ARG RAILS_SERVE_STATIC_FILES=true
ENV RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES}

ARG RAILS_ENV=production
ENV RAILS_ENV=${RAILS_ENV}

ARG NODE_OPTIONS="--max-old-space-size=4096 --openssl-legacy-provider"
ENV NODE_OPTIONS=${NODE_OPTIONS}

ENV BUNDLE_PATH="/gems"
ENV PATH="/gems/bin:$PATH"

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    git \
    curl \
    pkg-config \
    libpq-dev \
    libvips-dev \
    libyaml-dev \
    tzdata \
    shared-mime-info \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /var/app \
  && gem install bundler -v "$BUNDLER_VERSION"

COPY --from=node /usr/local/bin/node /usr/local/bin/
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx

RUN npm install -g pnpm@${PNPM_VERSION}

RUN echo 'export PNPM_HOME="/root/.local/share/pnpm"' >> /root/.bashrc \
  && echo 'export PATH="$PNPM_HOME:$PATH"' >> /root/.bashrc \
  && export PNPM_HOME="/root/.local/share/pnpm" \
  && export PATH="$PNPM_HOME:$PATH" \
  && pnpm --version

ENV PNPM_HOME="/root/.local/share/pnpm"
ENV PATH="$PNPM_HOME:$PATH"

WORKDIR /app

COPY Gemfile Gemfile.lock ./

ENV MAKE="make -j1"

# Install gems (uses precompiled x86_64-linux gems for nokogiri, grpc, protobuf, etc.)
RUN if [ "$RAILS_ENV" = "production" ]; then \
    bundle config set without 'development test'; \
    bundle install -j 2 -r 3; \
  else \
    bundle install -j 2 -r 3; \
  fi

COPY package.json pnpm-lock.yaml ./
RUN pnpm i

COPY . /app

# creating a log directory so that image wont fail when RAILS_LOG_TO_STDOUT is false
# https://github.com/chatwoot/chatwoot/issues/701
RUN mkdir -p /app/log

# generate production assets if production environment
RUN if [ "$RAILS_ENV" = "production" ]; then \
    SECRET_KEY_BASE=precompile_placeholder RAILS_LOG_TO_STDOUT=enabled bundle exec rake assets:precompile \
    && rm -rf spec node_modules tmp/cache; \
  fi

# Generate .git_sha file with current commit hash (with fallback if .git is not in context)
ARG GIT_SHA=""
RUN (git rev-parse HEAD 2>/dev/null || echo "${GIT_SHA:-custom-build}") > /app/.git_sha

# Remove unnecessary files
RUN rm -rf /gems/cache/*.gem \
  && find /gems/ \( -name "*.c" -o -name "*.o" \) -delete \
  && rm -rf .git \
  && rm -f .gitignore

# final build stage
FROM ruby:3.4.4-slim

ARG NODE_VERSION="24.13.0"
ARG PNPM_VERSION="10.2.0"
ENV NODE_VERSION=${NODE_VERSION}
ENV PNPM_VERSION=${PNPM_VERSION}

ARG BUNDLE_WITHOUT="development:test"
ENV BUNDLE_WITHOUT=${BUNDLE_WITHOUT}
ENV BUNDLER_VERSION=2.5.16

ARG EXECJS_RUNTIME="Disabled"
ENV EXECJS_RUNTIME=${EXECJS_RUNTIME}

ARG RAILS_SERVE_STATIC_FILES=true
ENV RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES}

ARG RAILS_ENV=production
ENV RAILS_ENV=${RAILS_ENV}
ENV BUNDLE_PATH="/gems"
ENV PATH="/gems/bin:$PATH"

RUN apt-get update && apt-get install -y --no-install-recommends \
    postgresql-client \
    libpq5 \
    libvips42 \
    imagemagick \
    git \
    curl \
    tzdata \
    shared-mime-info \
    libjemalloc2 \
  && rm -rf /var/lib/apt/lists/* \
  && gem install bundler -v "$BUNDLER_VERSION"

# Configure jemalloc for optimal memory usage and low fragmentation
RUN if [ -f /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 ]; then \
      ln -s /usr/lib/x86_64-linux-gnu/libjemalloc.so.2 /usr/lib/libjemalloc.so.2; \
    elif [ -f /usr/lib/aarch64-linux-gnu/libjemalloc.so.2 ]; then \
      ln -s /usr/lib/aarch64-linux-gnu/libjemalloc.so.2 /usr/lib/libjemalloc.so.2; \
    fi
ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2

# Restrict libvips to its trusted image loaders when generating variants
ENV VIPS_BLOCK_UNTRUSTED=1

COPY --from=node /usr/local/bin/node /usr/local/bin/
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules

RUN if [ "$RAILS_ENV" != "production" ]; then \
  ln -s /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
  && ln -s /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
  && npm install -g pnpm@${PNPM_VERSION} \
  && pnpm --version; \
  fi

COPY --from=pre-builder /gems/ /gems/
COPY --from=pre-builder /app /chatwoot

# Copy entrypoints explicitly and install to /entrypoint.sh (safe from volume mounts)
COPY docker/entrypoints /chatwoot/docker/entrypoints
COPY docker/entrypoints/rails.sh /entrypoint.sh

RUN for f in /entrypoint.sh /chatwoot/docker/entrypoints/*.sh /chatwoot/docker/entrypoints/helpers/*; do \
      tr -d '\r' < "$f" > "$f.clean" && mv "$f.clean" "$f"; \
    done && \
    chmod +x /entrypoint.sh /chatwoot/docker/entrypoints/*.sh /chatwoot/docker/entrypoints/helpers/*

WORKDIR /chatwoot

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bundle", "exec", "rails", "s", "-p", "3000", "-b", "0.0.0.0"]

