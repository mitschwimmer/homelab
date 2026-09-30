#!/bin/sh
set -eu

# Open WebUI has no OAUTH_CLIENT_SECRET_FILE setting. Read the mounted
# credential into the process environment without putting its value in
# Incus configuration, command arguments, or logs.
OAUTH_CLIENT_SECRET=$(cat /var/lib/homelab-secrets/client_secret)
WEBUI_SECRET_KEY=$(cat /var/lib/homelab-secrets/secret_key)
test -n "$OAUTH_CLIENT_SECRET"
test -n "$WEBUI_SECRET_KEY"
export OAUTH_CLIENT_SECRET WEBUI_SECRET_KEY
cd /app/backend
exec bash start.sh
