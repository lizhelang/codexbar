use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsagePollingAccount {
    pub account_id: String,
    pub is_suspended: bool,
    pub token_expired: bool,
    #[serde(default)]
    pub last_checked_at: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsagePollingPlanRequest {
    #[serde(default)]
    pub active_provider_kind: Option<String>,
    #[serde(default)]
    pub active_account: Option<UsagePollingAccount>,
    pub now: f64,
    pub max_age_seconds: f64,
    pub force: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsagePollingPlanResult {
    pub should_refresh: bool,
    #[serde(default)]
    pub account_id: Option<String>,
    #[serde(default)]
    pub skip_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageModeTransitionProviderInput {
    pub provider_id: String,
    #[serde(default)]
    pub active_account_id: Option<String>,
    #[serde(default)]
    pub account_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageModeTransitionRequest {
    pub current_mode: String,
    pub target_mode: String,
    #[serde(default)]
    pub active_provider_id: Option<String>,
    #[serde(default)]
    pub active_account_id: Option<String>,
    #[serde(default)]
    pub switch_mode_selection_provider_id: Option<String>,
    #[serde(default)]
    pub switch_mode_selection_account_id: Option<String>,
    #[serde(default)]
    pub oauth_provider_id: Option<String>,
    #[serde(default)]
    pub oauth_active_account_id: Option<String>,
    #[serde(default)]
    pub providers: Vec<UsageModeTransitionProviderInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageModeTransitionResult {
    pub next_mode: String,
    #[serde(default)]
    pub next_active_provider_id: Option<String>,
    #[serde(default)]
    pub next_active_account_id: Option<String>,
    #[serde(default)]
    pub next_switch_mode_selection_provider_id: Option<String>,
    #[serde(default)]
    pub next_switch_mode_selection_account_id: Option<String>,
    pub should_sync_codex: bool,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ActiveSelectionCandidateInput {
    #[serde(default)]
    pub provider_id: Option<String>,
    #[serde(default)]
    pub account_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRemovalTransitionRequest {
    #[serde(default)]
    pub current_active_provider_id: Option<String>,
    #[serde(default)]
    pub current_active_account_id: Option<String>,
    pub removed_provider_id: String,
    #[serde(default)]
    pub removed_account_id: Option<String>,
    pub provider_still_exists: bool,
    #[serde(default)]
    pub next_provider_active_account_id: Option<String>,
    #[serde(default)]
    pub fallback_candidates: Vec<ActiveSelectionCandidateInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderRemovalTransitionResult {
    #[serde(default)]
    pub next_active_provider_id: Option<String>,
    #[serde(default)]
    pub next_active_account_id: Option<String>,
    pub should_sync_codex: bool,
    pub rust_owner: String,
}

pub fn plan_usage_polling(request: UsagePollingPlanRequest) -> UsagePollingPlanResult {
    let Some(account) = request.active_account else {
        return UsagePollingPlanResult {
            should_refresh: false,
            account_id: None,
            skip_reason: Some("missingActiveAccount".to_string()),
        };
    };

    if request.active_provider_kind.as_deref() != Some("openai_oauth") {
        return UsagePollingPlanResult {
            should_refresh: false,
            account_id: Some(account.account_id),
            skip_reason: Some("inactiveProvider".to_string()),
        };
    }
    if account.is_suspended {
        return UsagePollingPlanResult {
            should_refresh: false,
            account_id: Some(account.account_id),
            skip_reason: Some("suspended".to_string()),
        };
    }
    if account.token_expired {
        return UsagePollingPlanResult {
            should_refresh: false,
            account_id: Some(account.account_id),
            skip_reason: Some("tokenExpired".to_string()),
        };
    }
    if request.force {
        return UsagePollingPlanResult {
            should_refresh: true,
            account_id: Some(account.account_id),
            skip_reason: None,
        };
    }

    let stale = account
        .last_checked_at
        .map(|last_checked_at| (request.now - last_checked_at).max(0.0) >= request.max_age_seconds)
        .unwrap_or(true);

    UsagePollingPlanResult {
        should_refresh: stale,
        account_id: Some(account.account_id),
        skip_reason: if stale {
            None
        } else {
            Some("freshUsageSnapshot".to_string())
        },
    }
}

pub fn resolve_usage_mode_transition(
    request: UsageModeTransitionRequest,
) -> UsageModeTransitionResult {
    let current_mode = normalize_usage_mode(&request.current_mode);
    let target_mode = normalize_usage_mode(&request.target_mode);
    let oauth_provider_id = normalize_nonempty(request.oauth_provider_id);
    let oauth_active_account_id = normalize_nonempty(request.oauth_active_account_id);
    let mut next_active_provider_id = normalize_nonempty(request.active_provider_id);
    let mut next_active_account_id = normalize_nonempty(request.active_account_id);
    let mut next_switch_mode_selection_provider_id =
        normalize_nonempty(request.switch_mode_selection_provider_id);
    let mut next_switch_mode_selection_account_id =
        normalize_nonempty(request.switch_mode_selection_account_id);

    if target_mode == "aggregate_gateway" {
        next_switch_mode_selection_provider_id = next_active_provider_id.clone();
        next_switch_mode_selection_account_id = next_active_account_id.clone();
        next_active_provider_id = oauth_provider_id.clone();
        next_active_account_id = oauth_active_account_id.clone();
    } else if target_mode == "switch" && current_mode != "switch" {
        let valid_switch_selection = next_switch_mode_selection_provider_id
            .as_ref()
            .zip(next_switch_mode_selection_account_id.as_ref())
            .and_then(|(provider_id, account_id)| {
                request
                    .providers
                    .iter()
                    .find(|provider| provider.provider_id == *provider_id)
                    .and_then(|provider| {
                        provider
                            .account_ids
                            .iter()
                            .any(|candidate| candidate == account_id)
                            .then_some((provider_id.clone(), account_id.clone()))
                    })
            });
        if let Some((provider_id, account_id)) = valid_switch_selection {
            next_active_provider_id = Some(provider_id);
            next_active_account_id = Some(account_id);
        }
    }

    let should_sync_codex =
        target_mode == "aggregate_gateway" || next_active_provider_id == oauth_provider_id;

    UsageModeTransitionResult {
        next_mode: target_mode,
        next_active_provider_id,
        next_active_account_id,
        next_switch_mode_selection_provider_id,
        next_switch_mode_selection_account_id,
        should_sync_codex,
        rust_owner: "core_runtime.resolve_usage_mode_transition".to_string(),
    }
}

pub fn resolve_provider_removal_transition(
    request: ProviderRemovalTransitionRequest,
) -> ProviderRemovalTransitionResult {
    let current_active_provider_id = normalize_nonempty(request.current_active_provider_id);
    let current_active_account_id = normalize_nonempty(request.current_active_account_id);
    let removed_provider_id =
        normalize_nonempty(Some(request.removed_provider_id)).unwrap_or_default();
    let removed_account_id = normalize_nonempty(request.removed_account_id);

    let mut next_active_provider_id = current_active_provider_id.clone();
    let mut next_active_account_id = current_active_account_id.clone();
    let mut should_sync_codex = false;

    if current_active_provider_id.as_deref() == Some(removed_provider_id.as_str()) {
        if request.provider_still_exists {
            if removed_account_id.is_none()
                || current_active_account_id.as_deref() == removed_account_id.as_deref()
            {
                next_active_provider_id = Some(removed_provider_id);
                next_active_account_id =
                    normalize_nonempty(request.next_provider_active_account_id);
                should_sync_codex = true;
            }
        } else {
            let fallback = request
                .fallback_candidates
                .into_iter()
                .find_map(|candidate| {
                    let provider_id = normalize_nonempty(candidate.provider_id)?;
                    let account_id = normalize_nonempty(candidate.account_id)?;
                    Some((provider_id, account_id))
                });
            if let Some((provider_id, account_id)) = fallback {
                next_active_provider_id = Some(provider_id);
                next_active_account_id = Some(account_id);
                should_sync_codex = true;
            } else {
                next_active_provider_id = None;
                next_active_account_id = None;
            }
        }
    }

    ProviderRemovalTransitionResult {
        next_active_provider_id,
        next_active_account_id,
        should_sync_codex,
        rust_owner: "core_runtime.resolve_provider_removal_transition".to_string(),
    }
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

fn normalize_usage_mode(value: &str) -> String {
    match value.trim() {
        "aggregate_gateway" | "aggregateGateway" => "aggregate_gateway".to_string(),
        _ => "switch".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn provider(
        provider_id: &str,
        active_account_id: Option<&str>,
        account_ids: &[&str],
    ) -> UsageModeTransitionProviderInput {
        UsageModeTransitionProviderInput {
            provider_id: provider_id.to_string(),
            active_account_id: active_account_id.map(str::to_string),
            account_ids: account_ids.iter().map(|value| value.to_string()).collect(),
        }
    }

    #[test]
    fn usage_polling_plan_skips_missing_active_account() {
        let result = plan_usage_polling(UsagePollingPlanRequest {
            active_provider_kind: Some("openai_oauth".to_string()),
            active_account: None,
            now: 10.0,
            max_age_seconds: 5.0,
            force: false,
        });

        assert!(!result.should_refresh);
        assert_eq!(result.skip_reason.as_deref(), Some("missingActiveAccount"));
    }

    #[test]
    fn usage_mode_transition_captures_switch_selection_and_promotes_oauth_account() {
        let result = resolve_usage_mode_transition(UsageModeTransitionRequest {
            current_mode: "switch".to_string(),
            target_mode: "aggregate_gateway".to_string(),
            active_provider_id: Some("compatible-provider".to_string()),
            active_account_id: Some("acct-compatible".to_string()),
            switch_mode_selection_provider_id: None,
            switch_mode_selection_account_id: None,
            oauth_provider_id: Some("openai-oauth".to_string()),
            oauth_active_account_id: Some("acct-oauth".to_string()),
            providers: vec![
                provider("openai-oauth", Some("acct-oauth"), &["acct-oauth"]),
                provider(
                    "compatible-provider",
                    Some("acct-compatible"),
                    &["acct-compatible"],
                ),
            ],
        });

        assert_eq!(result.next_mode, "aggregate_gateway");
        assert_eq!(
            result.next_switch_mode_selection_provider_id.as_deref(),
            Some("compatible-provider")
        );
        assert_eq!(
            result.next_switch_mode_selection_account_id.as_deref(),
            Some("acct-compatible")
        );
        assert_eq!(
            result.next_active_provider_id.as_deref(),
            Some("openai-oauth")
        );
        assert_eq!(result.next_active_account_id.as_deref(), Some("acct-oauth"));
        assert!(result.should_sync_codex);
    }

    #[test]
    fn usage_mode_transition_restores_valid_switch_selection() {
        let result = resolve_usage_mode_transition(UsageModeTransitionRequest {
            current_mode: "aggregate_gateway".to_string(),
            target_mode: "switch".to_string(),
            active_provider_id: Some("openai-oauth".to_string()),
            active_account_id: Some("acct-oauth".to_string()),
            switch_mode_selection_provider_id: Some("compatible-provider".to_string()),
            switch_mode_selection_account_id: Some("acct-compatible".to_string()),
            oauth_provider_id: Some("openai-oauth".to_string()),
            oauth_active_account_id: Some("acct-oauth".to_string()),
            providers: vec![
                provider("openai-oauth", Some("acct-oauth"), &["acct-oauth"]),
                provider(
                    "compatible-provider",
                    Some("acct-compatible"),
                    &["acct-compatible"],
                ),
            ],
        });

        assert_eq!(result.next_mode, "switch");
        assert_eq!(
            result.next_active_provider_id.as_deref(),
            Some("compatible-provider")
        );
        assert_eq!(
            result.next_active_account_id.as_deref(),
            Some("acct-compatible")
        );
        assert!(!result.should_sync_codex);
    }

    #[test]
    fn usage_mode_transition_keeps_oauth_selection_when_switch_target_is_invalid() {
        let result = resolve_usage_mode_transition(UsageModeTransitionRequest {
            current_mode: "aggregate_gateway".to_string(),
            target_mode: "switch".to_string(),
            active_provider_id: Some("openai-oauth".to_string()),
            active_account_id: Some("acct-oauth".to_string()),
            switch_mode_selection_provider_id: Some("compatible-provider".to_string()),
            switch_mode_selection_account_id: Some("missing-account".to_string()),
            oauth_provider_id: Some("openai-oauth".to_string()),
            oauth_active_account_id: Some("acct-oauth".to_string()),
            providers: vec![
                provider("openai-oauth", Some("acct-oauth"), &["acct-oauth"]),
                provider(
                    "compatible-provider",
                    Some("acct-compatible"),
                    &["acct-compatible"],
                ),
            ],
        });

        assert_eq!(
            result.next_active_provider_id.as_deref(),
            Some("openai-oauth")
        );
        assert_eq!(result.next_active_account_id.as_deref(), Some("acct-oauth"));
        assert!(result.should_sync_codex);
    }

    #[test]
    fn provider_removal_transition_falls_back_to_first_candidate_when_provider_is_removed() {
        let result = resolve_provider_removal_transition(ProviderRemovalTransitionRequest {
            current_active_provider_id: Some("compatible-provider".to_string()),
            current_active_account_id: Some("acct-compatible".to_string()),
            removed_provider_id: "compatible-provider".to_string(),
            removed_account_id: None,
            provider_still_exists: false,
            next_provider_active_account_id: None,
            fallback_candidates: vec![
                ActiveSelectionCandidateInput {
                    provider_id: Some("openai-oauth".to_string()),
                    account_id: Some("acct-oauth".to_string()),
                },
                ActiveSelectionCandidateInput {
                    provider_id: Some("openrouter".to_string()),
                    account_id: Some("acct-openrouter".to_string()),
                },
            ],
        });

        assert_eq!(
            result.next_active_provider_id.as_deref(),
            Some("openai-oauth")
        );
        assert_eq!(result.next_active_account_id.as_deref(), Some("acct-oauth"));
        assert!(result.should_sync_codex);
    }

    #[test]
    fn provider_removal_transition_keeps_provider_and_selects_next_account_when_active_account_is_removed()
     {
        let result = resolve_provider_removal_transition(ProviderRemovalTransitionRequest {
            current_active_provider_id: Some("compatible-provider".to_string()),
            current_active_account_id: Some("acct-old".to_string()),
            removed_provider_id: "compatible-provider".to_string(),
            removed_account_id: Some("acct-old".to_string()),
            provider_still_exists: true,
            next_provider_active_account_id: Some("acct-new".to_string()),
            fallback_candidates: vec![],
        });

        assert_eq!(
            result.next_active_provider_id.as_deref(),
            Some("compatible-provider")
        );
        assert_eq!(result.next_active_account_id.as_deref(), Some("acct-new"));
        assert!(result.should_sync_codex);
    }
}
