#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROLLOUT="$SCRIPT_DIR/invite-v2-rollout.sh"
OLD_IMAGE=${BUZZ_REHEARSAL_OLD_IMAGE:-ghcr.io/block/buzz:0.2.0@sha256:a0f67203d71d15d237fa7517788799957c30c8acdb81cbcff711e07e951c2710}
CANDIDATE_RECEIPT=${BUZZ_REHEARSAL_CANDIDATE_RECEIPT:-/root/buzz-invite-v2-final/candidate.receipt}
CANDIDATE_SOURCE=${BUZZ_REHEARSAL_CANDIDATE_SOURCE:-$SCRIPT_DIR/../..}

BUZZ_ALLOW_NON_ROOT=1 "$ROLLOUT" verify-candidate-receipt "$CANDIDATE_RECEIPT" "$CANDIDATE_SOURCE"
CANDIDATE_IMAGE=$(grep -E '^candidate_image_id=' "$CANDIDATE_RECEIPT")
CANDIDATE_IMAGE=${CANDIDATE_IMAGE#*=}

run_id="invite-v2-rehearsal-$$"
network="$run_id"
postgres="$run_id-postgres"
redis="$run_id-redis"
minio="$run_id-minio"
relay="$run_id-relay"
tmp_dir=$(mktemp -d)

cleanup() {
  docker rm -f "$relay" "$postgres" "$redis" "$minio" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

docker network create "$network" >/dev/null
docker run -d --name "$postgres" --network "$network" --network-alias postgres \
  -e POSTGRES_USER=buzz -e POSTGRES_PASSWORD=buzz_dev -e POSTGRES_DB=buzz \
  postgres:18-alpine >/dev/null
docker run -d --name "$redis" --network "$network" --network-alias redis redis:7-alpine >/dev/null
docker run -d --name "$minio" --network "$network" --network-alias minio \
  -e MINIO_ROOT_USER=buzz_dev -e MINIO_ROOT_PASSWORD=buzz_dev_secret \
  minio/minio:RELEASE.2025-09-07T16-13-09Z server /data >/dev/null

for _ in $(seq 1 60); do
  if docker exec "$postgres" pg_isready -U buzz -d buzz >/dev/null 2>&1; then break; fi
  sleep 1
done
for _ in $(seq 1 60); do
  if docker exec "$minio" curl --fail --silent http://127.0.0.1:9000/minio/health/live >/dev/null 2>&1; then break; fi
  sleep 1
done
docker run --rm --network "$network" --entrypoint /bin/sh \
  minio/mc:RELEASE.2025-08-13T08-35-41Z -c \
  'mc alias set rehearsal http://minio:9000 buzz_dev buzz_dev_secret >/dev/null && mc mb --ignore-existing rehearsal/buzz-media >/dev/null'

relay_run() {
  local image=$1 auto_migrate=$2
  docker rm -f "$relay" >/dev/null 2>&1 || true
  docker run -d --name "$relay" --network "$network" -p 127.0.0.1::8080 \
    -e DATABASE_URL=postgres://buzz:buzz_dev@postgres:5432/buzz \
    -e REDIS_URL=redis://redis:6379 \
    -e RELAY_URL=ws://rehearsal.buzz.invalid:3000 \
    -e BUZZ_AUTO_MIGRATE="$auto_migrate" \
    -e BUZZ_REQUIRE_RELAY_MEMBERSHIP=true \
    -e BUZZ_REQUIRE_AUTH_TOKEN=true \
    -e RELAY_OWNER_PUBKEY=1111111111111111111111111111111111111111111111111111111111111111 \
    -e BUZZ_RELAY_PRIVATE_KEY=2222222222222222222222222222222222222222222222222222222222222222 \
    -e BUZZ_S3_ENDPOINT=http://minio:9000 \
    -e BUZZ_S3_ACCESS_KEY=buzz_dev \
    -e BUZZ_S3_SECRET_KEY=buzz_dev_secret \
    -e BUZZ_S3_BUCKET=buzz-media \
    -e BUZZ_GIT_CONFORMANCE_PROBE=false \
    "$image" >/dev/null
}

wait_relay() {
  local port
  port=$(docker port "$relay" 8080/tcp | head -n1 | tr -d '\r')
  port=${port##*:}
  for _ in $(seq 1 90); do
    if curl --fail --silent "http://127.0.0.1:$port/_readiness" >/dev/null 2>&1; then return 0; fi
    [[ $(docker inspect --format '{{.State.Running}}' "$relay") == true ]] || break
    sleep 1
  done
  docker logs "$relay" >&2 || true
  return 1
}

db_invariant_hash() {
  docker exec "$postgres" psql -X -U buzz -d buzz -Atc "
    COPY (
      SELECT jsonb_build_object(
        'type', 'member', 'community_id', community_id, 'pubkey', pubkey,
        'role', role, 'added_by', added_by, 'created_at', created_at
      )::text AS row_data
      FROM relay_members
      UNION ALL
      SELECT jsonb_build_object(
        'type', 'message', 'community_id', community_id,
        'id', encode(id, 'hex'), 'pubkey', encode(pubkey, 'hex'),
        'created_at', created_at, 'kind', kind, 'tags', tags,
        'content', content, 'sig', encode(sig, 'hex'),
        'channel_id', channel_id, 'deleted_at', deleted_at, 'd_tag', d_tag
      )::text AS row_data
      FROM events
      WHERE kind IN (9, 40002, 40003, 40004, 40005, 40006, 40008)
      ORDER BY row_data
    ) TO STDOUT
  " | sha256sum | cut -d' ' -f1
}

service_identity() {
  docker inspect --format '{{.Id}} {{.State.StartedAt}}' "$postgres" "$redis" "$minio" | sha256sum | cut -d' ' -f1
}

printf '1/6 base relay migrates schema 1-6 and becomes ready\n'
relay_run "$OLD_IMAGE" true
wait_relay
versions=$(docker exec "$postgres" psql -U buzz -d buzz -Atc 'select string_agg(version::text,'"'"','"'"' order by version) from _sqlx_migrations')
[[ "$versions" == 1,2,3,4,5,6 ]]

printf '2/6 base relay is restarted with auto-migrate disabled before schema 25\n'
relay_run "$OLD_IMAGE" false
wait_relay
[[ $(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$relay" | grep '^BUZZ_AUTO_MIGRATE=') == BUZZ_AUTO_MIGRATE=false ]]

before_data=$(db_invariant_hash)
before_services=$(service_identity)

printf '3/6 exact migration 0025 is applied out of band\n'
BUZZ_ALLOW_NON_ROOT=1 \
BUZZ_SKIP_BACKUP_GUARD=1 \
BUZZ_RELAY_CONTAINER="$relay" \
BUZZ_POSTGRES_CONTAINER="$postgres" \
BUZZ_DB_USER=buzz BUZZ_DB_NAME=buzz \
BUZZ_MIGRATION_FILE="$SCRIPT_DIR/../../migrations/0025_relay_invites.sql" \
  "$ROLLOUT" apply-migration

printf '4/6 old base with auto-migrate enabled demonstrates SQLx VersionMissing\n'
relay_run "$OLD_IMAGE" true
for _ in $(seq 1 30); do
  [[ $(docker inspect --format '{{.State.Running}}' "$relay") == false ]] && break
  sleep 1
done
[[ $(docker inspect --format '{{.State.Running}}' "$relay") == false ]]
docker logs "$relay" >"$tmp_dir/version-missing.log" 2>&1
if ! grep -Eq 'VersionMissing\(25\)|migration 25 was previously applied but is missing' "$tmp_dir/version-missing.log"; then
  printf 'expected SQLx VersionMissing evidence was absent:\n' >&2
  grep -E 'ERROR|Error|migration' "$tmp_dir/version-missing.log" >&2 || true
  exit 1
fi

printf '5/6 candidate serves schema 25 with auto-migrate disabled\n'
relay_run "$CANDIDATE_IMAGE" false
wait_relay
BUZZ_ALLOW_NON_ROOT=1 "$ROLLOUT" assert-running-candidate "$CANDIDATE_RECEIPT" "$relay"
[[ $(docker exec "$postgres" psql -U buzz -d buzz -Atc 'select count(*) from relay_invites') == 0 ]]

printf '6/6 old base rollback serves schema 25 with auto-migrate disabled\n'
relay_run "$OLD_IMAGE" false
wait_relay
versions=$(docker exec "$postgres" psql -U buzz -d buzz -Atc 'select string_agg(version::text,'"'"','"'"' order by version) from _sqlx_migrations')
[[ "$versions" == 1,2,3,4,5,6,25 ]]
after_data=$(db_invariant_hash)
[[ "$after_data" == "$before_data" ]]
[[ $(service_identity) == "$before_services" ]]

printf 'base -> 0025 -> candidate -> base rollback rehearsal passed\n'
