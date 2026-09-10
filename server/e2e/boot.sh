#!/usr/bin/env bash
# Boots the Rails app for the Playwright e2e suite against an ISOLATED
# database (storage/e2e.sqlite3 via DATABASE_URL) and library root
# (storage/e2e-library via LIBRARY_ROOT), so neither the RSpec test database
# nor the development data is ever touched. Started by playwright.config.js's
# webServer; port overridable with E2E_PORT.
set -euo pipefail
cd "$(dirname "$0")/.."

export RAILS_ENV=test
export DATABASE_URL="sqlite3:storage/e2e.sqlite3"
export LIBRARY_ROOT="$PWD/storage/e2e-library"
export SECRET_KEY_BASE=e2e-not-a-secret

bin/rails db:prepare > /dev/null
bin/rails runner e2e/seed.rb

exec bin/rails server -p "${E2E_PORT:-3100}"
