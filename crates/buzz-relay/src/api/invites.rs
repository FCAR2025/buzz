//! Relay invite HTTP API — mint and claim stateless invite codes.
//!
//! Routes (both NIP-98 signed, outside the Nostr event data plane):
//!
//! - `POST /api/invites` — mint an invite code. Caller must hold the `owner`
//!   or `admin` role in the tenant community (mirrors the kind:9030 authz).
//! - `POST /api/invites/claim` — claim an invite code. Deliberately **exempt
//!   from the relay-membership gate**: the whole point is that the caller is
//!   not a member yet. NIP-98 proves control of the joining pubkey; the HMAC
//!   on the code proves an admin authorized the join.
//!
//! Token format, key derivation, and security trade-offs live in
//! [`crate::invite_token`].

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::Json,
};
use serde::Deserialize;
use serde_json::Value;

use crate::handlers::side_effects::{publish_nip43_member_added, publish_nip43_membership_list};
use buzz_core::invite::{
    hash_v2_code, validate_v2_code, DEFAULT_INVITE_TTL_SECS, MAX_INVITE_TTL_SECS, MAX_INVITE_USES,
    MIN_INVITE_TTL_SECS, V2_PREFIX,
};

use crate::invite_token;
use crate::state::AppState;

use super::{api_error, bridge, internal_error};

/// Fixed-window size for the per-pubkey claim rate limiter.
pub(crate) const CLAIM_RATE_WINDOW: Duration = Duration::from_secs(60);
/// Max claim attempts per pubkey per window. Claims are idempotent and a real
/// user performs exactly one, so this only bounds brute-force probing.
const CLAIM_RATE_LIMIT: u32 = 10;
/// Maximum distinct pubkeys retained by the process-local claim limiter.
/// NIP-98 proves key ownership, not that a key is costly to create, so this
/// bound is required in addition to expiry.
pub(crate) const CLAIM_RATE_CACHE_CAPACITY: u64 = 10_000;

/// Body for `POST /api/invites`.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MintInviteRequest {
    /// Requested lifetime in seconds. Must be between
    /// [`MIN_INVITE_TTL_SECS`] and
    /// [`invite_token::MAX_INVITE_TTL_SECS`]; defaults to 72 h.
    #[serde(default)]
    pub ttl_secs: Option<u64>,
    /// Maximum number of uses before the invite is exhausted. `None` (omitted
    /// or `null`) means unlimited — preserves current behavior. When present,
    /// must be an integer from 1 through [`MAX_INVITE_USES`].
    #[serde(default)]
    pub max_uses: Option<i32>,
}

fn validate_mint_request(
    request: &MintInviteRequest,
) -> Result<(u64, Option<i32>), (StatusCode, Json<Value>)> {
    let ttl = request.ttl_secs.unwrap_or(DEFAULT_INVITE_TTL_SECS);
    if !(MIN_INVITE_TTL_SECS..=MAX_INVITE_TTL_SECS).contains(&ttl) {
        return Err(api_error(
            StatusCode::BAD_REQUEST,
            &format!(
                "ttl_secs must be between {} and {MAX_INVITE_TTL_SECS}",
                MIN_INVITE_TTL_SECS
            ),
        ));
    }

    if let Some(max_uses) = request.max_uses {
        if !(1..=MAX_INVITE_USES).contains(&max_uses) {
            return Err(api_error(
                StatusCode::BAD_REQUEST,
                &format!("max_uses must be between 1 and {MAX_INVITE_USES}"),
            ));
        }
    }

    Ok((ttl, request.max_uses))
}

/// Body for `POST /api/invites/claim`.
#[derive(Debug, Deserialize)]
pub struct ClaimInviteRequest {
    /// The invite code to redeem.
    pub code: String,
}

/// Shared prelude: bind the tenant from the Host header and verify the NIP-98
/// signature + replay for `path`.
async fn authenticate(
    state: &Arc<AppState>,
    headers: &HeaderMap,
    path: &str,
    body: &[u8],
) -> Result<(buzz_core::TenantContext, nostr::PublicKey), (StatusCode, Json<Value>)> {
    let raw_host = headers
        .get(axum::http::header::HOST)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let tenant = crate::tenant::bind_community(&state.db, raw_host)
        .await
        .map_err(|_| {
            api_error(
                StatusCode::NOT_FOUND,
                "relay: no community is configured for this host",
            )
        })?;

    let url = bridge::nip98_expected_url(&state.config.relay_url, &tenant, path);
    let (pubkey, event_id_bytes) = bridge::verify_bridge_auth_with_options(
        headers,
        "POST",
        &url,
        Some(body),
        true, // invites always require NIP-98; no X-Pubkey dev fallback
        true, // POST bodies must be covered by a payload tag
    )?;
    bridge::check_nip98_replay(state, &tenant, event_id_bytes).await?;

    Ok((tenant, pubkey))
}

/// Mint an invite code — `POST /api/invites`, NIP-98 signed by an owner/admin.
///
/// Returns the code, its expiry, and a shareable landing-page URL on the
/// tenant host.
pub async fn mint_invite(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let (tenant, pubkey) = authenticate(&state, &headers, "/api/invites", &body).await?;

    // Authz mirrors kind:9030 (add member): owner or admin only.
    let sender_hex = pubkey.to_hex();
    let member = state
        .db
        .get_relay_member(tenant.community(), &sender_hex)
        .await
        .map_err(|e| internal_error(&format!("invite mint role lookup: {e}")))?;
    let role = member.map(|m| m.role).unwrap_or_default();
    if role != "owner" && role != "admin" {
        return Err(api_error(
            StatusCode::FORBIDDEN,
            "only relay owners and admins can create invites",
        ));
    }

    let request: MintInviteRequest = if body.is_empty() {
        MintInviteRequest::default()
    } else {
        serde_json::from_slice(&body).map_err(|e| {
            api_error(
                StatusCode::BAD_REQUEST,
                &format!("invalid invite JSON: {e}"),
            )
        })?
    };

    let (ttl, max_uses) = validate_mint_request(&request)?;

    // Mint a v2 opaque, database-backed invite.
    let invite = state
        .db
        .mint_relay_invite(tenant.community(), &sender_hex, ttl, max_uses)
        .await
        .map_err(|error| match error {
            buzz_db::DbError::InvalidData(message) => api_error(StatusCode::BAD_REQUEST, &message),
            error => internal_error(&format!("invite mint: {error}")),
        })?;

    // Same TLS-posture logic as nip98_expected_url: wss deployments get an
    // https landing page URL, ws dev/test deployments get http.
    let scheme = if state.config.relay_url.trim_start().starts_with("wss://") {
        "https"
    } else {
        "http"
    };

    tracing::info!(
        community = %tenant.community(),
        minted_by = %sender_hex,
        invite_id = %invite.invite_id,
        expires_at = %invite.expires_at,
        max_uses = ?invite.max_uses,
        "relay invite minted"
    );

    // expires_at as unix seconds for the response contract.
    let expires_at_unix = invite.expires_at.timestamp() as u64;

    Ok(Json(serde_json::json!({
        "code": invite.code,
        "expires_at": expires_at_unix,
        "max_uses": invite.max_uses,
        "uses_remaining": invite.uses_remaining,
        "url": format!("{scheme}://{}/invite/{}", tenant.host(), invite.code),
    })))
}

/// Claim an invite code — `POST /api/invites/claim`, NIP-98 signed by the
/// *joining* pubkey. Exempt from the relay-membership gate by design.
///
/// Routing is by exact prefix: `v2.` codes go to the database-backed
/// redemption path; every other code goes to the v1 HMAC verifier. A `v2.`
/// code is never fallen back to v1 verification.
pub async fn claim_invite(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    body: axum::body::Bytes,
) -> Result<Json<Value>, (StatusCode, Json<Value>)> {
    let (tenant, pubkey) = authenticate(&state, &headers, "/api/invites/claim", &body).await?;

    if claim_rate_limited(&state, tenant.community(), &pubkey) {
        return Err(api_error(
            StatusCode::TOO_MANY_REQUESTS,
            "too many invite claim attempts, slow down",
        ));
    }

    let request: ClaimInviteRequest = serde_json::from_slice(&body)
        .map_err(|e| api_error(StatusCode::BAD_REQUEST, &format!("invalid claim JSON: {e}")))?;

    let claimer_hex = pubkey.to_hex();
    let key = invite_token::derive_invite_key(&state.relay_keypair);

    // --- v2 database-backed path ---
    //
    // Route by exact prefix: v2. codes use the durable invite table. No
    // fallback to v1 HMAC verification for malformed v2 input.
    if request.code.starts_with(V2_PREFIX) {
        validate_v2_code(&request.code)
            .map_err(|_| api_error(StatusCode::FORBIDDEN, "invite_invalid"))?;

        let token_hash = hash_v2_code(&request.code);
        let outcome = state
            .db
            .claim_relay_invite(tenant.community(), &token_hash, &claimer_hex)
            .await
            .map_err(|e| internal_error(&format!("v2 invite claim: {e}")))?;

        return match outcome {
            buzz_db::relay_invite::ClaimOutcome::Joined { .. } => {
                tracing::info!(
                    community = %tenant.community(),
                    member = %claimer_hex,
                    "relay member added via v2 invite"
                );
                // NIP-43 side effects only on Joined, never on other outcomes.
                if let Err(e) = publish_nip43_member_added(&tenant, &state, &claimer_hex).await {
                    tracing::warn!(
                        "failed to publish NIP-43 member-added delta after v2 claim: {e}"
                    );
                }
                if let Err(e) = publish_nip43_membership_list(&tenant, &state).await {
                    tracing::warn!("failed to publish NIP-43 membership list after v2 claim: {e}");
                }
                Ok(Json(serde_json::json!({
                    "status": "joined",
                    "community_id": tenant.community().to_string(),
                    "host": tenant.host(),
                    "role": "member",
                })))
            }
            buzz_db::relay_invite::ClaimOutcome::AlreadyMember { .. } => {
                Ok(Json(serde_json::json!({
                    "status": "already_member",
                    "community_id": tenant.community().to_string(),
                    "host": tenant.host(),
                    "role": "member",
                })))
            }
            buzz_db::relay_invite::ClaimOutcome::Expired => {
                Err(api_error(StatusCode::FORBIDDEN, "invite_expired"))
            }
            buzz_db::relay_invite::ClaimOutcome::Exhausted => {
                Err(api_error(StatusCode::FORBIDDEN, "invite_exhausted"))
            }
            buzz_db::relay_invite::ClaimOutcome::Invalid => {
                Err(api_error(StatusCode::FORBIDDEN, "invite_invalid"))
            }
        };
    }

    // --- v1 HMAC path (stateless tokens, drain window) ---
    let payload = invite_token::verify_invite(&key, tenant.community(), &request.code).map_err(
        |e| match e {
            // Expired is post-MAC: revealing it helps the UX without helping a forger.
            invite_token::InviteError::Expired => {
                api_error(StatusCode::FORBIDDEN, "invite_expired")
            }
            // Everything else stays coarse so the endpoint is a poor oracle.
            _ => api_error(StatusCode::FORBIDDEN, "invite_invalid"),
        },
    )?;

    let was_inserted = state
        .db
        .add_relay_member(tenant.community(), &claimer_hex, &payload.r, Some("invite"))
        .await
        .map_err(|e| internal_error(&format!("invite claim insert: {e}")))?;

    if was_inserted {
        tracing::info!(
            community = %tenant.community(),
            member = %claimer_hex,
            "relay member added via invite"
        );
        if let Err(e) = publish_nip43_member_added(&tenant, &state, &claimer_hex).await {
            tracing::warn!("failed to publish NIP-43 member-added delta after claim: {e}");
        }
        if let Err(e) = publish_nip43_membership_list(&tenant, &state).await {
            tracing::warn!("failed to publish NIP-43 membership list after claim: {e}");
        }
    }

    Ok(Json(serde_json::json!({
        "status": if was_inserted { "joined" } else { "already_member" },
        "community_id": tenant.community().to_string(),
        "host": tenant.host(),
        "role": payload.r,
    })))
}

/// Fixed-window rate limit on claim attempts, keyed by community and claimer
/// pubkey so traffic for one tenant cannot consume another tenant's allowance.
///
/// Entries expire after one window and the cache has a hard capacity. Both are
/// important because a pre-membership caller can cheaply create fresh Nostr
/// keypairs; retaining one immortal entry per key would make the limiter itself
/// an unbounded-memory denial-of-service vector.
fn claim_rate_limited(
    state: &AppState,
    community: buzz_core::tenant::CommunityId,
    pubkey: &nostr::PublicKey,
) -> bool {
    claim_key_rate_limited(
        &state.invite_claim_rate_limiter,
        (community, pubkey.to_bytes()),
    )
}

fn claim_key_rate_limited(
    cache: &moka::sync::Cache<crate::state::ScopedPubkeyKey, Arc<std::sync::atomic::AtomicU32>>,
    key: crate::state::ScopedPubkeyKey,
) -> bool {
    let counter = cache.get_with(key, || Arc::new(std::sync::atomic::AtomicU32::new(0)));
    counter.fetch_add(1, Ordering::Relaxed) >= CLAIM_RATE_LIMIT
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use super::{
        claim_key_rate_limited, validate_v2_code, CLAIM_RATE_LIMIT, MAX_INVITE_USES,
        MIN_INVITE_TTL_SECS,
    };
    use axum::{
        body::{to_bytes, Body},
        http::{header, Request, StatusCode},
    };
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
    use nostr::{EventBuilder, Keys, Kind, Tag};
    use serde_json::Value;
    use sha2::{Digest, Sha256};
    use tower::ServiceExt;
    use uuid::Uuid;

    use crate::invite_token::MAX_INVITE_TTL_SECS;
    use crate::router::build_router;
    use crate::state::AppState;

    struct AlwaysFreshReplayGuard;

    impl buzz_auth::Nip98ReplayGuard for AlwaysFreshReplayGuard {
        fn try_mark_in_scope<'a>(
            &'a self,
            _scope: &'a str,
            _event_id: &'a nostr::EventId,
            _ttl_secs: u64,
        ) -> std::pin::Pin<
            Box<dyn std::future::Future<Output = Result<bool, buzz_auth::AuthError>> + Send + 'a>,
        > {
            Box::pin(async { Ok(true) })
        }
    }

    const TEST_DB_URL: &str = "postgres://buzz:buzz_dev@localhost:5432/buzz"; // sadscan:disable np.postgres.1

    fn claim_cache(
        capacity: u64,
        ttl: Duration,
    ) -> moka::sync::Cache<crate::state::ScopedPubkeyKey, Arc<std::sync::atomic::AtomicU32>> {
        moka::sync::Cache::builder()
            .max_capacity(capacity)
            .time_to_live(ttl)
            .build()
    }

    #[test]
    fn claim_limiter_rejects_after_limit() {
        let cache = claim_cache(100, Duration::from_secs(60));
        let key = (buzz_core::CommunityId::from_uuid(Uuid::nil()), [7; 32]);

        for _ in 0..CLAIM_RATE_LIMIT {
            assert!(!claim_key_rate_limited(&cache, key));
        }
        assert!(claim_key_rate_limited(&cache, key));
    }

    #[test]
    fn mint_request_rejects_unknown_fields_and_typos() {
        for body in [
            serde_json::json!({ "maxUses": 1 }),
            serde_json::json!({ "ttlSeconds": 3600 }),
            serde_json::json!({ "max_uses": 1, "extra": true }),
        ] {
            assert!(
                serde_json::from_value::<super::MintInviteRequest>(body.clone()).is_err(),
                "unknown key must fail closed: {body}"
            );
        }
    }

    #[test]
    fn claim_limiter_expires_entries() {
        let cache = claim_cache(100, Duration::from_millis(10));
        let key = (buzz_core::CommunityId::from_uuid(Uuid::nil()), [8; 32]);
        assert!(!claim_key_rate_limited(&cache, key));
        assert!(cache.get(&key).is_some());

        std::thread::sleep(Duration::from_millis(25));
        cache.run_pending_tasks();

        assert!(cache.get(&key).is_none());
        assert!(!claim_key_rate_limited(&cache, key));
    }

    #[test]
    fn claim_limiter_isolates_communities_for_same_pubkey() {
        let cache = claim_cache(100, Duration::from_secs(60));
        let pubkey = [9; 32];
        let community_a = buzz_core::CommunityId::from_uuid(Uuid::from_u128(0xAAAA));
        let community_b = buzz_core::CommunityId::from_uuid(Uuid::from_u128(0xBBBB));

        for _ in 0..CLAIM_RATE_LIMIT {
            assert!(!claim_key_rate_limited(&cache, (community_a, pubkey)));
        }
        assert!(claim_key_rate_limited(&cache, (community_a, pubkey)));
        assert!(!claim_key_rate_limited(&cache, (community_b, pubkey)));
    }

    #[test]
    fn claim_limiter_bounds_distinct_pubkeys() {
        let capacity = 10;
        let cache = claim_cache(capacity, Duration::from_secs(60));
        for id in 0..100_u64 {
            let mut pubkey = [0; 32];
            pubkey[..8].copy_from_slice(&id.to_le_bytes());
            let key = (buzz_core::CommunityId::from_uuid(Uuid::nil()), pubkey);
            assert!(!claim_key_rate_limited(&cache, key));
        }
        cache.run_pending_tasks();

        assert!(cache.entry_count() <= capacity);
    }

    fn nip98_auth_header(keys: &Keys, url: &str, body: &[u8]) -> String {
        let hash: [u8; 32] = Sha256::digest(body).into();
        let tags = vec![
            Tag::parse(["u", url]).expect("u tag"),
            Tag::parse(["method", "POST"]).expect("method tag"),
            Tag::parse(["payload", hex::encode(hash).as_str()]).expect("payload tag"),
        ];
        let event = EventBuilder::new(Kind::HttpAuth, "")
            .tags(tags)
            .sign_with_keys(keys)
            .expect("sign NIP-98 event");
        let event_json = serde_json::to_string(&event).expect("serialize NIP-98 event");
        let encoded = base64::engine::general_purpose::STANDARD.encode(event_json.as_bytes());
        format!("Nostr {encoded}")
    }

    /// Build a closed-relay (`require_relay_membership = true`) test state with
    /// a fresh community on `host`; returns `None` when Postgres is unavailable.
    async fn invite_test_state(host: &str) -> Option<Arc<AppState>> {
        let database_url =
            std::env::var("BUZZ_TEST_DATABASE_URL").unwrap_or_else(|_| TEST_DB_URL.to_string());
        let redis_url = std::env::var("BUZZ_TEST_REDIS_URL")
            .unwrap_or_else(|_| "redis://127.0.0.1:1".to_string());
        let mut config = crate::config::Config::from_env().ok()?;
        config.database_url = database_url.clone();
        config.redis_url = redis_url;
        config.relay_url = format!("wss://{host}");
        // The claim route must work on relays where membership is enforced —
        // that is the entire point of an invite.
        config.require_relay_membership = true;

        let pool = sqlx::PgPool::connect(&database_url).await.ok()?;
        let db = buzz_db::Db::from_pool(pool.clone());
        db.ensure_configured_community(host).await.ok()?;

        let redis_pool = deadpool_redis::Config::from_url(&config.redis_url)
            .create_pool(Some(deadpool_redis::Runtime::Tokio1))
            .ok()?;
        let pubsub = Arc::new(
            buzz_pubsub::PubSubManager::new(&config.redis_url, redis_pool.clone())
                .await
                .ok()?,
        );
        let audit = buzz_audit::AuditService::new(pool.clone());
        let auth = buzz_auth::AuthService::new(config.auth.clone());
        let search = buzz_search::SearchService::new(pool.clone());
        let workflow_engine = Arc::new(buzz_workflow::WorkflowEngine::new(
            db.clone(),
            buzz_workflow::WorkflowConfig::default(),
        ));
        let media_storage = buzz_media::MediaStorage::new(&config.media).ok()?;
        let (mut state, _audit_shutdown) = AppState::new(
            config,
            db,
            redis_pool,
            audit,
            pubsub,
            auth,
            search,
            workflow_engine,
            Keys::generate(),
            media_storage,
        );
        state.nip98_replay = Arc::new(AlwaysFreshReplayGuard);
        Some(Arc::new(state))
    }

    async fn post_json(
        state: Arc<AppState>,
        host: &str,
        path: &str,
        keys: &Keys,
        body: String,
    ) -> axum::response::Response {
        let url = format!("https://{host}{path}");
        let auth = nip98_auth_header(keys, &url, body.as_bytes());
        build_router(state)
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(path)
                    .header(header::HOST, host)
                    .header(header::AUTHORIZATION, auth)
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(body))
                    .expect("request"),
            )
            .await
            .expect("response")
    }

    async fn read_json(response: axum::response::Response) -> Value {
        let bytes = to_bytes(response.into_body(), 1024 * 1024)
            .await
            .expect("read response body");
        serde_json::from_slice(&bytes).expect("response JSON")
    }

    async fn mint_code(state: Arc<AppState>, host: &str, owner: &Keys, request: Value) -> String {
        let response = post_json(state, host, "/api/invites", owner, request.to_string()).await;
        assert_eq!(response.status(), StatusCode::OK);
        read_json(response)
            .await
            .get("code")
            .and_then(Value::as_str)
            .expect("minted code")
            .to_string()
    }

    async fn event_count(state: &AppState, community: buzz_core::CommunityId, kind: i32) -> i64 {
        state
            .db
            .count_events(&buzz_db::EventQuery {
                kinds: Some(vec![kind]),
                global_only: true,
                ..buzz_db::EventQuery::for_community(community)
            })
            .await
            .expect("count side-effect events")
    }

    #[test]
    fn mint_request_deserialization_is_strict() {
        for valid in [
            serde_json::json!({}),
            serde_json::json!({ "max_uses": null }),
            serde_json::json!({ "max_uses": 1 }),
            serde_json::json!({ "max_uses": MAX_INVITE_USES }),
        ] {
            serde_json::from_value::<super::MintInviteRequest>(valid).expect("valid request");
        }

        for invalid in [
            serde_json::json!({ "max_uses": 1.5 }),
            serde_json::json!({ "max_uses": "10" }),
            serde_json::json!({ "ttl_secs": -1 }),
            serde_json::json!({ "ttl_secs": 1.5 }),
            serde_json::json!({ "ttl_secs": "3600" }),
        ] {
            assert!(
                serde_json::from_value::<super::MintInviteRequest>(invalid.clone()).is_err(),
                "accepted wrong JSON type: {invalid}"
            );
        }
    }

    #[test]
    fn mint_request_validation_enforces_bounds_without_a_database() {
        use super::validate_mint_request;

        for (request, expected) in [
            (
                super::MintInviteRequest::default(),
                (crate::invite_token::DEFAULT_INVITE_TTL_SECS, None),
            ),
            (
                super::MintInviteRequest {
                    ttl_secs: Some(MIN_INVITE_TTL_SECS),
                    max_uses: Some(1),
                },
                (MIN_INVITE_TTL_SECS, Some(1)),
            ),
            (
                super::MintInviteRequest {
                    ttl_secs: Some(MAX_INVITE_TTL_SECS),
                    max_uses: Some(MAX_INVITE_USES),
                },
                (MAX_INVITE_TTL_SECS, Some(MAX_INVITE_USES)),
            ),
        ] {
            assert_eq!(
                validate_mint_request(&request).expect("valid request"),
                expected
            );
        }

        for request in [
            super::MintInviteRequest {
                ttl_secs: None,
                max_uses: Some(0),
            },
            super::MintInviteRequest {
                ttl_secs: None,
                max_uses: Some(-1),
            },
            super::MintInviteRequest {
                ttl_secs: None,
                max_uses: Some(MAX_INVITE_USES + 1),
            },
            super::MintInviteRequest {
                ttl_secs: Some(MIN_INVITE_TTL_SECS - 1),
                max_uses: None,
            },
            super::MintInviteRequest {
                ttl_secs: Some(MAX_INVITE_TTL_SECS + 1),
                max_uses: None,
            },
        ] {
            assert_eq!(
                validate_mint_request(&request)
                    .expect_err("invalid request")
                    .0,
                StatusCode::BAD_REQUEST
            );
        }
    }

    #[tokio::test]
    #[ignore = "requires Postgres"]
    async fn mint_validates_max_uses_and_ttl_bounds() {
        let host = format!("invites-validation-{}.example", Uuid::new_v4().simple());
        let owner = Keys::generate();
        let state = invite_test_state(&host)
            .await
            .expect("requires reachable Postgres and relay test state");
        let community = state
            .db
            .lookup_community_by_host(&host)
            .await
            .expect("lookup")
            .expect("community exists");
        state
            .db
            .add_relay_member(community.id, &owner.public_key().to_hex(), "owner", None)
            .await
            .expect("seed owner");

        let verification_pool = sqlx::PgPool::connect(&state.config.database_url)
            .await
            .expect("verification pool");
        let invites_before: i64 =
            sqlx::query_scalar("SELECT count(*) FROM relay_invites WHERE community_id = $1")
                .bind(community.id.as_uuid())
                .fetch_one(&verification_pool)
                .await
                .expect("count invites before hostile requests");

        for body in [
            serde_json::json!({ "max_uses": 0 }),
            serde_json::json!({ "max_uses": -1 }),
            serde_json::json!({ "max_uses": MAX_INVITE_USES + 1 }),
            serde_json::json!({ "ttl_secs": MIN_INVITE_TTL_SECS - 1 }),
            serde_json::json!({ "ttl_secs": MAX_INVITE_TTL_SECS + 1 }),
            serde_json::json!({ "maxUses": 1 }),
            serde_json::json!({ "ttlSeconds": MIN_INVITE_TTL_SECS }),
            serde_json::json!({ "max_uses": 1, "extra": true }),
        ] {
            let response = post_json(
                state.clone(),
                &host,
                "/api/invites",
                &owner,
                body.to_string(),
            )
            .await;
            assert_eq!(response.status(), StatusCode::BAD_REQUEST, "{body}");
        }
        let invites_after: i64 =
            sqlx::query_scalar("SELECT count(*) FROM relay_invites WHERE community_id = $1")
                .bind(community.id.as_uuid())
                .fetch_one(&verification_pool)
                .await
                .expect("count invites after hostile requests");
        assert_eq!(
            invites_after, invites_before,
            "invalid or misspelled fields must not mint an unlimited invite"
        );

        for body in [
            serde_json::json!({}),
            serde_json::json!({ "max_uses": null }),
            serde_json::json!({ "max_uses": 1 }),
            serde_json::json!({ "ttl_secs": MIN_INVITE_TTL_SECS }),
            serde_json::json!({ "ttl_secs": MAX_INVITE_TTL_SECS }),
        ] {
            let response = post_json(
                state.clone(),
                &host,
                "/api/invites",
                &owner,
                body.to_string(),
            )
            .await;
            assert_eq!(response.status(), StatusCode::OK, "{body}");
        }

        let response = post_json(
            state,
            &host,
            "/api/invites",
            &owner,
            serde_json::json!({ "max_uses": 10 }).to_string(),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let response = read_json(response).await;
        let code = response["code"].as_str().expect("string invite code");
        validate_v2_code(code).expect("canonical v2 invite code");
        assert!(response["expires_at"].as_u64().is_some(), "numeric expiry");
        assert_eq!(response["max_uses"].as_i64(), Some(10));
        assert_eq!(response["uses_remaining"].as_i64(), Some(10));
        let expected_url = format!("https://{host}/invite/{code}");
        assert_eq!(response["url"].as_str(), Some(expected_url.as_str()));
    }

    #[tokio::test]
    #[ignore = "requires Postgres"]
    async fn malformed_and_unknown_v2_codes_are_forbidden_without_v1_fallback() {
        let host = format!("invites-v2-invalid-{}.example", Uuid::new_v4().simple());
        let joiner = Keys::generate();
        let state = invite_test_state(&host)
            .await
            .expect("requires reachable Postgres and relay test state");
        let unknown = format!("v2.{}", URL_SAFE_NO_PAD.encode([9_u8; 32]));

        for code in [
            "v2.".to_string(),
            "v2.not-base64!".to_string(),
            format!("v2.{}", URL_SAFE_NO_PAD.encode([9_u8; 31])),
            unknown,
        ] {
            let response = post_json(
                state.clone(),
                &host,
                "/api/invites/claim",
                &joiner,
                serde_json::json!({ "code": code }).to_string(),
            )
            .await;
            assert_eq!(response.status(), StatusCode::FORBIDDEN, "{code}");
            assert_eq!(
                read_json(response)
                    .await
                    .get("error")
                    .and_then(Value::as_str),
                Some("invite_invalid")
            );
        }
    }

    #[tokio::test]
    #[ignore = "requires Postgres"]
    async fn bounded_v2_claims_publish_side_effects_only_for_joined() {
        let host = format!(
            "invites-v2-side-effects-{}.example",
            Uuid::new_v4().simple()
        );
        let owner = Keys::generate();
        let first = Keys::generate();
        let second = Keys::generate();
        let state = invite_test_state(&host)
            .await
            .expect("requires reachable Postgres and relay test state");
        let community = state
            .db
            .lookup_community_by_host(&host)
            .await
            .expect("lookup")
            .expect("community exists");
        state
            .db
            .add_relay_member(community.id, &owner.public_key().to_hex(), "owner", None)
            .await
            .expect("seed owner");
        let before_delta_count = event_count(
            &state,
            community.id,
            buzz_core::kind::KIND_NIP43_MEMBER_ADDED as i32,
        )
        .await;
        let before_list_count = event_count(
            &state,
            community.id,
            buzz_core::kind::KIND_NIP43_MEMBERSHIP_LIST as i32,
        )
        .await;
        let code = mint_code(
            state.clone(),
            &host,
            &owner,
            serde_json::json!({ "max_uses": 1 }),
        )
        .await;
        let claim_body = serde_json::json!({ "code": code }).to_string();

        let response = post_json(
            state.clone(),
            &host,
            "/api/invites/claim",
            &first,
            claim_body.clone(),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            read_json(response)
                .await
                .get("status")
                .and_then(Value::as_str),
            Some("joined")
        );
        let delta_count = event_count(
            &state,
            community.id,
            buzz_core::kind::KIND_NIP43_MEMBER_ADDED as i32,
        )
        .await;
        let list_count = event_count(
            &state,
            community.id,
            buzz_core::kind::KIND_NIP43_MEMBERSHIP_LIST as i32,
        )
        .await;
        assert_eq!(delta_count, before_delta_count + 1);
        assert_eq!(list_count, before_list_count + 1);

        let response = post_json(
            state.clone(),
            &host,
            "/api/invites/claim",
            &first,
            claim_body.clone(),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            read_json(response)
                .await
                .get("status")
                .and_then(Value::as_str),
            Some("already_member")
        );
        assert_eq!(
            event_count(
                &state,
                community.id,
                buzz_core::kind::KIND_NIP43_MEMBER_ADDED as i32,
            )
            .await,
            delta_count
        );
        assert_eq!(
            event_count(
                &state,
                community.id,
                buzz_core::kind::KIND_NIP43_MEMBERSHIP_LIST as i32,
            )
            .await,
            list_count
        );

        let response = post_json(
            state.clone(),
            &host,
            "/api/invites/claim",
            &second,
            claim_body,
        )
        .await;
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        assert_eq!(
            read_json(response)
                .await
                .get("error")
                .and_then(Value::as_str),
            Some("invite_exhausted")
        );
        assert_eq!(
            event_count(
                &state,
                community.id,
                buzz_core::kind::KIND_NIP43_MEMBER_ADDED as i32,
            )
            .await,
            delta_count
        );
        assert_eq!(
            event_count(
                &state,
                community.id,
                buzz_core::kind::KIND_NIP43_MEMBERSHIP_LIST as i32,
            )
            .await,
            list_count
        );
    }

    #[tokio::test]
    #[ignore = "requires Postgres"]
    async fn owner_mints_and_new_pubkey_claims() {
        let host = format!("invites-{}.example", Uuid::new_v4().simple());
        let owner = Keys::generate();
        let joiner = Keys::generate();
        let Some(state) = invite_test_state(&host).await else {
            return;
        };
        let community = state
            .db
            .lookup_community_by_host(&host)
            .await
            .expect("lookup")
            .expect("community exists");
        let community_id = community.id;
        state
            .db
            .add_relay_member(community_id, &owner.public_key().to_hex(), "owner", None)
            .await
            .expect("seed owner");

        // Mint.
        let response = post_json(
            state.clone(),
            &host,
            "/api/invites",
            &owner,
            "{}".to_string(),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let json = read_json(response).await;
        let code = json.get("code").and_then(Value::as_str).expect("code");
        let url = json.get("url").and_then(Value::as_str).expect("url");
        assert!(url.contains("/invite/"), "unexpected url: {url}");

        // Claim on a closed relay by a pubkey that is not yet a member.
        let claim_body = serde_json::json!({ "code": code }).to_string();
        let response = post_json(
            state.clone(),
            &host,
            "/api/invites/claim",
            &joiner,
            claim_body.clone(),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let json = read_json(response).await;
        assert_eq!(json.get("status").and_then(Value::as_str), Some("joined"));
        assert_eq!(json.get("role").and_then(Value::as_str), Some("member"));

        let member = state
            .db
            .get_relay_member(community_id, &joiner.public_key().to_hex())
            .await
            .expect("member lookup")
            .expect("joiner is now a member");
        assert_eq!(member.role, "member");

        // Second claim is idempotent.
        let response = post_json(state, &host, "/api/invites/claim", &joiner, claim_body).await;
        assert_eq!(response.status(), StatusCode::OK);
        let json = read_json(response).await;
        assert_eq!(
            json.get("status").and_then(Value::as_str),
            Some("already_member")
        );
    }

    #[tokio::test]
    #[ignore = "requires Postgres"]
    async fn non_admin_cannot_mint() {
        let host = format!("invites-{}.example", Uuid::new_v4().simple());
        let member = Keys::generate();
        let outsider = Keys::generate();
        let Some(state) = invite_test_state(&host).await else {
            return;
        };
        let community = state
            .db
            .lookup_community_by_host(&host)
            .await
            .expect("lookup")
            .expect("community exists");
        let community_id = community.id;
        state
            .db
            .add_relay_member(community_id, &member.public_key().to_hex(), "member", None)
            .await
            .expect("seed member");

        for keys in [&member, &outsider] {
            let response =
                post_json(state.clone(), &host, "/api/invites", keys, "{}".to_string()).await;
            assert_eq!(response.status(), StatusCode::FORBIDDEN);
        }
    }

    #[tokio::test]
    #[ignore = "requires Postgres"]
    async fn claim_rejects_invalid_code() {
        let host = format!("invites-{}.example", Uuid::new_v4().simple());
        let joiner = Keys::generate();
        let Some(state) = invite_test_state(&host).await else {
            return;
        };

        let body = serde_json::json!({ "code": "garbage.code" }).to_string();
        let response = post_json(state.clone(), &host, "/api/invites/claim", &joiner, body).await;
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
        let json = read_json(response).await;
        assert_eq!(
            json.get("error").and_then(Value::as_str),
            Some("invite_invalid")
        );

        let community = state
            .db
            .lookup_community_by_host(&host)
            .await
            .expect("lookup")
            .expect("community exists");
        let is_member = state
            .db
            .is_relay_member(community.id, &joiner.public_key().to_hex())
            .await
            .expect("member check");
        assert!(!is_member, "invalid code must not admit anyone");
    }

    #[tokio::test]
    #[ignore = "requires Postgres"]
    async fn code_minted_for_one_community_fails_on_another() {
        let host_a = format!("invites-a-{}.example", Uuid::new_v4().simple());
        let host_b = format!("invites-b-{}.example", Uuid::new_v4().simple());
        let owner = Keys::generate();
        let joiner = Keys::generate();
        let Some(state) = invite_test_state(&host_a).await else {
            return;
        };
        state
            .db
            .ensure_configured_community(&host_b)
            .await
            .expect("second community");
        let community_a = state
            .db
            .lookup_community_by_host(&host_a)
            .await
            .expect("lookup")
            .expect("community a");
        state
            .db
            .add_relay_member(community_a.id, &owner.public_key().to_hex(), "owner", None)
            .await
            .expect("seed owner");

        let response = post_json(
            state.clone(),
            &host_a,
            "/api/invites",
            &owner,
            "{}".to_string(),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let json = read_json(response).await;
        let code = json.get("code").and_then(Value::as_str).expect("code");

        // Present community A's code on community B's host.
        let body = serde_json::json!({ "code": code }).to_string();
        let response = post_json(state, &host_b, "/api/invites/claim", &joiner, body).await;
        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }
}
