#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROLLOUT="$SCRIPT_DIR/invite-v2-rollout.sh"
MIGRATION="$SCRIPT_DIR/../../migrations/0025_relay_invites.sql"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

tmp_dir=$(mktemp -d)
real_pg=''
cleanup() {
  [[ -z "$real_pg" ]] || docker rm -f "$real_pg" >/dev/null 2>&1 || true
  rm -rf "$tmp_dir"
}
trap cleanup EXIT
export BUZZ_ALLOW_NON_ROOT=1
export BUZZ_ALLOW_DIRTY_SOURCE=1

if BUZZ_ALLOW_NON_ROOT=1 BUZZ_BACKUP_POINTER="$tmp_dir/missing-backup-pointer" \
  "$ROLLOUT" assert-backup 2>"$tmp_dir/backup.err"; then
  fail 'backup guard accepted a missing verified preimage'
fi
grep -Fq 'verified backup required' "$tmp_dir/backup.err" || fail 'missing-backup failure was not explicit'

old_image='ghcr.io/block/buzz:0.2.0@sha256:a0f67203d71d15d237fa7517788799957c30c8acdb81cbcff711e07e951c2710'
candidate_image='buzz-relay-invite-v2@sha256:1111111111111111111111111111111111111111111111111111111111111111'

old_overlay="$tmp_dir/old.yml"
"$ROLLOUT" render-overlay "$old_image" "$old_overlay"
grep -Fq "image: $old_image" "$old_overlay" || fail 'old overlay did not pin the old image digest'
grep -Fq 'BUZZ_AUTO_MIGRATE: "false"' "$old_overlay" || fail 'old overlay did not disable auto-migrate'

candidate_overlay="$tmp_dir/candidate.yml"
"$ROLLOUT" render-overlay "$candidate_image" "$candidate_overlay"
grep -Fq "image: $candidate_image" "$candidate_overlay" || fail 'candidate overlay did not pin the candidate image digest'
grep -Fq 'BUZZ_AUTO_MIGRATE: "false"' "$candidate_overlay" || fail 'candidate overlay did not disable auto-migrate'

candidate_id='sha256:1111111111111111111111111111111111111111111111111111111111111111'
candidate_id_overlay="$tmp_dir/candidate-id.yml"
"$ROLLOUT" render-overlay "$candidate_id" "$candidate_id_overlay"
grep -Fq "image: $candidate_id" "$candidate_id_overlay" || fail 'candidate overlay rejected a locally loaded immutable image ID'

expected_checksum=$(openssl dgst -sha384 -binary "$MIGRATION" | od -An -vtx1 | tr -d ' \n')
actual_checksum=$("$ROLLOUT" migration-checksum "$MIGRATION")
[[ "$actual_checksum" == "$expected_checksum" ]] || fail 'migration checksum is not SQLx SHA-384'

fake_bin="$tmp_dir/bin"
mkdir -p "$fake_bin"

backup_prefix="$tmp_dir/invite-v2-"
incomplete_backup="${backup_prefix}incomplete"
mkdir -m 0700 "$incomplete_backup"
printf 'compose\n' >"$incomplete_backup/compose.yml"
printf 'dump\n' >"$incomplete_backup/database-preimage.dump"
chmod 0600 "$incomplete_backup/compose.yml" "$incomplete_backup/database-preimage.dump"
"$ROLLOUT" write-manifest "$incomplete_backup"
printf '%s\n' "$incomplete_backup" >"$tmp_dir/incomplete.pointer"
chmod 0600 "$tmp_dir/incomplete.pointer"
if BUZZ_ALLOW_NON_ROOT=1 BUZZ_BACKUP_PATH_PREFIX="$backup_prefix" \
  BUZZ_BACKUP_POINTER="$tmp_dir/incomplete.pointer" "$ROLLOUT" assert-backup \
  2>"$tmp_dir/incomplete.err"; then
  fail 'backup guard accepted an incomplete but self-consistent manifest'
fi
grep -Fq 'required backup artifact missing' "$tmp_dir/incomplete.err" ||
  fail 'incomplete backup failure did not identify the missing required artifact'

complete_backup="${backup_prefix}complete"
mkdir -m 0700 "$complete_backup"
printf 'compose\n' >"$complete_backup/compose.yml"
printf 'env\n' >"$complete_backup/.env"
printf 'nginx\n' >"$complete_backup/nginx-relay.conf"
printf '[{}]\n' >"$complete_backup/relay-container-inspect.json"
printf 'valid-dump\n' >"$complete_backup/database-preimage.dump"
tar -cf "$complete_backup/etc-buzz.tar" -C "$tmp_dir" incomplete.pointer
chmod 0600 "$complete_backup"/* "$complete_backup/.env"
"$ROLLOUT" write-manifest "$complete_backup"
printf '%s\n' "$complete_backup" >"$tmp_dir/complete.pointer"
chmod 0600 "$tmp_dir/complete.pointer"

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$#" == 5 && "$1" == exec && "$2" == -i && "$4" == pg_restore && "$5" == --list ]]; then
  payload=$(tee)
  [[ "$payload" == valid-dump ]]
  exit
fi
exit 64
EOF
chmod +x "$fake_bin/docker"
PATH="$fake_bin:$PATH" BUZZ_ALLOW_NON_ROOT=1 BUZZ_BACKUP_PATH_PREFIX="$backup_prefix" \
  BUZZ_BACKUP_POINTER="$tmp_dir/complete.pointer" "$ROLLOUT" assert-backup
printf 'corrupt-dump\n' >"$complete_backup/database-preimage.dump"
chmod 0600 "$complete_backup/database-preimage.dump"
"$ROLLOUT" write-manifest "$complete_backup"
if PATH="$fake_bin:$PATH" BUZZ_ALLOW_NON_ROOT=1 BUZZ_BACKUP_PATH_PREFIX="$backup_prefix" \
  BUZZ_BACKUP_POINTER="$tmp_dir/complete.pointer" "$ROLLOUT" assert-backup \
  2>"$tmp_dir/corrupt-dump.err"; then
  fail 'backup guard accepted a corrupt but self-consistently hashed PostgreSQL archive'
fi
grep -Fq 'PostgreSQL dump restore preflight failed' "$tmp_dir/corrupt-dump.err" ||
  fail 'corrupt PostgreSQL archive failure was not explicit'
printf 'valid-dump\n' >"$complete_backup/database-preimage.dump"
chmod 0600 "$complete_backup/database-preimage.dump"
"$ROLLOUT" write-manifest "$complete_backup"
chmod 0644 "$complete_backup/.env"
if PATH="$fake_bin:$PATH" BUZZ_ALLOW_NON_ROOT=1 BUZZ_BACKUP_PATH_PREFIX="$backup_prefix" \
  BUZZ_BACKUP_POINTER="$tmp_dir/complete.pointer" "$ROLLOUT" assert-backup \
  2>"$tmp_dir/backup-mode.err"; then
  fail 'backup guard accepted an artifact with an unsafe mode'
fi
grep -Fq 'trusted-owner mode 0600' "$tmp_dir/backup-mode.err" ||
  fail 'unsafe backup mode failure was not explicit'
chmod 0600 "$complete_backup/.env"

real_pg="buzz-invite-archive-test-$$"
docker run -d --name "$real_pg" \
  -e POSTGRES_USER=buzz -e POSTGRES_PASSWORD=buzz_dev -e POSTGRES_DB=buzz \
  postgres:18-alpine >/dev/null
for _ in $(seq 1 60); do
  docker exec "$real_pg" pg_isready -U buzz -d buzz >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$real_pg" psql -X -v ON_ERROR_STOP=1 -U buzz -d buzz \
  -c 'CREATE TABLE archive_probe (id integer PRIMARY KEY)' >/dev/null

real_backup="${backup_prefix}real"
mkdir -m 0700 "$real_backup"
printf 'compose\n' >"$real_backup/compose.yml"
printf 'env\n' >"$real_backup/.env"
printf 'nginx\n' >"$real_backup/nginx-relay.conf"
docker inspect "$real_pg" >"$real_backup/relay-container-inspect.json"
docker exec "$real_pg" pg_dump -U buzz -d buzz -Fc >"$real_backup/database-preimage.dump"
tar -cf "$real_backup/etc-buzz.tar" -C "$tmp_dir" incomplete.pointer
chmod 0600 "$real_backup"/* "$real_backup/.env"
"$ROLLOUT" write-manifest "$real_backup"
printf '%s\n' "$real_backup" >"$tmp_dir/real.pointer"
chmod 0600 "$tmp_dir/real.pointer"
BUZZ_BACKUP_PATH_PREFIX="$backup_prefix" BUZZ_BACKUP_POINTER="$tmp_dir/real.pointer" \
  BUZZ_POSTGRES_CONTAINER="$real_pg" "$ROLLOUT" assert-backup

printf 'corrupt-real-archive\n' >"$real_backup/database-preimage.dump"
chmod 0600 "$real_backup/database-preimage.dump"
"$ROLLOUT" write-manifest "$real_backup"
if BUZZ_BACKUP_PATH_PREFIX="$backup_prefix" BUZZ_BACKUP_POINTER="$tmp_dir/real.pointer" \
  BUZZ_POSTGRES_CONTAINER="$real_pg" "$ROLLOUT" assert-backup \
  2>"$tmp_dir/corrupt-real.err"; then
  fail 'real PostgreSQL restore preflight accepted a corrupt rehashed archive'
fi
grep -Fq 'PostgreSQL dump restore preflight failed' "$tmp_dir/corrupt-real.err" ||
  fail 'real corrupt archive failure was not explicit'
docker rm -f "$real_pg" >/dev/null
real_pg=''

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == inspect && "$2" == --format=* ]]; then
  printf 'BUZZ_AUTO_MIGRATE=%s\n' "${FAKE_AUTO_MIGRATE:-true}"
  exit 0
fi
exit 64
EOF
chmod +x "$fake_bin/docker"

if PATH="$fake_bin:$PATH" FAKE_AUTO_MIGRATE=true "$ROLLOUT" assert-auto-migrate-off relay-under-test 2>"$tmp_dir/guard.err"; then
  fail 'guard accepted BUZZ_AUTO_MIGRATE=true'
fi
grep -Fq 'BUZZ_AUTO_MIGRATE must be false' "$tmp_dir/guard.err" || fail 'guard failure was not explicit'

PATH="$fake_bin:$PATH" FAKE_AUTO_MIGRATE=false "$ROLLOUT" assert-auto-migrate-off relay-under-test

source_checkout="$SCRIPT_DIR/../.."
candidate_revision=$(git -C "$source_checkout" rev-parse HEAD)
candidate_tree=$(git -C "$source_checkout" rev-parse 'HEAD^{tree}')
candidate_base=0d9be2fde1fc18e57da8f2ca229cc01699867550
candidate_patch=$(git -C "$source_checkout" diff --binary --full-index --no-ext-diff \
  "$candidate_base" "$candidate_revision" | sha256sum | cut -d' ' -f1)
candidate_receipt="$tmp_dir/candidate.receipt"
cat >"$candidate_receipt" <<EOF
candidate_image_ref=$candidate_image
candidate_image_id=$candidate_id
candidate_oci_revision=$candidate_revision
candidate_commit=$candidate_revision
candidate_tree=$candidate_tree
base_commit=$candidate_base
patch_sha256=$candidate_patch
EOF

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == image && "$2" == inspect && "$3" == --format=* ]]; then
  case "$3" in
    *'.Id'*) printf '%s\n' "${FAKE_IMAGE_ID:?}" ;;
    *'org.opencontainers.image.revision'*) printf '%s\n' "${FAKE_IMAGE_REVISION:?}" ;;
    *) exit 64 ;;
  esac
  exit 0
fi
exit 64
EOF
chmod +x "$fake_bin/docker"

PATH="$fake_bin:$PATH" FAKE_IMAGE_ID="$candidate_id" FAKE_IMAGE_REVISION="$candidate_revision" \
  "$ROLLOUT" verify-candidate-receipt "$candidate_receipt" "$source_checkout"
if PATH="$fake_bin:$PATH" FAKE_IMAGE_ID='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  FAKE_IMAGE_REVISION="$candidate_revision" "$ROLLOUT" verify-candidate-receipt "$candidate_receipt" "$source_checkout" \
  2>"$tmp_dir/image-id.err"; then
  fail 'candidate receipt accepted an image ID mismatch'
fi
grep -Fq 'candidate image ID mismatch' "$tmp_dir/image-id.err" || fail 'image ID mismatch was not explicit'
if PATH="$fake_bin:$PATH" FAKE_IMAGE_ID="$candidate_id" \
  FAKE_IMAGE_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  "$ROLLOUT" verify-candidate-receipt "$candidate_receipt" "$source_checkout" 2>"$tmp_dir/revision.err"; then
  fail 'candidate receipt accepted an OCI revision mismatch'
fi
grep -Fq 'candidate OCI revision mismatch' "$tmp_dir/revision.err" || fail 'OCI revision mismatch was not explicit'

for field in candidate_commit candidate_tree base_commit patch_sha256; do
  bad_receipt="$tmp_dir/bad-$field.receipt"
  cp "$candidate_receipt" "$bad_receipt"
  case "$field" in
    candidate_commit)
      perl -0pi -e 's/^candidate_commit=.*/candidate_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/m' "$bad_receipt"
      perl -0pi -e 's/^candidate_oci_revision=.*/candidate_oci_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/m' "$bad_receipt"
      bad_revision=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      ;;
    candidate_tree)
      perl -0pi -e 's/^candidate_tree=.*/candidate_tree=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/m' "$bad_receipt"
      bad_revision=$candidate_revision
      ;;
    base_commit)
      perl -0pi -e 's/^base_commit=.*/base_commit=cccccccccccccccccccccccccccccccccccccccc/m' "$bad_receipt"
      bad_revision=$candidate_revision
      ;;
    patch_sha256)
      perl -0pi -e 's/^patch_sha256=.*/patch_sha256=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/m' "$bad_receipt"
      bad_revision=$candidate_revision
      ;;
  esac
  if PATH="$fake_bin:$PATH" FAKE_IMAGE_ID="$candidate_id" FAKE_IMAGE_REVISION="$bad_revision" \
    "$ROLLOUT" verify-candidate-receipt "$bad_receipt" "$source_checkout" 2>"$tmp_dir/$field.err"; then
    fail "candidate receipt accepted mismatched $field"
  fi
  grep -Fq 'candidate source lineage mismatch' "$tmp_dir/$field.err" ||
    fail "source lineage mismatch for $field was not explicit"
done

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == inspect && "$2" == --format=* ]]; then
  printf '%s\n' "${FAKE_RUNNING_IMAGE_ID:?}"
  exit 0
fi
if [[ "$1" == image && "$2" == inspect && "$3" == --format=* ]]; then
  printf '%s\n' "${FAKE_IMAGE_REVISION:?}"
  exit 0
fi
exit 64
EOF
chmod +x "$fake_bin/docker"
PATH="$fake_bin:$PATH" FAKE_RUNNING_IMAGE_ID="$candidate_id" FAKE_IMAGE_REVISION="$candidate_revision" \
  "$ROLLOUT" assert-running-candidate "$candidate_receipt" relay-under-test
if PATH="$fake_bin:$PATH" \
  FAKE_RUNNING_IMAGE_ID='sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
  FAKE_IMAGE_REVISION="$candidate_revision" \
  "$ROLLOUT" assert-running-candidate "$candidate_receipt" relay-under-test 2>"$tmp_dir/running-id.err"; then
  fail 'running candidate accepted a container image mismatch'
fi
grep -Fq 'running candidate image ID mismatch' "$tmp_dir/running-id.err" || fail 'running image mismatch was not explicit'
if PATH="$fake_bin:$PATH" FAKE_RUNNING_IMAGE_ID="$candidate_id" \
  FAKE_IMAGE_REVISION='dddddddddddddddddddddddddddddddddddddddd' \
  "$ROLLOUT" assert-running-candidate "$candidate_receipt" relay-under-test 2>"$tmp_dir/running-revision.err"; then
  fail 'running candidate accepted a revision mismatch'
fi
grep -Fq 'running candidate OCI revision mismatch' "$tmp_dir/running-revision.err" || fail 'running revision mismatch was not explicit'

expected_patch_hash=$(git -C "$SCRIPT_DIR/../.." diff --binary --full-index --no-ext-diff \
  0d9be2fde1fc18e57da8f2ca229cc01699867550 HEAD | sha256sum | cut -d' ' -f1)
actual_patch_hash=$("$ROLLOUT" patch-hash 0d9be2fde1fc18e57da8f2ca229cc01699867550 HEAD)
[[ "$actual_patch_hash" == "$expected_patch_hash" ]] || fail 'patch hash is not reproducible from the documented git diff stream'

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == inspect ]]; then
  printf 'BUZZ_AUTO_MIGRATE=false\n'
  exit 0
fi
if [[ "$1" == exec && "$2" == -i ]]; then
  tee "$FAKE_SQL_CAPTURE" >/dev/null
  : >"$FAKE_MIGRATED_MARKER"
  exit 0
fi
if [[ "$*" == *"WHERE version = 25"* ]]; then
  if [[ -f "$FAKE_MIGRATED_MARKER" ]]; then
    printf 'true:%s\n' "$EXPECTED_CHECKSUM"
  fi
  exit 0
fi
if [[ "$*" == *"to_regclass"* ]]; then
  if [[ -f "$FAKE_MIGRATED_MARKER" ]]; then
    printf 'relay_invites\n'
  fi
  exit 0
fi
exit 64
EOF
chmod +x "$fake_bin/docker"

sql_capture="$tmp_dir/migration.sql"
migrated_marker="$tmp_dir/migrated"
PATH="$fake_bin:$PATH" \
  BUZZ_ALLOW_NON_ROOT=1 \
  BUZZ_SKIP_BACKUP_GUARD=1 \
  BUZZ_RELAY_CONTAINER=relay-under-test \
  BUZZ_POSTGRES_CONTAINER=postgres-under-test \
  FAKE_SQL_CAPTURE="$sql_capture" \
  FAKE_MIGRATED_MARKER="$migrated_marker" \
  EXPECTED_CHECKSUM="$expected_checksum" \
  "$ROLLOUT" apply-migration
grep -Fq 'CREATE TABLE relay_invites' "$sql_capture" || fail 'out-of-band transaction did not stream exact migration SQL'
grep -Fq "decode('$expected_checksum', 'hex')" "$sql_capture" || fail 'SQLx migration row did not use the exact checksum'
grep -Fq 'COMMIT;' "$sql_capture" || fail 'migration and SQLx record were not committed together'
first_apply_hash=$(sha256sum "$sql_capture" | cut -d' ' -f1)
PATH="$fake_bin:$PATH" \
  BUZZ_ALLOW_NON_ROOT=1 \
  BUZZ_SKIP_BACKUP_GUARD=1 \
  BUZZ_RELAY_CONTAINER=relay-under-test \
  BUZZ_POSTGRES_CONTAINER=postgres-under-test \
  FAKE_SQL_CAPTURE="$sql_capture" \
  FAKE_MIGRATED_MARKER="$migrated_marker" \
  EXPECTED_CHECKSUM="$expected_checksum" \
  "$ROLLOUT" apply-migration >/dev/null
[[ $(sha256sum "$sql_capture" | cut -d' ' -f1) == "$first_apply_hash" ]] || fail 'idempotent re-run executed migration SQL again'

cat >"$tmp_dir/before.invariants" <<'EOF'
members=1:member-hash
messages=2:message-hash
communities=1
channels=3
non_relay_services=service-hash
config=env-hash
migrations=1,2,3,4,5,6
relay_invites=absent
relay_image=old
EOF
cat >"$tmp_dir/after.invariants" <<'EOF'
members=1:member-hash
messages=2:message-hash
communities=1
channels=3
non_relay_services=service-hash
config=env-hash
migrations=1,2,3,4,5,6,25
relay_invites=0
relay_image=candidate
EOF
"$ROLLOUT" compare-invariants "$tmp_dir/before.invariants" "$tmp_dir/after.invariants"

perl -0pi -e 's/messages=2:message-hash/messages=3:drift/' "$tmp_dir/after.invariants"
if "$ROLLOUT" compare-invariants "$tmp_dir/before.invariants" "$tmp_dir/after.invariants" 2>"$tmp_dir/drift.err"; then
  fail 'invariant comparison accepted message drift'
fi
grep -Fq 'invariant drift' "$tmp_dir/drift.err" || fail 'invariant drift failure was not explicit'

cat >"$fake_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == inspect && "$*" == *'.Config.Env'* ]]; then
  printf 'BUZZ_AUTO_MIGRATE=false\n'
elif [[ "$1" == inspect && "$*" == *'.Config.Image'* ]]; then
  printf 'candidate@sha256:test\n'
elif [[ "$1" == inspect ]]; then
  printf 'stable-container-id stable-start-time\n'
elif [[ "$*" == *'count(*) from relay_members'* ]]; then
  printf '1\n'
elif [[ "$*" == *'count(*) from events'* ]]; then
  printf '2\n'
elif [[ "$*" == *'count(*) from communities'* ]]; then
  printf '1\n'
elif [[ "$*" == *'count(*) from channels'* ]]; then
  printf '3\n'
elif [[ "$*" == *'string_agg(version::text'* ]]; then
  printf '1,2,3,4,5,6,25\n'
elif [[ "$*" == *'count(*) from relay_invites'* ]]; then
  printf '0\n'
elif [[ "$*" == *'to_regclass'* ]]; then
  printf 'relay_invites\n'
elif [[ "$*" == *'COPY ('* ]]; then
  printf 'stable-row-stream\n'
else
  exit 64
fi
EOF
chmod +x "$fake_bin/docker"
printf 'production-config-fixture\n' >"$tmp_dir/config.env"
PATH="$fake_bin:$PATH" \
  BUZZ_ALLOW_NON_ROOT=1 \
  BUZZ_INVARIANT_CONFIG_FILES="$tmp_dir/config.env" \
  BUZZ_NON_RELAY_CONTAINERS='postgres redis minio tls pair' \
  "$ROLLOUT" capture-invariants "$tmp_dir/captured.invariants"
grep -Eq '^members=1:[0-9a-f]{64}$' "$tmp_dir/captured.invariants" || fail 'membership invariant was not captured'
grep -Eq '^messages=2:[0-9a-f]{64}$' "$tmp_dir/captured.invariants" || fail 'message invariant was not captured'
grep -Fq 'migrations=1,2,3,4,5,6,25' "$tmp_dir/captured.invariants" || fail 'migration invariant was not captured'
grep -Fq 'relay_invites=0' "$tmp_dir/captured.invariants" || fail 'invite-table invariant was not captured'

manifest_dir="$tmp_dir/manifest"
mkdir -p "$manifest_dir"
printf 'secret-config\n' >"$manifest_dir/.env"
printf 'database-backup\n' >"$manifest_dir/database.dump"
"$ROLLOUT" write-manifest "$manifest_dir"
grep -Fq './.env' "$manifest_dir/SHA256SUMS" || fail 'backup manifest omitted dotfiles'
(cd "$manifest_dir" && sha256sum --check --status SHA256SUMS) || fail 'backup manifest did not attest every file'

printf 'invite-v2 rollout contract tests passed\n'
