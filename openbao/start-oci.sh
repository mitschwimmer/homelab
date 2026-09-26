#!/bin/sh
# PID 1 for the existing OCI images. Fail closed until Agent has rendered files.
set -eu

app_pid=
agent_pid=
stop() {
  [ -z "$app_pid" ] || kill "$app_pid" 2>/dev/null || true
  [ -z "$agent_pid" ] || kill "$agent_pid" 2>/dev/null || true
  [ -z "$app_pid" ] || wait "$app_pid" 2>/dev/null || true
  [ -z "$agent_pid" ] || wait "$agent_pid" 2>/dev/null || true
}
trap 'stop; exit 0' TERM INT

/opt/platform/bao agent -config=/etc/openbao/agent.hcl &
agent_pid=$!

# All required paths are non-secret configuration in the instance metadata.
# The mount itself is tmpfs, so stale files cannot survive a reboot.
for name in $HOMELAB_REQUIRED_SECRETS; do
  while [ ! -s "/run/secrets/$name" ]; do
    if ! kill -0 "$agent_pid" 2>/dev/null; then
      wait "$agent_pid" || true
      exit 1
    fi
    sleep 2
  done
done

case "$HOMELAB_SERVICE" in
  authelia) /app/entrypoint.sh & ;;
  grafana) /run.sh & ;;
  prometheus) /bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/prometheus & ;;
  *) echo "Unknown service" >&2; stop; exit 1 ;;
esac
app_pid=$!

while kill -0 "$agent_pid" 2>/dev/null && kill -0 "$app_pid" 2>/dev/null; do
  sleep 2 & wait $! || true
done
stop
exit 1
