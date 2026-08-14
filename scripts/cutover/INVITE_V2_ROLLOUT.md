# Buzz invite v2 guarded rollout

State: **PREPARED AND REHEARSED — NOT DEPLOYED**

This runbook deploys the final candidate attested by `candidate.receipt` and migration `0025_relay_invites.sql` without making rollback depend on migration files absent from the live-base image.

## Invariant

The live-base image embeds migrations 1–6. Once database migration 25 exists, that image exits with SQLx `VersionMissing(25)` if `BUZZ_AUTO_MIGRATE=true`. Therefore every serving relay must have `BUZZ_AUTO_MIGRATE=false` before migration 25 is applied. The candidate and any rollback to the live-base image must retain that setting. Migration 25 remains additive and is not dropped during rollback.

The rollout script enforces this order:

1. Create and verify a root-only preimage backup, including exact required artifacts, ownership/modes, complete hashes, readable configuration/container archives, and a PostgreSQL restore-list preflight.
2. Recreate only the old relay with an immutable old-image digest and auto-migration disabled.
3. Verify readiness and capture pre-migration invariants.
4. Apply the exact migration bytes and SQLx SHA-384 record in one PostgreSQL transaction.
5. Verify the transferred archive SHA-256, OCI manifest/config/layer descriptors and raw blobs, Linux/AMD64 platform, source lineage, target manifest descriptor/RepoDigest, and image revision against the receipt. Recreate only the relay from the immutable manifest-digest reference with auto-migration disabled.
6. Verify the running container uses the exact OCI manifest digest and that the manifest still binds the reviewed config, layers, platform, and revision; then verify readiness, migration state, empty invite table, and invariants.

Do not mint or claim an invite during this rollout. The existing stateless v1 link remains in its drain window until `2026-08-15T17:27:17Z`.

## Frozen inputs

- Live base: `0d9be2fde1fc18e57da8f2ca229cc01699867550`
- Old image: `ghcr.io/block/buzz:0.2.0@sha256:a0f67203d71d15d237fa7517788799957c30c8acdb81cbcff711e07e951c2710`
- Candidate source commit/tree/base/patch SHA-256 and image archive/manifest/config/layer/platform/revision descriptors: exact values in the rereviewed `candidate.receipt`
- Migration SHA-384: `5ed27780d08863488ec5cddd2661f3619c490cf740f6dd13f242da113efe7e1212b2f2d3a9b548c472f3382ad9f7a155`

The patch SHA-256 is reproducible from an explicit byte stream:

```bash
git -C source diff --binary --full-index --no-ext-diff "$(grep '^base_commit=' candidate.receipt | cut -d= -f2-)" "$(grep '^candidate_commit=' candidate.receipt | cut -d= -f2-)" | sha256sum
```

## Deployment commands

Run only after independent rereview approves the frozen commit and image.

Place the complete, clean Git source checkout at `/root/buzz-invite-v2-final/source`, the independently reviewed receipt at `/root/buzz-invite-v2-final/candidate.receipt`, and the exact transported archive at `/root/buzz-invite-v2-final/candidate-image.tar` on `nspawn-buzz`. Keep the receipt and archive outside `source` to preserve the clean-checkout trust gate. The checkout must have the receipt's candidate commit checked out and contain the base, runtime-revision, and candidate Git objects. Before `docker load`, verify the archive's SHA-256 against the receipt. After loading, the verifier authenticates every raw OCI descriptor/blob and requires the containerd image store to resolve the receipt's immutable `repository@manifest-digest` reference with matching `.Descriptor.digest`, RepoDigest, Linux/AMD64 platform, and revision.

```bash
bundle=/root/buzz-invite-v2-final
source_checkout="$bundle/source"
rollout="$source_checkout/scripts/cutover/invite-v2-rollout.sh"
cd "$bundle"
archive="$bundle/candidate-image.tar"
sha256sum "$archive"
docker load <"$archive"
"$rollout" verify-candidate-receipt candidate.receipt "$source_checkout" "$archive"

backup_dir=/root/buzz-rollbacks/invite-v2-$(date -u +%Y%m%dT%H%M%SZ)
"$rollout" backup "$backup_dir"
"$rollout" assert-backup
```

Independently attest the preimage from the controller before the first relay recreation:

```bash
ssh root@nspawn-buzz 'backup_dir=$(< /etc/buzz/invite-v2-backup-path); cd "$backup_dir" && sha256sum --check SHA256SUMS'
```

The backup guard requires `compose.yml`, `.env`, `nginx-relay.conf`, `etc-buzz.tar`, `relay-container-inspect.json`, `database-preimage.dump`, and `SHA256SUMS`. The directory must be root-owned mode `0700`; the pointer and every artifact must be root-owned mode `0600`. Every required artifact must appear exactly once in the manifest. The guard reads the tar, parses the JSON with Python without printing its contents, and streams the full custom-format dump into `pg_restore --list` inside the matching PostgreSQL container before allowing the rollout to continue. It does not require host `jq` or `pg_restore`.

Stage the old image with migration checking disabled, then capture the pre-migration state:

```bash
"$rollout" stage-old-guard
"$rollout" assert-auto-migrate-off buzz-prod-relay-1
"$rollout" capture-invariants "$backup_dir/before.invariants"
```

Apply migration 25 out of band and deploy the candidate:

```bash
"$rollout" apply-migration
"$rollout" verify-migration
"$rollout" deploy-candidate candidate.receipt "$source_checkout" "$archive"
"$rollout" assert-running-candidate candidate.receipt "$archive" buzz-prod-relay-1
"$rollout" assert-auto-migrate-off buzz-prod-relay-1
"$rollout" capture-invariants "$backup_dir/after.invariants"
"$rollout" compare-invariants "$backup_dir/before.invariants" "$backup_dir/after.invariants"
```

The comparison permits only three expected changes: migration versions `1–6` become `1–6,25`, `relay_invites` becomes an empty table, and the relay image changes. The invariant comparison ignores `relay_image` only because `verify-candidate-receipt` and `assert-running-candidate` separately enforce the manifest digest, config and ordered layers, platform, and revision. It rejects changes to semantic memberships, message events, community/channel counts, configuration hashes, or non-relay container identities/start times. Relay startup may publish NIP-43 membership-list system events and update membership timestamps; those are excluded from the semantic membership/message invariant because they are existing startup behavior, not member or message drift.

Finally verify both health surfaces, the pinned image, the disabled migration setting, an empty invite table, and no migration failure in logs:

```bash
curl --fail --silent http://127.0.0.1:3000/health
curl --fail --silent http://127.0.0.1:8080/_readiness
docker inspect --format '{{.Config.Image}} {{range .Config.Env}}{{println .}}{{end}}' buzz-prod-relay-1
docker exec buzz-prod-postgres-1 psql -X -U buzz -d buzz -Atc 'select version, success, encode(checksum, '\''hex'\'') from _sqlx_migrations order by version'
docker exec buzz-prod-postgres-1 psql -X -U buzz -d buzz -Atc 'select count(*) from relay_invites'
docker logs --since 10m buzz-prod-relay-1 2>&1 | grep -E 'Database migration failed|VersionMissing|ERROR'
```

The final `grep` is expected to return no lines. Record that outcome explicitly; a nonzero `grep` exit alone is not sufficient evidence.

## Rollback

Rollback never drops `relay_invites` and never re-enables SQLx migration checking:

```bash
bundle=/root/buzz-invite-v2-final
rollout="$bundle/source/scripts/cutover/invite-v2-rollout.sh"
cd "$bundle"
"$rollout" rollback
"$rollout" assert-auto-migrate-off buzz-prod-relay-1
curl --fail --silent http://127.0.0.1:3000/health
curl --fail --silent http://127.0.0.1:8080/_readiness
```

The rollback command recreates only the relay from the immutable old digest using `/etc/buzz/invite-v2-old-guard.yml`. PostgreSQL, Redis, MinIO, TLS, and pair services are not restarted. Re-capture invariants after rollback and compare them with the pre-migration file; the comparator accepts the retained empty migration-25 table but rejects membership, message, configuration, or non-relay service drift.

The full PostgreSQL dump is disaster recovery only. Do not restore it for an ordinary application rollback, because the additive table is safe for the old relay when auto-migration remains disabled.

## Rehearsal

The rehearsal uses the pinned old image, PostgreSQL 18, Redis 7, MinIO, production membership/auth settings, and the candidate receipt:

```bash
BUZZ_REHEARSAL_CANDIDATE_RECEIPT=/root/buzz-invite-v2-final/candidate.receipt \
BUZZ_REHEARSAL_CANDIDATE_SOURCE=/root/buzz-invite-v2-final/source \
BUZZ_REHEARSAL_CANDIDATE_ARCHIVE=/root/buzz-invite-v2-final/candidate-image.tar \
BUZZ_REHEARSAL_CANDIDATE_IMAGE=buzz-relay-invite-v2:75c4c5160 \
  /root/buzz-invite-v2-final/source/scripts/cutover/rehearse-invite-v2-rollback.sh
```

The local rehearsal explicitly enables classic-image-store compatibility because its daemon reports the config digest as `.Id`; production never enables that flag. Contract tests separately model the target containerd path and require the manifest digest for both the target descriptor and running container. The rehearsal proves the base image creates migrations 1–6, the guard takes effect before migration 25, the exact migration is recorded, the unguarded old binary fails with SQLx `VersionMissing`, the guarded candidate becomes ready, and the guarded old binary becomes ready again without semantic membership/message drift or restarting supporting services.
