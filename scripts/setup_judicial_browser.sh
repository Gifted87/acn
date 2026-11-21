#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BROWSER_DIR="${PROJECT_ROOT}/priv/judicial_browser"

cd "${BROWSER_DIR}"
npm ci
npx playwright install chromium

printf 'Judicial browser runtime is ready.\n'
