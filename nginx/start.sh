#!/bin/sh
set -eu
TEMPLATE=/etc/nginx/templates/default.conf.tmpl
OUT=/etc/nginx/conf.d/default.conf
ACTIVE_POOL=${ACTIVE_POOL:-blue}
APP_PORT=${APP_PORT:-3000}

if [ "$ACTIVE_POOL" = "blue" ]; then
  PRIMARY_HOST="app_blue"
  BACKUP_HOST="app_green"
else
  PRIMARY_HOST="app_green"
  BACKUP_HOST="app_blue"
fi

sed -e "s/PRIMARY_HOST/${PRIMARY_HOST}/g" \
    -e "s/BACKUP_HOST/${BACKUP_HOST}/g" \
    -e "s/PRIMARY_PORT/${APP_PORT}/g" \
    -e "s/BACKUP_PORT/${APP_PORT}/g" \
    "$TEMPLATE" > "$OUT"

echo "Generated $OUT (PRIMARY=${PRIMARY_HOST}:${APP_PORT})"
nginx -t && nginx -g 'daemon off;'
