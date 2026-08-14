#!/usr/bin/env bash
set -euo pipefail

# Rollout/rollback guard for migration 0025.  The old 0.2.0 relay embeds only
# migrations 1-6 and must never execute SQLx migration validation after 0025
# has been recorded.  Every serving image therefore runs with
# BUZZ_AUTO_MIGRATE=false before, during, and after this rollout.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
DEFAULT_MIGRATION="$SCRIPT_DIR/../../migrations/0025_relay_invites.sql"
EXPECTED_MIGRATION_SHA384=5ed27780d08863488ec5cddd2661f3619c490cf740f6dd13f242da113efe7e1212b2f2d3a9b548c472f3382ad9f7a155
DEFAULT_OLD_IMAGE='ghcr.io/block/buzz:0.2.0@sha256:a0f67203d71d15d237fa7517788799957c30c8acdb81cbcff711e07e951c2710'
DEFAULT_BASE_COMMIT=0d9be2fde1fc18e57da8f2ca229cc01699867550
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

COMPOSE_FILE=${BUZZ_COMPOSE_FILE:-/etc/buzz/compose.yml}
PROJECT=${BUZZ_PROJECT:-buzz-prod}
RELAY_SERVICE=${BUZZ_RELAY_SERVICE:-relay}
RELAY_CONTAINER=${BUZZ_RELAY_CONTAINER:-buzz-prod-relay-1}
POSTGRES_CONTAINER=${BUZZ_POSTGRES_CONTAINER:-buzz-prod-postgres-1}
DB_USER=${BUZZ_DB_USER:-buzz}
DB_NAME=${BUZZ_DB_NAME:-buzz}
HEALTH_URL=${BUZZ_HEALTH_URL:-http://127.0.0.1:8080/_readiness}
OLD_IMAGE=${BUZZ_OLD_IMAGE:-$DEFAULT_OLD_IMAGE}
OLD_OVERLAY=${BUZZ_OLD_OVERLAY:-/etc/buzz/invite-v2-old-guard.yml}
CANDIDATE_OVERLAY=${BUZZ_CANDIDATE_OVERLAY:-/etc/buzz/invite-v2-candidate.yml}
MIGRATION=${BUZZ_MIGRATION_FILE:-$DEFAULT_MIGRATION}
BACKUP_POINTER=${BUZZ_BACKUP_POINTER:-/etc/buzz/invite-v2-backup-path}
BACKUP_PATH_PREFIX=${BUZZ_BACKUP_PATH_PREFIX:-/root/buzz-rollbacks/invite-v2-}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root_for_live_action() {
  [[ ${BUZZ_ALLOW_NON_ROOT:-0} == 1 || $(id -u) == 0 ]] || die 'live rollout actions require root'
}

expected_owner_uid() {
  if [[ -n ${BUZZ_EXPECTED_OWNER_UID:-} ]]; then
    printf '%s\n' "$BUZZ_EXPECTED_OWNER_UID"
  elif [[ ${BUZZ_ALLOW_NON_ROOT:-0} == 1 ]]; then
    id -u
  else
    printf '0\n'
  fi
}

assert_backup_verified() {
  [[ ${BUZZ_SKIP_BACKUP_GUARD:-0} == 1 ]] && return 0
  [[ -f "$BACKUP_POINTER" ]] || die "verified backup required; pointer missing: $BACKUP_POINTER"
  local backup_dir artifact config_file owner expected_uid mode manifest_entry
  local -a required_artifacts
  expected_uid=$(expected_owner_uid)
  owner=$(stat -c '%u' "$BACKUP_POINTER")
  mode=$(stat -c '%a' "$BACKUP_POINTER")
  [[ "$owner" == "$expected_uid" && "$mode" == 600 ]] ||
    die 'verified backup required; pointer must be trusted-owner mode 0600'
  IFS= read -r backup_dir <"$BACKUP_POINTER"
  [[ "$backup_dir" == "$BACKUP_PATH_PREFIX"* && -d "$backup_dir" ]] ||
    die 'verified backup required; pointer target is invalid'
  owner=$(stat -c '%u' "$backup_dir")
  mode=$(stat -c '%a' "$backup_dir")
  [[ "$owner" == "$expected_uid" && "$mode" == 700 ]] ||
    die 'verified backup required; directory must be trusted-owner mode 0700'

  required_artifacts=(compose.yml etc-buzz.tar relay-container-inspect.json database-preimage.dump)
  for config_file in ${BUZZ_BACKUP_CONFIG_FILES:-/etc/buzz/.env /etc/buzz/nginx-relay.conf}; do
    required_artifacts+=("$(basename -- "$config_file")")
  done
  required_artifacts+=(SHA256SUMS)
  for artifact in "${required_artifacts[@]}"; do
    [[ -f "$backup_dir/$artifact" ]] || die "required backup artifact missing: $artifact"
    owner=$(stat -c '%u' "$backup_dir/$artifact")
    mode=$(stat -c '%a' "$backup_dir/$artifact")
    [[ "$owner" == "$expected_uid" && "$mode" == 600 ]] ||
      die "verified backup required; $artifact must be trusted-owner mode 0600"
  done

  for artifact in "${required_artifacts[@]}"; do
    [[ "$artifact" == SHA256SUMS ]] && continue
    manifest_entry=$(grep -c -F " ./$artifact" "$backup_dir/SHA256SUMS" || true)
    [[ "$manifest_entry" == 1 ]] ||
      die "verified backup required; manifest must attest exactly one ./$artifact"
  done
  (cd "$backup_dir" && sha256sum --check --status SHA256SUMS) ||
    die 'verified backup required; SHA256 preimage attestation failed'
  tar -tf "$backup_dir/etc-buzz.tar" >/dev/null ||
    die 'verified backup required; etc-buzz archive is unreadable'
  python3 -c 'import json, sys; value = json.load(open(sys.argv[1], encoding="utf-8")); sys.exit(0 if isinstance(value, list) and len(value) >= 1 else 1)' \
    "$backup_dir/relay-container-inspect.json" >/dev/null 2>&1 ||
    die 'verified backup required; relay container inspect is unreadable'
  docker exec -i "$POSTGRES_CONTAINER" pg_restore --list \
    <"$backup_dir/database-preimage.dump" >/dev/null 2>&1 ||
    die 'verified backup required; PostgreSQL dump restore preflight failed'
}

migration_checksum() {
  local migration_file=$1
  [[ -f "$migration_file" ]] || die "migration file not found: $migration_file"
  openssl dgst -sha384 -binary "$migration_file" | od -An -vtx1 | tr -d ' \n'
}

verify_source_migration() {
  local actual
  actual=$(migration_checksum "$MIGRATION")
  [[ "$actual" == "$EXPECTED_MIGRATION_SHA384" ]] ||
    die "migration checksum mismatch: expected $EXPECTED_MIGRATION_SHA384, got $actual"
}

patch_hash() {
  local base=${1:?base commit required} candidate=${2:?candidate commit required}
  git -C "$REPO_ROOT" diff --binary --full-index --no-ext-diff "$base" "$candidate" \
    | sha256sum | cut -d' ' -f1
}

receipt_value() {
  local receipt=$1 key=$2 count value
  count=$(grep -c -E "^${key}=" "$receipt" || true)
  [[ "$count" == 1 ]] || die "candidate receipt must contain exactly one $key"
  value=$(grep -E "^${key}=" "$receipt")
  printf '%s\n' "${value#*=}"
}

load_candidate_receipt() {
  local receipt=${1:?candidate receipt required}
  [[ -f "$receipt" ]] || die "candidate receipt not found: $receipt"
  RECEIPT_IMAGE_REF=$(receipt_value "$receipt" candidate_image_ref)
  RECEIPT_ARCHIVE_SHA256=$(receipt_value "$receipt" candidate_archive_sha256)
  RECEIPT_MANIFEST_DIGEST=$(receipt_value "$receipt" candidate_manifest_digest)
  RECEIPT_MANIFEST_SIZE=$(receipt_value "$receipt" candidate_manifest_size)
  RECEIPT_CONFIG_DIGEST=$(receipt_value "$receipt" candidate_config_digest)
  RECEIPT_CONFIG_SIZE=$(receipt_value "$receipt" candidate_config_size)
  RECEIPT_LAYERS=$(receipt_value "$receipt" candidate_layers)
  RECEIPT_OS=$(receipt_value "$receipt" candidate_os)
  RECEIPT_ARCH=$(receipt_value "$receipt" candidate_arch)
  RECEIPT_REVISION=$(receipt_value "$receipt" candidate_oci_revision)
  RECEIPT_COMMIT=$(receipt_value "$receipt" candidate_commit)
  RECEIPT_TREE=$(receipt_value "$receipt" candidate_tree)
  RECEIPT_BASE=$(receipt_value "$receipt" base_commit)
  RECEIPT_PATCH_SHA256=$(receipt_value "$receipt" patch_sha256)
  [[ "$RECEIPT_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'candidate receipt archive SHA-256 is invalid'
  [[ "$RECEIPT_MANIFEST_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'candidate receipt manifest digest is invalid'
  [[ "$RECEIPT_CONFIG_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die 'candidate receipt config digest is invalid'
  [[ "$RECEIPT_MANIFEST_SIZE" =~ ^[1-9][0-9]*$ && "$RECEIPT_CONFIG_SIZE" =~ ^[1-9][0-9]*$ ]] ||
    die 'candidate receipt descriptor size is invalid'
  [[ "$RECEIPT_LAYERS" =~ ^sha256:[0-9a-f]{64}:[1-9][0-9]*(,sha256:[0-9a-f]{64}:[1-9][0-9]*)*$ ]] ||
    die 'candidate receipt layer descriptors are invalid'
  [[ "$RECEIPT_OS" == linux && "$RECEIPT_ARCH" == amd64 ]] || die 'candidate receipt platform must be linux/amd64'
  [[ "$RECEIPT_IMAGE_REF" == *@"$RECEIPT_MANIFEST_DIGEST" ]] ||
    die 'candidate image reference must be pinned to the receipt manifest digest'
  [[ "$RECEIPT_REVISION" =~ ^[0-9a-f]{40}$ ]] || die 'candidate receipt OCI revision is invalid'
  [[ "$RECEIPT_TREE" =~ ^[0-9a-f]{40}$ ]] || die 'candidate receipt tree is invalid'
  [[ "$RECEIPT_BASE" =~ ^[0-9a-f]{40}$ ]] || die 'candidate receipt base commit is invalid'
  [[ "$RECEIPT_PATCH_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'candidate receipt patch hash is invalid'
}

verify_source_lineage() {
  local source=${1:?trusted candidate source checkout required}
  local head tree patch owner
  [[ -d "$source" ]] || die "candidate source lineage mismatch: checkout missing: $source"
  git -C "$source" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    die 'candidate source lineage mismatch: source is not a Git worktree'
  owner=$(stat -c '%u' "$source")
  [[ "$owner" == "$(expected_owner_uid)" ]] ||
    die 'candidate source lineage mismatch: source checkout owner is not trusted'
  [[ ${BUZZ_ALLOW_DIRTY_SOURCE:-0} == 1 || -z $(git -C "$source" status --porcelain) ]] ||
    die 'candidate source lineage mismatch: source checkout is dirty'
  git -C "$source" cat-file -e "${RECEIPT_COMMIT}^{commit}" 2>/dev/null ||
    die 'candidate source lineage mismatch: candidate commit is absent'
  git -C "$source" cat-file -e "${RECEIPT_BASE}^{commit}" 2>/dev/null ||
    die 'candidate source lineage mismatch: base commit is absent'
  git -C "$source" cat-file -e "${RECEIPT_REVISION}^{commit}" 2>/dev/null ||
    die 'candidate source lineage mismatch: image revision commit is absent'
  head=$(git -C "$source" rev-parse HEAD)
  [[ "$head" == "$RECEIPT_COMMIT" ]] ||
    die "candidate source lineage mismatch: checkout HEAD is $head, expected $RECEIPT_COMMIT"
  git -C "$source" merge-base --is-ancestor "$RECEIPT_BASE" "$RECEIPT_COMMIT" ||
    die 'candidate source lineage mismatch: base is not an ancestor of candidate'
  git -C "$source" merge-base --is-ancestor "$RECEIPT_REVISION" "$RECEIPT_COMMIT" ||
    die 'candidate source lineage mismatch: image revision is not an ancestor of candidate'
  tree=$(git -C "$source" rev-parse "${RECEIPT_COMMIT}^{tree}")
  [[ "$tree" == "$RECEIPT_TREE" ]] ||
    die "candidate source lineage mismatch: tree is $tree, expected $RECEIPT_TREE"
  patch=$(git -C "$source" diff --binary --full-index --no-ext-diff \
    "$RECEIPT_BASE" "$RECEIPT_COMMIT" | sha256sum | cut -d' ' -f1)
  [[ "$patch" == "$RECEIPT_PATCH_SHA256" ]] ||
    die "candidate source lineage mismatch: patch SHA-256 is $patch, expected $RECEIPT_PATCH_SHA256"
}

image_revision() {
  docker image inspect --format='{{index .Config.Labels "org.opencontainers.image.revision"}}' "$1"
}

oci_archive_receipt_facts() {
  local archive=${1:?candidate image archive required}
  python3 - "$archive" <<'PY'
import hashlib, json, sys, tarfile

archive = sys.argv[1]
def digest(payload): return "sha256:" + hashlib.sha256(payload).hexdigest()
with tarfile.open(archive, "r:*") as tf:
    members = {m.name.removeprefix("./"): m for m in tf.getmembers() if m.isfile()}
    def read(name): return tf.extractfile(members[name]).read()
    index = json.loads(read("index.json"))
    descriptor = index["manifests"][0]
    manifest_raw = read("blobs/sha256/" + descriptor["digest"].removeprefix("sha256:"))
    if digest(manifest_raw) != descriptor["digest"] or len(manifest_raw) != descriptor["size"]: raise SystemExit("invalid manifest descriptor")
    manifest = json.loads(manifest_raw)
    config_descriptor = manifest["config"]
    config_raw = read("blobs/sha256/" + config_descriptor["digest"].removeprefix("sha256:"))
    if digest(config_raw) != config_descriptor["digest"] or len(config_raw) != config_descriptor["size"]: raise SystemExit("invalid config descriptor")
    config = json.loads(config_raw)
    layer_values = []
    for layer in manifest["layers"]:
        raw = read("blobs/sha256/" + layer["digest"].removeprefix("sha256:"))
        if digest(raw) != layer["digest"] or len(raw) != layer["size"]: raise SystemExit("invalid layer descriptor")
        layer_values.append(layer["digest"] + ":" + str(layer["size"]))
print("candidate_archive_sha256=" + hashlib.sha256(open(archive, "rb").read()).hexdigest())
print("candidate_manifest_digest=" + descriptor["digest"])
print("candidate_manifest_size=" + str(descriptor["size"]))
print("candidate_config_digest=" + config_descriptor["digest"])
print("candidate_config_size=" + str(config_descriptor["size"]))
print("candidate_layers=" + ",".join(layer_values))
print("candidate_os=" + config["os"])
print("candidate_arch=" + config["architecture"])
print("candidate_oci_revision=" + config["config"]["Labels"]["org.opencontainers.image.revision"])
PY
}

verify_oci_archive() {
  local archive=${1:?candidate image archive required} archive_sha
  [[ -f "$archive" ]] || die "candidate image archive not found: $archive"
  archive_sha=$(sha256sum "$archive" | cut -d' ' -f1)
  [[ "$archive_sha" == "$RECEIPT_ARCHIVE_SHA256" ]] ||
    die "candidate archive SHA-256 mismatch: expected $RECEIPT_ARCHIVE_SHA256, got $archive_sha"
  python3 - "$archive" "$RECEIPT_MANIFEST_DIGEST" "$RECEIPT_MANIFEST_SIZE" \
    "$RECEIPT_CONFIG_DIGEST" "$RECEIPT_CONFIG_SIZE" "$RECEIPT_LAYERS" \
    "$RECEIPT_OS" "$RECEIPT_ARCH" "$RECEIPT_REVISION" <<'PY' ||
import hashlib, json, sys, tarfile

archive, manifest_digest, manifest_size, config_digest, config_size, layers, expected_os, expected_arch, revision = sys.argv[1:]

def fail(message):
    print("ERROR: candidate OCI archive " + message, file=sys.stderr)
    raise SystemExit(1)

def digest_bytes(payload):
    return "sha256:" + hashlib.sha256(payload).hexdigest()

with tarfile.open(archive, "r:*") as tf:
    members = tf.getmembers()
    names = [member.name.removeprefix("./") for member in members if member.isfile()]
    if len(names) != len(set(names)):
        fail("contains duplicate file entries")

    def read(name):
        matches = [member for member in members if member.isfile() and member.name.removeprefix("./") == name]
        if len(matches) != 1:
            fail("must contain exactly one " + name)
        stream = tf.extractfile(matches[0])
        if stream is None:
            fail("cannot read " + name)
        return stream.read()

    try:
        index = json.loads(read("index.json"))
    except Exception:
        fail("index.json is invalid JSON")
    descriptors = index.get("manifests")
    if not isinstance(descriptors, list) or len(descriptors) != 1:
        fail("index must select exactly one manifest")
    descriptor = descriptors[0]
    if descriptor.get("digest") != manifest_digest or descriptor.get("size") != int(manifest_size):
        fail("index manifest descriptor mismatch")

    manifest_raw = read("blobs/sha256/" + manifest_digest.removeprefix("sha256:"))
    if len(manifest_raw) != int(manifest_size) or digest_bytes(manifest_raw) != manifest_digest:
        fail("manifest blob digest or size mismatch")
    try:
        manifest = json.loads(manifest_raw)
    except Exception:
        fail("manifest blob is invalid JSON")
    config_descriptor = manifest.get("config", {})
    if config_descriptor.get("digest") != config_digest or config_descriptor.get("size") != int(config_size):
        fail("config descriptor mismatch")

    config_raw = read("blobs/sha256/" + config_digest.removeprefix("sha256:"))
    if len(config_raw) != int(config_size) or digest_bytes(config_raw) != config_digest:
        fail("config blob digest or size mismatch")
    try:
        config = json.loads(config_raw)
    except Exception:
        fail("config blob is invalid JSON")
    if config.get("os") != expected_os or config.get("architecture") != expected_arch:
        fail("platform mismatch")
    labels = config.get("config", {}).get("Labels") or {}
    if labels.get("org.opencontainers.image.revision") != revision:
        fail("revision mismatch")

    expected_layers = []
    for item in layers.split(","):
        algorithm, digest, size = item.split(":")
        expected_layers.append({"digest": algorithm + ":" + digest, "size": int(size)})
    actual_layers = manifest.get("layers")
    if not isinstance(actual_layers, list) or [
        {"digest": item.get("digest"), "size": item.get("size")} for item in actual_layers
    ] != expected_layers:
        fail("ordered layer descriptors mismatch")
    for layer in expected_layers:
        raw = read("blobs/sha256/" + layer["digest"].removeprefix("sha256:"))
        if len(raw) != layer["size"] or digest_bytes(raw) != layer["digest"]:
            fail("layer blob digest or size mismatch")
PY
    die 'candidate OCI archive verification failed'
}

image_descriptor_digest() {
  local value
  value=$(docker image inspect --format='{{.Descriptor.digest}}' "$1" 2>/dev/null || true)
  [[ "$value" == '<no value>' ]] && value=''
  printf '%s\n' "$value"
}

image_repo_digests() {
  docker image inspect --format='{{join .RepoDigests ","}}' "$1" 2>/dev/null || true
}

verify_candidate_receipt() {
  local receipt=${1:?candidate receipt required}
  local source=${2:?trusted candidate source checkout required}
  local archive=${3:?candidate image archive required}
  local inspect_ref actual_id actual_descriptor actual_repo_digests actual_revision actual_os actual_arch
  load_candidate_receipt "$receipt"
  verify_source_lineage "$source"
  verify_oci_archive "$archive"
  inspect_ref=${BUZZ_CANDIDATE_INSPECT_REF:-$RECEIPT_IMAGE_REF}
  actual_id=$(docker image inspect --format='{{.Id}}' "$inspect_ref")
  actual_descriptor=$(image_descriptor_digest "$inspect_ref")
  actual_repo_digests=$(image_repo_digests "$inspect_ref")
  if [[ -n "$actual_descriptor" ]]; then
    [[ "$actual_descriptor" == "$RECEIPT_MANIFEST_DIGEST" ]] ||
      die "candidate manifest digest mismatch: expected $RECEIPT_MANIFEST_DIGEST, got $actual_descriptor"
    [[ ",$actual_repo_digests," == *,"$RECEIPT_IMAGE_REF",* ]] || die 'candidate immutable RepoDigest is missing'
  else
    [[ ${BUZZ_ALLOW_CLASSIC_IMAGE_STORE:-0} == 1 ]] ||
      die 'candidate target image lacks an OCI manifest descriptor'
    [[ "$actual_id" == "$RECEIPT_CONFIG_DIGEST" ]] ||
      die "candidate config digest mismatch: expected $RECEIPT_CONFIG_DIGEST, got ${actual_id:-missing}"
  fi
  actual_revision=$(image_revision "$inspect_ref")
  [[ "$actual_revision" == "$RECEIPT_REVISION" ]] ||
    die "candidate OCI revision mismatch: expected $RECEIPT_REVISION, got ${actual_revision:-missing}"
  actual_os=$(docker image inspect --format='{{.Os}}' "$inspect_ref")
  actual_arch=$(docker image inspect --format='{{.Architecture}}' "$inspect_ref")
  [[ "$actual_os/$actual_arch" == "$RECEIPT_OS/$RECEIPT_ARCH" ]] ||
    die "candidate image platform mismatch: expected $RECEIPT_OS/$RECEIPT_ARCH, got $actual_os/$actual_arch"
}

assert_running_candidate() {
  local receipt=${1:?candidate receipt required} archive=${2:?candidate image archive required}
  local container=${3:-$RELAY_CONTAINER}
  local running_id running_revision running_descriptor running_repo_digests running_os running_arch
  load_candidate_receipt "$receipt"
  verify_oci_archive "$archive"
  running_id=$(docker inspect --format='{{.Image}}' "$container")
  if [[ ${BUZZ_ALLOW_CLASSIC_IMAGE_STORE:-0} == 1 && "$running_id" == "$RECEIPT_CONFIG_DIGEST" ]]; then
    running_revision=$(image_revision "$running_id")
    [[ "$running_revision" == "$RECEIPT_REVISION" ]] ||
      die "running candidate OCI revision mismatch: expected $RECEIPT_REVISION, got ${running_revision:-missing}"
    return 0
  fi
  [[ "$running_id" == "$RECEIPT_MANIFEST_DIGEST" ]] ||
    die "running candidate manifest mismatch: expected $RECEIPT_MANIFEST_DIGEST, got ${running_id:-missing}"
  running_descriptor=$(image_descriptor_digest "$running_id")
  [[ "$running_descriptor" == "$RECEIPT_MANIFEST_DIGEST" ]] ||
    die "running candidate descriptor mismatch: expected $RECEIPT_MANIFEST_DIGEST, got ${running_descriptor:-missing}"
  running_repo_digests=$(image_repo_digests "$running_id")
  [[ ",$running_repo_digests," == *,"$RECEIPT_IMAGE_REF",* ]] || die 'running candidate immutable RepoDigest is missing'
  running_revision=$(image_revision "$running_id")
  [[ "$running_revision" == "$RECEIPT_REVISION" ]] ||
    die "running candidate OCI revision mismatch: expected $RECEIPT_REVISION, got ${running_revision:-missing}"
  running_os=$(docker image inspect --format='{{.Os}}' "$running_id")
  running_arch=$(docker image inspect --format='{{.Architecture}}' "$running_id")
  [[ "$running_os/$running_arch" == "$RECEIPT_OS/$RECEIPT_ARCH" ]] ||
    die "running candidate platform mismatch: expected $RECEIPT_OS/$RECEIPT_ARCH, got $running_os/$running_arch"
}

write_candidate_receipt() {
  local image_repository=${1:?candidate image repository required}
  local archive=${2:?candidate image archive required}
  local output=${3:?candidate receipt output required}
  local base=${4:-$DEFAULT_BASE_COMMIT} commit tree revision patch facts_file manifest_digest
  [[ ! -e "$output" ]] || die "candidate receipt already exists: $output"
  commit=$(git -C "$REPO_ROOT" rev-parse HEAD)
  tree=$(git -C "$REPO_ROOT" rev-parse 'HEAD^{tree}')
  facts_file=$(mktemp)
  oci_archive_receipt_facts "$archive" >"$facts_file"
  revision=$(grep '^candidate_oci_revision=' "$facts_file" | cut -d= -f2-)
  manifest_digest=$(grep '^candidate_manifest_digest=' "$facts_file" | cut -d= -f2-)
  git -C "$REPO_ROOT" merge-base --is-ancestor "$revision" "$commit" ||
    die 'candidate image revision must be an ancestor of the receipt source commit'
  patch=$(patch_hash "$base" "$commit")
  umask 077
  mkdir -p -- "$(dirname -- "$output")"
  {
    printf 'candidate_image_ref=%s@%s\n' "$image_repository" "$manifest_digest"
    cat "$facts_file"
    printf 'candidate_commit=%s\n' "$commit"
    printf 'candidate_tree=%s\n' "$tree"
    printf 'base_commit=%s\n' "$base"
    printf 'patch_sha256=%s\n' "$patch"
  } >"$output"
  rm -f -- "$facts_file"
  chmod 0600 "$output"
  load_candidate_receipt "$output"
  verify_source_lineage "$REPO_ROOT"
  verify_oci_archive "$archive"
}

render_overlay() {
  local image=$1 output=$2
  [[ "$image" == *@sha256:* || "$image" == sha256:* ]] || die 'image must be pinned by digest or immutable image ID'
  umask 077
  mkdir -p -- "$(dirname -- "$output")"
  {
    printf 'services:\n'
    printf '  %s:\n' "$RELAY_SERVICE"
    printf '    image: %s\n' "$image"
    printf '    environment:\n'
    printf '      BUZZ_AUTO_MIGRATE: "false"\n'
  } >"$output"
}

container_env_value() {
  local container=$1 key=$2 line
  while IFS= read -r line; do
    case "$line" in
      "$key="*) printf '%s\n' "${line#*=}"; return 0 ;;
    esac
  done < <(docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$container")
  return 1
}

assert_auto_migrate_off() {
  local container=$1 value
  value=$(container_env_value "$container" BUZZ_AUTO_MIGRATE || true)
  [[ "$value" == false || "$value" == 0 ]] ||
    die "BUZZ_AUTO_MIGRATE must be false in $container; observed ${value:-unset}"
}

wait_healthy() {
  local _
  for _ in $(seq 1 60); do
    if curl --fail --silent --show-error "$HEALTH_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  die "relay readiness did not become healthy: $HEALTH_URL"
}

compose_relay_up() {
  local overlay=$1
  docker compose --project-name "$PROJECT" -f "$COMPOSE_FILE" -f "$overlay" \
    up -d --no-deps "$RELAY_SERVICE"
  assert_auto_migrate_off "$RELAY_CONTAINER"
  wait_healthy
}

psql_scalar() {
  docker exec "$POSTGRES_CONTAINER" psql -X -v ON_ERROR_STOP=1 \
    -U "$DB_USER" -d "$DB_NAME" -Atc "$1"
}

verify_migration_record() {
  local record table_name
  record=$(psql_scalar "SELECT success::text || ':' || encode(checksum, 'hex') FROM _sqlx_migrations WHERE version = 25")
  [[ "$record" == "true:$EXPECTED_MIGRATION_SHA384" ]] ||
    die "migration 25 record mismatch: ${record:-missing}"
  table_name=$(psql_scalar "SELECT COALESCE(to_regclass('public.relay_invites')::text, '')")
  [[ "$table_name" == relay_invites ]] || die 'relay_invites table is missing'
}

invariant_value() {
  local file=$1 key=$2
  grep -E "^${key}=" "$file" | head -n1 | cut -d= -f2-
}

compare_invariants() {
  local before=${1:?before invariant file required} after=${2:?after invariant file required}
  [[ -f "$before" && -f "$after" ]] || die 'invariant files must exist'
  [[ $(invariant_value "$before" migrations) == 1,2,3,4,5,6 ]] ||
    die 'invariant drift: preimage migrations are not exactly 1-6'
  [[ $(invariant_value "$after" migrations) == 1,2,3,4,5,6,25 ]] ||
    die 'invariant drift: postimage migrations are not exactly 1-6,25'
  [[ $(invariant_value "$before" relay_invites) == absent ]] ||
    die 'invariant drift: relay_invites unexpectedly existed in preimage'
  [[ $(invariant_value "$after" relay_invites) == 0 ]] ||
    die 'invariant drift: relay_invites must remain empty because minting is prohibited'
  if ! diff -u \
    <(grep -Ev '^(migrations|relay_invites|relay_image)=' "$before" | sort) \
    <(grep -Ev '^(migrations|relay_invites|relay_image)=' "$after" | sort) >/dev/null; then
    die 'invariant drift: membership, message, config, or non-relay service state changed'
  fi
}

sql_stream_hash() {
  local query=$1
  docker exec "$POSTGRES_CONTAINER" psql -X -v ON_ERROR_STOP=1 \
    -U "$DB_USER" -d "$DB_NAME" -Atc "COPY ($query) TO STDOUT" \
    | sha256sum | cut -d' ' -f1
}

capture_invariants() {
  require_root_for_live_action
  local output=${1:?invariant output file required}
  [[ ! -e "$output" ]] || die "invariant output already exists: $output"
  local members_count members_hash messages_count messages_hash
  local communities_count channels_count migrations relay_invites relay_image
  local services_hash config_hash table_name
  local -a non_relay_containers

  members_count=$(psql_scalar 'select count(*) from relay_members')
  members_hash=$(sql_stream_hash "SELECT jsonb_build_object(
    'community_id', community_id, 'pubkey', pubkey, 'role', role,
    'added_by', added_by, 'created_at', created_at
    )::text FROM relay_members ORDER BY community_id, pubkey")
  messages_count=$(psql_scalar 'select count(*) from events where kind in (9,40002,40003,40004,40005,40006,40008)')
  messages_hash=$(sql_stream_hash "SELECT jsonb_build_object(
    'community_id', community_id, 'id', encode(id, 'hex'),
    'pubkey', encode(pubkey, 'hex'), 'created_at', created_at,
    'kind', kind, 'tags', tags, 'content', content, 'sig', encode(sig, 'hex'),
    'channel_id', channel_id, 'deleted_at', deleted_at, 'd_tag', d_tag
    )::text FROM events WHERE kind IN (9,40002,40003,40004,40005,40006,40008)
    ORDER BY community_id, id")
  communities_count=$(psql_scalar 'select count(*) from communities')
  channels_count=$(psql_scalar 'select count(*) from channels')
  migrations=$(psql_scalar "select string_agg(version::text, ',' order by version) from _sqlx_migrations")
  table_name=$(psql_scalar "select coalesce(to_regclass('public.relay_invites')::text, '')")
  if [[ "$table_name" == relay_invites ]]; then
    relay_invites=$(psql_scalar 'select count(*) from relay_invites')
  else
    relay_invites=absent
  fi
  relay_image=$(docker inspect --format='{{.Config.Image}}' "$RELAY_CONTAINER")
  read -r -a non_relay_containers <<<"${BUZZ_NON_RELAY_CONTAINERS:-buzz-prod-postgres-1 buzz-prod-redis-1 buzz-prod-minio-1 buzz-prod-tls-1 buzz-prod-pair-1}"
  services_hash=$(
    docker inspect --format='{{.Id}} {{.State.StartedAt}}' \
      "${non_relay_containers[@]}" \
      | sha256sum | cut -d' ' -f1
  )
  config_hash=$(
    for config_file in ${BUZZ_INVARIANT_CONFIG_FILES:-/etc/buzz/.env /etc/buzz/compose.yml /etc/buzz/nginx-relay.conf}; do
      [[ -f "$config_file" ]] && sha256sum "$config_file"
    done | sha256sum | cut -d' ' -f1
  )

  umask 077
  {
    printf 'members=%s:%s\n' "$members_count" "$members_hash"
    printf 'messages=%s:%s\n' "$messages_count" "$messages_hash"
    printf 'communities=%s\n' "$communities_count"
    printf 'channels=%s\n' "$channels_count"
    printf 'non_relay_services=%s\n' "$services_hash"
    printf 'config=%s\n' "$config_hash"
    printf 'migrations=%s\n' "$migrations"
    printf 'relay_invites=%s\n' "$relay_invites"
    printf 'relay_image=%s\n' "$relay_image"
  } >"$output"
  chmod 0600 "$output"
}

write_manifest() {
  local directory=${1:?manifest directory required}
  local manifest_tmp
  [[ -d "$directory" ]] || die "manifest directory not found: $directory"
  manifest_tmp=$(mktemp)
  (
    cd "$directory"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -print0 \
      | sort -z | xargs -0 -r sha256sum >"$manifest_tmp"
    install -m 0600 "$manifest_tmp" SHA256SUMS
    sha256sum --check SHA256SUMS
  )
  rm -f -- "$manifest_tmp"
}

backup_preimage() {
  require_root_for_live_action
  local backup_dir=${1:?backup directory required}
  [[ "$backup_dir" == "$BACKUP_PATH_PREFIX"* ]] ||
    die "backup directory must use the explicit prefix $BACKUP_PATH_PREFIX"
  [[ ! -e "$backup_dir" ]] || die "backup target already exists: $backup_dir"

  install -d -m 0700 "$backup_dir"
  install -m 0600 "$COMPOSE_FILE" "$backup_dir/compose.yml"
  tar -C /etc -cf "$backup_dir/etc-buzz.tar" buzz
  chmod 0600 "$backup_dir/etc-buzz.tar"
  for config_file in ${BUZZ_BACKUP_CONFIG_FILES:-/etc/buzz/.env /etc/buzz/nginx-relay.conf}; do
    [[ -f "$config_file" ]] || die "required backup source missing: $config_file"
    install -m 0600 "$config_file" "$backup_dir/$(basename -- "$config_file")"
  done
  docker inspect "$RELAY_CONTAINER" >"$backup_dir/relay-container-inspect.json"
  chmod 0600 "$backup_dir/relay-container-inspect.json"
  docker exec "$POSTGRES_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc \
    >"$backup_dir/database-preimage.dump"
  chmod 0600 "$backup_dir/database-preimage.dump"
  write_manifest "$backup_dir"
  umask 077
  printf '%s\n' "$backup_dir" >"$BACKUP_POINTER"
  chmod 0600 "$BACKUP_POINTER"
  assert_backup_verified
  printf '%s\n' "$backup_dir"
}

stage_old_guard() {
  require_root_for_live_action
  assert_backup_verified
  render_overlay "$OLD_IMAGE" "$OLD_OVERLAY"
  compose_relay_up "$OLD_OVERLAY"
}

apply_migration() {
  require_root_for_live_action
  assert_backup_verified
  verify_source_migration
  assert_auto_migrate_off "$RELAY_CONTAINER"

  local existing table_name
  existing=$(psql_scalar "SELECT success::text || ':' || encode(checksum, 'hex') FROM _sqlx_migrations WHERE version = 25")
  if [[ -n "$existing" ]]; then
    verify_migration_record
    printf 'migration 25 already applied with matching SQLx checksum\n'
    return 0
  fi
  table_name=$(psql_scalar "SELECT COALESCE(to_regclass('public.relay_invites')::text, '')")
  [[ -z "$table_name" ]] || die 'relay_invites exists without a SQLx migration 25 record; refusing partial-state repair'

  {
    printf '\\set ON_ERROR_STOP on\nBEGIN;\n'
    cat -- "$MIGRATION"
    printf '\n'
    printf "INSERT INTO _sqlx_migrations (version, description, installed_on, success, checksum, execution_time) VALUES (25, 'relay invites', now(), TRUE, decode('%s', 'hex'), 0);\n" "$EXPECTED_MIGRATION_SHA384"
    printf 'COMMIT;\n'
  } | docker exec -i "$POSTGRES_CONTAINER" psql -X -v ON_ERROR_STOP=1 \
      -U "$DB_USER" -d "$DB_NAME"

  verify_migration_record
}

deploy_candidate() {
  require_root_for_live_action
  assert_backup_verified
  local receipt=${1:?candidate receipt required}
  local source=${2:?trusted candidate source checkout required}
  local archive=${3:?candidate image archive required}
  verify_candidate_receipt "$receipt" "$source" "$archive"
  assert_auto_migrate_off "$RELAY_CONTAINER"
  verify_migration_record
  render_overlay "$RECEIPT_IMAGE_REF" "$CANDIDATE_OVERLAY"
  compose_relay_up "$CANDIDATE_OVERLAY"
  assert_running_candidate "$receipt" "$archive" "$RELAY_CONTAINER"
}

rollback_old() {
  require_root_for_live_action
  render_overlay "$OLD_IMAGE" "$OLD_OVERLAY"
  compose_relay_up "$OLD_OVERLAY"
  verify_migration_record
}

usage() {
  printf '%s\n' \
    'usage:' \
    '  invite-v2-rollout.sh render-overlay IMAGE@sha256:DIGEST OUTPUT' \
    '  invite-v2-rollout.sh migration-checksum [MIGRATION]' \
    '  invite-v2-rollout.sh patch-hash BASE_COMMIT CANDIDATE_COMMIT' \
    '  invite-v2-rollout.sh write-candidate-receipt IMAGE_REF ARCHIVE OUTPUT [BASE_COMMIT]' \
    '  invite-v2-rollout.sh verify-candidate-receipt RECEIPT TRUSTED_SOURCE_CHECKOUT ARCHIVE' \
    '  invite-v2-rollout.sh assert-running-candidate RECEIPT ARCHIVE [CONTAINER]' \
    '  invite-v2-rollout.sh assert-auto-migrate-off CONTAINER' \
    '  invite-v2-rollout.sh assert-backup' \
    '  invite-v2-rollout.sh backup /root/buzz-rollbacks/invite-v2-TIMESTAMP' \
    '  invite-v2-rollout.sh stage-old-guard' \
    '  invite-v2-rollout.sh apply-migration' \
    '  invite-v2-rollout.sh deploy-candidate RECEIPT TRUSTED_SOURCE_CHECKOUT ARCHIVE' \
    '  invite-v2-rollout.sh rollback' \
    '  invite-v2-rollout.sh verify-migration' \
    '  invite-v2-rollout.sh capture-invariants OUTPUT' \
    '  invite-v2-rollout.sh write-manifest DIRECTORY' \
    '  invite-v2-rollout.sh compare-invariants BEFORE AFTER'
}

command=${1:-}
case "$command" in
  render-overlay) render_overlay "${2:?image required}" "${3:?output required}" ;;
  migration-checksum) migration_checksum "${2:-$MIGRATION}" ;;
  patch-hash) patch_hash "${2:?base commit required}" "${3:?candidate commit required}" ;;
  write-candidate-receipt) write_candidate_receipt "${2:?image reference required}" "${3:?archive required}" "${4:?output required}" "${5:-$DEFAULT_BASE_COMMIT}" ;;
  verify-candidate-receipt) verify_candidate_receipt "${2:?candidate receipt required}" "${3:?trusted candidate source checkout required}" "${4:?archive required}" ;;
  assert-running-candidate) assert_running_candidate "${2:?candidate receipt required}" "${3:?archive required}" "${4:-$RELAY_CONTAINER}" ;;
  assert-auto-migrate-off) assert_auto_migrate_off "${2:?container required}" ;;
  assert-backup) assert_backup_verified ;;
  backup) backup_preimage "${2:?backup directory required}" ;;
  stage-old-guard) stage_old_guard ;;
  apply-migration) apply_migration ;;
  deploy-candidate) deploy_candidate "${2:?candidate receipt required}" "${3:?trusted candidate source checkout required}" "${4:?archive required}" ;;
  rollback) rollback_old ;;
  verify-migration) verify_migration_record ;;
  capture-invariants) capture_invariants "${2:?output file required}" ;;
  write-manifest) write_manifest "${2:?directory required}" ;;
  compare-invariants) compare_invariants "${2:?before file required}" "${3:?after file required}" ;;
  *) usage >&2; exit 64 ;;
esac
