# syntax=docker/dockerfile:1

# Production image for Folio, the Kindle private-cloud library server.
# Built and run via your reverse-proxy compose file (service "folio"):
#   docker compose build folio && docker compose up -d folio

ARG RUBY_VERSION=3.3.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Calibre provides ebook-convert/ebook-meta, which do all conversion,
# metadata, cover and text-extraction work.
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 calibre && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives && \
    ebook-convert --version && ebook-meta --version

# BUNDLE_WITHOUT is an ARG so CI/local test runs can build a variant with
# the development/test gems: docker build --build-arg BUNDLE_WITHOUT="" .
ARG BUNDLE_WITHOUT="development test"
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="${BUNDLE_WITHOUT}"

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile --gemfile

COPY . .

RUN bundle exec bootsnap precompile app/ lib/

RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# uid/gid 1000 matches the host user that owns the bind-mounted storage and
# the read-only library share.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 3000
CMD ["./bin/rails", "server"]
