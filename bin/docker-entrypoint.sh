#!/bin/sh
set -e

if [ -z "$SECRET_KEY_BASE" ]; then
  export SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\r\n')
fi

./bin/forge eval "Platser.Release.migrate()"

exec ./bin/platser start
