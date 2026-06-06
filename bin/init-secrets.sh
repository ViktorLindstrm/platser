#!/bin/sh
set -e

ENV_FILE=".env"

if [ -f "$ENV_FILE" ] && grep -q "^SECRET_KEY_BASE=" "$ENV_FILE"; then
  echo "✓ $ENV_FILE already contains SECRET_KEY_BASE — nothing to do."
  exit 0
fi

SECRET=$(docker run --rm ghcr.io/viktorlindstrm/forge:latest eval \
  "IO.puts(:crypto.strong_rand_bytes(48) |> Base.encode64())" 2>/dev/null | tr -d '\r\n')

if [ -z "$SECRET" ]; then
  echo "✗ Failed to generate secret. Make sure Docker is running." >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  cp .env.example "$ENV_FILE" 2>/dev/null || touch "$ENV_FILE"
fi

if grep -q "^SECRET_KEY_BASE=" "$ENV_FILE" 2>/dev/null; then
  sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$SECRET|" "$ENV_FILE"
else
  echo "SECRET_KEY_BASE=$SECRET" >> "$ENV_FILE"
fi

echo "✓ Generated and saved SECRET_KEY_BASE to $ENV_FILE"
