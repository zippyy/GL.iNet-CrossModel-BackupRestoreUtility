#!/usr/bin/env bash
# Container smoke test for the Docker edition (Blocker 7 / CI).
#
# Builds the hardened image and exercises the REAL container:
#   - compose configuration is valid with an isolated temporary secret
#   - process starts, /api/health is healthy
#   - process is NOT uid 0
#   - /data is writable; application tree is read-only to the runtime user
#   - authentication is fail-closed (no cookie rejected, wrong password rejected,
#     valid login issues session + CSRF, missing CSRF rejected, valid CSRF passes)
#   - static UI (index.html, app.js, app.css) loads
#   - restart preserves /data (persistent named volume)
#   - graceful stop (SIGTERM) exits cleanly
#
# Usage:
#   test/container-smoke.sh [image-tag]
# Env: SMOKE_SECRET_FILE (optional path to an existing admin secret file)
set -euo pipefail

IMAGE="${1:-glinet-crossmodel-docker:test}"
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$ROOT"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# Every failure path dumps container state/logs so CI failures are never
# silent (a previous run died at a docker exec with stderr swallowed and the
# ERR trap did not fire on die's explicit exit).
dump_diagnostics() {
  echo "--- container diagnostics ---" >&2
  docker ps -a --filter "name=$NAME" --format '{{.Names}}  {{.Status}}' >&2 2>/dev/null || true
  docker inspect -f 'state={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} exit={{.State.ExitCode}} error={{.State.Error}} oom={{.State.OOMKilled}}' "$NAME" >&2 2>/dev/null || echo "no container $NAME" >&2
  echo "--- full container logs (verbatim) ---" >&2
  docker logs "$NAME" >&2 2>&1 || echo "(docker logs failed)" >&2
  echo "--- healthcheck log ---" >&2
  docker inspect -f '{{range .State.Health.Log}}{{.ExitCode}} {{.Output}}{{end}}' "$NAME" >&2 2>/dev/null || true
  echo "--- config summary ---" >&2
  docker inspect -f 'user={{.Config.User}} readonly={{.HostConfig.ReadonlyRootfs}} entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}}' "$NAME" >&2 2>/dev/null || true
}
die() { dump_diagnostics; bad "$1"; exit 1; }
trap 'dump_diagnostics' ERR

WORK=$(mktemp -d /tmp/gcm-container-smoke.XXXXXX)
SECRET_FILE="${SMOKE_SECRET_FILE:-$WORK/admin_password}"
[ -f "$SECRET_FILE" ] || printf '%s\n' 'container-smoke-admin-secret-123' > "$SECRET_FILE"
chmod 600 "$SECRET_FILE"
ADMIN_PASSWORD=$(cat "$SECRET_FILE")
NAME="gcm-smoke-$RANDOM$$"
PORT=$((20000 + RANDOM % 20000))
VOLUME="gcm-smoke-data-$RANDOM$$"
CLEANUP=()

cleanup() {
  for c in "${CLEANUP[@]:-}"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
  docker volume rm "$VOLUME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== compose config =="
export GCM_ADMIN_PASSWORD_FILE="$SECRET_FILE"
if docker compose config >/dev/null 2>&1; then ok 'docker compose config is valid'; else die 'docker compose config FAILED'; fi

echo "== image build =="
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "image $IMAGE already present"
else
  docker build -t "$IMAGE" . >/dev/null 2>&1 || die 'docker build FAILED'
  ok 'docker build succeeded'
fi

echo "== start container (read-only root, tmpfs /tmp, named volume /data, secret file) =="
docker run -d --name "$NAME" \
  --read-only \
  --tmpfs /tmp \
  -v "$VOLUME:/data" \
  -v "$SECRET_FILE:/run/secrets/admin_password:ro" \
  -e GCM_ADMIN_PASSWORD_FILE=/run/secrets/admin_password \
  -e GCM_LOG_LEVEL=INFO \
  -p "127.0.0.1:$PORT:8787" \
  "$IMAGE" >/dev/null || die 'docker run FAILED'
CLEANUP+=("$NAME")

echo "== wait for health =="
HEALTHY=0
for _ in $(seq 1 60); do
  if docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null | grep -q healthy; then HEALTHY=1; break; fi
  sleep 1
done
[ "$HEALTHY" = 1 ] || die 'container never became healthy'
ok 'container health endpoint is healthy'

echo "== container running state =="
# Use docker inspect (proven to work on the CI runner) rather than docker ps,
# which disagreed with the daemon in an earlier run. dump_diagnostics on the
# die path below prints the full state + logs for any non-running container.
RUNNING_STATE=$(docker inspect -f '{{.State.Status}}' "$NAME" 2>/dev/null || echo missing)
echo "container state: $RUNNING_STATE"
case "$RUNNING_STATE" in running) ok 'container is running' ;; *) die "container is not running: $RUNNING_STATE" ;; esac

# If the hardened (read-only) container ever dies on its own, bisect with a
# plain container (no --read-only, no tmpfs) so CI tells us whether the
# read-only root is the trigger rather than guessing.
if [ "$RUNNING_STATE" != running ]; then
  echo "== bisect: same image without --read-only/tmpfs =="
  PROBE_NAME="gcm-smoke-probe-$RANDOM$$"
  docker run -d --name "$PROBE_NAME" \
    -v "$VOLUME:/data" \
    -v "$SECRET_FILE:/run/secrets/admin_password:ro" \
    -e GCM_ADMIN_PASSWORD_FILE=/run/secrets/admin_password \
    "$IMAGE" >/dev/null 2>&1 || echo "(probe container failed to start)"
  sleep 4
  PROBE_STATE=$(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' "$PROBE_NAME" 2>/dev/null || echo missing)
  echo "probe state: $PROBE_STATE"
  echo "--- probe logs ---"
  docker logs "$PROBE_NAME" 2>&1 || true
  docker rm -f "$PROBE_NAME" >/dev/null 2>&1 || true
fi

echo "== non-root + filesystem layout =="
UID_OUT=$(docker exec "$NAME" id -u | tr -d ' ')
if [ -n "$UID_OUT" ] && [ "$UID_OUT" != 0 ]; then ok "process uid is $UID_OUT (not root)"; else die "process uid is '$UID_OUT' (expected non-zero)"; fi
if docker exec "$NAME" sh -c 'test -w /data && touch /data/.smoke-write && rm /data/.smoke-write'; then ok '/data is writable by the runtime user'; else die '/data is NOT writable'; fi
if docker exec "$NAME" sh -c '! touch /app/server.js 2>/dev/null'; then ok 'application tree is read-only to the runtime user'; else bad 'application tree is writable'; fi

echo "== auth fail-closed =="
# Unauthenticated API request -> 401
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/routers")
[ "$CODE" = 401 ] && ok 'unauthenticated API request rejected (401)' || bad "unauthenticated request returned $CODE"
# Wrong password -> 401
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"password":"wrong-password-xyz"}' "http://127.0.0.1:$PORT/api/login")
[ "$CODE" = 401 ] && ok 'wrong password rejected (401)' || bad "wrong password returned $CODE"
# Valid login -> 200 + csrf + cookie
LOGIN_JSON=$(curl -s -c "$WORK/cookies.txt" -X POST -H 'Content-Type: application/json' -d "{\"password\":\"$ADMIN_PASSWORD\"}" "http://127.0.0.1:$PORT/api/login")
CSRF=$(printf '%s' "$LOGIN_JSON" | sed -n 's/.*"csrf":"\([^"]*\)".*/\1/p')
[ -n "$CSRF" ] && ok 'valid login issues a CSRF token' || die 'valid login returned no CSRF token'
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$WORK/cookies.txt" "http://127.0.0.1:$PORT/api/session")
[ "$CODE" = 200 ] && ok 'authenticated session endpoint reachable (200)' || bad "session endpoint returned $CODE"
# Missing CSRF on a state-changing route -> 403
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$WORK/cookies.txt" -X POST -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$PORT/api/routers/test")
[ "$CODE" = 403 ] && ok 'state-changing request without CSRF rejected (403)' || bad "no-CSRF request returned $CODE"
# Valid CSRF -> passes the gate (not 403)
CODE=$(curl -s -o /dev/null -w '%{http_code}' -b "$WORK/cookies.txt" -X POST -H 'Content-Type: application/json' -H "X-CSRF-Token: $CSRF" -d '{}' "http://127.0.0.1:$PORT/api/routers/test")
[ "$CODE" != 403 ] && ok "valid CSRF passes the gate (returned $CODE, not 403)" || bad 'valid CSRF still rejected (403)'

echo "== static UI =="
CODE=$(curl -s -o "$WORK/index.html" -w '%{http_code}' "http://127.0.0.1:$PORT/")
[ "$CODE" = 200 ] && grep -q '/app.js' "$WORK/index.html" && grep -q '/app.css' "$WORK/index.html" \
  && ok 'index.html renders with external assets' || bad 'index.html missing external assets'
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/app.js")
[ "$CODE" = 200 ] && ok 'app.js served (200)' || bad "app.js returned $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/app.css")
[ "$CODE" = 200 ] && ok 'app.css served (200)' || bad "app.css returned $CODE"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/health")
[ "$CODE" = 200 ] && ok 'API health responds (200)' || bad "api/health returned $CODE"

echo "== persistence across restart =="
MARKER="smoke-marker-$$"
docker exec "$NAME" sh -c "printf 'persist-me' > /data/$MARKER" || die 'could not write marker to /data'
docker restart "$NAME" >/dev/null 2>&1 || die 'docker restart FAILED'
HEALTHY=0
for _ in $(seq 1 60); do
  if docker inspect -f '{{.State.Health.Status}}' "$NAME" 2>/dev/null | grep -q healthy; then HEALTHY=1; break; fi
  sleep 1
done
[ "$HEALTHY" = 1 ] || die 'container not healthy after restart'
CONTENT=$(docker exec "$NAME" sh -c "cat /data/$MARKER 2>/dev/null" || true)
[ "$CONTENT" = 'persist-me' ] && ok '/data persists across restart (named volume)' || bad '/data did not survive restart'
docker exec "$NAME" sh -c "rm -f /data/$MARKER" 2>/dev/null || true

echo "== graceful stop =="
docker stop "$NAME" >/dev/null 2>&1 || true
EXIT_CODE=$(docker inspect -f '{{.State.ExitCode}}' "$NAME" 2>/dev/null || echo unknown)
if [ "$EXIT_CODE" = 0 ]; then ok "SIGTERM graceful shutdown (exit code 0)"; else bad "exit code after stop: $EXIT_CODE"; fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "container smoke: $PASS passed, $FAIL failed"
  exit 1
fi
echo "container smoke: $PASS checks passed"
