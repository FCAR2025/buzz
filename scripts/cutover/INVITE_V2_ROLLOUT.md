# Buzz invite v2 guarded rollout

State: **PREPARED AND REHEARSED — NOT DEPLOYED**

This runbook deploys the final candidate attested by `candidate.receipt` and migration `0025_relay_invites.sql` without making rollback depend on migration files absent from the live-base image.

## Invariant

The live-base image embeds migrations 1–6. Once database migration 25 exists, that image exits with SQLx `VersionMissing(25)` if `BUZZ_AUTO_MIGRATE=true`. Therefore every serving relay must have `BUZZ_AUTO_MIGRATE=false` before migration 25 is applied. The candidate and any rollback to the live-base image must retain that setting. Migration 25 remains additive and is not dropped during rollback.

The rollout script enforces this order:

1. Create and verify a root-only preimage backup.
2. Recreate only the old relay with an immutable old-image digest and auto-migration disabled.
3. Verify readiness and capture pre-migration invariants.
4. Apply the exact migration bytes and SQLx SHA-384 record in one PostgreSQL transaction.
5. Verify the candidate image ID and OCI revision against the receipt, then recreate only the relay from that immutable image ID with auto-migration disabled.
6. Verify the running container image ID and OCI revision, readiness, migration state, empty invite table, and invariants.

Do not mint or claim an invite during this rollout. The existing stateless v1 link remains in its drain window until `2026-08-15T17:27:17Z`.

## Frozen inputs

- Live base: `0d9be2fde1fc18e57da8f2ca229cc01699867550`
- Old image: `ghcr.io/block/buzz:0.2.0@sha256:a0f67203d71d15d237fa7517788799957c30c8acdb81cbcff711e07e951c2710`
- Candidate commit, tree, image ID, OCI revision, base, and patch SHA-256: exact values in the rereviewed `candidate.receipt`
- Migration SHA-384: `d4fdfc8bc8c9d75f7b812f40d533af80de1053fdd0d95c99b6ff6376e7d7090a8b514ef4e0e9d31aba258e6e7833b1c5`

The patch SHA-256 is reproducible from an explicit byte stream:

```bash
git diff --binary --full-index --no-ext-diff "$(grep '^base_commit=' candidate.receipt | cut -d= -f2-)" "$(grep '^candidate_commit=' candidate.receipt | cut -d= -f2-)" | sha256sum
```

## Deployment commands

Run only after independent rereview approves the frozen commit and image.

Place this script, the repository migration, and the independently reviewed receipt at the same relative paths under a root-owned deployment bundle on `nspawn-buzz`, then make the script executable. Load the candidate image before proceeding. The receipt verifier rejects an image whose local ID or `org.opencontainers.image.revision` label differs from the reviewed values.

```bash
cd /root/buzz-invite-v2-final
scripts/cutover/invite-v2-rollout.sh verify-candidate-receipt candidate.receipt

backup_dir=/root/buzz-rollbacks/invite-v2-$(date -u +%Y%m%dT%H%M%SZ)
scripts/cutover/invite-v2-rollout.sh backup "$backup_dir"
scripts/cutover/invite-v2-rollout.sh assert-backup
```

Independently attest the preimage from the controller before the first relay recreation:

```bash
ssh root@nspawn-buzz 'backup_dir=$(< /etc/buzz/invite-v2-backup-path); cd "$backup_dir" && sha256sum --check SHA256SUMS'
```

Stage the old image with migration checking disabled, then capture the pre-migration state:

```bash
scripts/cutover/invite-v2-rollout.sh stage-old-guard
scripts/cutover/invite-v2-rollout.sh assert-auto-migrate-off buzz-prod-relay-1
scripts/cutover/invite-v2-rollout.sh capture-invariants "$backup_dir/before.invariants"
```

Apply migration 25 out of band and deploy the candidate:

```bash
scripts/cutover/invite-v2-rollout.sh apply-migration
scripts/cutover/invite-v2-rollout.sh verify-migration
scripts/cutover/invite-v2-rollout.sh deploy-candidate candidate.receipt
scripts/cutover/invite-v2-rollout.sh assert-running-candidate candidate.receipt buzz-prod-relay-1
scripts/cutover/invite-v2-rollout.sh assert-auto-migrate-off buzz-prod-relay-1
scripts/cutover/invite-v2-rollout.sh capture-invariants "$backup_dir/after.invariants"
scripts/cutover/invite-v2-rollout.sh compare-invariants "$backup_dir/before.invariants" "$backup_dir/after.invariants"
```

The comparison permits only three expected changes: migration versions `1–6` become `1–6,25`, `relay_invites` becomes an empty table, and the relay image changes. The invariant comparison ignores `relay_image` only because `verify-candidate-receipt` and `assert-running-candidate` enforce the exact image ID and OCI revision separately. It rejects changes to semantic memberships, message events, community/channel counts, configuration hashes, or non-relay container identities/start times. Relay startup may publish NIP-43 membership-list system events and update membership timestamps; those are excluded from the semantic membership/message invariant because they are existing startup behavior, not member or message drift.

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
cd /root/buzz-invite-v2-final
scripts/cutover/invite-v2-rollout.sh rollback
scripts/cutover/invite-v2-rollout.sh assert-auto-migrate-off buzz-prod-relay-1
curl --fail --silent http://127.0.0.1:3000/health
curl --fail --silent http://127.0.0.1:8080/_readiness
```

The rollback command recreates only the relay from the immutable old digest using `/etc/buzz/invite-v2-old-guard.yml`. PostgreSQL, Redis, MinIO, TLS, and pair services are not restarted. Re-capture invariants after rollback and compare them with the pre-migration file; the comparator accepts the retained empty migration-25 table but rejects membership, message, configuration, or non-relay service drift.

The full PostgreSQL dump is disaster recovery only. Do not restore it for an ordinary application rollback, because the additive table is safe for the old relay when auto-migration remains disabled.

## Rehearsal

The rehearsal uses the pinned old image, PostgreSQL 18, Redis 7, MinIO, production membership/auth settings, and the candidate receipt:

```bash
BUZZ_REHEARSAL_CANDIDATE_RECEIPT=/root/buzz-invite-v2-final/candidate.receipt \
  scripts/cutover/rehearse-invite-v2-rollback.sh
```

It proves the base image creates migrations 1–6, the guard takes effect before migration 25, the exact migration is recorded, the unguarded old binary fails with SQLx `VersionMissing`, the guarded candidate becomes ready, and the guarded old binary becomes ready again without semantic membership/message drift or restarting supporting services.
