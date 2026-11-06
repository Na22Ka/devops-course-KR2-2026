#!/usr/bin/env bash
# Доставка статического сайта: scripts/deploy.sh [--dry-run]
set -euo pipefail

REMOTE="devops"
REMOTE_DIR="/var/www/devops-site/"
SITE_URL="https://devops.local"
CA_CERT="${HOME}/devops.crt"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
LOCAL_DIR="${REPO_ROOT}/site/"
DRY_RUN=false

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
if [[ $# -eq 1 && "$1" == --dry-run ]]; then
    DRY_RUN=true
elif [[ $# -ne 0 ]]; then
    fail 'использование: deploy.sh [--dry-run]'
fi

[[ -f "${LOCAL_DIR}index.html" ]] || fail 'отсутствует site/index.html; доставка отменена'
[[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]] ||
    fail 'есть незафиксированные изменения; доставка отменена'
command -v rsync >/dev/null || fail 'rsync не установлен'
command -v curl >/dev/null || fail 'curl не установлен'
if ! "$DRY_RUN"; then
    [[ -r "$CA_CERT" ]] || fail "не найден доверенный сертификат $CA_CERT"
fi

options=(-avz --delete --chmod=D755,F644)
if "$DRY_RUN"; then options+=(--dry-run); fi
if ! rsync "${options[@]}" -e 'ssh -o BatchMode=yes -o ConnectTimeout=5' \
    "$LOCAL_DIR" "${REMOTE}:${REMOTE_DIR}"; then
    fail 'rsync завершился с ошибкой'
fi

if "$DRY_RUN"; then
    printf 'Пробный запуск завершён; сервер не изменён. Коммит %s\n' \
        "$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    exit 0
fi

if ! curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
    --cacert "$CA_CERT" --output /dev/null "$SITE_URL/"; then
    fail 'проверка доступности HTTPS не пройдена'
fi
printf 'Доставлен коммит %s; HTTPS доступен\n' \
    "$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
