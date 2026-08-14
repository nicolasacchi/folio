# syntax=docker/dockerfile:1

# Production image for Folio, the Kindle private-cloud library server.
# Built and run via ~/traefik/docker-compose.yml (service "folio"):
#   docker compose build folio && docker compose up -d folio

ARG RUBY_VERSION=3.3.6
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

WORKDIR /rails

# Calibre provides ebook-convert/ebook-meta, which do all conversion,
# metadata, cover and text-extraction work. ocrmypdf (+ tesseract language
# packs) adds a text layer to scanned PDFs — see Library::Ocr/OcrBookJob —
# and pulls in ghostscript + tesseract-ocr as dependencies. Package names
# verified against this base image's release (Debian 12 "bookworm", per
# `docker run --rm ruby:3.3.6-slim cat /etc/os-release`).
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips sqlite3 calibre \
      ocrmypdf tesseract-ocr-eng tesseract-ocr-ita tesseract-ocr-deu tesseract-ocr-fra \
      tesseract-ocr-spa tesseract-ocr-por tesseract-ocr-rus tesseract-ocr-ara && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives && \
    ebook-convert --version && ebook-meta --version && ocrmypdf --version

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

# Bake the multilingual embedding model (see Library::Embeddings) into the
# image so runtime needs no network. Cached under XDG_CACHE_HOME/informers.
ENV XDG_CACHE_HOME="/rails/.cache"
RUN bundle exec ruby -r informers -e 'Informers.pipeline("embedding", "Xenova/paraphrase-multilingual-MiniLM-L12-v2").("warmup")' && \
    du -sh /rails/.cache

COPY . .

RUN bundle exec bootsnap precompile app/ lib/

RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

FROM base

ENV XDG_CACHE_HOME="/rails/.cache"

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

# uid/gid 1000 matches the host user that owns the bind-mounted storage and
# the read-only library share.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    chown -R rails:rails db log storage tmp .cache
USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

EXPOSE 3000
CMD ["./bin/rails", "server"]
