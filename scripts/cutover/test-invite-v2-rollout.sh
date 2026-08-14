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
trap 'rm -rf "$tmp_dir"' EXIT

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

candidate_revision='2222222222222222222222222222222222222222'
candidate_receipt="$tmp_dir/candidate.receipt"
cat >"$candidate_receipt" <<EOF
candidate_image_ref=$candidate_image
candidate_image_id=$candidate_id
candidate_oci_revision=$candidate_revision
candidate_commit=$candidate_revision
candidate_tree=3333333333333333333333333333333333333333
base_commit=4444444444444444444444444444444444444444
patch_sha256=5555555555555555555555555555555555555555555555555555555555555555
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
  "$ROLLOUT" verify-candidate-receipt "$candidate_receipt"
if PATH="$fake_bin:$PATH" FAKE_IMAGE_ID='sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  FAKE_IMAGE_REVISION="$candidate_revision" "$ROLLOUT" verify-candidate-receipt "$candidate_receipt" \
  2>"$tmp_dir/image-id.err"; then
  fail 'candidate receipt accepted an image ID mismatch'
fi
grep -Fq 'candidate image ID mismatch' "$tmp_dir/image-id.err" || fail 'image ID mismatch was not explicit'
if PATH="$fake_bin:$PATH" FAKE_IMAGE_ID="$candidate_id" \
  FAKE_IMAGE_REVISION='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  "$ROLLOUT" verify-candidate-receipt "$candidate_receipt" 2>"$tmp_dir/revision.err"; then
  fail 'candidate receipt accepted an OCI revision mismatch'
fi
grep -Fq 'candidate OCI revision mismatch' "$tmp_dir/revision.err" || fail 'OCI revision mismatch was not explicit'

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
