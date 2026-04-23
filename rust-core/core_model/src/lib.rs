use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FfiRequest {
    pub operation: String,
    pub payload: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FfiError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FfiResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<FfiError>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RawConfigInput {
    pub version: Option<u32>,
    #[serde(default)]
    pub global: RawGlobalSettings,
    #[serde(default)]
    pub active: RawActiveSelection,
    #[serde(default)]
    pub desktop_preferred_codex_app_path: Option<String>,
    #[serde(default)]
    pub model_pricing: BTreeMap<String, RawModelPricing>,
    #[serde(default)]
    pub openai: RawOpenAISettings,
    #[serde(default)]
    pub providers: Vec<RawProviderInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RawGlobalSettings {
    #[serde(default)]
    pub default_model: Option<String>,
    #[serde(default)]
    pub review_model: Option<String>,
    #[serde(default)]
    pub reasoning_effort: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RawActiveSelection {
    #[serde(default)]
    pub provider_id: Option<String>,
    #[serde(default)]
    pub account_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RawModelPricing {
    pub input_usd_per_token: f64,
    pub cached_input_usd_per_token: f64,
    pub output_usd_per_token: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RawOpenAISettings {
    #[serde(default)]
    pub account_order: Vec<String>,
    #[serde(default)]
    pub account_usage_mode: Option<String>,
    #[serde(default)]
    pub switch_mode_selection: Option<RawActiveSelection>,
    #[serde(default)]
    pub account_ordering_mode: Option<String>,
    #[serde(default)]
    pub manual_activation_behavior: Option<String>,
    #[serde(default)]
    pub usage_display_mode: Option<String>,
    #[serde(default)]
    pub quota_sort: RawQuotaSortSettings,
    #[serde(default)]
    pub interop_proxies_json: Option<String>,
    #[serde(default)]
    pub extensions: BTreeMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RawQuotaSortSettings {
    pub plus_relative_weight: f64,
    pub pro_relative_to_plus_multiplier: f64,
    pub team_relative_to_plus_multiplier: f64,
}

impl Default for RawQuotaSortSettings {
    fn default() -> Self {
        Self {
            plus_relative_weight: 10.0,
            pro_relative_to_plus_multiplier: 10.0,
            team_relative_to_plus_multiplier: 1.5,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RawProviderInput {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default = "default_true")]
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
    pub active_account_id: Option<String>,
    #[serde(default)]
    pub accounts: Vec<RawProviderAccountInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RawProviderAccountInput {
    #[serde(default)]
    pub id: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub label: Option<String>,
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
    pub api_key: Option<String>,
    #[serde(default)]
    pub plan_type: Option<String>,
    #[serde(default)]
    pub primary_used_percent: Option<f64>,
    #[serde(default)]
    pub secondary_used_percent: Option<f64>,
    #[serde(default)]
    pub primary_reset_at: Option<f64>,
    #[serde(default)]
    pub secondary_reset_at: Option<f64>,
    #[serde(default)]
    pub primary_limit_window_seconds: Option<i64>,
    #[serde(default)]
    pub secondary_limit_window_seconds: Option<i64>,
    #[serde(default)]
    pub last_checked: Option<f64>,
    #[serde(default)]
    pub is_suspended: Option<bool>,
    #[serde(default)]
    pub token_expired: Option<bool>,
    #[serde(default)]
    pub organization_name: Option<String>,
    #[serde(default)]
    pub interop_proxy_key: Option<String>,
    #[serde(default)]
    pub interop_notes: Option<String>,
    #[serde(default)]
    pub interop_concurrency: Option<i64>,
    #[serde(default)]
    pub interop_priority: Option<i64>,
    #[serde(default)]
    pub interop_rate_multiplier: Option<f64>,
    #[serde(default)]
    pub interop_auto_pause_on_expired: Option<bool>,
    #[serde(default)]
    pub interop_credentials_json: Option<String>,
    #[serde(default)]
    pub interop_extra_json: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalConfigSnapshot {
    pub version: u32,
    pub global: CanonicalGlobalSettings,
    pub active: CanonicalActiveSelection,
    #[serde(default)]
    pub model_pricing: BTreeMap<String, CanonicalModelPricing>,
    pub openai: CanonicalOpenAISettings,
    #[serde(default)]
    pub providers: Vec<CanonicalProviderSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalGlobalSettings {
    pub default_model: String,
    pub review_model: String,
    pub reasoning_effort: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalActiveSelection {
    #[serde(default)]
    pub provider_id: Option<String>,
    #[serde(default)]
    pub account_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalModelPricing {
    pub input_usd_per_token: f64,
    pub cached_input_usd_per_token: f64,
    pub output_usd_per_token: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalOpenAISettings {
    #[serde(default)]
    pub account_order: Vec<String>,
    pub account_usage_mode: String,
    #[serde(default)]
    pub switch_mode_selection: Option<CanonicalActiveSelection>,
    pub account_ordering_mode: String,
    pub manual_activation_behavior: String,
    pub usage_display_mode: String,
    pub quota_sort: CanonicalQuotaSortSettings,
    #[serde(default)]
    pub interop_proxies_json: Option<String>,
    #[serde(default)]
    pub extensions: BTreeMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalQuotaSortSettings {
    pub plus_relative_weight: f64,
    pub pro_relative_to_plus_multiplier: f64,
    pub team_relative_to_plus_multiplier: f64,
    pub pro_absolute_weight: f64,
    pub team_absolute_weight: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalProviderSnapshot {
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
    pub active_account_id: Option<String>,
    #[serde(default)]
    pub accounts: Vec<CanonicalProviderAccountSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalProviderAccountSnapshot {
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
    pub api_key: Option<String>,
    #[serde(default)]
    pub plan_type: Option<String>,
    #[serde(default)]
    pub primary_used_percent: Option<f64>,
    #[serde(default)]
    pub secondary_used_percent: Option<f64>,
    #[serde(default)]
    pub primary_reset_at: Option<f64>,
    #[serde(default)]
    pub secondary_reset_at: Option<f64>,
    #[serde(default)]
    pub primary_limit_window_seconds: Option<i64>,
    #[serde(default)]
    pub secondary_limit_window_seconds: Option<i64>,
    #[serde(default)]
    pub last_checked: Option<f64>,
    #[serde(default)]
    pub is_suspended: Option<bool>,
    #[serde(default)]
    pub token_expired: Option<bool>,
    #[serde(default)]
    pub organization_name: Option<String>,
    #[serde(default)]
    pub interop_proxy_key: Option<String>,
    #[serde(default)]
    pub interop_notes: Option<String>,
    #[serde(default)]
    pub interop_concurrency: Option<i64>,
    #[serde(default)]
    pub interop_priority: Option<i64>,
    #[serde(default)]
    pub interop_rate_multiplier: Option<f64>,
    #[serde(default)]
    pub interop_auto_pause_on_expired: Option<bool>,
    #[serde(default)]
    pub interop_credentials_json: Option<String>,
    #[serde(default)]
    pub interop_extra_json: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalAccountSnapshot {
    pub local_account_id: String,
    pub remote_account_id: String,
    pub email: String,
    pub access_token: String,
    pub refresh_token: String,
    pub id_token: String,
    #[serde(default)]
    pub expires_at: Option<f64>,
    #[serde(default)]
    pub oauth_client_id: Option<String>,
    pub plan_type: String,
    pub primary_used_percent: f64,
    pub secondary_used_percent: f64,
    #[serde(default)]
    pub primary_reset_at: Option<f64>,
    #[serde(default)]
    pub secondary_reset_at: Option<f64>,
    #[serde(default)]
    pub primary_limit_window_seconds: Option<i64>,
    #[serde(default)]
    pub secondary_limit_window_seconds: Option<i64>,
    #[serde(default)]
    pub last_checked: Option<f64>,
    pub is_active: bool,
    pub is_suspended: bool,
    pub token_expired: bool,
    #[serde(default)]
    pub token_last_refresh_at: Option<f64>,
    #[serde(default)]
    pub organization_name: Option<String>,
    pub quota_exhausted: bool,
    pub is_available_for_next_use_routing: bool,
    pub is_degraded_for_next_use_routing: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CanonicalizationResult {
    pub config: CanonicalConfigSnapshot,
    #[serde(default)]
    pub accounts: Vec<CanonicalAccountSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RouteRuntimeInput {
    pub configured_mode: String,
    pub effective_mode: String,
    #[serde(default)]
    pub aggregate_routed_account_id: Option<String>,
    #[serde(default)]
    pub sticky_bindings: Vec<StickyBindingInput>,
    #[serde(default)]
    pub route_journal: Vec<RouteJournalEntry>,
    #[serde(default)]
    pub lease_state: LeaseStateInput,
    #[serde(default)]
    pub running_thread_attribution: RunningThreadAttributionInput,
    #[serde(default)]
    pub live_session_attribution: LiveSessionAttributionInput,
    #[serde(default)]
    pub runtime_block_state: RuntimeBlockStateInput,
    pub now: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StickyBindingInput {
    pub thread_id: String,
    pub account_id: String,
    pub updated_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RouteJournalEntry {
    pub thread_id: String,
    pub account_id: String,
    pub timestamp: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct LeaseStateInput {
    #[serde(default)]
    pub leased_process_ids: Vec<i64>,
    pub has_active_lease: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RunningThreadAttributionInput {
    #[serde(default)]
    pub active_thread_ids: Vec<String>,
    pub recent_activity_window_seconds: f64,
    pub summary_is_unavailable: bool,
    #[serde(default)]
    pub in_use_account_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct LiveSessionAttributionInput {
    pub summary_is_unavailable: bool,
    #[serde(default)]
    pub active_session_ids: Vec<String>,
    #[serde(default)]
    pub attributed_account_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeBlockStateInput {
    #[serde(default)]
    pub blocked_account_ids: Vec<String>,
    #[serde(default)]
    pub retry_at: Option<f64>,
    #[serde(default)]
    pub reset_at: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RouteRuntimeSnapshotDto {
    pub configured_mode: String,
    pub effective_mode: String,
    pub aggregate_runtime_active: bool,
    #[serde(default)]
    pub latest_routed_account_id: Option<String>,
    pub latest_routed_account_is_summary: bool,
    pub sticky_affects_future_routing: bool,
    pub lease_active: bool,
    pub stale_sticky_eligible: bool,
    #[serde(default)]
    pub stale_sticky_thread_id: Option<String>,
    #[serde(default)]
    pub latest_route_at: Option<f64>,
    pub runtime_block_summary: RuntimeBlockSummary,
    pub running_thread_summary: RunningThreadSummary,
    pub live_session_summary: LiveSessionSummary,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeBlockSummary {
    pub has_blocker: bool,
    #[serde(default)]
    pub blocked_account_ids: Vec<String>,
    #[serde(default)]
    pub retry_at: Option<f64>,
    #[serde(default)]
    pub reset_at: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RunningThreadSummary {
    pub summary_is_unavailable: bool,
    #[serde(default)]
    pub active_thread_ids: Vec<String>,
    #[serde(default)]
    pub in_use_account_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct LiveSessionSummary {
    pub summary_is_unavailable: bool,
    #[serde(default)]
    pub active_session_ids: Vec<String>,
    #[serde(default)]
    pub attributed_account_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RenderCodecRequest {
    pub config: CanonicalConfigSnapshot,
    pub active_provider_id: String,
    pub active_account_id: String,
    #[serde(default)]
    pub existing_toml_text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CodecMessage {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RenderCodecOutput {
    pub auth_json: String,
    pub config_toml: String,
    #[serde(default)]
    pub codec_warnings: Vec<CodecMessage>,
    #[serde(default)]
    pub migration_notes: Vec<CodecMessage>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RefreshRetryState {
    pub attempts: u32,
    pub retry_after: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RefreshPlanRequest {
    pub account: CanonicalAccountSnapshot,
    pub force: bool,
    pub now: f64,
    pub refresh_window_seconds: f64,
    #[serde(default)]
    pub existing_retry_state: Option<RefreshRetryState>,
    pub in_flight: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RefreshPlanResult {
    pub should_refresh: bool,
    #[serde(default)]
    pub skip_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RefreshOutcomeRequest {
    pub account: CanonicalAccountSnapshot,
    pub now: f64,
    pub max_retry_count: u32,
    #[serde(default)]
    pub existing_retry_state: Option<RefreshRetryState>,
    pub outcome: String,
    #[serde(default)]
    pub refreshed_account: Option<CanonicalAccountSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RefreshOutcomeResult {
    pub account: CanonicalAccountSnapshot,
    #[serde(default)]
    pub next_retry_state: Option<RefreshRetryState>,
    pub disposition: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageMergeSuccessRequest {
    pub account: CanonicalAccountSnapshot,
    pub plan_type: String,
    pub primary_used_percent: f64,
    pub secondary_used_percent: f64,
    #[serde(default)]
    pub primary_reset_at: Option<f64>,
    #[serde(default)]
    pub secondary_reset_at: Option<f64>,
    #[serde(default)]
    pub primary_limit_window_seconds: Option<i64>,
    #[serde(default)]
    pub secondary_limit_window_seconds: Option<i64>,
    #[serde(default)]
    pub organization_name: Option<String>,
    pub checked_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageMergeResult {
    pub account: CanonicalAccountSnapshot,
    pub disposition: String,
}

pub fn default_true() -> bool {
    true
}
