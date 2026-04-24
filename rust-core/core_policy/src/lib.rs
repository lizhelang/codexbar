use std::collections::{BTreeMap, BTreeSet};

use core_model::{
    CanonicalAccountSnapshot, CanonicalActiveSelection, CanonicalConfigSnapshot,
    CanonicalGlobalSettings, CanonicalModelPricing, CanonicalOpenAISettings,
    CanonicalProviderAccountSnapshot, CanonicalProviderSnapshot, CanonicalQuotaSortSettings,
    CanonicalizationResult, LiveSessionSummary, RawConfigInput, RawProviderAccountInput,
    RawProviderInput, RefreshOutcomeRequest, RefreshOutcomeResult, RefreshPlanRequest,
    RefreshPlanResult, RefreshRetryState, RouteRuntimeInput, RouteRuntimeSnapshotDto,
    RunningThreadSummary, RuntimeBlockSummary, UsageMergeResult, UsageMergeSuccessRequest,
};

const DEFAULT_MODEL: &str = "gpt-5.4";
const DEFAULT_REASONING_EFFORT: &str = "xhigh";
const DEFAULT_PROVIDER_KIND: &str = "openai_compatible";
const DEFAULT_ACCOUNT_KIND: &str = "oauth_tokens";
const USAGE_MODE_SWITCH: &str = "switch";
const USAGE_MODE_AGGREGATE: &str = "aggregate_gateway";
const ORDERING_MODE_QUOTA_SORT: &str = "quotaSort";
const MANUAL_ACTIVATION_UPDATE_ONLY: &str = "updateConfigOnly";
const USAGE_DISPLAY_USED: &str = "used";
const ROUTING_DEGRADED_THRESHOLD: f64 = 80.0;
const ROUTING_EXHAUSTED_THRESHOLD: f64 = 100.0;
const OPENROUTER_KIND: &str = "openrouter";
const OPENAI_COMPATIBLE_KIND: &str = "openai_compatible";

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterModelInput {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterProviderAccountInput {
    pub id: String,
    pub kind: String,
    pub label: String,
    #[serde(default)]
    pub api_key: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterProviderInput {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub enabled: bool,
    #[serde(default)]
    pub base_url: Option<String>,
    #[serde(default)]
    pub default_model: Option<String>,
    #[serde(default)]
    pub selected_model_id: Option<String>,
    #[serde(default)]
    pub pinned_model_ids: Vec<String>,
    #[serde(default)]
    pub cached_model_catalog: Vec<OpenRouterModelInput>,
    #[serde(default)]
    pub model_catalog_fetched_at: Option<f64>,
    #[serde(default)]
    pub active_account_id: Option<String>,
    #[serde(default)]
    pub accounts: Vec<OpenRouterProviderAccountInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterNormalizationRequest {
    pub global_default_model: String,
    #[serde(default)]
    pub recent_openrouter_model_id: Option<String>,
    #[serde(default)]
    pub active_provider_id: Option<String>,
    #[serde(default)]
    pub active_account_id: Option<String>,
    #[serde(default)]
    pub switch_provider_id: Option<String>,
    #[serde(default)]
    pub switch_account_id: Option<String>,
    #[serde(default)]
    pub providers: Vec<OpenRouterProviderInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterNormalizationResult {
    pub changed: bool,
    #[serde(default)]
    pub remove_provider_ids: Vec<String>,
    #[serde(default)]
    pub merged_provider: Option<OpenRouterProviderInput>,
    #[serde(default)]
    pub active_provider_id: Option<String>,
    #[serde(default)]
    pub active_account_id: Option<String>,
    #[serde(default)]
    pub switch_provider_id: Option<String>,
    #[serde(default)]
    pub switch_account_id: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterCompatPersistenceRequest {
    pub provider: OpenRouterProviderInput,
    #[serde(default)]
    pub active_provider_id: Option<String>,
    #[serde(default)]
    pub switch_provider_id: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterCompatPersistenceResult {
    pub persisted_provider: OpenRouterProviderInput,
    #[serde(default)]
    pub active_provider_id: Option<String>,
    #[serde(default)]
    pub switch_provider_id: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthStoredAccountInput {
    pub id: String,
    pub kind: String,
    pub label: String,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub openai_account_id: Option<String>,
    #[serde(default)]
    pub access_token: Option<String>,
    #[serde(default)]
    pub refresh_token: Option<String>,
    #[serde(default)]
    pub id_token: Option<String>,
    #[serde(default)]
    pub expires_at: Option<f64>,
    #[serde(default)]
    pub oauth_client_id: Option<String>,
    #[serde(default)]
    pub token_last_refresh_at: Option<f64>,
    #[serde(default)]
    pub last_refresh: Option<f64>,
    #[serde(default)]
    pub added_at: Option<f64>,
    #[serde(default)]
    pub token_expired: Option<bool>,
    #[serde(default)]
    pub organization_name: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AuthJsonSnapshotAccountInput {
    pub access_token: String,
    pub refresh_token: String,
    pub id_token: String,
    #[serde(default)]
    pub expires_at: Option<f64>,
    #[serde(default)]
    pub oauth_client_id: Option<String>,
    #[serde(default)]
    pub token_last_refresh_at: Option<f64>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AuthJsonSnapshotInput {
    pub local_account_id: String,
    pub remote_account_id: String,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub token_last_refresh_at: Option<f64>,
    pub account: AuthJsonSnapshotAccountInput,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthAuthReconciliationRequest {
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
    pub snapshot: AuthJsonSnapshotInput,
    #[serde(default)]
    pub only_account_ids: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthAuthReconciliationResult {
    pub changed: bool,
    #[serde(default)]
    pub matched_index: Option<usize>,
    #[serde(default)]
    pub updated_account: Option<OAuthStoredAccountInput>,
}

pub fn canonicalize_config_and_accounts(input: RawConfigInput) -> CanonicalizationResult {
    let version = input.version.unwrap_or(1).max(1);
    let raw_default_model = input.global.default_model.clone();
    let global = CanonicalGlobalSettings {
        default_model: normalize_nonempty(raw_default_model.clone())
            .unwrap_or_else(|| DEFAULT_MODEL.to_string()),
        review_model: normalize_nonempty(input.global.review_model)
            .or_else(|| normalize_nonempty(raw_default_model))
            .unwrap_or_else(|| DEFAULT_MODEL.to_string()),
        reasoning_effort: normalize_nonempty(input.global.reasoning_effort)
            .unwrap_or_else(|| DEFAULT_REASONING_EFFORT.to_string()),
    };
    let active = CanonicalActiveSelection {
        provider_id: normalize_nonempty(input.active.provider_id),
        account_id: normalize_nonempty(input.active.account_id),
    };
    let model_pricing = input
        .model_pricing
        .into_iter()
        .filter_map(|(model_id, pricing)| {
            normalize_nonempty(Some(model_id)).map(|key| {
                (
                    key,
                    CanonicalModelPricing {
                        input_usd_per_token: sanitize_nonnegative(pricing.input_usd_per_token),
                        cached_input_usd_per_token: sanitize_nonnegative(
                            pricing.cached_input_usd_per_token,
                        ),
                        output_usd_per_token: sanitize_nonnegative(pricing.output_usd_per_token),
                    },
                )
            })
        })
        .collect::<BTreeMap<_, _>>();

    let openai = canonicalize_openai_settings(input.openai);
    let providers = input
        .providers
        .into_iter()
        .enumerate()
        .map(|(provider_index, provider)| canonicalize_provider(provider_index, provider))
        .collect::<Vec<_>>();

    let config = CanonicalConfigSnapshot {
        version,
        global,
        active,
        model_pricing,
        openai,
        providers,
    };
    let accounts = config
        .providers
        .iter()
        .flat_map(|provider| {
            provider
                .accounts
                .iter()
                .filter_map(|account| canonical_account_from_provider_account(provider, account))
        })
        .collect::<Vec<_>>();

    CanonicalizationResult { config, accounts }
}

pub fn compute_route_runtime_snapshot(input: RouteRuntimeInput) -> RouteRuntimeSnapshotDto {
    let latest_sticky_binding = input.sticky_bindings.first();
    let latest_route_record = input.route_journal.last();
    let latest_route_at = latest_sticky_binding
        .map(|binding| binding.updated_at)
        .or_else(|| latest_route_record.map(|entry| entry.timestamp));
    let latest_routed_account_id = normalize_nonempty(input.aggregate_routed_account_id).or_else(|| {
        latest_sticky_binding
            .and_then(|binding| normalize_nonempty(Some(binding.account_id.clone())))
            .or_else(|| {
                latest_route_record
                    .and_then(|entry| normalize_nonempty(Some(entry.account_id.clone())))
            })
    });

    let lease_active = input.lease_state.has_active_lease
        || input.lease_state.leased_process_ids.is_empty() == false;
    let stale_sticky_eligible = latest_sticky_binding
        .map(|binding| {
            input.running_thread_attribution.summary_is_unavailable == false
                && input
                    .running_thread_attribution
                    .active_thread_ids
                    .contains(&binding.thread_id)
                    == false
                && lease_active == false
                && (input.now - binding.updated_at)
                    > input.running_thread_attribution.recent_activity_window_seconds
        })
        .unwrap_or(false);

    let configured_mode = normalize_usage_mode(Some(input.configured_mode.clone()));
    let effective_mode = normalize_usage_mode(Some(input.effective_mode.clone()));

    RouteRuntimeSnapshotDto {
        configured_mode: configured_mode.clone(),
        effective_mode: effective_mode.clone(),
        aggregate_runtime_active: effective_mode == USAGE_MODE_AGGREGATE,
        latest_routed_account_id: latest_routed_account_id.clone(),
        latest_routed_account_is_summary: latest_routed_account_id.is_some(),
        sticky_affects_future_routing: latest_sticky_binding.is_some()
            && configured_mode == USAGE_MODE_AGGREGATE,
        lease_active,
        stale_sticky_eligible,
        stale_sticky_thread_id: if stale_sticky_eligible {
            latest_sticky_binding.map(|binding| binding.thread_id.clone())
        } else {
            None
        },
        latest_route_at,
        runtime_block_summary: RuntimeBlockSummary {
            has_blocker: input.runtime_block_state.blocked_account_ids.is_empty() == false
                || input.runtime_block_state.retry_at.is_some()
                || input.runtime_block_state.reset_at.is_some(),
            blocked_account_ids: dedup_vec(input.runtime_block_state.blocked_account_ids),
            retry_at: input.runtime_block_state.retry_at,
            reset_at: input.runtime_block_state.reset_at,
        },
        running_thread_summary: RunningThreadSummary {
            summary_is_unavailable: input.running_thread_attribution.summary_is_unavailable,
            active_thread_ids: dedup_vec(input.running_thread_attribution.active_thread_ids),
            in_use_account_ids: dedup_vec(input.running_thread_attribution.in_use_account_ids),
        },
        live_session_summary: LiveSessionSummary {
            summary_is_unavailable: input.live_session_attribution.summary_is_unavailable,
            active_session_ids: dedup_vec(input.live_session_attribution.active_session_ids),
            attributed_account_ids: dedup_vec(input.live_session_attribution.attributed_account_ids),
        },
    }
}

pub fn plan_refresh(request: RefreshPlanRequest) -> RefreshPlanResult {
    if request.in_flight {
        return RefreshPlanResult {
            should_refresh: false,
            skip_reason: Some("inFlight".to_string()),
        };
    }
    if request
        .existing_retry_state
        .as_ref()
        .map(|state| state.retry_after > request.now)
        .unwrap_or(false)
    {
        return RefreshPlanResult {
            should_refresh: false,
            skip_reason: Some("retryBackoff".to_string()),
        };
    }
    if request.account.is_suspended {
        return RefreshPlanResult {
            should_refresh: false,
            skip_reason: Some("suspended".to_string()),
        };
    }
    if request.force {
        return RefreshPlanResult {
            should_refresh: true,
            skip_reason: None,
        };
    }
    if request.account.token_expired {
        return RefreshPlanResult {
            should_refresh: false,
            skip_reason: Some("tokenExpired".to_string()),
        };
    }
    let should_refresh = match request.account.expires_at {
        Some(expires_at) => (expires_at - request.now) <= request.refresh_window_seconds,
        None => request.account.token_last_refresh_at.is_none(),
    };
    RefreshPlanResult {
        should_refresh,
        skip_reason: if should_refresh {
            None
        } else {
            Some("notDue".to_string())
        },
    }
}

pub fn apply_refresh_outcome(request: RefreshOutcomeRequest) -> RefreshOutcomeResult {
    match request.outcome.as_str() {
        "refreshed" => RefreshOutcomeResult {
            account: request
                .refreshed_account
                .map(finalize_account)
                .unwrap_or_else(|| finalize_account(request.account)),
            next_retry_state: None,
            disposition: "refreshed".to_string(),
        },
        "terminal_failure" => {
            let mut account = request.account;
            account.token_expired = true;
            RefreshOutcomeResult {
                account: finalize_account(account),
                next_retry_state: None,
                disposition: "terminalFailure".to_string(),
            }
        }
        "transient_failure" => RefreshOutcomeResult {
            account: finalize_account(request.account),
            next_retry_state: Some(next_retry_state(
                request.existing_retry_state,
                request.now,
                request.max_retry_count,
            )),
            disposition: "transientFailure".to_string(),
        },
        _ => RefreshOutcomeResult {
            account: finalize_account(request.account),
            next_retry_state: request.existing_retry_state,
            disposition: "skipped".to_string(),
        },
    }
}

pub fn merge_usage_success(request: UsageMergeSuccessRequest) -> UsageMergeResult {
    let mut account = request.account;
    account.plan_type = normalize_nonempty(Some(request.plan_type)).unwrap_or_else(|| "free".to_string());
    account.primary_used_percent = sanitize_nonnegative(request.primary_used_percent);
    account.secondary_used_percent = sanitize_nonnegative(request.secondary_used_percent);
    account.primary_reset_at = request.primary_reset_at;
    account.secondary_reset_at = request.secondary_reset_at;
    account.primary_limit_window_seconds = sanitize_positive_optional(
        request.primary_limit_window_seconds,
    );
    account.secondary_limit_window_seconds = sanitize_positive_optional(
        request.secondary_limit_window_seconds,
    );
    account.last_checked = Some(request.checked_at);
    account.token_expired = false;
    if let Some(name) = normalize_nonempty(request.organization_name) {
        account.organization_name = Some(name);
    }
    UsageMergeResult {
        account: finalize_account(account),
        disposition: "updated".to_string(),
    }
}

pub fn mark_usage_forbidden(account: CanonicalAccountSnapshot) -> UsageMergeResult {
    let mut updated = account;
    updated.is_suspended = true;
    UsageMergeResult {
        account: finalize_account(updated),
        disposition: "forbidden".to_string(),
    }
}

pub fn mark_usage_token_expired(account: CanonicalAccountSnapshot) -> UsageMergeResult {
    let mut updated = account;
    updated.token_expired = true;
    UsageMergeResult {
        account: finalize_account(updated),
        disposition: "tokenExpired".to_string(),
    }
}

pub fn normalize_openrouter_providers(
    request: OpenRouterNormalizationRequest,
) -> OpenRouterNormalizationResult {
    let matching_providers = request
        .providers
        .iter()
        .filter(|provider| is_legacy_openrouter_provider(provider) || provider.kind == OPENROUTER_KIND)
        .cloned()
        .collect::<Vec<_>>();
    if matching_providers.is_empty() {
        return OpenRouterNormalizationResult {
            changed: false,
            remove_provider_ids: vec![],
            merged_provider: None,
            active_provider_id: request.active_provider_id,
            active_account_id: request.active_account_id,
            switch_provider_id: request.switch_provider_id,
            switch_account_id: request.switch_account_id,
        };
    }

    let mut merged_provider = matching_providers
        .iter()
        .find(|provider| provider.kind == OPENROUTER_KIND)
        .cloned()
        .unwrap_or_else(|| OpenRouterProviderInput {
            id: "openrouter".to_string(),
            kind: OPENROUTER_KIND.to_string(),
            label: "OpenRouter".to_string(),
            enabled: true,
            base_url: None,
            default_model: None,
            selected_model_id: None,
            pinned_model_ids: vec![],
            cached_model_catalog: vec![],
            model_catalog_fetched_at: None,
            active_account_id: None,
            accounts: vec![],
        });
    let remove_provider_ids = matching_providers
        .iter()
        .map(|provider| provider.id.clone())
        .collect::<Vec<_>>();
    let matching_ids = remove_provider_ids.iter().cloned().collect::<BTreeSet<_>>();
    let previous_active_provider_id = request.active_provider_id.clone();
    let previous_active_account_id = request.active_account_id.clone();
    let previous_switch_provider_id = request.switch_provider_id.clone();
    let previous_switch_account_id = request.switch_account_id.clone();
    let mut changed = matching_providers.iter().any(|provider| provider.kind != OPENROUTER_KIND);
    let mut resolved_active_account_id = None::<String>;
    let mut seen_account_keys = BTreeSet::<String>::new();
    let mut merged_accounts = vec![];

    for provider in &matching_providers {
        if merged_provider.selected_model_id.is_none() {
            merged_provider.selected_model_id = provider
                .selected_model_id
                .clone()
                .and_then(|value| valid_openrouter_model_identifier(Some(value)))
                .or_else(|| valid_openrouter_model_identifier(provider.default_model.clone()))
                .or_else(|| infer_openrouter_model(provider.base_url.as_deref()));
        }
        merged_provider.pinned_model_ids = resolved_pinned_model_ids(
            merged_provider
                .pinned_model_ids
                .iter()
                .cloned()
                .chain(provider.pinned_model_ids.iter().cloned())
                .collect(),
            merged_provider
                .selected_model_id
                .clone()
                .or_else(|| provider.selected_model_id.clone())
                .or_else(|| provider.default_model.clone()),
        );

        if let Some(provider_fetched_at) = provider.model_catalog_fetched_at {
            let should_replace_catalog = merged_provider.model_catalog_fetched_at.is_none()
                || provider_fetched_at > merged_provider.model_catalog_fetched_at.unwrap_or(f64::MIN)
                || merged_provider.cached_model_catalog.is_empty();
            if should_replace_catalog {
                merged_provider.cached_model_catalog = provider.cached_model_catalog.clone();
                merged_provider.model_catalog_fetched_at = Some(provider_fetched_at);
            }
        } else if merged_provider.cached_model_catalog.is_empty()
            && provider.cached_model_catalog.is_empty() == false
        {
            merged_provider.cached_model_catalog = provider.cached_model_catalog.clone();
        }

        for account in &provider.accounts {
            let dedupe_key = openrouter_account_deduplication_key(account);
            if seen_account_keys.insert(dedupe_key) {
                merged_accounts.push(account.clone());
            }
        }

        if previous_active_provider_id.as_deref() == Some(provider.id.as_str()) {
            resolved_active_account_id = previous_active_account_id
                .clone()
                .or_else(|| provider.active_account_id.clone());
        }
    }

    if merged_provider.selected_model_id.is_none() {
        if let Some(model) =
            valid_openrouter_model_identifier(Some(request.global_default_model.clone()))
        {
            merged_provider.selected_model_id = Some(model);
            changed = true;
        }
    }
    if merged_provider.selected_model_id.is_none() {
        if let Some(model) = valid_openrouter_model_identifier(request.recent_openrouter_model_id) {
            merged_provider.selected_model_id = Some(model);
            changed = true;
        }
    }
    merged_provider.kind = OPENROUTER_KIND.to_string();
    merged_provider.default_model = None;
    merged_provider.pinned_model_ids = resolved_pinned_model_ids(
        merged_provider.pinned_model_ids,
        merged_provider.selected_model_id.clone(),
    );
    merged_provider.accounts = merged_accounts;

    if let Some(resolved_active_account_id) = resolved_active_account_id.clone() {
        if merged_provider
            .accounts
            .iter()
            .any(|account| account.id == resolved_active_account_id)
        {
            merged_provider.active_account_id = Some(resolved_active_account_id);
        } else {
            let fallback_account_id = merged_provider.accounts.first().map(|account| account.id.clone());
            if merged_provider.active_account_id != fallback_account_id {
                changed = true;
            }
            merged_provider.active_account_id = fallback_account_id;
        }
    } else {
        let fallback_account_id = merged_provider.accounts.first().map(|account| account.id.clone());
        if merged_provider.active_account_id != fallback_account_id {
            changed = true;
        }
        merged_provider.active_account_id = fallback_account_id;
    }

    let (active_provider_id, active_account_id) = if previous_active_provider_id
        .as_ref()
        .map(|provider_id| matching_ids.contains(provider_id))
        .unwrap_or(false)
    {
        if request.active_provider_id.as_deref() != Some(merged_provider.id.as_str())
            || request.active_account_id != merged_provider.active_account_id
        {
            changed = true;
        }
        (Some(merged_provider.id.clone()), merged_provider.active_account_id.clone())
    } else {
        (request.active_provider_id, request.active_account_id)
    };

    let (switch_provider_id, switch_account_id) = if previous_switch_provider_id
        .as_ref()
        .map(|provider_id| matching_ids.contains(provider_id))
        .unwrap_or(false)
    {
        let resolved_account_id = if previous_switch_account_id
            .as_ref()
            .map(|account_id| merged_provider.accounts.iter().any(|account| account.id == *account_id))
            .unwrap_or(false)
        {
            previous_switch_account_id
        } else {
            merged_provider.active_account_id.clone()
        };
        if request.switch_provider_id.as_deref() != Some(merged_provider.id.as_str())
            || request.switch_account_id != resolved_account_id
        {
            changed = true;
        }
        (Some(merged_provider.id.clone()), resolved_account_id)
    } else {
        (request.switch_provider_id, request.switch_account_id)
    };

    OpenRouterNormalizationResult {
        changed,
        remove_provider_ids,
        merged_provider: Some(merged_provider),
        active_provider_id,
        active_account_id,
        switch_provider_id,
        switch_account_id,
    }
}

pub fn make_openrouter_compat_persistence(
    request: OpenRouterCompatPersistenceRequest,
) -> OpenRouterCompatPersistenceResult {
    let runtime_provider_id = request.provider.id.clone();
    let mut persisted_provider = request.provider;
    persisted_provider.id = "openrouter-compat".to_string();
    persisted_provider.kind = OPENAI_COMPATIBLE_KIND.to_string();
    persisted_provider.base_url = Some("https://openrouter.ai/api/v1".to_string());
    persisted_provider.default_model = persisted_provider.selected_model_id.clone();

    OpenRouterCompatPersistenceResult {
        persisted_provider: persisted_provider.clone(),
        active_provider_id: if request.active_provider_id.as_deref() == Some(runtime_provider_id.as_str()) {
            Some(persisted_provider.id.clone())
        } else {
            request.active_provider_id
        },
        switch_provider_id: if request.switch_provider_id.as_deref() == Some(runtime_provider_id.as_str()) {
            Some(persisted_provider.id.clone())
        } else {
            request.switch_provider_id
        },
    }
}

pub fn reconcile_oauth_auth_snapshot(
    request: OAuthAuthReconciliationRequest,
) -> OAuthAuthReconciliationResult {
    let only_account_ids = request
        .only_account_ids
        .into_iter()
        .collect::<BTreeSet<_>>();
    let matched_index = matching_stored_account_index(
        &request.accounts,
        &request.snapshot,
        if only_account_ids.is_empty() {
            None
        } else {
            Some(&only_account_ids)
        },
    );
    let Some(matched_index) = matched_index else {
        return OAuthAuthReconciliationResult {
            changed: false,
            matched_index: None,
            updated_account: None,
        };
    };

    let existing = &request.accounts[matched_index];
    if should_absorb_auth_snapshot(&request.snapshot, existing) == false {
        return OAuthAuthReconciliationResult {
            changed: false,
            matched_index: Some(matched_index),
            updated_account: None,
        };
    }

    OAuthAuthReconciliationResult {
        changed: true,
        matched_index: Some(matched_index),
        updated_account: Some(absorb_auth_snapshot(&request.snapshot, existing)),
    }
}

fn canonicalize_openai_settings(input: core_model::RawOpenAISettings) -> CanonicalOpenAISettings {
    let plus_relative_weight = clamp(input.quota_sort.plus_relative_weight, 1.0, 20.0);
    let pro_relative_to_plus_multiplier =
        clamp(input.quota_sort.pro_relative_to_plus_multiplier, 5.0, 30.0);
    let team_relative_to_plus_multiplier =
        clamp(input.quota_sort.team_relative_to_plus_multiplier, 1.0, 3.0);

    CanonicalOpenAISettings {
        account_order: dedup_nonempty_strings(input.account_order),
        account_usage_mode: normalize_usage_mode(input.account_usage_mode),
        switch_mode_selection: input.switch_mode_selection.map(|selection| CanonicalActiveSelection {
            provider_id: normalize_nonempty(selection.provider_id),
            account_id: normalize_nonempty(selection.account_id),
        }),
        account_ordering_mode: normalize_nonempty(input.account_ordering_mode)
            .unwrap_or_else(|| ORDERING_MODE_QUOTA_SORT.to_string()),
        manual_activation_behavior: normalize_nonempty(input.manual_activation_behavior)
            .unwrap_or_else(|| MANUAL_ACTIVATION_UPDATE_ONLY.to_string()),
        usage_display_mode: normalize_nonempty(input.usage_display_mode)
            .unwrap_or_else(|| USAGE_DISPLAY_USED.to_string()),
        quota_sort: CanonicalQuotaSortSettings {
            plus_relative_weight,
            pro_relative_to_plus_multiplier,
            team_relative_to_plus_multiplier,
            pro_absolute_weight: plus_relative_weight * pro_relative_to_plus_multiplier,
            team_absolute_weight: plus_relative_weight * team_relative_to_plus_multiplier,
        },
        interop_proxies_json: normalize_nonempty(input.interop_proxies_json),
        extensions: input.extensions,
    }
}

fn canonicalize_provider(provider_index: usize, input: RawProviderInput) -> CanonicalProviderSnapshot {
    let kind = normalize_nonempty(input.kind).unwrap_or_else(|| DEFAULT_PROVIDER_KIND.to_string());
    let is_openrouter = kind == "openrouter";
    let id = normalize_nonempty(input.id).unwrap_or_else(|| format!("provider-{provider_index}"));
    let label = normalize_nonempty(input.label).unwrap_or_else(|| id.clone());
    let base_url = normalize_nonempty(input.base_url);
    let default_model = normalize_nonempty(input.default_model);
    let selected_model_id =
        normalize_nonempty(input.selected_model_id).or_else(|| default_model.clone());
    let mut pinned_model_ids = dedup_nonempty_strings(input.pinned_model_ids);
    if let Some(selected) = selected_model_id.clone() {
        if pinned_model_ids.contains(&selected) == false {
            pinned_model_ids.insert(0, selected);
        }
    }
    let accounts = input
        .accounts
        .into_iter()
        .enumerate()
        .map(|(account_index, account)| canonicalize_provider_account(provider_index, account_index, account))
        .collect::<Vec<_>>();
    let active_account_id = normalize_nonempty(input.active_account_id).or_else(|| {
        accounts
            .first()
            .map(|account| account.id.clone())
            .and_then(|id| normalize_nonempty(Some(id)))
    });

    CanonicalProviderSnapshot {
        id,
        kind,
        label,
        enabled: input.enabled,
        base_url,
        default_model: if is_openrouter { None } else { default_model },
        selected_model_id,
        pinned_model_ids,
        active_account_id,
        accounts,
    }
}

fn canonicalize_provider_account(
    provider_index: usize,
    account_index: usize,
    input: RawProviderAccountInput,
) -> CanonicalProviderAccountSnapshot {
    let id = normalize_nonempty(input.id).unwrap_or_else(|| format!("account-{provider_index}-{account_index}"));
    let email = normalize_nonempty(input.email);
    let label = normalize_nonempty(input.label)
        .or_else(|| email.clone())
        .unwrap_or_else(|| id.clone());

    CanonicalProviderAccountSnapshot {
        id,
        kind: normalize_nonempty(input.kind).unwrap_or_else(|| DEFAULT_ACCOUNT_KIND.to_string()),
        label,
        email,
        openai_account_id: normalize_nonempty(input.openai_account_id),
        access_token: normalize_nonempty(input.access_token),
        refresh_token: normalize_nonempty(input.refresh_token),
        id_token: normalize_nonempty(input.id_token),
        expires_at: input.expires_at,
        oauth_client_id: normalize_nonempty(input.oauth_client_id),
        token_last_refresh_at: input.token_last_refresh_at,
        api_key: normalize_nonempty(input.api_key),
        plan_type: normalize_nonempty(input.plan_type),
        primary_used_percent: input.primary_used_percent.map(sanitize_nonnegative),
        secondary_used_percent: input.secondary_used_percent.map(sanitize_nonnegative),
        primary_reset_at: input.primary_reset_at,
        secondary_reset_at: input.secondary_reset_at,
        primary_limit_window_seconds: sanitize_positive_optional(input.primary_limit_window_seconds),
        secondary_limit_window_seconds: sanitize_positive_optional(input.secondary_limit_window_seconds),
        last_checked: input.last_checked,
        is_suspended: input.is_suspended,
        token_expired: input.token_expired,
        organization_name: normalize_nonempty(input.organization_name),
        interop_proxy_key: normalize_nonempty(input.interop_proxy_key),
        interop_notes: normalize_nonempty(input.interop_notes),
        interop_concurrency: input.interop_concurrency.filter(|value| *value > 0),
        interop_priority: input.interop_priority,
        interop_rate_multiplier: input.interop_rate_multiplier.filter(|value| value.is_finite()),
        interop_auto_pause_on_expired: input.interop_auto_pause_on_expired,
        interop_credentials_json: normalize_nonempty(input.interop_credentials_json),
        interop_extra_json: normalize_nonempty(input.interop_extra_json),
    }
}

fn canonical_account_from_provider_account(
    provider: &CanonicalProviderSnapshot,
    account: &CanonicalProviderAccountSnapshot,
) -> Option<CanonicalAccountSnapshot> {
    if account.kind != "oauth_tokens" {
        return None;
    }
    let access_token = account.access_token.clone()?;
    let refresh_token = account.refresh_token.clone()?;
    let id_token = account.id_token.clone()?;
    let local_account_id = account.id.clone();
    let remote_account_id = account
        .openai_account_id
        .clone()
        .unwrap_or_else(|| local_account_id.clone());
    let email = account
        .email
        .clone()
        .unwrap_or_else(|| account.label.clone());
    let is_active = provider
        .active_account_id
        .as_ref()
        .map(|id| id == &account.id)
        .unwrap_or(false);

    Some(finalize_account(CanonicalAccountSnapshot {
        local_account_id,
        remote_account_id,
        email,
        access_token,
        refresh_token,
        id_token,
        expires_at: account.expires_at,
        oauth_client_id: account.oauth_client_id.clone(),
        plan_type: account
            .plan_type
            .clone()
            .unwrap_or_else(|| "free".to_string()),
        primary_used_percent: account.primary_used_percent.unwrap_or(0.0),
        secondary_used_percent: account.secondary_used_percent.unwrap_or(0.0),
        primary_reset_at: account.primary_reset_at,
        secondary_reset_at: account.secondary_reset_at,
        primary_limit_window_seconds: account.primary_limit_window_seconds,
        secondary_limit_window_seconds: account.secondary_limit_window_seconds,
        last_checked: account.last_checked,
        is_active,
        is_suspended: account.is_suspended.unwrap_or(false),
        token_expired: account.token_expired.unwrap_or(false),
        token_last_refresh_at: account.token_last_refresh_at,
        organization_name: account.organization_name.clone(),
        quota_exhausted: false,
        is_available_for_next_use_routing: false,
        is_degraded_for_next_use_routing: false,
    }))
}

fn finalize_account(mut account: CanonicalAccountSnapshot) -> CanonicalAccountSnapshot {
    let primary_used_percent = sanitize_nonnegative(account.primary_used_percent);
    let secondary_used_percent = sanitize_nonnegative(account.secondary_used_percent);
    let quota_exhausted = primary_used_percent >= ROUTING_EXHAUSTED_THRESHOLD
        || secondary_used_percent >= ROUTING_EXHAUSTED_THRESHOLD;
    let is_available = account.is_suspended == false && account.token_expired == false && quota_exhausted == false;
    let is_degraded = is_available
        && (primary_used_percent >= ROUTING_DEGRADED_THRESHOLD
            || secondary_used_percent >= ROUTING_DEGRADED_THRESHOLD);

    account.email = normalize_nonempty(Some(account.email)).unwrap_or_else(|| account.local_account_id.clone());
    account.remote_account_id = normalize_nonempty(Some(account.remote_account_id))
        .unwrap_or_else(|| account.local_account_id.clone());
    account.oauth_client_id = normalize_nonempty(account.oauth_client_id);
    account.plan_type = normalize_nonempty(Some(account.plan_type)).unwrap_or_else(|| "free".to_string());
    account.primary_used_percent = primary_used_percent;
    account.secondary_used_percent = secondary_used_percent;
    account.primary_limit_window_seconds = sanitize_positive_optional(account.primary_limit_window_seconds);
    account.secondary_limit_window_seconds = sanitize_positive_optional(account.secondary_limit_window_seconds);
    account.organization_name = normalize_nonempty(account.organization_name);
    account.quota_exhausted = quota_exhausted;
    account.is_available_for_next_use_routing = is_available;
    account.is_degraded_for_next_use_routing = is_degraded;
    account
}

fn next_retry_state(
    existing: Option<RefreshRetryState>,
    now: f64,
    max_retry_count: u32,
) -> RefreshRetryState {
    let attempts = ((existing.map(|state| state.attempts).unwrap_or(0)) + 1).min(max_retry_count.max(1));
    let backoff_minutes = 2f64.powi((attempts.saturating_sub(1)) as i32);
    RefreshRetryState {
        attempts,
        retry_after: now + backoff_minutes * 60.0,
    }
}

fn normalize_usage_mode(value: Option<String>) -> String {
    match normalize_nonempty(value).as_deref() {
        Some(USAGE_MODE_AGGREGATE) => USAGE_MODE_AGGREGATE.to_string(),
        _ => USAGE_MODE_SWITCH.to_string(),
    }
}

fn valid_openrouter_model_identifier(candidate: Option<String>) -> Option<String> {
    let trimmed = normalize_nonempty(candidate)?;
    if trimmed.contains('/') && trimmed.contains(' ') == false {
        Some(trimmed)
    } else {
        None
    }
}

fn normalized_openrouter_model_ids(values: Vec<String>) -> Vec<String> {
    let mut seen = BTreeSet::new();
    values
        .into_iter()
        .filter_map(|value| valid_openrouter_model_identifier(Some(value)))
        .filter(|value| seen.insert(value.clone()))
        .collect()
}

fn resolved_pinned_model_ids(pinned_model_ids: Vec<String>, selected_model_id: Option<String>) -> Vec<String> {
    let mut normalized = normalized_openrouter_model_ids(pinned_model_ids);
    if let Some(selected_model_id) = valid_openrouter_model_identifier(selected_model_id) {
        if normalized.contains(&selected_model_id) == false {
            normalized.insert(0, selected_model_id);
        }
    }
    normalized
}

fn is_legacy_openrouter_provider(provider: &OpenRouterProviderInput) -> bool {
    if provider.kind != OPENAI_COMPATIBLE_KIND {
        return false;
    }
    let Some(base_url) = provider.base_url.as_deref() else {
        return false;
    };
    let Some((host, path)) = host_and_path(base_url) else {
        return false;
    };
    if host != "openrouter.ai" {
        return false;
    }
    let components = openrouter_path_components(path);
    if components == vec!["api".to_string(), "v1".to_string()] {
        return true;
    }
    components.len() == 3 && components[2].eq_ignore_ascii_case("api")
}

fn infer_openrouter_model(base_url: Option<&str>) -> Option<String> {
    let base_url = base_url?;
    let (host, path) = host_and_path(base_url)?;
    if host != "openrouter.ai" {
        return None;
    }
    let components = openrouter_path_components(path);
    if components.len() == 3 && components[2].eq_ignore_ascii_case("api") {
        valid_openrouter_model_identifier(Some(format!("{}/{}", components[0], components[1])))
    } else {
        None
    }
}

fn openrouter_path_components(path: &str) -> Vec<String> {
    path.split('/')
        .filter(|part| part.is_empty() == false)
        .map(|part| part.to_string())
        .collect()
}

fn host_and_path(url: &str) -> Option<(String, &str)> {
    let without_scheme = url.split_once("://").map(|(_, rest)| rest).unwrap_or(url);
    let (host, path) = without_scheme.split_once('/').unwrap_or((without_scheme, ""));
    let host = host.split(':').next()?.trim().to_ascii_lowercase();
    Some((host, path))
}

fn openrouter_account_deduplication_key(account: &OpenRouterProviderAccountInput) -> String {
    normalize_nonempty(account.api_key.clone()).unwrap_or_else(|| account.id.clone())
}

fn normalize_nonempty(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let trimmed = value.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed.to_string())
        }
    })
}

fn matching_stored_account_index(
    accounts: &[OAuthStoredAccountInput],
    snapshot: &AuthJsonSnapshotInput,
    only_account_ids: Option<&BTreeSet<String>>,
) -> Option<usize> {
    let eligible_accounts = accounts
        .iter()
        .enumerate()
        .filter(|(_, account)| {
            account.kind == "oauth_tokens"
                && only_account_ids
                    .map(|ids| ids.contains(&account.id))
                    .unwrap_or(true)
        })
        .collect::<Vec<_>>();

    if snapshot.local_account_id.is_empty() == false {
        if let Some((index, _)) = eligible_accounts
            .iter()
            .find(|(_, account)| account.id == snapshot.local_account_id)
        {
            return Some(*index);
        }
    }

    if snapshot.remote_account_id.is_empty() {
        return None;
    }

    let remote_matches = eligible_accounts
        .iter()
        .filter(|(_, account)| {
            account
                .openai_account_id
                .as_deref()
                .unwrap_or(account.id.as_str())
                == snapshot.remote_account_id
        })
        .collect::<Vec<_>>();
    if remote_matches.len() == 1 {
        return Some(remote_matches[0].0);
    }

    let Some(email) = snapshot.email.as_ref().map(|value| value.to_lowercase()) else {
        return None;
    };
    let email_matches = remote_matches
        .into_iter()
        .filter(|(_, account)| {
            account
                .email
                .as_ref()
                .map(|value| value.to_lowercase())
                .as_deref()
                == Some(email.as_str())
        })
        .collect::<Vec<_>>();
    if email_matches.len() == 1 {
        Some(email_matches[0].0)
    } else {
        None
    }
}

fn should_absorb_auth_snapshot(
    snapshot: &AuthJsonSnapshotInput,
    stored: &OAuthStoredAccountInput,
) -> bool {
    let local_last_refresh = stored.token_last_refresh_at.or(stored.last_refresh);
    is_later(snapshot.token_last_refresh_at, local_last_refresh)
        || is_later(snapshot.account.expires_at, stored.expires_at)
        || is_later(snapshot.account.token_last_refresh_at, local_last_refresh)
        || token_tuple_changed(snapshot, stored) && stored.token_expired.unwrap_or(false)
}

fn absorb_auth_snapshot(
    snapshot: &AuthJsonSnapshotInput,
    stored: &OAuthStoredAccountInput,
) -> OAuthStoredAccountInput {
    let mut updated = stored.clone();
    updated.access_token = Some(snapshot.account.access_token.clone());
    if snapshot.account.refresh_token.is_empty() == false {
        updated.refresh_token = Some(snapshot.account.refresh_token.clone());
    }
    if snapshot.account.id_token.is_empty() == false {
        updated.id_token = Some(snapshot.account.id_token.clone());
    }
    updated.email = snapshot.email.clone().or(updated.email);
    updated.openai_account_id = Some(snapshot.remote_account_id.clone());
    updated.expires_at = snapshot.account.expires_at.or(updated.expires_at);
    updated.oauth_client_id = snapshot
        .account
        .oauth_client_id
        .clone()
        .or(updated.oauth_client_id);
    updated.token_last_refresh_at = snapshot
        .token_last_refresh_at
        .or(snapshot.account.token_last_refresh_at)
        .or(updated.token_last_refresh_at)
        .or(updated.last_refresh);
    updated.last_refresh = updated.token_last_refresh_at.or(updated.last_refresh);
    updated.token_expired = Some(false);
    updated
}

fn token_tuple_changed(snapshot: &AuthJsonSnapshotInput, stored: &OAuthStoredAccountInput) -> bool {
    stored.access_token.as_deref() != Some(snapshot.account.access_token.as_str())
        || stored.refresh_token.as_deref() != Some(snapshot.account.refresh_token.as_str())
        || stored.id_token.as_deref() != Some(snapshot.account.id_token.as_str())
}

fn is_later(lhs: Option<f64>, rhs: Option<f64>) -> bool {
    match (lhs, rhs) {
        (Some(lhs), Some(rhs)) => lhs > rhs,
        (Some(_), None) => true,
        _ => false,
    }
}

fn sanitize_nonnegative(value: f64) -> f64 {
    if value.is_finite() && value >= 0.0 {
        value
    } else {
        0.0
    }
}

fn sanitize_positive_optional(value: Option<i64>) -> Option<i64> {
    value.filter(|value| *value > 0)
}

fn dedup_nonempty_strings(values: Vec<String>) -> Vec<String> {
    let mut seen = BTreeSet::new();
    values
        .into_iter()
        .filter_map(|value| normalize_nonempty(Some(value)))
        .filter(|value| seen.insert(value.clone()))
        .collect()
}

fn dedup_vec(values: Vec<String>) -> Vec<String> {
    dedup_nonempty_strings(values)
}

fn clamp(value: f64, min_value: f64, max_value: f64) -> f64 {
    sanitize_nonnegative(value).clamp(min_value, max_value)
}

#[cfg(test)]
mod tests {
    use core_model::{
        LeaseStateInput, RawGlobalSettings, RawOpenAISettings, RawProviderAccountInput,
        RawProviderInput, RouteJournalEntry, RuntimeBlockStateInput, StickyBindingInput,
    };

    use super::*;

    #[test]
    fn canonicalizes_openai_oauth_account_into_routing_snapshot() {
        let result = canonicalize_config_and_accounts(RawConfigInput {
            global: RawGlobalSettings {
                default_model: Some(" gpt-5.4 ".into()),
                review_model: None,
                reasoning_effort: None,
            },
            openai: RawOpenAISettings::default(),
            providers: vec![RawProviderInput {
                id: Some("openai-oauth".into()),
                kind: Some("openai_oauth".into()),
                label: Some("OpenAI".into()),
                accounts: vec![RawProviderAccountInput {
                    id: Some("acct-1".into()),
                    kind: Some("oauth_tokens".into()),
                    label: Some("acct@example.com".into()),
                    email: Some("acct@example.com".into()),
                    openai_account_id: Some("remote-1".into()),
                    access_token: Some("access".into()),
                    refresh_token: Some("refresh".into()),
                    id_token: Some("id".into()),
                    primary_used_percent: Some(85.0),
                    ..RawProviderAccountInput::default()
                }],
                active_account_id: Some("acct-1".into()),
                ..RawProviderInput::default()
            }],
            ..RawConfigInput::default()
        });

        assert_eq!(result.config.global.default_model, "gpt-5.4");
        assert_eq!(result.accounts.len(), 1);
        assert!(result.accounts[0].is_degraded_for_next_use_routing);
    }

    #[test]
    fn route_runtime_snapshot_marks_stale_sticky() {
        let snapshot = compute_route_runtime_snapshot(RouteRuntimeInput {
            configured_mode: USAGE_MODE_AGGREGATE.into(),
            effective_mode: USAGE_MODE_AGGREGATE.into(),
            sticky_bindings: vec![StickyBindingInput {
                thread_id: "thread-1".into(),
                account_id: "acct-1".into(),
                updated_at: 10.0,
            }],
            lease_state: LeaseStateInput::default(),
            running_thread_attribution: core_model::RunningThreadAttributionInput {
                active_thread_ids: vec![],
                recent_activity_window_seconds: 5.0,
                summary_is_unavailable: false,
                in_use_account_ids: vec![],
            },
            live_session_attribution: Default::default(),
            runtime_block_state: RuntimeBlockStateInput::default(),
            route_journal: vec![RouteJournalEntry {
                thread_id: "thread-1".into(),
                account_id: "acct-1".into(),
                timestamp: 10.0,
            }],
            aggregate_routed_account_id: None,
            now: 20.0,
        });

        assert!(snapshot.stale_sticky_eligible);
        assert_eq!(snapshot.stale_sticky_thread_id.as_deref(), Some("thread-1"));
    }

    #[test]
    fn normalize_openrouter_providers_promotes_legacy_provider_and_rewrites_active_selection() {
        let result = normalize_openrouter_providers(OpenRouterNormalizationRequest {
            global_default_model: "anthropic/claude-3.7-sonnet".to_string(),
            recent_openrouter_model_id: None,
            active_provider_id: Some("legacy-openrouter".to_string()),
            active_account_id: Some("acct-openrouter".to_string()),
            switch_provider_id: None,
            switch_account_id: None,
            providers: vec![OpenRouterProviderInput {
                id: "legacy-openrouter".to_string(),
                kind: "openai_compatible".to_string(),
                label: "Legacy OpenRouter".to_string(),
                enabled: true,
                base_url: Some("https://openrouter.ai/api/v1".to_string()),
                default_model: None,
                selected_model_id: None,
                pinned_model_ids: vec![],
                cached_model_catalog: vec![],
                model_catalog_fetched_at: None,
                active_account_id: Some("acct-openrouter".to_string()),
                accounts: vec![OpenRouterProviderAccountInput {
                    id: "acct-openrouter".to_string(),
                    kind: "api_key".to_string(),
                    label: "Primary".to_string(),
                    api_key: Some("sk-or-v1-primary".to_string()),
                }],
            }],
        });

        let provider = result.merged_provider.expect("merged provider");
        assert!(result.changed);
        assert_eq!(provider.id, "openrouter");
        assert_eq!(provider.kind, "openrouter");
        assert_eq!(
            provider.selected_model_id.as_deref(),
            Some("anthropic/claude-3.7-sonnet")
        );
        assert_eq!(provider.pinned_model_ids, vec!["anthropic/claude-3.7-sonnet"]);
        assert_eq!(result.active_provider_id.as_deref(), Some("openrouter"));
        assert_eq!(result.active_account_id.as_deref(), Some("acct-openrouter"));
    }

    #[test]
    fn make_openrouter_compat_persistence_rewrites_provider_identity() {
        let result = make_openrouter_compat_persistence(OpenRouterCompatPersistenceRequest {
            provider: OpenRouterProviderInput {
                id: "openrouter".to_string(),
                kind: "openrouter".to_string(),
                label: "OpenRouter".to_string(),
                enabled: true,
                base_url: None,
                default_model: None,
                selected_model_id: Some("anthropic/claude-3.7-sonnet".to_string()),
                pinned_model_ids: vec!["anthropic/claude-3.7-sonnet".to_string()],
                cached_model_catalog: vec![OpenRouterModelInput {
                    id: "anthropic/claude-3.7-sonnet".to_string(),
                    name: Some("Claude 3.7 Sonnet".to_string()),
                }],
                model_catalog_fetched_at: Some(1_710_000_000.0),
                active_account_id: Some("acct-openrouter".to_string()),
                accounts: vec![OpenRouterProviderAccountInput {
                    id: "acct-openrouter".to_string(),
                    kind: "api_key".to_string(),
                    label: "Primary".to_string(),
                    api_key: Some("sk-or-v1-primary".to_string()),
                }],
            },
            active_provider_id: Some("openrouter".to_string()),
            switch_provider_id: Some("openrouter".to_string()),
        });

        assert_eq!(result.persisted_provider.id, "openrouter-compat");
        assert_eq!(result.persisted_provider.kind, "openai_compatible");
        assert_eq!(
            result.persisted_provider.base_url.as_deref(),
            Some("https://openrouter.ai/api/v1")
        );
        assert_eq!(
            result.persisted_provider.default_model.as_deref(),
            Some("anthropic/claude-3.7-sonnet")
        );
        assert_eq!(result.active_provider_id.as_deref(), Some("openrouter-compat"));
        assert_eq!(result.switch_provider_id.as_deref(), Some("openrouter-compat"));
    }

    #[test]
    fn reconcile_oauth_auth_snapshot_absorbs_newer_snapshot() {
        let result = reconcile_oauth_auth_snapshot(OAuthAuthReconciliationRequest {
            accounts: vec![OAuthStoredAccountInput {
                id: "acct_reconcile".to_string(),
                kind: "oauth_tokens".to_string(),
                label: "reconcile@example.com".to_string(),
                email: Some("reconcile@example.com".to_string()),
                openai_account_id: Some("acct_reconcile".to_string()),
                access_token: Some("old-access".to_string()),
                refresh_token: Some("old-refresh".to_string()),
                id_token: Some("old-id".to_string()),
                expires_at: Some(1_730_003_600.0),
                oauth_client_id: Some("app_old_client".to_string()),
                token_last_refresh_at: Some(1_730_000_000.0),
                last_refresh: None,
                added_at: None,
                token_expired: Some(true),
                organization_name: None,
            }],
            snapshot: AuthJsonSnapshotInput {
                local_account_id: "acct_reconcile".to_string(),
                remote_account_id: "acct_reconcile".to_string(),
                email: Some("reconcile@example.com".to_string()),
                token_last_refresh_at: Some(1_730_000_600.0),
                account: AuthJsonSnapshotAccountInput {
                    access_token: "new-access".to_string(),
                    refresh_token: "new-refresh".to_string(),
                    id_token: "new-id".to_string(),
                    expires_at: Some(1_730_007_200.0),
                    oauth_client_id: Some("app_new_client".to_string()),
                    token_last_refresh_at: Some(1_730_000_600.0),
                },
            },
            only_account_ids: vec![],
        });

        assert!(result.changed);
        assert_eq!(result.matched_index, Some(0));
        let updated = result.updated_account.unwrap();
        assert_eq!(updated.access_token.as_deref(), Some("new-access"));
        assert_eq!(updated.oauth_client_id.as_deref(), Some("app_new_client"));
        assert_eq!(updated.token_last_refresh_at, Some(1_730_000_600.0));
        assert_eq!(updated.token_expired, Some(false));
    }

    #[test]
    fn reconcile_oauth_auth_snapshot_keeps_local_snapshot_when_auth_is_older() {
        let result = reconcile_oauth_auth_snapshot(OAuthAuthReconciliationRequest {
            accounts: vec![OAuthStoredAccountInput {
                id: "acct_keep_local".to_string(),
                kind: "oauth_tokens".to_string(),
                label: "keep-local@example.com".to_string(),
                email: Some("keep-local@example.com".to_string()),
                openai_account_id: Some("acct_keep_local".to_string()),
                access_token: Some("local-access".to_string()),
                refresh_token: Some("local-refresh".to_string()),
                id_token: Some("local-id".to_string()),
                expires_at: Some(1_740_007_200.0),
                oauth_client_id: Some("app_local_client".to_string()),
                token_last_refresh_at: Some(1_740_000_600.0),
                last_refresh: None,
                added_at: None,
                token_expired: Some(false),
                organization_name: None,
            }],
            snapshot: AuthJsonSnapshotInput {
                local_account_id: "acct_keep_local".to_string(),
                remote_account_id: "acct_keep_local".to_string(),
                email: Some("keep-local@example.com".to_string()),
                token_last_refresh_at: Some(1_740_000_000.0),
                account: AuthJsonSnapshotAccountInput {
                    access_token: "old-access".to_string(),
                    refresh_token: "old-refresh".to_string(),
                    id_token: "old-id".to_string(),
                    expires_at: Some(1_740_003_600.0),
                    oauth_client_id: Some("app_old_client".to_string()),
                    token_last_refresh_at: Some(1_740_000_000.0),
                },
            },
            only_account_ids: vec![],
        });

        assert!(!result.changed);
        assert_eq!(result.matched_index, Some(0));
        assert_eq!(result.updated_account, None);
    }

    #[test]
    fn reconcile_oauth_auth_snapshot_does_not_match_different_account_on_email_alone() {
        let result = reconcile_oauth_auth_snapshot(OAuthAuthReconciliationRequest {
            accounts: vec![OAuthStoredAccountInput {
                id: "acct_local_only".to_string(),
                kind: "oauth_tokens".to_string(),
                label: "same-email@example.com".to_string(),
                email: Some("same-email@example.com".to_string()),
                openai_account_id: Some("acct_local_remote".to_string()),
                access_token: Some("local-access".to_string()),
                refresh_token: Some("local-refresh".to_string()),
                id_token: Some("local-id".to_string()),
                expires_at: Some(1_750_003_600.0),
                oauth_client_id: Some("app_local_only".to_string()),
                token_last_refresh_at: Some(1_750_000_600.0),
                last_refresh: None,
                added_at: None,
                token_expired: Some(false),
                organization_name: None,
            }],
            snapshot: AuthJsonSnapshotInput {
                local_account_id: "acct_other_only".to_string(),
                remote_account_id: "acct_other_remote".to_string(),
                email: Some("same-email@example.com".to_string()),
                token_last_refresh_at: Some(1_750_001_200.0),
                account: AuthJsonSnapshotAccountInput {
                    access_token: "other-access".to_string(),
                    refresh_token: "other-refresh".to_string(),
                    id_token: "other-id".to_string(),
                    expires_at: Some(1_750_007_200.0),
                    oauth_client_id: Some("app_other_only".to_string()),
                    token_last_refresh_at: Some(1_750_001_200.0),
                },
            },
            only_account_ids: vec![],
        });

        assert!(!result.changed);
        assert_eq!(result.matched_index, None);
        assert_eq!(result.updated_account, None);
    }
}
