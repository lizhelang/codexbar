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
const OAUTH_LEGACY_CSV_HEADERS: [&str; 7] = [
    "format_version",
    "email",
    "account_id",
    "access_token",
    "refresh_token",
    "id_token",
    "is_active",
];

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
    pub api_key: Option<String>,
    #[serde(default)]
    pub added_at: Option<f64>,
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
    #[serde(default)]
    pub plan_type: Option<String>,
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
pub struct AuthJsonSnapshotParseRequest {
    pub text: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AuthJsonSnapshotParseResult {
    #[serde(default)]
    pub snapshot: Option<AuthJsonSnapshotInput>,
    #[serde(default)]
    pub openai_api_key: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthTokenResponseParseRequest {
    pub body_text: String,
    #[serde(default)]
    pub fallback_refresh_token: Option<String>,
    #[serde(default)]
    pub fallback_id_token: Option<String>,
    #[serde(default)]
    pub fallback_client_id: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthTokenResponseParseResult {
    pub access_token: String,
    pub refresh_token: String,
    pub id_token: String,
    #[serde(default)]
    pub oauth_client_id: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthAccountBuildRequest {
    pub access_token: String,
    pub refresh_token: String,
    pub id_token: String,
    #[serde(default)]
    pub oauth_client_id: Option<String>,
    #[serde(default)]
    pub token_last_refresh_at: Option<f64>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RefreshOAuthAccountFromTokensRequest {
    pub current_account: CanonicalAccountSnapshot,
    pub access_token: String,
    pub refresh_token: String,
    pub id_token: String,
    #[serde(default)]
    pub oauth_client_id: Option<String>,
    #[serde(default)]
    pub token_last_refresh_at: Option<f64>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthTokenMetadataRequest {
    pub access_token: String,
    #[serde(default)]
    pub id_token: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthTokenMetadataResult {
    #[serde(default)]
    pub profile_email: Option<String>,
    #[serde(default)]
    pub chatgpt_user_id: Option<String>,
    #[serde(default)]
    pub oauth_client_id: Option<String>,
    #[serde(default)]
    pub organization_id: Option<String>,
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

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SharedTeamOrganizationNormalizationRequest {
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SharedTeamOrganizationNormalizationResult {
    pub changed: bool,
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthMetadataRefreshRequest {
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthMetadataRefreshResult {
    pub changed: bool,
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthQuotaSnapshotSanitizationRequest {
    pub now: f64,
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthQuotaSnapshotSanitizationResult {
    pub changed: bool,
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthProviderAssemblyRequest {
    #[serde(default)]
    pub imported_accounts: Vec<OAuthStoredAccountInput>,
    #[serde(default)]
    pub snapshot: Option<AuthJsonSnapshotInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthProviderAssemblyResult {
    pub should_create: bool,
    #[serde(default)]
    pub active_account_id: Option<String>,
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ReservedProviderIdInput {
    pub id: String,
    pub kind: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ReservedProviderIdNormalizationRequest {
    #[serde(default)]
    pub active_provider_id: Option<String>,
    #[serde(default)]
    pub switch_provider_id: Option<String>,
    #[serde(default)]
    pub providers: Vec<ReservedProviderIdInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ReservedProviderIdNormalizationResult {
    pub changed: bool,
    #[serde(default)]
    pub active_provider_id: Option<String>,
    #[serde(default)]
    pub switch_provider_id: Option<String>,
    #[serde(default)]
    pub providers: Vec<ReservedProviderIdInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LegacyCodexTomlParseRequest {
    pub text: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LegacyCodexTomlParseResult {
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub review_model: Option<String>,
    #[serde(default)]
    pub reasoning_effort: Option<String>,
    #[serde(default)]
    pub openai_base_url: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSecretsEnvParseRequest {
    pub text: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderSecretsEnvParseResult {
    #[serde(default)]
    pub values: BTreeMap<String, String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct InteropProxyMergeRequest {
    #[serde(default)]
    pub existing_json: Option<String>,
    #[serde(default)]
    pub incoming_json: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct InteropProxyMergeResult {
    #[serde(default)]
    pub merged_json: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthInteropMetadataEntry {
    pub account_id: String,
    #[serde(default)]
    pub proxy_key: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub concurrency: Option<i64>,
    #[serde(default)]
    pub priority: Option<i64>,
    #[serde(default)]
    pub rate_multiplier: Option<f64>,
    #[serde(default)]
    pub auto_pause_on_expired: Option<bool>,
    #[serde(default)]
    pub credentials_json: Option<String>,
    #[serde(default)]
    pub extra_json: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthInteropContextApplyRequest {
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
    #[serde(default)]
    pub metadata_entries: Vec<OAuthInteropMetadataEntry>,
    #[serde(default)]
    pub existing_json: Option<String>,
    #[serde(default)]
    pub incoming_json: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthInteropContextApplyResult {
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
    #[serde(default)]
    pub merged_json: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthInteropExportAccountInput {
    pub account_id: String,
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
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthInteropExportRequest {
    #[serde(default)]
    pub accounts: Vec<OAuthInteropExportAccountInput>,
    #[serde(default)]
    pub metadata_entries: Vec<OAuthInteropMetadataEntry>,
    #[serde(default)]
    pub available_proxy_keys: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthInteropExportResult {
    pub accounts_payload: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthInteropBundleParseRequest {
    pub text: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthInteropImportedAccountInput {
    pub account_id: String,
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
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthInteropBundleParseResult {
    #[serde(default)]
    pub accounts: Vec<OAuthInteropImportedAccountInput>,
    #[serde(default)]
    pub active_account_id: Option<String>,
    pub row_count: usize,
    #[serde(default)]
    pub metadata_entries: Vec<OAuthInteropMetadataEntry>,
    #[serde(default)]
    pub proxies_json: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthLegacyCsvParseRequest {
    pub text: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthLegacyCsvParseResult {
    #[serde(default)]
    pub accounts: Vec<OAuthInteropImportedAccountInput>,
    #[serde(default)]
    pub active_account_id: Option<String>,
    pub row_count: usize,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WhamUsageParseRequest {
    pub body_json: serde_json::Value,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WhamUsageParseResult {
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
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CustomProviderIdResolutionRequest {
    pub label: String,
    pub fallback_provider_id: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CustomProviderIdResolutionResult {
    pub provider_id: String,
    pub rust_owner: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LegacyMigrationProviderAccountInput {
    pub id: String,
    #[serde(default)]
    pub openai_account_id: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LegacyMigrationProviderInput {
    pub id: String,
    pub kind: String,
    #[serde(default)]
    pub base_url: Option<String>,
    #[serde(default)]
    pub active_account_id: Option<String>,
    #[serde(default)]
    pub accounts: Vec<LegacyMigrationProviderAccountInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LegacyMigrationActiveSelectionRequest {
    #[serde(default)]
    pub openai_base_url: Option<String>,
    pub has_openai_api_key: bool,
    #[serde(default)]
    pub auth_snapshot_local_account_id: Option<String>,
    #[serde(default)]
    pub auth_snapshot_remote_account_id: Option<String>,
    #[serde(default)]
    pub providers: Vec<LegacyMigrationProviderInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LegacyMigrationActiveSelectionResult {
    #[serde(default)]
    pub provider_id: Option<String>,
    #[serde(default)]
    pub account_id: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LegacyImportedProviderPlanRequest {
    #[serde(default)]
    pub base_url: Option<String>,
    pub api_key: String,
    #[serde(default)]
    pub existing_base_urls: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LegacyImportedProviderPlanResult {
    pub should_create: bool,
    #[serde(default)]
    pub provider_id: Option<String>,
    #[serde(default)]
    pub label: Option<String>,
    #[serde(default)]
    pub normalized_base_url: Option<String>,
    #[serde(default)]
    pub account_label: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthIdentityNormalizationRequest {
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthIdentityNormalizationResult {
    pub changed: bool,
    #[serde(default)]
    pub migrated_account_ids: BTreeMap<String, String>,
    #[serde(default)]
    pub accounts: Vec<OAuthStoredAccountInput>,
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
    let latest_routed_account_id =
        normalize_nonempty(input.aggregate_routed_account_id).or_else(|| {
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
                    > input
                        .running_thread_attribution
                        .recent_activity_window_seconds
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
            attributed_account_ids: dedup_vec(
                input.live_session_attribution.attributed_account_ids,
            ),
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
    account.plan_type =
        normalize_nonempty(Some(request.plan_type)).unwrap_or_else(|| "free".to_string());
    account.primary_used_percent = sanitize_nonnegative(request.primary_used_percent);
    account.secondary_used_percent = sanitize_nonnegative(request.secondary_used_percent);
    account.primary_reset_at = request.primary_reset_at;
    account.secondary_reset_at = request.secondary_reset_at;
    account.primary_limit_window_seconds =
        sanitize_positive_optional(request.primary_limit_window_seconds);
    account.secondary_limit_window_seconds =
        sanitize_positive_optional(request.secondary_limit_window_seconds);
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
        .filter(|provider| {
            is_legacy_openrouter_provider(provider) || provider.kind == OPENROUTER_KIND
        })
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
    let mut changed = matching_providers
        .iter()
        .any(|provider| provider.kind != OPENROUTER_KIND);
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
                || provider_fetched_at
                    > merged_provider.model_catalog_fetched_at.unwrap_or(f64::MIN)
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
            let fallback_account_id = merged_provider
                .accounts
                .first()
                .map(|account| account.id.clone());
            if merged_provider.active_account_id != fallback_account_id {
                changed = true;
            }
            merged_provider.active_account_id = fallback_account_id;
        }
    } else {
        let fallback_account_id = merged_provider
            .accounts
            .first()
            .map(|account| account.id.clone());
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
        (
            Some(merged_provider.id.clone()),
            merged_provider.active_account_id.clone(),
        )
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
            .map(|account_id| {
                merged_provider
                    .accounts
                    .iter()
                    .any(|account| account.id == *account_id)
            })
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
        active_provider_id: if request.active_provider_id.as_deref()
            == Some(runtime_provider_id.as_str())
        {
            Some(persisted_provider.id.clone())
        } else {
            request.active_provider_id
        },
        switch_provider_id: if request.switch_provider_id.as_deref()
            == Some(runtime_provider_id.as_str())
        {
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

pub fn normalize_shared_team_organization_names(
    request: SharedTeamOrganizationNormalizationRequest,
) -> SharedTeamOrganizationNormalizationResult {
    let mut accounts = request.accounts;
    let grouped_indices = accounts
        .iter()
        .enumerate()
        .filter_map(|(index, account)| {
            if is_shared_openai_team_account(account) == false {
                return None;
            }
            normalized_shared_openai_account_id(account)
                .map(|shared_account_id| (shared_account_id, index))
        })
        .fold(
            BTreeMap::<String, Vec<usize>>::new(),
            |mut partial, (shared_account_id, index)| {
                partial.entry(shared_account_id).or_default().push(index);
                partial
            },
        );

    let mut changed = false;
    for indices in grouped_indices.values() {
        let shared_names = indices
            .iter()
            .filter_map(|index| {
                normalized_shared_organization_name(accounts[*index].organization_name.clone())
            })
            .collect::<BTreeSet<_>>();
        if shared_names.len() != 1 {
            continue;
        }
        let Some(shared_name) = shared_names.into_iter().next() else {
            continue;
        };

        for index in indices {
            let normalized_name =
                normalized_shared_organization_name(accounts[*index].organization_name.clone());
            if normalized_name.as_deref() == Some(shared_name.as_str()) {
                if accounts[*index].organization_name.as_deref() != Some(shared_name.as_str()) {
                    accounts[*index].organization_name = Some(shared_name.clone());
                    changed = true;
                }
                continue;
            }
            if normalized_name.is_none() {
                accounts[*index].organization_name = Some(shared_name.clone());
                changed = true;
            }
        }
    }

    SharedTeamOrganizationNormalizationResult { changed, accounts }
}

pub fn refresh_oauth_account_metadata(
    request: OAuthMetadataRefreshRequest,
) -> OAuthMetadataRefreshResult {
    let mut changed = false;
    let accounts = request
        .accounts
        .into_iter()
        .map(|account| {
            let refreshed = refreshed_oauth_account_metadata(account.clone());
            if refreshed != account {
                changed = true;
            }
            refreshed
        })
        .collect::<Vec<_>>();

    OAuthMetadataRefreshResult { changed, accounts }
}

pub fn normalize_reserved_provider_ids(
    request: ReservedProviderIdNormalizationRequest,
) -> ReservedProviderIdNormalizationResult {
    let mut providers = request.providers;
    let mut active_provider_id = request.active_provider_id;
    let mut switch_provider_id = request.switch_provider_id;
    let mut changed = false;

    for index in 0..providers.len() {
        let provider = providers[index].clone();
        if provider.id != "openrouter" || provider.kind == OPENROUTER_KIND {
            continue;
        }

        let replacement_id =
            next_available_provider_id("openrouter-custom", provider.id.as_str(), &providers);
        providers[index].id = replacement_id.clone();
        if active_provider_id.as_deref() == Some(provider.id.as_str()) {
            active_provider_id = Some(replacement_id.clone());
        }
        if switch_provider_id.as_deref() == Some(provider.id.as_str()) {
            switch_provider_id = Some(replacement_id);
        }
        changed = true;
    }

    ReservedProviderIdNormalizationResult {
        changed,
        active_provider_id,
        switch_provider_id,
        providers,
    }
}

pub fn parse_legacy_codex_toml(request: LegacyCodexTomlParseRequest) -> LegacyCodexTomlParseResult {
    LegacyCodexTomlParseResult {
        model: parse_toml_string_value(&request.text, "model"),
        review_model: parse_toml_string_value(&request.text, "review_model"),
        reasoning_effort: parse_toml_string_value(&request.text, "model_reasoning_effort"),
        openai_base_url: parse_legacy_openai_base_url(&request.text),
    }
}

pub fn parse_auth_json_snapshot(
    request: AuthJsonSnapshotParseRequest,
) -> AuthJsonSnapshotParseResult {
    AuthJsonSnapshotParseResult {
        snapshot: parsed_auth_json_snapshot(&request.text),
        openai_api_key: parsed_openai_api_key(&request.text),
    }
}

pub fn parse_oauth_token_response(
    request: OAuthTokenResponseParseRequest,
) -> Result<OAuthTokenResponseParseResult, String> {
    let payload = serde_json::from_str::<serde_json::Value>(&request.body_text)
        .map_err(|_| "noToken".to_string())?;
    let object = payload
        .as_object()
        .ok_or_else(|| "noToken".to_string())?;

    if let Some(error_code) = object.get("error").and_then(|value| value.as_str()) {
        let description = object
            .get("error_description")
            .and_then(|value| value.as_str())
            .unwrap_or("");
        return Err(format!("serverError: {}: {}", error_code, description));
    }

    let access_token = object
        .get("access_token")
        .and_then(|value| value.as_str())
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
        .ok_or_else(|| "noToken".to_string())?;
    let refresh_token = object
        .get("refresh_token")
        .and_then(|value| value.as_str())
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
        .or_else(|| normalize_nonempty(request.fallback_refresh_token))
        .ok_or_else(|| "noToken".to_string())?;
    let id_token = object
        .get("id_token")
        .and_then(|value| value.as_str())
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
        .or_else(|| normalize_nonempty(request.fallback_id_token))
        .ok_or_else(|| "noToken".to_string())?;
    let oauth_client_id = object
        .get("client_id")
        .and_then(|value| value.as_str())
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
        .or_else(|| normalize_nonempty(request.fallback_client_id));

    Ok(OAuthTokenResponseParseResult {
        access_token,
        refresh_token,
        id_token,
        oauth_client_id,
    })
}

pub fn build_oauth_account_from_tokens(
    request: OAuthAccountBuildRequest,
) -> CanonicalAccountSnapshot {
    let access_claims = decode_jwt_claims(&request.access_token);
    let auth_claims = access_claims
        .get("https://api.openai.com/auth")
        .and_then(|value| value.as_object())
        .cloned()
        .unwrap_or_default();
    let id_claims = decode_jwt_claims(&request.id_token);

    let local_account_id = auth_claims
        .get("chatgpt_account_user_id")
        .and_then(|value| value.as_str())
        .map(|value| value.to_string())
        .filter(|value| value.is_empty() == false)
        .or_else(|| {
            auth_claims
                .get("chatgpt_account_id")
                .and_then(|value| value.as_str())
                .map(|value| value.to_string())
                .filter(|value| value.is_empty() == false)
        })
        .unwrap_or_default();
    let remote_account_id = auth_claims
        .get("chatgpt_account_id")
        .and_then(|value| value.as_str())
        .map(|value| value.to_string())
        .filter(|value| value.is_empty() == false)
        .unwrap_or_else(|| local_account_id.clone());
    let plan_type = auth_claims
        .get("chatgpt_plan_type")
        .and_then(|value| value.as_str())
        .map(|value| value.to_string())
        .filter(|value| value.is_empty() == false)
        .unwrap_or_else(|| "free".to_string());
    let email = id_claims
        .get("email")
        .and_then(|value| value.as_str())
        .map(|value| value.to_string())
        .unwrap_or_default();

    let id_auth_claims = id_claims
        .get("https://api.openai.com/auth")
        .and_then(|value| value.as_object());
    let expires_at = access_claims
        .get("exp")
        .and_then(|value| value.as_f64())
        .or_else(|| id_claims.get("exp").and_then(|value| value.as_f64()))
        .or_else(|| {
            id_auth_claims
                .and_then(|claims| {
                    claims
                        .get("chatgpt_subscription_active_until")
                        .and_then(|value| value.as_str())
                })
                .and_then(parse_iso8601_to_unix_seconds)
        });
    let oauth_client_id = normalize_nonempty(request.oauth_client_id).or_else(|| {
        access_claims
            .get("client_id")
            .and_then(|value| value.as_str())
            .and_then(|value| normalize_nonempty(Some(value.to_string())))
    });

    CanonicalAccountSnapshot {
        local_account_id,
        remote_account_id,
        email,
        access_token: request.access_token,
        refresh_token: request.refresh_token,
        id_token: request.id_token,
        expires_at,
        oauth_client_id,
        plan_type,
        primary_used_percent: 0.0,
        secondary_used_percent: 0.0,
        primary_reset_at: None,
        secondary_reset_at: None,
        primary_limit_window_seconds: None,
        secondary_limit_window_seconds: None,
        last_checked: None,
        is_active: false,
        is_suspended: false,
        token_expired: false,
        token_last_refresh_at: request.token_last_refresh_at,
        organization_name: None,
        quota_exhausted: false,
        is_available_for_next_use_routing: true,
        is_degraded_for_next_use_routing: false,
    }
}

pub fn refresh_oauth_account_from_tokens(
    request: RefreshOAuthAccountFromTokensRequest,
) -> CanonicalAccountSnapshot {
    let built = build_oauth_account_from_tokens(OAuthAccountBuildRequest {
        access_token: request.access_token,
        refresh_token: request.refresh_token,
        id_token: request.id_token,
        oauth_client_id: request.oauth_client_id,
        token_last_refresh_at: request.token_last_refresh_at,
    });

    let current = request.current_account;
    let mut refreshed = built;
    refreshed.local_account_id = current.local_account_id;
    refreshed.remote_account_id = current.remote_account_id;
    if refreshed.email.is_empty() {
        refreshed.email = current.email;
    }
    if refreshed.plan_type == "free" && current.plan_type.is_empty() == false {
        refreshed.plan_type = current.plan_type;
    }
    refreshed.primary_used_percent = current.primary_used_percent;
    refreshed.secondary_used_percent = current.secondary_used_percent;
    refreshed.primary_reset_at = current.primary_reset_at;
    refreshed.secondary_reset_at = current.secondary_reset_at;
    refreshed.primary_limit_window_seconds = current.primary_limit_window_seconds;
    refreshed.secondary_limit_window_seconds = current.secondary_limit_window_seconds;
    refreshed.last_checked = current.last_checked;
    refreshed.is_active = current.is_active;
    refreshed.is_suspended = false;
    refreshed.token_expired = false;
    refreshed.organization_name = current.organization_name;

    finalize_account(refreshed)
}

pub fn inspect_oauth_token_metadata(
    request: OAuthTokenMetadataRequest,
) -> OAuthTokenMetadataResult {
    let access_claims = decode_jwt_claims(&request.access_token);
    let auth_claims = access_claims
        .get("https://api.openai.com/auth")
        .and_then(|value| value.as_object());
    let profile_claims = access_claims
        .get("https://api.openai.com/profile")
        .and_then(|value| value.as_object());
    let id_claims = request
        .id_token
        .as_deref()
        .map(decode_jwt_claims)
        .unwrap_or_default();
    let id_auth_claims = id_claims
        .get("https://api.openai.com/auth")
        .and_then(|value| value.as_object());

    OAuthTokenMetadataResult {
        profile_email: profile_claims
            .and_then(|value| value.get("email"))
            .and_then(|value| value.as_str())
            .and_then(|value| normalize_nonempty(Some(value.to_string()))),
        chatgpt_user_id: auth_claims
            .and_then(|value| {
                value
                    .get("chatgpt_user_id")
                    .or_else(|| value.get("user_id"))
                    .and_then(|value| value.as_str())
            })
            .and_then(|value| normalize_nonempty(Some(value.to_string()))),
        oauth_client_id: access_claims
            .get("client_id")
            .and_then(|value| value.as_str())
            .and_then(|value| normalize_nonempty(Some(value.to_string()))),
        organization_id: auth_claims
            .and_then(|value| value.get("organization_id"))
            .or_else(|| id_auth_claims.and_then(|value| value.get("organization_id")))
            .and_then(|value| value.as_str())
            .and_then(|value| normalize_nonempty(Some(value.to_string()))),
    }
}

pub fn parse_provider_secrets_env(
    request: ProviderSecretsEnvParseRequest,
) -> ProviderSecretsEnvParseResult {
    let mut values = BTreeMap::new();

    for raw_line in request.text.lines() {
        let line = raw_line.trim();
        if line.starts_with("export ") == false {
            continue;
        }

        let body = &line["export ".len()..];
        let mut parts = body.splitn(2, '=');
        let Some(key) = parts
            .next()
            .map(|value| value.trim())
            .filter(|value| value.is_empty() == false)
        else {
            continue;
        };
        let Some(raw_value) = parts.next() else {
            continue;
        };

        values.insert(key.to_string(), normalize_provider_secret_value(raw_value.trim()));
    }

    ProviderSecretsEnvParseResult { values }
}

pub fn resolve_custom_provider_id(
    request: CustomProviderIdResolutionRequest,
) -> CustomProviderIdResolutionResult {
    let mut provider_id = String::new();
    let mut last_was_dash = false;

    for character in request.label.chars().flat_map(|value| value.to_lowercase()) {
        if character.is_ascii_lowercase() || character.is_ascii_digit() {
            provider_id.push(character);
            last_was_dash = false;
        } else if provider_id.is_empty() == false && last_was_dash == false {
            provider_id.push('-');
            last_was_dash = true;
        }
    }

    while provider_id.ends_with('-') {
        provider_id.pop();
    }

    if provider_id.is_empty() {
        provider_id = request.fallback_provider_id;
    } else if provider_id == "openrouter" {
        provider_id = "openrouter-custom".to_string();
    }

    CustomProviderIdResolutionResult {
        provider_id,
        rust_owner: "core_policy.resolve_custom_provider_id".to_string(),
    }
}

pub fn merge_interop_proxies_json(request: InteropProxyMergeRequest) -> InteropProxyMergeResult {
    let existing_items = interop_proxy_items(request.existing_json.as_deref());
    let incoming_items = interop_proxy_items(request.incoming_json.as_deref());

    if existing_items.is_empty() && incoming_items.is_empty() {
        return InteropProxyMergeResult {
            merged_json: request.existing_json,
        };
    }

    let mut merged: Vec<serde_json::Map<String, serde_json::Value>> = Vec::new();
    let mut index_by_proxy_key: BTreeMap<String, usize> = BTreeMap::new();

    for item in existing_items.into_iter().chain(incoming_items) {
        let proxy_key = item
            .get("proxy_key")
            .and_then(json_string)
            .and_then(|value| normalize_nonempty(Some(value)));

        if let Some(proxy_key) = proxy_key {
            if let Some(index) = index_by_proxy_key.get(&proxy_key).copied() {
                merged[index] = item;
            } else {
                index_by_proxy_key.insert(proxy_key, merged.len());
                merged.push(item);
            }
        } else {
            merged.push(item);
        }
    }

    InteropProxyMergeResult {
        merged_json: serde_json::to_string(&merged)
            .ok()
            .or(request.incoming_json)
            .or(request.existing_json),
    }
}

pub fn apply_oauth_interop_context(
    request: OAuthInteropContextApplyRequest,
) -> OAuthInteropContextApplyResult {
    let metadata_by_account_id = request
        .metadata_entries
        .into_iter()
        .map(|entry| (entry.account_id.clone(), entry))
        .collect::<BTreeMap<_, _>>();

    let accounts = request
        .accounts
        .into_iter()
        .map(|mut account| {
            if let Some(metadata) = metadata_by_account_id.get(&account.id) {
                account.interop_proxy_key = normalize_nonempty(metadata.proxy_key.clone());
                account.interop_notes = normalize_nonempty(metadata.notes.clone());
                account.interop_concurrency = metadata.concurrency.filter(|value| *value > 0);
                account.interop_priority = metadata.priority;
                account.interop_rate_multiplier =
                    metadata.rate_multiplier.filter(|value| value.is_finite() && *value > 0.0);
                account.interop_auto_pause_on_expired = metadata.auto_pause_on_expired;
                account.interop_credentials_json =
                    normalize_nonempty(metadata.credentials_json.clone());
                account.interop_extra_json = normalize_nonempty(metadata.extra_json.clone());
            }
            account
        })
        .collect();

    let merged_json = merge_interop_proxies_json(InteropProxyMergeRequest {
        existing_json: request.existing_json,
        incoming_json: request.incoming_json,
    })
    .merged_json;

    OAuthInteropContextApplyResult { accounts, merged_json }
}

pub fn render_oauth_interop_export_accounts(
    request: OAuthInteropExportRequest,
) -> OAuthInteropExportResult {
    let metadata_by_account_id = request
        .metadata_entries
        .into_iter()
        .map(|entry| (entry.account_id.clone(), entry))
        .collect::<BTreeMap<_, _>>();
    let available_proxy_keys = request
        .available_proxy_keys
        .into_iter()
        .filter_map(|value| normalize_nonempty(Some(value)))
        .collect::<BTreeSet<_>>();

    let accounts_payload = request
        .accounts
        .into_iter()
        .map(|account| {
            let metadata = metadata_by_account_id.get(&account.account_id);
            let mut credentials = json_object_from_text(metadata.and_then(|value| value.credentials_json.as_deref()))
                .unwrap_or_default();
            let token_metadata = inspect_oauth_token_metadata(OAuthTokenMetadataRequest {
                access_token: account.access_token.clone(),
                id_token: Some(account.id_token.clone()),
            });

            credentials.insert(
                "access_token".to_string(),
                serde_json::Value::String(account.access_token.clone()),
            );
            credentials.insert(
                "refresh_token".to_string(),
                serde_json::Value::String(account.refresh_token.clone()),
            );
            credentials.insert(
                "id_token".to_string(),
                serde_json::Value::String(account.id_token.clone()),
            );
            credentials.insert(
                "chatgpt_account_id".to_string(),
                serde_json::Value::String(account.remote_account_id.clone()),
            );

            if let Some(chatgpt_user_id) = first_nonempty([
                token_metadata.chatgpt_user_id.clone(),
            ]) {
                credentials.insert(
                    "chatgpt_user_id".to_string(),
                    serde_json::Value::String(chatgpt_user_id),
                );
            }

            if let Some(client_id) = first_nonempty([
                account.oauth_client_id.clone(),
                token_metadata.oauth_client_id.clone(),
                credentials.get("client_id").and_then(json_string),
            ]) {
                credentials.insert(
                    "client_id".to_string(),
                    serde_json::Value::String(client_id),
                );
            }

            if account.email.trim().is_empty() == false {
                credentials.insert(
                    "email".to_string(),
                    serde_json::Value::String(account.email.clone()),
                );
            }
            if let Some(expires_at) = account.expires_at {
                if let Some(number) = serde_json::Number::from_f64(expires_at.floor()) {
                    credentials.insert("expires_at".to_string(), serde_json::Value::Number(number));
                }
            }
            if account.plan_type.trim().is_empty() == false {
                credentials.insert(
                    "plan_type".to_string(),
                    serde_json::Value::String(account.plan_type.clone()),
                );
            }
            if let Some(organization_id) = first_nonempty([
                token_metadata.organization_id.clone(),
                credentials.get("organization_id").and_then(json_string),
            ]) {
                credentials.insert(
                    "organization_id".to_string(),
                    serde_json::Value::String(organization_id),
                );
            }

            let mut extra =
                json_object_from_text(metadata.and_then(|value| value.extra_json.as_deref()))
                    .unwrap_or_default();
            if account.email.trim().is_empty() == false && extra.contains_key("email") == false {
                extra.insert(
                    "email".to_string(),
                    serde_json::Value::String(account.email.clone()),
                );
            }

            let mut object = serde_json::Map::new();
            object.insert(
                "name".to_string(),
                serde_json::Value::String(if account.email.trim().is_empty() {
                    account.account_id.clone()
                } else {
                    account.email.clone()
                }),
            );
            object.insert(
                "platform".to_string(),
                serde_json::Value::String("openai".to_string()),
            );
            object.insert(
                "type".to_string(),
                serde_json::Value::String("oauth".to_string()),
            );
            object.insert(
                "credentials".to_string(),
                serde_json::Value::Object(credentials),
            );
            object.insert(
                "concurrency".to_string(),
                serde_json::Value::Number(
                    serde_json::Number::from(metadata.and_then(|value| value.concurrency).unwrap_or(1)),
                ),
            );
            object.insert(
                "priority".to_string(),
                serde_json::Value::Number(
                    serde_json::Number::from(metadata.and_then(|value| value.priority).unwrap_or(1)),
                ),
            );
            object.insert(
                "rate_multiplier".to_string(),
                serde_json::Value::Number(
                    serde_json::Number::from_f64(
                        metadata
                            .and_then(|value| value.rate_multiplier)
                            .filter(|value| value.is_finite() && *value > 0.0)
                            .unwrap_or(1.0),
                    )
                    .unwrap(),
                ),
            );
            object.insert(
                "auto_pause_on_expired".to_string(),
                serde_json::Value::Bool(metadata.and_then(|value| value.auto_pause_on_expired).unwrap_or(true)),
            );

            if extra.is_empty() == false {
                object.insert("extra".to_string(), serde_json::Value::Object(extra));
            }
            if let Some(notes) = metadata
                .and_then(|value| normalize_nonempty(value.notes.clone()))
            {
                object.insert("notes".to_string(), serde_json::Value::String(notes));
            }
            if let Some(proxy_key) = metadata
                .and_then(|value| normalize_nonempty(value.proxy_key.clone()))
                .filter(|proxy_key| available_proxy_keys.contains(proxy_key))
            {
                object.insert("proxy_key".to_string(), serde_json::Value::String(proxy_key));
            }
            if let Some(expires_at) = account.expires_at {
                if let Some(number) = serde_json::Number::from_f64(expires_at.floor()) {
                    object.insert("expires_at".to_string(), serde_json::Value::Number(number));
                }
            }

            serde_json::Value::Object(object)
        })
        .collect::<Vec<_>>();

    OAuthInteropExportResult {
        accounts_payload: serde_json::to_string(&accounts_payload).unwrap_or_else(|_| "[]".to_string()),
    }
}

pub fn parse_oauth_interop_bundle(
    request: OAuthInteropBundleParseRequest,
) -> Result<OAuthInteropBundleParseResult, String> {
    let payload = serde_json::from_str::<serde_json::Value>(&request.text)
        .map_err(|_| "invalidDataFile".to_string())?;
    let object = payload
        .as_object()
        .ok_or_else(|| "invalidDataFile".to_string())?;

    if let Some(kind) = object
        .get("type")
        .and_then(json_string)
        .map(|value| value.to_lowercase())
    {
        if kind != "rhino2api-data" && kind != "rhino2api-bundle" {
            return Err("unsupportedDataType".to_string());
        }
    }

    let account_items = object
        .get("accounts")
        .and_then(|value| value.as_array())
        .ok_or_else(|| "invalidDataFile".to_string())?;
    let proxies_json = object
        .get("proxies")
        .and_then(|value| value.as_array().cloned())
        .and_then(|value| serde_json::to_string(&value).ok());
    let declared_active_account_id = object
        .get("active_account_id")
        .and_then(json_string)
        .and_then(|value| normalize_nonempty(Some(value)));

    let mut accounts = Vec::new();
    let mut metadata_entries = Vec::new();

    for (index, item) in account_items.iter().enumerate() {
        let account_index = index + 1;
        let item = item
            .as_object()
            .ok_or_else(|| "invalidDataFile".to_string())?;
        let platform = item.get("platform").and_then(json_string).map(|value| value.to_lowercase());
        let account_type = item.get("type").and_then(json_string).map(|value| value.to_lowercase());
        if platform.as_deref() != Some("openai") || account_type.as_deref() != Some("oauth") {
            continue;
        }

        let credentials = item
            .get("credentials")
            .and_then(|value| value.as_object())
            .cloned()
            .ok_or_else(|| format!("missingRequiredValue:{account_index}"))?;

        let access_token = credentials
            .get("access_token")
            .and_then(json_string)
            .and_then(|value| normalize_nonempty(Some(value)))
            .ok_or_else(|| format!("missingRequiredValue:{account_index}"))?;
        let refresh_token = credentials
            .get("refresh_token")
            .and_then(json_string)
            .and_then(|value| normalize_nonempty(Some(value)))
            .ok_or_else(|| format!("missingRequiredValue:{account_index}"))?;
        let id_token = credentials
            .get("id_token")
            .and_then(json_string)
            .and_then(|value| normalize_nonempty(Some(value)))
            .ok_or_else(|| format!("missingRequiredValue:{account_index}"))?;

        let built_account = build_oauth_account_from_tokens(OAuthAccountBuildRequest {
            access_token: access_token.clone(),
            refresh_token: refresh_token.clone(),
            id_token: id_token.clone(),
            oauth_client_id: credentials.get("client_id").and_then(json_string),
            token_last_refresh_at: None,
        });
        if built_account.local_account_id.is_empty() {
            return Err(format!("invalidAccount:{account_index}"));
        }

        let extra = item.get("extra").and_then(|value| value.as_object()).cloned();
        let email = if built_account.email.is_empty() {
            credentials
                .get("email")
                .and_then(json_string)
                .or_else(|| extra.as_ref().and_then(|extra| extra.get("email")).and_then(json_string))
                .unwrap_or_default()
        } else {
            built_account.email.clone()
        };
        let expires_at = built_account.expires_at.or_else(|| {
            credentials
                .get("expires_at")
                .and_then(json_number_as_f64)
                .or_else(|| item.get("expires_at").and_then(json_number_as_f64))
        });

        accounts.push(OAuthInteropImportedAccountInput {
            account_id: built_account.local_account_id.clone(),
            remote_account_id: built_account.remote_account_id.clone(),
            email,
            access_token: access_token.clone(),
            refresh_token: refresh_token.clone(),
            id_token: id_token.clone(),
            expires_at,
            oauth_client_id: built_account.oauth_client_id.clone(),
            plan_type: built_account.plan_type.clone(),
        });

        metadata_entries.push(OAuthInteropMetadataEntry {
            account_id: built_account.local_account_id,
            proxy_key: item.get("proxy_key").and_then(json_string),
            notes: item.get("notes").and_then(json_string),
            concurrency: item.get("concurrency").and_then(json_number_as_i64),
            priority: item.get("priority").and_then(json_number_as_i64),
            rate_multiplier: item.get("rate_multiplier").and_then(json_number_as_f64),
            auto_pause_on_expired: item.get("auto_pause_on_expired").and_then(json_bool_value),
            credentials_json: serde_json::to_string(&serde_json::Value::Object(credentials)).ok(),
            extra_json: extra.and_then(|value| serde_json::to_string(&serde_json::Value::Object(value)).ok()),
        });
    }

    if accounts.is_empty() {
        return Err("noImportableAccounts".to_string());
    }

    let active_account_id = declared_active_account_id.filter(|active_account_id| {
        accounts
            .iter()
            .any(|account| account.account_id == *active_account_id)
    });

    Ok(OAuthInteropBundleParseResult {
        row_count: accounts.len(),
        accounts,
        active_account_id,
        metadata_entries,
        proxies_json,
    })
}

pub fn parse_legacy_oauth_csv(
    request: OAuthLegacyCsvParseRequest,
) -> Result<OAuthLegacyCsvParseResult, String> {
    let normalized = normalize_csv_text(&request.text);
    let raw_lines = normalized
        .split('\n')
        .map(|value| value.to_string())
        .collect::<Vec<_>>();
    let header_index = raw_lines
        .iter()
        .position(|line| line.trim().is_empty() == false)
        .ok_or_else(|| "emptyFile".to_string())?;

    let header_row_number = header_index + 1;
    let headers = parse_csv_line(&raw_lines[header_index], header_row_number)?
        .into_iter()
        .map(|value| value.trim().to_string())
        .collect::<Vec<_>>();
    let header_set = headers.iter().collect::<BTreeSet<_>>();
    if header_set.len() != headers.len()
        || OAUTH_LEGACY_CSV_HEADERS
            .iter()
            .all(|required| headers.iter().any(|header| header == required))
            == false
    {
        return Err("missingRequiredColumns".to_string());
    }

    let header_index_map = headers
        .iter()
        .enumerate()
        .map(|(index, header)| (header.as_str(), index))
        .collect::<BTreeMap<_, _>>();

    let mut accounts = Vec::new();
    let mut seen_account_ids = BTreeSet::new();
    let mut active_account_id = None;

    for (line_index, line) in raw_lines.iter().enumerate().skip(header_index + 1) {
        if line.trim().is_empty() {
            continue;
        }

        let row_number = line_index + 1;
        let columns = parse_csv_line(line, row_number)?;
        if columns.len() != headers.len() {
            return Err(format!("invalidCSV:{row_number}"));
        }

        let value = |key: &str| -> String {
            let index = *header_index_map.get(key).unwrap();
            columns[index].trim().to_string()
        };

        if value("format_version").to_lowercase() != "v1" {
            return Err("unsupportedFormatVersion".to_string());
        }

        let access_token = value("access_token");
        let refresh_token = value("refresh_token");
        let id_token = value("id_token");
        if access_token.is_empty() || refresh_token.is_empty() || id_token.is_empty() {
            return Err(format!("missingRequiredValue:{row_number}"));
        }

        let built_account = build_oauth_account_from_tokens(OAuthAccountBuildRequest {
            access_token: access_token.clone(),
            refresh_token: refresh_token.clone(),
            id_token: id_token.clone(),
            oauth_client_id: None,
            token_last_refresh_at: None,
        });
        if built_account.local_account_id.is_empty() {
            return Err(format!("invalidAccount:{row_number}"));
        }

        let declared_account_id = value("account_id");
        if declared_account_id.is_empty() == false
            && declared_account_id != built_account.local_account_id
            && declared_account_id != built_account.remote_account_id
        {
            return Err(format!("accountIDMismatch:{row_number}"));
        }

        let declared_email = value("email");
        if declared_email.is_empty() == false && declared_email != built_account.email {
            return Err(format!("emailMismatch:{row_number}"));
        }

        if seen_account_ids.insert(built_account.local_account_id.clone()) == false {
            return Err("duplicateAccountID".to_string());
        }

        let is_active = parse_csv_active_flag(&value("is_active"), row_number)?;
        if is_active {
            if active_account_id.is_some() {
                return Err("multipleActiveAccounts".to_string());
            }
            active_account_id = Some(built_account.local_account_id.clone());
        }

        accounts.push(OAuthInteropImportedAccountInput {
            account_id: built_account.local_account_id,
            remote_account_id: built_account.remote_account_id,
            email: built_account.email,
            access_token,
            refresh_token,
            id_token,
            expires_at: built_account.expires_at,
            oauth_client_id: built_account.oauth_client_id,
            plan_type: built_account.plan_type,
        });
    }

    if accounts.is_empty() {
        return Err("emptyFile".to_string());
    }

    Ok(OAuthLegacyCsvParseResult {
        row_count: accounts.len(),
        accounts,
        active_account_id,
    })
}

pub fn parse_wham_usage(request: WhamUsageParseRequest) -> WhamUsageParseResult {
    let plan_type = request
        .body_json
        .get("plan_type")
        .and_then(|value| value.as_str())
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
        .unwrap_or_else(|| "free".to_string());

    let rate_limit = request
        .body_json
        .get("rate_limit")
        .and_then(|value| value.as_object());

    let primary_window = rate_limit
        .and_then(|value| value.get("primary_window"))
        .and_then(|value| value.as_object());
    let secondary_window = rate_limit
        .and_then(|value| value.get("secondary_window"))
        .and_then(|value| value.as_object());

    WhamUsageParseResult {
        plan_type,
        primary_used_percent: wham_usage_percent(primary_window, "used_percent"),
        secondary_used_percent: wham_usage_percent(secondary_window, "used_percent"),
        primary_reset_at: wham_timestamp(primary_window, "reset_at"),
        secondary_reset_at: wham_timestamp(secondary_window, "reset_at"),
        primary_limit_window_seconds: wham_window_seconds(primary_window, "limit_window_seconds"),
        secondary_limit_window_seconds: wham_window_seconds(
            secondary_window,
            "limit_window_seconds",
        ),
    }
}

pub fn sanitize_oauth_quota_snapshots(
    request: OAuthQuotaSnapshotSanitizationRequest,
) -> OAuthQuotaSnapshotSanitizationResult {
    let mut changed = false;
    let accounts = request
        .accounts
        .into_iter()
        .map(|account| {
            if account.kind != "oauth_tokens" {
                return account;
            }

            let sanitized = sanitized_oauth_quota_account(account.clone(), request.now);
            if sanitized != account {
                changed = true;
            }
            sanitized
        })
        .collect::<Vec<_>>();

    OAuthQuotaSnapshotSanitizationResult { changed, accounts }
}

pub fn assemble_oauth_provider(
    request: OAuthProviderAssemblyRequest,
) -> OAuthProviderAssemblyResult {
    let mut accounts = request.imported_accounts;

    if let Some(snapshot) = request.snapshot {
        let imported = oauth_stored_account_from_snapshot(snapshot);
        if accounts.iter().any(|account| account.id == imported.id) == false {
            accounts.push(imported);
        }
    }

    OAuthProviderAssemblyResult {
        should_create: accounts.is_empty() == false,
        active_account_id: accounts.first().map(|account| account.id.clone()),
        accounts,
    }
}

pub fn resolve_legacy_migration_active_selection(
    request: LegacyMigrationActiveSelectionRequest,
) -> LegacyMigrationActiveSelectionResult {
    if let Some(base_url) = normalize_nonempty(request.openai_base_url.clone()) {
        if let Some(provider) = request
            .providers
            .iter()
            .find(|provider| provider.base_url.as_deref() == Some(base_url.as_str()))
        {
            return legacy_selection_result(provider);
        }
    }

    if let Some(provider) = request.providers.iter().find(|provider| provider.kind == "openai_oauth") {
        if request.auth_snapshot_local_account_id.is_some() || request.auth_snapshot_remote_account_id.is_some() {
            let account_id = request
                .auth_snapshot_local_account_id
                .as_ref()
                .and_then(|local_account_id| {
                    provider
                        .accounts
                        .iter()
                        .find(|account| account.id == *local_account_id)
                        .map(|account| account.id.clone())
                })
                .or_else(|| {
                    let remote_account_id = request.auth_snapshot_remote_account_id.as_ref()?;
                    let matches = provider
                        .accounts
                        .iter()
                        .filter(|account| {
                            account
                                .openai_account_id
                                .as_ref()
                                .unwrap_or(&account.id)
                                == remote_account_id
                        })
                        .map(|account| account.id.clone())
                        .collect::<Vec<_>>();
                    if matches.len() == 1 {
                        matches.first().cloned()
                    } else {
                        None
                    }
                })
                .or_else(|| active_provider_account_id(provider));

            return LegacyMigrationActiveSelectionResult {
                provider_id: Some(provider.id.clone()),
                account_id,
            };
        }
    }

    if request.has_openai_api_key {
        if let Some(provider) = request
            .providers
            .iter()
            .find(|provider| provider.kind == OPENAI_COMPATIBLE_KIND)
        {
            return legacy_selection_result(provider);
        }
    }

    request
        .providers
        .first()
        .map(legacy_selection_result)
        .unwrap_or(LegacyMigrationActiveSelectionResult {
            provider_id: None,
            account_id: None,
        })
}

pub fn plan_legacy_imported_provider(
    request: LegacyImportedProviderPlanRequest,
) -> LegacyImportedProviderPlanResult {
    let normalized_base_url = request
        .base_url
        .and_then(|value| normalize_nonempty(Some(value)))
        .unwrap_or_else(|| "https://api.openai.com/v1".to_string());

    if request
        .existing_base_urls
        .iter()
        .any(|value| value == &normalized_base_url)
    {
        return LegacyImportedProviderPlanResult {
            should_create: false,
            provider_id: None,
            label: None,
            normalized_base_url: None,
            account_label: None,
        };
    }

    let label = extracted_host(&normalized_base_url).unwrap_or_else(|| "Imported".to_string());
    LegacyImportedProviderPlanResult {
        should_create: true,
        provider_id: Some(imported_provider_id(&label)),
        label: Some(label),
        normalized_base_url: Some(normalized_base_url),
        account_label: Some("Imported".to_string()),
    }
}

pub fn normalize_oauth_account_identities(
    request: OAuthIdentityNormalizationRequest,
) -> OAuthIdentityNormalizationResult {
    let mut migrated_account_ids = BTreeMap::new();
    let mut accounts = Vec::<OAuthStoredAccountInput>::new();
    let mut changed = false;

    for stored in request.accounts {
        if stored.kind != "oauth_tokens" {
            accounts.push(stored);
            continue;
        }

        let Some(access_token) = normalize_nonempty(stored.access_token.clone()) else {
            accounts.push(stored);
            continue;
        };

        let mut updated = stored.clone();
        let local_account_id = oauth_local_account_id_from_access_token(&access_token);
        let remote_account_id = oauth_remote_account_id_from_access_token(&access_token);

        if let Some(local_account_id) = local_account_id {
            if updated.id != local_account_id {
                migrated_account_ids.insert(updated.id.clone(), local_account_id.clone());
                updated.id = local_account_id;
                changed = true;
            }
        }

        if let Some(remote_account_id) = remote_account_id {
            if updated.openai_account_id.as_deref() != Some(remote_account_id.as_str()) {
                updated.openai_account_id = Some(remote_account_id);
                changed = true;
            }
        }

        if let Some(existing_index) = accounts.iter().position(|account| account.id == updated.id) {
            let merged = merge_oauth_identity_account(accounts[existing_index].clone(), updated);
            if accounts[existing_index] != merged {
                changed = true;
            }
            accounts[existing_index] = merged;
        } else {
            accounts.push(updated);
        }
    }

    OAuthIdentityNormalizationResult {
        changed,
        migrated_account_ids,
        accounts,
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
        switch_mode_selection: input.switch_mode_selection.map(|selection| {
            CanonicalActiveSelection {
                provider_id: normalize_nonempty(selection.provider_id),
                account_id: normalize_nonempty(selection.account_id),
            }
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

fn canonicalize_provider(
    provider_index: usize,
    input: RawProviderInput,
) -> CanonicalProviderSnapshot {
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
        .map(|(account_index, account)| {
            canonicalize_provider_account(provider_index, account_index, account)
        })
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
    let id = normalize_nonempty(input.id)
        .unwrap_or_else(|| format!("account-{provider_index}-{account_index}"));
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
        primary_limit_window_seconds: sanitize_positive_optional(
            input.primary_limit_window_seconds,
        ),
        secondary_limit_window_seconds: sanitize_positive_optional(
            input.secondary_limit_window_seconds,
        ),
        last_checked: input.last_checked,
        is_suspended: input.is_suspended,
        token_expired: input.token_expired,
        organization_name: normalize_nonempty(input.organization_name),
        interop_proxy_key: normalize_nonempty(input.interop_proxy_key),
        interop_notes: normalize_nonempty(input.interop_notes),
        interop_concurrency: input.interop_concurrency.filter(|value| *value > 0),
        interop_priority: input.interop_priority,
        interop_rate_multiplier: input
            .interop_rate_multiplier
            .filter(|value| value.is_finite()),
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
    let is_available =
        account.is_suspended == false && account.token_expired == false && quota_exhausted == false;
    let is_degraded = is_available
        && (primary_used_percent >= ROUTING_DEGRADED_THRESHOLD
            || secondary_used_percent >= ROUTING_DEGRADED_THRESHOLD);

    account.email =
        normalize_nonempty(Some(account.email)).unwrap_or_else(|| account.local_account_id.clone());
    account.remote_account_id = normalize_nonempty(Some(account.remote_account_id))
        .unwrap_or_else(|| account.local_account_id.clone());
    account.oauth_client_id = normalize_nonempty(account.oauth_client_id);
    account.plan_type =
        normalize_nonempty(Some(account.plan_type)).unwrap_or_else(|| "free".to_string());
    account.primary_used_percent = primary_used_percent;
    account.secondary_used_percent = secondary_used_percent;
    account.primary_limit_window_seconds =
        sanitize_positive_optional(account.primary_limit_window_seconds);
    account.secondary_limit_window_seconds =
        sanitize_positive_optional(account.secondary_limit_window_seconds);
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
    let attempts =
        ((existing.map(|state| state.attempts).unwrap_or(0)) + 1).min(max_retry_count.max(1));
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

fn resolved_pinned_model_ids(
    pinned_model_ids: Vec<String>,
    selected_model_id: Option<String>,
) -> Vec<String> {
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
    let (host, path) = without_scheme
        .split_once('/')
        .unwrap_or((without_scheme, ""));
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

fn is_shared_openai_team_account(account: &OAuthStoredAccountInput) -> bool {
    account.kind == "oauth_tokens"
        && account
            .plan_type
            .as_deref()
            .map(|value| value.trim().eq_ignore_ascii_case("team"))
            .unwrap_or(false)
}

fn normalized_shared_openai_account_id(account: &OAuthStoredAccountInput) -> Option<String> {
    normalize_nonempty(
        account
            .openai_account_id
            .clone()
            .or_else(|| Some(account.id.clone())),
    )
}

fn normalized_shared_organization_name(organization_name: Option<String>) -> Option<String> {
    normalize_nonempty(organization_name)
}

fn next_available_provider_id(
    base: &str,
    excluding_current_id: &str,
    providers: &[ReservedProviderIdInput],
) -> String {
    let existing_ids = providers
        .iter()
        .map(|provider| provider.id.as_str())
        .filter(|id| *id != excluding_current_id)
        .collect::<BTreeSet<_>>();

    let mut candidate = base.to_string();
    let mut suffix = 2;
    while existing_ids.contains(candidate.as_str()) {
        candidate = format!("{}-{}", base, suffix);
        suffix += 1;
    }
    candidate
}

fn refreshed_oauth_account_metadata(
    mut account: OAuthStoredAccountInput,
) -> OAuthStoredAccountInput {
    if account.kind != "oauth_tokens" {
        return account;
    }
    let (Some(access_token), Some(_refresh_token), Some(id_token)) = (
        account.access_token.clone(),
        account.refresh_token.clone(),
        account.id_token.clone(),
    ) else {
        return account;
    };

    let access_claims = decode_jwt_claims(&access_token);
    let id_claims = decode_jwt_claims(&id_token);
    let auth_claims = access_claims
        .get("https://api.openai.com/auth")
        .and_then(|value| value.as_object());

    if account
        .email
        .as_deref()
        .map(|value| value.trim().is_empty())
        .unwrap_or(true)
    {
        if let Some(email) = id_claims
            .get("email")
            .and_then(|value| value.as_str())
            .and_then(|value| normalize_nonempty(Some(value.to_string())))
        {
            account.email = Some(email);
        }
    }

    if account
        .openai_account_id
        .as_deref()
        .map(|value| value.trim().is_empty())
        .unwrap_or(true)
    {
        if let Some(openai_account_id) = auth_claims
            .and_then(|claims| {
                claims
                    .get("chatgpt_account_id")
                    .and_then(|value| value.as_str())
                    .map(|value| value.to_string())
                    .or_else(|| {
                        claims
                            .get("chatgpt_account_user_id")
                            .and_then(|value| value.as_str())
                            .map(|value| value.to_string())
                    })
            })
            .and_then(|value| normalize_nonempty(Some(value)))
        {
            account.openai_account_id = Some(openai_account_id);
        }
    }

    let derived_expires_at = access_claims
        .get("exp")
        .and_then(|value| value.as_f64())
        .or_else(|| id_claims.get("exp").and_then(|value| value.as_f64()));
    if derived_expires_at.is_some() {
        account.expires_at = derived_expires_at.or(account.expires_at);
    }

    let derived_client_id = account
        .oauth_client_id
        .clone()
        .or_else(|| {
            access_claims
                .get("client_id")
                .and_then(|value| value.as_str())
                .map(|value| value.to_string())
        })
        .and_then(|value| normalize_nonempty(Some(value)));
    if derived_client_id.is_some() {
        account.oauth_client_id = derived_client_id.or(account.oauth_client_id);
    }

    account.token_last_refresh_at = account.token_last_refresh_at.or(account.last_refresh);
    account.last_refresh = account.token_last_refresh_at.or(account.last_refresh);
    account
}

fn parse_legacy_openai_base_url(text: &str) -> Option<String> {
    parse_toml_string_value(text, "openai_base_url")
        .or_else(|| parse_toml_string_value_in_model_provider(text, "OpenAI", "base_url"))
        .or_else(|| parse_toml_string_value_in_model_provider(text, "openai", "base_url"))
}

fn interop_proxy_items(
    text: Option<&str>,
) -> Vec<serde_json::Map<String, serde_json::Value>> {
    text.and_then(|text| serde_json::from_str::<serde_json::Value>(text).ok())
        .and_then(|value| value.as_array().cloned())
        .map(|items| {
            items.into_iter()
                .filter_map(|item| item.as_object().cloned())
                .collect()
        })
        .unwrap_or_default()
}

fn normalize_csv_text(text: &str) -> String {
    let mut normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    if normalized.starts_with('\u{FEFF}') {
        normalized.remove(0);
    }
    normalized
}

fn parse_csv_line(line: &str, row_number: usize) -> Result<Vec<String>, String> {
    let characters = line.chars().collect::<Vec<_>>();
    let mut fields = Vec::new();
    let mut current = String::new();
    let mut index = 0;
    let mut is_quoted = false;

    while index < characters.len() {
        let character = characters[index];
        if is_quoted {
            if character == '"' {
                let next_index = index + 1;
                if next_index < characters.len() && characters[next_index] == '"' {
                    current.push('"');
                    index += 1;
                } else {
                    is_quoted = false;
                }
            } else {
                current.push(character);
            }
        } else {
            match character {
                ',' => {
                    fields.push(current);
                    current = String::new();
                }
                '"' => {
                    if current.is_empty() == false {
                        return Err(format!("invalidCSV:{row_number}"));
                    }
                    is_quoted = true;
                }
                _ => current.push(character),
            }
        }
        index += 1;
    }

    if is_quoted {
        return Err(format!("invalidCSV:{row_number}"));
    }
    fields.push(current);
    Ok(fields)
}

fn parse_csv_active_flag(value: &str, row_number: usize) -> Result<bool, String> {
    match value.trim().to_lowercase().as_str() {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => Err(format!("invalidActiveValue:{row_number}")),
    }
}

fn json_object_from_text(
    text: Option<&str>,
) -> Option<serde_json::Map<String, serde_json::Value>> {
    text.and_then(|text| serde_json::from_str::<serde_json::Value>(text).ok())
        .and_then(|value| value.as_object().cloned())
}

fn json_number_as_f64(value: &serde_json::Value) -> Option<f64> {
    match value {
        serde_json::Value::Number(number) => number.as_f64(),
        serde_json::Value::String(text) => text.trim().parse::<f64>().ok(),
        _ => None,
    }
}

fn json_number_as_i64(value: &serde_json::Value) -> Option<i64> {
    match value {
        serde_json::Value::Number(number) => number.as_i64(),
        serde_json::Value::String(text) => text.trim().parse::<i64>().ok(),
        _ => None,
    }
}

fn json_bool_value(value: &serde_json::Value) -> Option<bool> {
    match value {
        serde_json::Value::Bool(value) => Some(*value),
        serde_json::Value::Number(number) => Some(number.as_i64().unwrap_or_default() != 0),
        serde_json::Value::String(text) => match text.trim().to_lowercase().as_str() {
            "true" | "1" | "yes" | "on" => Some(true),
            "false" | "0" | "no" | "off" => Some(false),
            _ => None,
        },
        _ => None,
    }
}

fn first_nonempty<I>(values: I) -> Option<String>
where
    I: IntoIterator<Item = Option<String>>,
{
    values
        .into_iter()
        .find_map(|value| normalize_nonempty(value))
}

fn parse_toml_string_value_in_model_provider(
    text: &str,
    provider_key: &str,
    value_key: &str,
) -> Option<String> {
    let header = format!("[model_providers.{provider_key}]");
    let mut inside_target_block = false;

    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            inside_target_block = trimmed == header;
            continue;
        }
        if inside_target_block {
            if let Some(value) = parse_toml_string_line(line, value_key) {
                return Some(value);
            }
        }
    }

    None
}

fn parse_toml_string_value(text: &str, key: &str) -> Option<String> {
    text.lines()
        .filter_map(|line| parse_toml_string_line(line, key))
        .next()
}

fn parse_toml_string_line(line: &str, key: &str) -> Option<String> {
    let (raw_key, raw_value) = line.split_once('=')?;
    if raw_key.trim() != key {
        return None;
    }
    let value = raw_value.trim_start();
    let value = value.strip_prefix('"')?;
    let end = value.find('"')?;
    normalize_nonempty(Some(value[..end].to_string()))
}

fn normalize_provider_secret_value(value: &str) -> String {
    if value.len() >= 2
        && ((value.starts_with('"') && value.ends_with('"'))
            || (value.starts_with('\'') && value.ends_with('\'')))
    {
        value[1..value.len() - 1].to_string()
    } else {
        value.to_string()
    }
}

fn extracted_host(url: &str) -> Option<String> {
    let after_scheme = url.split_once("://").map(|(_, rest)| rest).unwrap_or(url);
    let host = after_scheme.split('/').next().unwrap_or("").trim();
    if host.is_empty() {
        None
    } else {
        Some(host.to_string())
    }
}

fn imported_provider_id(label: &str) -> String {
    let mut slug = label
        .chars()
        .map(|ch| if ch.is_ascii_alphanumeric() { ch.to_ascii_lowercase() } else { '-' })
        .collect::<String>();
    while slug.contains("--") {
        slug = slug.replace("--", "-");
    }
    let slug = slug.trim_matches('-');
    if slug.is_empty() {
        return "imported".to_string();
    }
    if slug == "openrouter" {
        return "openrouter-compat".to_string();
    }
    slug.to_string()
}

fn oauth_local_account_id_from_access_token(access_token: &str) -> Option<String> {
    let auth_claims = decode_jwt_claims(access_token)
        .get("https://api.openai.com/auth")
        .and_then(|value| value.as_object())?
        .clone();
    auth_claims
        .get("chatgpt_account_user_id")
        .and_then(|value| value.as_str())
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
        .or_else(|| {
            auth_claims
                .get("chatgpt_account_id")
                .and_then(|value| value.as_str())
                .and_then(|value| normalize_nonempty(Some(value.to_string())))
        })
}

fn wham_usage_percent(
    window: Option<&serde_json::Map<String, serde_json::Value>>,
    key: &str,
) -> f64 {
    window
        .and_then(|value| value.get(key))
        .and_then(|value| value.as_f64())
        .unwrap_or(0.0)
}

fn wham_timestamp(
    window: Option<&serde_json::Map<String, serde_json::Value>>,
    key: &str,
) -> Option<f64> {
    window
        .and_then(|value| value.get(key))
        .and_then(|value| value.as_f64())
}

fn wham_window_seconds(
    window: Option<&serde_json::Map<String, serde_json::Value>>,
    key: &str,
) -> Option<i64> {
    window.and_then(|value| value.get(key)).and_then(|value| {
        value
            .as_i64()
            .or_else(|| value.as_f64().map(|number| number as i64))
    })
}

fn oauth_remote_account_id_from_access_token(access_token: &str) -> Option<String> {
    let auth_claims = decode_jwt_claims(access_token)
        .get("https://api.openai.com/auth")
        .and_then(|value| value.as_object())?
        .clone();
    auth_claims
        .get("chatgpt_account_id")
        .and_then(|value| value.as_str())
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
        .or_else(|| oauth_local_account_id_from_access_token(access_token))
}

fn merge_oauth_identity_account(
    existing: OAuthStoredAccountInput,
    incoming: OAuthStoredAccountInput,
) -> OAuthStoredAccountInput {
    OAuthStoredAccountInput {
        label: existing.label,
        added_at: existing.added_at.or(incoming.added_at),
        api_key: incoming.api_key.or(existing.api_key),
        email: incoming.email.or(existing.email),
        expires_at: incoming.expires_at.or(existing.expires_at),
        oauth_client_id: incoming.oauth_client_id.or(existing.oauth_client_id),
        token_last_refresh_at: incoming
            .token_last_refresh_at
            .or(existing.token_last_refresh_at)
            .or(existing.last_refresh),
        last_refresh: incoming.last_refresh.or(existing.last_refresh),
        primary_used_percent: incoming.primary_used_percent.or(existing.primary_used_percent),
        secondary_used_percent: incoming.secondary_used_percent.or(existing.secondary_used_percent),
        primary_reset_at: incoming.primary_reset_at.or(existing.primary_reset_at),
        secondary_reset_at: incoming.secondary_reset_at.or(existing.secondary_reset_at),
        primary_limit_window_seconds: incoming
            .primary_limit_window_seconds
            .or(existing.primary_limit_window_seconds),
        secondary_limit_window_seconds: incoming
            .secondary_limit_window_seconds
            .or(existing.secondary_limit_window_seconds),
        last_checked: incoming.last_checked.or(existing.last_checked),
        is_suspended: incoming.is_suspended.or(existing.is_suspended),
        token_expired: incoming.token_expired.or(existing.token_expired),
        organization_name: incoming.organization_name.or(existing.organization_name),
        interop_proxy_key: incoming.interop_proxy_key.or(existing.interop_proxy_key),
        interop_notes: incoming.interop_notes.or(existing.interop_notes),
        interop_concurrency: incoming.interop_concurrency.or(existing.interop_concurrency),
        interop_priority: incoming.interop_priority.or(existing.interop_priority),
        interop_rate_multiplier: incoming.interop_rate_multiplier.or(existing.interop_rate_multiplier),
        interop_auto_pause_on_expired: incoming
            .interop_auto_pause_on_expired
            .or(existing.interop_auto_pause_on_expired),
        interop_credentials_json: incoming
            .interop_credentials_json
            .or(existing.interop_credentials_json),
        interop_extra_json: incoming.interop_extra_json.or(existing.interop_extra_json),
        ..incoming
    }
}

fn oauth_stored_account_from_snapshot(snapshot: AuthJsonSnapshotInput) -> OAuthStoredAccountInput {
    OAuthStoredAccountInput {
        id: snapshot.local_account_id.clone(),
        kind: "oauth_tokens".to_string(),
        label: snapshot
            .email
            .clone()
            .unwrap_or_else(|| snapshot.local_account_id.chars().take(8).collect()),
        email: snapshot.email,
        openai_account_id: Some(snapshot.remote_account_id),
        access_token: Some(snapshot.account.access_token),
        refresh_token: Some(snapshot.account.refresh_token),
        id_token: Some(snapshot.account.id_token),
        expires_at: snapshot.account.expires_at,
        oauth_client_id: snapshot.account.oauth_client_id,
        token_last_refresh_at: snapshot
            .token_last_refresh_at
            .or(snapshot.account.token_last_refresh_at),
        last_refresh: snapshot
            .token_last_refresh_at
            .or(snapshot.account.token_last_refresh_at),
        api_key: None,
        added_at: None,
        plan_type: snapshot.account.plan_type,
        primary_used_percent: None,
        secondary_used_percent: None,
        primary_reset_at: None,
        secondary_reset_at: None,
        primary_limit_window_seconds: None,
        secondary_limit_window_seconds: None,
        last_checked: None,
        is_suspended: Some(false),
        token_expired: Some(false),
        organization_name: None,
        interop_proxy_key: None,
        interop_notes: None,
        interop_concurrency: None,
        interop_priority: None,
        interop_rate_multiplier: None,
        interop_auto_pause_on_expired: None,
        interop_credentials_json: None,
        interop_extra_json: None,
    }
}

fn sanitized_oauth_quota_account(
    mut account: OAuthStoredAccountInput,
    now: f64,
) -> OAuthStoredAccountInput {
    let normalized_plan_type = normalize_nonempty(account.plan_type.clone())
        .unwrap_or_else(|| "free".to_string());
    let primary_used_percent = sanitize_nonnegative(account.primary_used_percent.unwrap_or(0.0));
    let secondary_used_percent = sanitize_nonnegative(account.secondary_used_percent.unwrap_or(0.0));

    let primary_limit_window_seconds = resolved_primary_limit_window_seconds(
        account.primary_limit_window_seconds,
        account.primary_reset_at,
        &normalized_plan_type,
        now,
    );
    let secondary_limit_window_seconds = resolved_secondary_limit_window_seconds(
        account.secondary_limit_window_seconds,
        account.secondary_reset_at,
        secondary_used_percent,
        &normalized_plan_type,
    );

    account.plan_type = Some(normalized_plan_type);
    account.primary_used_percent = Some(primary_used_percent);
    account.secondary_used_percent = Some(secondary_used_percent);
    account.primary_limit_window_seconds = primary_limit_window_seconds;
    account.secondary_limit_window_seconds = secondary_limit_window_seconds;
    account.primary_reset_at = clamped_reset_at(
        account.primary_reset_at,
        primary_limit_window_seconds,
        account.last_checked,
        now,
    );
    account.secondary_reset_at = clamped_reset_at(
        account.secondary_reset_at,
        secondary_limit_window_seconds,
        account.last_checked,
        now,
    );
    account.is_suspended = Some(account.is_suspended.unwrap_or(false));
    account.token_expired = Some(account.token_expired.unwrap_or(false));
    account
}

fn resolved_primary_limit_window_seconds(
    explicit_window: Option<i64>,
    primary_reset_at: Option<f64>,
    plan_type: &str,
    now: f64,
) -> Option<i64> {
    if let Some(explicit_window) = sanitize_positive_optional(explicit_window) {
        return Some(explicit_window);
    }

    if plan_type.trim().eq_ignore_ascii_case("free")
        && primary_reset_at
            .map(|reset_at| reset_at - now > 12.0 * 3_600.0)
            .unwrap_or(false)
    {
        return Some(7 * 86_400);
    }

    Some(5 * 3_600)
}

fn resolved_secondary_limit_window_seconds(
    explicit_window: Option<i64>,
    secondary_reset_at: Option<f64>,
    secondary_used_percent: f64,
    plan_type: &str,
) -> Option<i64> {
    if let Some(explicit_window) = sanitize_positive_optional(explicit_window) {
        return Some(explicit_window);
    }

    if secondary_reset_at.is_some() || secondary_used_percent > 0.0 {
        return Some(7 * 86_400);
    }

    if matches!(plan_type.trim().to_ascii_lowercase().as_str(), "plus" | "pro" | "team") {
        return Some(7 * 86_400);
    }

    None
}

fn clamped_reset_at(
    raw_reset_at: Option<f64>,
    limit_window_seconds: Option<i64>,
    last_checked: Option<f64>,
    now: f64,
) -> Option<f64> {
    let raw_reset_at = raw_reset_at?;
    let Some(limit_window_seconds) = limit_window_seconds else {
        return Some(raw_reset_at);
    };
    if limit_window_seconds <= 0 {
        return Some(raw_reset_at);
    }
    let anchor = last_checked.unwrap_or(now);
    Some(raw_reset_at.min(anchor + limit_window_seconds as f64))
}

fn legacy_selection_result(
    provider: &LegacyMigrationProviderInput,
) -> LegacyMigrationActiveSelectionResult {
    LegacyMigrationActiveSelectionResult {
        provider_id: Some(provider.id.clone()),
        account_id: active_provider_account_id(provider),
    }
}

fn active_provider_account_id(provider: &LegacyMigrationProviderInput) -> Option<String> {
    provider
        .active_account_id
        .as_ref()
        .and_then(|active_account_id| {
            provider
                .accounts
                .iter()
                .find(|account| account.id == *active_account_id)
                .map(|account| account.id.clone())
        })
        .or_else(|| provider.accounts.first().map(|account| account.id.clone()))
}

fn parsed_auth_json_snapshot(text: &str) -> Option<AuthJsonSnapshotInput> {
    let root = serde_json::from_str::<serde_json::Value>(text).ok()?;
    let tokens = root.get("tokens")?.as_object()?;
    let access_token = json_string(tokens.get("access_token")?)?;
    let refresh_token = json_string(tokens.get("refresh_token")?)?;
    let id_token = json_string(tokens.get("id_token")?)?;
    let fallback_remote_account_id = tokens
        .get("account_id")
        .and_then(json_string)
        .unwrap_or_default();
    let last_refresh = root
        .get("last_refresh")
        .and_then(json_string)
        .and_then(|value| parse_iso8601_to_unix_seconds(&value));
    let access_claims = decode_jwt_claims(&access_token);
    let id_claims = decode_jwt_claims(&id_token);
    let auth_claims = access_claims
        .get("https://api.openai.com/auth")
        .and_then(|value| value.as_object());
    let id_auth_claims = id_claims
        .get("https://api.openai.com/auth")
        .and_then(|value| value.as_object());
    let local_account_id = auth_claims
        .and_then(|claims| {
            claims
                .get("chatgpt_account_user_id")
                .and_then(|value| value.as_str())
                .or_else(|| {
                    claims
                        .get("chatgpt_account_id")
                        .and_then(|value| value.as_str())
                })
        })
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
        .or_else(|| normalize_nonempty(Some(fallback_remote_account_id.clone())))
        .unwrap_or_default();
    let remote_account_id = auth_claims
        .and_then(|claims| {
            claims
                .get("chatgpt_account_id")
                .and_then(|value| value.as_str())
        })
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
        .or_else(|| normalize_nonempty(Some(fallback_remote_account_id)))
        .unwrap_or_else(|| local_account_id.clone());

    if local_account_id.is_empty() && remote_account_id.is_empty() {
        return None;
    }

    let oauth_client_id = root
        .get("client_id")
        .and_then(json_string)
        .or_else(|| tokens.get("client_id").and_then(json_string))
        .or_else(|| {
            access_claims
                .get("client_id")
                .and_then(|value| value.as_str())
                .map(|value| value.to_string())
        })
        .and_then(|value| normalize_nonempty(Some(value)));
    let email = id_claims
        .get("email")
        .and_then(|value| value.as_str())
        .and_then(|value| normalize_nonempty(Some(value.to_string())));
    let expires_at = access_claims
        .get("exp")
        .and_then(|value| value.as_f64())
        .or_else(|| id_claims.get("exp").and_then(|value| value.as_f64()))
        .or_else(|| {
            id_auth_claims
                .and_then(|claims| {
                    claims
                        .get("chatgpt_subscription_active_until")
                        .and_then(|value| value.as_str())
                })
                .and_then(parse_iso8601_to_unix_seconds)
        });
    let plan_type = auth_claims
        .and_then(|claims| {
            claims
                .get("chatgpt_plan_type")
                .and_then(|value| value.as_str())
        })
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
        .or_else(|| Some("free".to_string()));

    Some(AuthJsonSnapshotInput {
        local_account_id,
        remote_account_id,
        email,
        token_last_refresh_at: last_refresh,
        account: AuthJsonSnapshotAccountInput {
            access_token,
            refresh_token,
            id_token,
            expires_at,
            oauth_client_id,
            token_last_refresh_at: last_refresh,
            plan_type,
        },
    })
}

fn parsed_openai_api_key(text: &str) -> Option<String> {
    let root = serde_json::from_str::<serde_json::Value>(text).ok()?;
    root.get("OPENAI_API_KEY")
        .and_then(|value| value.as_str())
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
}

fn json_string(value: &serde_json::Value) -> Option<String> {
    value
        .as_str()
        .and_then(|value| normalize_nonempty(Some(value.to_string())))
}

fn parse_iso8601_to_unix_seconds(value: &str) -> Option<f64> {
    let value = value.trim();
    if value.len() < 19 {
        return None;
    }
    let year = value.get(0..4)?.parse::<i32>().ok()?;
    let month = value.get(5..7)?.parse::<u32>().ok()?;
    let day = value.get(8..10)?.parse::<u32>().ok()?;
    let hour = value.get(11..13)?.parse::<u32>().ok()?;
    let minute = value.get(14..16)?.parse::<u32>().ok()?;
    let second = value.get(17..19)?.parse::<u32>().ok()?;
    if value.get(4..5)? != "-"
        || value.get(7..8)? != "-"
        || !matches!(value.get(10..11)?, "T" | "t" | " ")
        || value.get(13..14)? != ":"
        || value.get(16..17)? != ":"
        || !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }

    let mut index = 19;
    let mut fractional = 0.0;
    if value.get(index..index + 1) == Some(".") {
        index += 1;
        let start = index;
        while value
            .as_bytes()
            .get(index)
            .map(|byte| byte.is_ascii_digit())
            .unwrap_or(false)
        {
            index += 1;
        }
        if index > start {
            let divisor = 10_f64.powi((index - start) as i32);
            fractional = value.get(start..index)?.parse::<f64>().ok()? / divisor;
        }
    }

    let offset_seconds = match value.get(index..index + 1)? {
        "Z" | "z" => 0,
        "+" | "-" => {
            let sign = if value.get(index..index + 1)? == "+" {
                1
            } else {
                -1
            };
            let hours = value.get(index + 1..index + 3)?.parse::<i64>().ok()?;
            let minutes = value.get(index + 4..index + 6)?.parse::<i64>().ok()?;
            if value.get(index + 3..index + 4)? != ":" || hours > 23 || minutes > 59 {
                return None;
            }
            sign * (hours * 3600 + minutes * 60)
        }
        _ => return None,
    };

    let days = days_from_civil(year, month, day);
    Some(
        (days * 86_400 + i64::from(hour) * 3_600 + i64::from(minute) * 60 + i64::from(second)
            - offset_seconds) as f64
            + fractional,
    )
}

fn days_from_civil(year: i32, month: u32, day: u32) -> i64 {
    let year = year - i32::from(month <= 2);
    let era = if year >= 0 { year } else { year - 399 } / 400;
    let year_of_era = year - era * 400;
    let month = month as i32;
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day as i32 - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    i64::from(era) * 146_097 + i64::from(day_of_era) - 719_468
}

fn decode_jwt_claims(token: &str) -> serde_json::Map<String, serde_json::Value> {
    let payload = token.split('.').nth(1).unwrap_or_default();
    let Some(bytes) = decode_base64url(payload) else {
        return serde_json::Map::new();
    };
    serde_json::from_slice::<serde_json::Value>(&bytes)
        .ok()
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default()
}

fn decode_base64url(input: &str) -> Option<Vec<u8>> {
    let mut normalized = input
        .chars()
        .filter(|character| *character != '=')
        .map(|character| match character {
            '-' => '+',
            '_' => '/',
            other => other,
        })
        .collect::<String>();
    let remainder = normalized.len() % 4;
    if remainder != 0 {
        normalized.push_str(&"=".repeat(4 - remainder));
    }

    let mut output = Vec::new();
    for chunk in normalized.as_bytes().chunks(4) {
        if chunk.len() != 4 {
            return None;
        }
        let a = decode_base64_byte(chunk[0])?;
        let b = decode_base64_byte(chunk[1])?;
        output.push((a << 2) | (b >> 4));

        if chunk[2] != b'=' {
            let c = decode_base64_byte(chunk[2])?;
            output.push(((b & 0x0f) << 4) | (c >> 2));
            if chunk[3] != b'=' {
                let d = decode_base64_byte(chunk[3])?;
                output.push(((c & 0x03) << 6) | d);
            }
        }
    }

    Some(output)
}

fn decode_base64_byte(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
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

    fn empty_oauth_stored_account() -> OAuthStoredAccountInput {
        OAuthStoredAccountInput {
            id: String::new(),
            kind: "oauth_tokens".to_string(),
            label: String::new(),
            email: None,
            openai_account_id: None,
            access_token: None,
            refresh_token: None,
            id_token: None,
            expires_at: None,
            oauth_client_id: None,
            token_last_refresh_at: None,
            last_refresh: None,
            api_key: None,
            added_at: None,
            plan_type: None,
            primary_used_percent: None,
            secondary_used_percent: None,
            primary_reset_at: None,
            secondary_reset_at: None,
            primary_limit_window_seconds: None,
            secondary_limit_window_seconds: None,
            last_checked: None,
            is_suspended: None,
            token_expired: None,
            organization_name: None,
            interop_proxy_key: None,
            interop_notes: None,
            interop_concurrency: None,
            interop_priority: None,
            interop_rate_multiplier: None,
            interop_auto_pause_on_expired: None,
            interop_credentials_json: None,
            interop_extra_json: None,
        }
    }

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
        assert_eq!(
            provider.pinned_model_ids,
            vec!["anthropic/claude-3.7-sonnet"]
        );
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
        assert_eq!(
            result.active_provider_id.as_deref(),
            Some("openrouter-compat")
        );
        assert_eq!(
            result.switch_provider_id.as_deref(),
            Some("openrouter-compat")
        );
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
                plan_type: Some("plus".to_string()),
                token_expired: Some(true),
                ..empty_oauth_stored_account()
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
                    plan_type: Some("plus".to_string()),
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
                plan_type: Some("plus".to_string()),
                token_expired: Some(false),
                ..empty_oauth_stored_account()
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
                    plan_type: Some("plus".to_string()),
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
                plan_type: Some("plus".to_string()),
                token_expired: Some(false),
                ..empty_oauth_stored_account()
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
                    plan_type: Some("plus".to_string()),
                },
            },
            only_account_ids: vec![],
        });

        assert!(!result.changed);
        assert_eq!(result.matched_index, None);
        assert_eq!(result.updated_account, None);
    }

    #[test]
    fn normalize_shared_team_organization_names_propagates_single_trimmed_name() {
        let result =
            normalize_shared_team_organization_names(SharedTeamOrganizationNormalizationRequest {
                accounts: vec![
                    OAuthStoredAccountInput {
                        id: "user-first__acct_team_shared".to_string(),
                        kind: "oauth_tokens".to_string(),
                        label: "first-team@example.com".to_string(),
                        email: Some("first-team@example.com".to_string()),
                        openai_account_id: Some("acct_team_shared".to_string()),
                        access_token: None,
                        refresh_token: None,
                        id_token: None,
                        expires_at: None,
                        oauth_client_id: None,
                        token_last_refresh_at: None,
                        plan_type: Some("team".to_string()),
                        token_expired: Some(false),
                        organization_name: Some("  Acme Team  ".to_string()),
                        ..empty_oauth_stored_account()
                    },
                    OAuthStoredAccountInput {
                        id: "user-second__acct_team_shared".to_string(),
                        kind: "oauth_tokens".to_string(),
                        label: "second-team@example.com".to_string(),
                        email: Some("second-team@example.com".to_string()),
                        openai_account_id: Some("acct_team_shared".to_string()),
                        access_token: None,
                        refresh_token: None,
                        id_token: None,
                        expires_at: None,
                        oauth_client_id: None,
                        token_last_refresh_at: None,
                        plan_type: Some("team".to_string()),
                        token_expired: Some(false),
                        organization_name: None,
                        ..empty_oauth_stored_account()
                    },
                ],
            });

        assert!(result.changed);
        assert_eq!(
            result.accounts[0].organization_name.as_deref(),
            Some("Acme Team")
        );
        assert_eq!(
            result.accounts[1].organization_name.as_deref(),
            Some("Acme Team")
        );
    }

    #[test]
    fn normalize_shared_team_organization_names_keeps_conflicting_names_unchanged() {
        let result =
            normalize_shared_team_organization_names(SharedTeamOrganizationNormalizationRequest {
                accounts: vec![
                    OAuthStoredAccountInput {
                        id: "user-first__acct_team_conflict".to_string(),
                        kind: "oauth_tokens".to_string(),
                        label: "first-team@example.com".to_string(),
                        email: Some("first-team@example.com".to_string()),
                        openai_account_id: Some("acct_team_conflict".to_string()),
                        access_token: None,
                        refresh_token: None,
                        id_token: None,
                        expires_at: None,
                        oauth_client_id: None,
                        token_last_refresh_at: None,
                        plan_type: Some("team".to_string()),
                        token_expired: Some(false),
                        organization_name: Some("Acme Team".to_string()),
                        ..empty_oauth_stored_account()
                    },
                    OAuthStoredAccountInput {
                        id: "user-second__acct_team_conflict".to_string(),
                        kind: "oauth_tokens".to_string(),
                        label: "second-team@example.com".to_string(),
                        email: Some("second-team@example.com".to_string()),
                        openai_account_id: Some("acct_team_conflict".to_string()),
                        access_token: None,
                        refresh_token: None,
                        id_token: None,
                        expires_at: None,
                        oauth_client_id: None,
                        token_last_refresh_at: None,
                        plan_type: Some("team".to_string()),
                        token_expired: Some(false),
                        organization_name: Some("Other Team".to_string()),
                        ..empty_oauth_stored_account()
                    },
                ],
            });

        assert!(!result.changed);
        assert_eq!(
            result.accounts[0].organization_name.as_deref(),
            Some("Acme Team")
        );
        assert_eq!(
            result.accounts[1].organization_name.as_deref(),
            Some("Other Team")
        );
    }

    #[test]
    fn normalize_reserved_provider_ids_remaps_non_openrouter_provider_using_reserved_id() {
        let result = normalize_reserved_provider_ids(ReservedProviderIdNormalizationRequest {
            active_provider_id: Some("openrouter".to_string()),
            switch_provider_id: Some("openrouter".to_string()),
            providers: vec![
                ReservedProviderIdInput {
                    id: "openrouter".to_string(),
                    kind: "openai_compatible".to_string(),
                },
                ReservedProviderIdInput {
                    id: "openrouter-custom".to_string(),
                    kind: "openai_compatible".to_string(),
                },
            ],
        });

        assert!(result.changed);
        assert_eq!(result.providers[0].id, "openrouter-custom-2");
        assert_eq!(
            result.active_provider_id.as_deref(),
            Some("openrouter-custom-2")
        );
        assert_eq!(
            result.switch_provider_id.as_deref(),
            Some("openrouter-custom-2")
        );
    }

    #[test]
    fn parse_legacy_codex_toml_reads_global_values_and_explicit_base_url() {
        let result = parse_legacy_codex_toml(LegacyCodexTomlParseRequest {
            text: r#"
                model = "gpt-5.4"
                review_model = "gpt-5.4-mini"
                model_reasoning_effort = "high"
                openai_base_url = "https://gateway.example.com/v1"
                [model_providers.OpenAI]
                base_url = "https://ignored.example.com/v1"
            "#
            .to_string(),
        });

        assert_eq!(result.model.as_deref(), Some("gpt-5.4"));
        assert_eq!(result.review_model.as_deref(), Some("gpt-5.4-mini"));
        assert_eq!(result.reasoning_effort.as_deref(), Some("high"));
        assert_eq!(
            result.openai_base_url.as_deref(),
            Some("https://gateway.example.com/v1")
        );
    }

    #[test]
    fn parse_legacy_codex_toml_falls_back_to_openai_provider_block_base_url() {
        let result = parse_legacy_codex_toml(LegacyCodexTomlParseRequest {
            text: r#"
                model = "gpt-5.4"
                [model_providers.openai]
                name = "OpenAI"
                base_url = "https://provider.example.com/v1"
                [model_providers.other]
                base_url = "https://other.example.com/v1"
            "#
            .to_string(),
        });

        assert_eq!(
            result.openai_base_url.as_deref(),
            Some("https://provider.example.com/v1")
        );
    }

    #[test]
    fn parse_auth_json_snapshot_extracts_tokens_claims_and_last_refresh() {
        let access_token = "eyJhbGciOiJub25lIn0.eyJleHAiOjE3NjcxNjgwMDAuMCwiY2xpZW50X2lkIjoiYXBwX2F1dGhfY2xpZW50IiwiaHR0cHM6Ly9hcGkub3BlbmFpLmNvbS9hdXRoIjp7ImNoYXRncHRfYWNjb3VudF9pZCI6ImFjY3RfYXV0aCIsImNoYXRncHRfYWNjb3VudF91c2VyX2lkIjoidXNlci1hdXRoX19hY2N0X2F1dGgiLCJjaGF0Z3B0X3BsYW5fdHlwZSI6InRlYW0ifX0.";
        let id_token = "eyJhbGciOiJub25lIn0.eyJlbWFpbCI6ImF1dGhAZXhhbXBsZS5jb20ifQ.";
        let text = format!(
            r#"{{
                "last_refresh": "2024-03-09T16:00:00.000Z",
                "tokens": {{
                    "access_token": "{access_token}",
                    "refresh_token": "refresh-auth",
                    "id_token": "{id_token}",
                    "account_id": "acct_fallback"
                }}
            }}"#
        );
        let result = parse_auth_json_snapshot(AuthJsonSnapshotParseRequest { text });
        let snapshot = result.snapshot.expect("snapshot");

        assert_eq!(snapshot.local_account_id, "user-auth__acct_auth");
        assert_eq!(snapshot.remote_account_id, "acct_auth");
        assert_eq!(snapshot.email.as_deref(), Some("auth@example.com"));
        assert_eq!(snapshot.token_last_refresh_at, Some(1_710_000_000.0));
        assert_eq!(
            snapshot.account.oauth_client_id.as_deref(),
            Some("app_auth_client")
        );
        assert_eq!(snapshot.account.expires_at, Some(1_767_168_000.0));
        assert_eq!(snapshot.account.plan_type.as_deref(), Some("team"));
        assert!(result.openai_api_key.is_none());
    }

    #[test]
    fn parse_auth_json_snapshot_extracts_openai_api_key_without_tokens() {
        let result = parse_auth_json_snapshot(AuthJsonSnapshotParseRequest {
            text: r#"{"OPENAI_API_KEY":"sk-legacy"}"#.to_string(),
        });

        assert!(result.snapshot.is_none());
        assert_eq!(result.openai_api_key.as_deref(), Some("sk-legacy"));
    }

    #[test]
    fn parse_oauth_token_response_uses_fallback_refresh_and_id_tokens_when_missing() {
        let result = parse_oauth_token_response(OAuthTokenResponseParseRequest {
            body_text: r#"{"access_token":"access-new","client_id":"client-new"}"#.to_string(),
            fallback_refresh_token: Some("refresh-existing".to_string()),
            fallback_id_token: Some("id-existing".to_string()),
            fallback_client_id: Some("client-existing".to_string()),
        })
        .expect("result");

        assert_eq!(result.access_token, "access-new");
        assert_eq!(result.refresh_token, "refresh-existing");
        assert_eq!(result.id_token, "id-existing");
        assert_eq!(result.oauth_client_id.as_deref(), Some("client-new"));
    }

    #[test]
    fn parse_oauth_token_response_returns_server_error_message() {
        let error = parse_oauth_token_response(OAuthTokenResponseParseRequest {
            body_text: r#"{"error":"invalid_grant","error_description":"bad code"}"#.to_string(),
            fallback_refresh_token: None,
            fallback_id_token: None,
            fallback_client_id: None,
        })
        .expect_err("error");

        assert_eq!(error, "serverError: invalid_grant: bad code");
    }

    #[test]
    fn build_oauth_account_from_tokens_projects_claims_and_subscription_fallback() {
        let access_token = "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC1idWlsZCIsImNoYXRncHRfYWNjb3VudF91c2VyX2lkIjoidXNlci1idWlsZF9fYWNjdC1idWlsZCIsImNoYXRncHRfcGxhbl90eXBlIjoidGVhbSJ9LCJjbGllbnRfaWQiOiJhcHBfYnVpbGRfY2xpZW50In0.";
        let id_token = "eyJhbGciOiJub25lIn0.eyJlbWFpbCI6ImJ1aWxkQGV4YW1wbGUuY29tIiwiaHR0cHM6Ly9hcGkub3BlbmFpLmNvbS9hdXRoIjp7ImNoYXRncHRfc3Vic2NyaXB0aW9uX2FjdGl2ZV91bnRpbCI6IjIwMjYtMDQtMjZUMDA6MDA6MDAuMDAwWiJ9fQ.";

        let account = build_oauth_account_from_tokens(OAuthAccountBuildRequest {
            access_token: access_token.to_string(),
            refresh_token: "refresh-build".to_string(),
            id_token: id_token.to_string(),
            oauth_client_id: None,
            token_last_refresh_at: Some(1_777_000_000.0),
        });

        assert_eq!(account.local_account_id, "user-build__acct-build");
        assert_eq!(account.remote_account_id, "acct-build");
        assert_eq!(account.email, "build@example.com");
        assert_eq!(account.plan_type, "team");
        assert_eq!(account.oauth_client_id.as_deref(), Some("app_build_client"));
        assert_eq!(account.expires_at, Some(1_777_161_600.0));
        assert_eq!(account.token_last_refresh_at, Some(1_777_000_000.0));
    }

    #[test]
    fn refresh_oauth_account_from_tokens_preserves_usage_identity_and_org_fields() {
        let access_token = "eyJhbGciOiJub25lIn0.eyJleHAiOjE3OTAwMDAzNjAwLjAsImNsaWVudF9pZCI6ImFwcF9yZWZyZXNoX2NsaWVudCIsImh0dHBzOi8vYXBpLm9wZW5haS5jb20vYXV0aCI6eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0LXJlZnJlc2giLCJjaGF0Z3B0X3BsYW5fdHlwZSI6ImZyZWUifX0.";
        let id_token = "eyJhbGciOiJub25lIn0.e30.";
        let refreshed = refresh_oauth_account_from_tokens(RefreshOAuthAccountFromTokensRequest {
            current_account: CanonicalAccountSnapshot {
                local_account_id: "user-refresh__acct-refresh".to_string(),
                remote_account_id: "acct-refresh".to_string(),
                email: "refresh@example.com".to_string(),
                access_token: "access-old".to_string(),
                refresh_token: "refresh-old".to_string(),
                id_token: "id-old".to_string(),
                expires_at: Some(1_788_000_000.0),
                oauth_client_id: Some("app_current_client".to_string()),
                plan_type: "team".to_string(),
                primary_used_percent: 87.0,
                secondary_used_percent: 41.0,
                primary_reset_at: Some(1_788_100_000.0),
                secondary_reset_at: Some(1_788_200_000.0),
                primary_limit_window_seconds: Some(18_000),
                secondary_limit_window_seconds: Some(604_800),
                last_checked: Some(1_788_050_000.0),
                is_active: true,
                is_suspended: true,
                token_expired: true,
                token_last_refresh_at: Some(1_788_040_000.0),
                organization_name: Some("Acme Team".to_string()),
                quota_exhausted: false,
                is_available_for_next_use_routing: false,
                is_degraded_for_next_use_routing: false,
            },
            access_token: access_token.to_string(),
            refresh_token: "refresh-new".to_string(),
            id_token: id_token.to_string(),
            oauth_client_id: Some("app_refresh_client".to_string()),
            token_last_refresh_at: Some(1_789_000_000.0),
        });

        assert_eq!(refreshed.local_account_id, "user-refresh__acct-refresh");
        assert_eq!(refreshed.remote_account_id, "acct-refresh");
        assert_eq!(refreshed.email, "refresh@example.com");
        assert_eq!(refreshed.plan_type, "team");
        assert_eq!(refreshed.primary_used_percent, 87.0);
        assert_eq!(refreshed.secondary_used_percent, 41.0);
        assert_eq!(refreshed.primary_reset_at, Some(1_788_100_000.0));
        assert_eq!(refreshed.secondary_reset_at, Some(1_788_200_000.0));
        assert_eq!(refreshed.last_checked, Some(1_788_050_000.0));
        assert_eq!(refreshed.organization_name.as_deref(), Some("Acme Team"));
        assert!(refreshed.is_active);
        assert!(!refreshed.is_suspended);
        assert!(!refreshed.token_expired);
        assert_eq!(refreshed.oauth_client_id.as_deref(), Some("app_refresh_client"));
        assert_eq!(refreshed.token_last_refresh_at, Some(1_789_000_000.0));
    }

    #[test]
    fn inspect_oauth_token_metadata_reads_profile_user_client_and_org_ids() {
        let access_token = "eyJhbGciOiJub25lIn0.eyJjbGllbnRfaWQiOiJhcHBfbWV0YV9jbGllbnQiLCJodHRwczovL2FwaS5vcGVuYWkuY29tL3Byb2ZpbGUiOnsiZW1haWwiOiJwcm9maWxlQGV4YW1wbGUuY29tIn0sImh0dHBzOi8vYXBpLm9wZW5haS5jb20vYXV0aCI6eyJjaGF0Z3B0X3VzZXJfaWQiOiJ1c2VyLW1ldGEiLCJvcmdhbml6YXRpb25faWQiOiJvcmdfYWNjZXNzIn19.";
        let id_token = "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsib3JnYW5pemF0aW9uX2lkIjoib3JnX2lkIn19.";

        let result = inspect_oauth_token_metadata(OAuthTokenMetadataRequest {
            access_token: access_token.to_string(),
            id_token: Some(id_token.to_string()),
        });

        assert_eq!(result.profile_email.as_deref(), Some("profile@example.com"));
        assert_eq!(result.chatgpt_user_id.as_deref(), Some("user-meta"));
        assert_eq!(result.oauth_client_id.as_deref(), Some("app_meta_client"));
        assert_eq!(result.organization_id.as_deref(), Some("org_access"));
    }

    #[test]
    fn parse_provider_secrets_env_reads_export_lines_and_unquotes_values() {
        let result = parse_provider_secrets_env(ProviderSecretsEnvParseRequest {
            text: r#"
                export OPENAI_API_KEY="sk-openai"
                export S_OAI_KEY='sk-s'
                export HTJ_OAI_KEY=sk-htj
                ignored=1
            "#
            .to_string(),
        });

        assert_eq!(result.values.get("OPENAI_API_KEY").map(String::as_str), Some("sk-openai"));
        assert_eq!(result.values.get("S_OAI_KEY").map(String::as_str), Some("sk-s"));
        assert_eq!(result.values.get("HTJ_OAI_KEY").map(String::as_str), Some("sk-htj"));
        assert!(!result.values.contains_key("ignored"));
    }

    #[test]
    fn merge_interop_proxies_json_replaces_duplicate_proxy_key_and_keeps_other_entries() {
        let result = merge_interop_proxies_json(InteropProxyMergeRequest {
            existing_json: Some(
                r#"[{"proxy_key":"http|127.0.0.1|7890||","name":"old","port":7890},{"proxy_key":"http|127.0.0.1|8888||","name":"keep","port":8888}]"#
                    .to_string(),
            ),
            incoming_json: Some(
                r#"[{"proxy_key":"http|127.0.0.1|7890||","name":"new","port":9999}]"#
                    .to_string(),
            ),
        });

        let merged = serde_json::from_str::<serde_json::Value>(
            result.merged_json.as_deref().unwrap_or("null"),
        )
        .unwrap();
        let items = merged.as_array().unwrap();
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].get("name").and_then(|value| value.as_str()), Some("new"));
        assert_eq!(items[0].get("port").and_then(|value| value.as_i64()), Some(9999));
        assert_eq!(items[1].get("name").and_then(|value| value.as_str()), Some("keep"));
    }

    #[test]
    fn render_oauth_interop_export_accounts_projects_metadata_and_proxy_key() {
        let result = render_oauth_interop_export_accounts(OAuthInteropExportRequest {
            accounts: vec![OAuthInteropExportAccountInput {
                account_id: "acct_active".to_string(),
                remote_account_id: "acct_remote".to_string(),
                email: "active@example.com".to_string(),
                access_token: "access-token".to_string(),
                refresh_token: "refresh-token".to_string(),
                id_token: "id-token".to_string(),
                expires_at: Some(1_777_682_631.0),
                oauth_client_id: Some("app_active_client".to_string()),
                plan_type: "plus".to_string(),
            }],
            metadata_entries: vec![OAuthInteropMetadataEntry {
                account_id: "acct_active".to_string(),
                proxy_key: Some("http|127.0.0.1|7890||".to_string()),
                notes: Some("primary".to_string()),
                concurrency: Some(10),
                priority: Some(1),
                rate_multiplier: Some(1.0),
                auto_pause_on_expired: Some(true),
                credentials_json: Some(r#"{"privacy_mode":"training_off"}"#.to_string()),
                extra_json: Some(r#"{"privacy_mode":"training_off"}"#.to_string()),
            }],
            available_proxy_keys: vec!["http|127.0.0.1|7890||".to_string()],
        });

        let payload = serde_json::from_str::<serde_json::Value>(&result.accounts_payload).unwrap();
        let accounts = payload.as_array().unwrap();
        assert_eq!(accounts.len(), 1);
        let account = accounts[0].as_object().unwrap();
        assert_eq!(account.get("platform").and_then(|value| value.as_str()), Some("openai"));
        assert_eq!(account.get("type").and_then(|value| value.as_str()), Some("oauth"));
        assert_eq!(
            account.get("proxy_key").and_then(|value| value.as_str()),
            Some("http|127.0.0.1|7890||")
        );
        let credentials = account.get("credentials").and_then(|value| value.as_object()).unwrap();
        assert_eq!(
            credentials.get("client_id").and_then(|value| value.as_str()),
            Some("app_active_client")
        );
        assert_eq!(
            credentials.get("chatgpt_account_id").and_then(|value| value.as_str()),
            Some("acct_remote")
        );
        let extra = account.get("extra").and_then(|value| value.as_object()).unwrap();
        assert_eq!(
            extra.get("privacy_mode").and_then(|value| value.as_str()),
            Some("training_off")
        );
        assert_eq!(account.get("notes").and_then(|value| value.as_str()), Some("primary"));
    }

    #[test]
    fn parse_wham_usage_reads_plus_primary_and_secondary_windows() {
        let result = parse_wham_usage(WhamUsageParseRequest {
            body_json: serde_json::json!({
                "plan_type": "plus",
                "rate_limit": {
                    "primary_window": {
                        "used_percent": 0.0,
                        "limit_window_seconds": 18_000,
                        "reset_at": 1_775_372_003.0
                    },
                    "secondary_window": {
                        "used_percent": 100.0,
                        "limit_window_seconds": 604_800,
                        "reset_at": 1_775_690_771.0
                    }
                }
            }),
        });

        assert_eq!(result.plan_type, "plus");
        assert_eq!(result.primary_limit_window_seconds, Some(18_000));
        assert_eq!(result.secondary_limit_window_seconds, Some(604_800));
        assert_eq!(result.primary_used_percent, 0.0);
        assert_eq!(result.secondary_used_percent, 100.0);
        assert_eq!(result.primary_reset_at, Some(1_775_372_003.0));
        assert_eq!(result.secondary_reset_at, Some(1_775_690_771.0));
    }

    #[test]
    fn parse_wham_usage_defaults_free_and_treats_null_secondary_window_as_missing() {
        let result = parse_wham_usage(WhamUsageParseRequest {
            body_json: serde_json::json!({
                "rate_limit": {
                    "primary_window": {
                        "used_percent": 100.0,
                        "limit_window_seconds": 604_800,
                        "reset_at": 1_775_860_349.0
                    },
                    "secondary_window": serde_json::Value::Null
                }
            }),
        });

        assert_eq!(result.plan_type, "free");
        assert_eq!(result.primary_limit_window_seconds, Some(604_800));
        assert_eq!(result.secondary_limit_window_seconds, None);
        assert_eq!(result.primary_used_percent, 100.0);
        assert_eq!(result.secondary_used_percent, 0.0);
        assert_eq!(result.secondary_reset_at, None);
    }

    #[test]
    fn parse_wham_usage_preserves_secondary_window_when_usage_is_zero_and_seconds_are_float() {
        let result = parse_wham_usage(WhamUsageParseRequest {
            body_json: serde_json::json!({
                "plan_type": "plus",
                "rate_limit": {
                    "primary_window": {
                        "used_percent": 0.0,
                        "limit_window_seconds": 18_000.0,
                        "reset_at": 1_775_372_003.0
                    },
                    "secondary_window": {
                        "used_percent": 0.0,
                        "limit_window_seconds": 604_800.0,
                        "reset_at": 1_775_690_771.0
                    }
                }
            }),
        });

        assert_eq!(result.secondary_limit_window_seconds, Some(604_800));
        assert_eq!(result.secondary_used_percent, 0.0);
        assert_eq!(result.secondary_reset_at, Some(1_775_690_771.0));
    }

    #[test]
    fn resolve_legacy_migration_active_selection_prefers_matching_base_url_then_oauth_then_api_key() {
        let by_base_url = resolve_legacy_migration_active_selection(
            LegacyMigrationActiveSelectionRequest {
                openai_base_url: Some("https://gateway.example.com/v1".to_string()),
                has_openai_api_key: false,
                auth_snapshot_local_account_id: None,
                auth_snapshot_remote_account_id: None,
                providers: vec![
                    LegacyMigrationProviderInput {
                        id: "compat".to_string(),
                        kind: OPENAI_COMPATIBLE_KIND.to_string(),
                        base_url: Some("https://gateway.example.com/v1".to_string()),
                        active_account_id: Some("acct-compat".to_string()),
                        accounts: vec![LegacyMigrationProviderAccountInput {
                            id: "acct-compat".to_string(),
                            openai_account_id: None,
                        }],
                    },
                ],
            },
        );
        assert_eq!(by_base_url.provider_id.as_deref(), Some("compat"));
        assert_eq!(by_base_url.account_id.as_deref(), Some("acct-compat"));

        let by_oauth_snapshot = resolve_legacy_migration_active_selection(
            LegacyMigrationActiveSelectionRequest {
                openai_base_url: None,
                has_openai_api_key: false,
                auth_snapshot_local_account_id: Some("user-1__acct-oauth".to_string()),
                auth_snapshot_remote_account_id: Some("acct-oauth".to_string()),
                providers: vec![LegacyMigrationProviderInput {
                    id: "openai-oauth".to_string(),
                    kind: "openai_oauth".to_string(),
                    base_url: None,
                    active_account_id: Some("user-1__acct-oauth".to_string()),
                    accounts: vec![LegacyMigrationProviderAccountInput {
                        id: "user-1__acct-oauth".to_string(),
                        openai_account_id: Some("acct-oauth".to_string()),
                    }],
                }],
            },
        );
        assert_eq!(by_oauth_snapshot.provider_id.as_deref(), Some("openai-oauth"));
        assert_eq!(by_oauth_snapshot.account_id.as_deref(), Some("user-1__acct-oauth"));

        let by_api_key = resolve_legacy_migration_active_selection(
            LegacyMigrationActiveSelectionRequest {
                openai_base_url: None,
                has_openai_api_key: true,
                auth_snapshot_local_account_id: None,
                auth_snapshot_remote_account_id: None,
                providers: vec![LegacyMigrationProviderInput {
                    id: "imported".to_string(),
                    kind: OPENAI_COMPATIBLE_KIND.to_string(),
                    base_url: Some("https://api.openai.com/v1".to_string()),
                    active_account_id: Some("acct-imported".to_string()),
                    accounts: vec![LegacyMigrationProviderAccountInput {
                        id: "acct-imported".to_string(),
                        openai_account_id: None,
                    }],
                }],
            },
        );
        assert_eq!(by_api_key.provider_id.as_deref(), Some("imported"));
        assert_eq!(by_api_key.account_id.as_deref(), Some("acct-imported"));
    }

    #[test]
    fn resolve_legacy_migration_active_selection_falls_back_to_first_provider() {
        let result = resolve_legacy_migration_active_selection(
            LegacyMigrationActiveSelectionRequest {
                openai_base_url: None,
                has_openai_api_key: false,
                auth_snapshot_local_account_id: None,
                auth_snapshot_remote_account_id: None,
                providers: vec![
                    LegacyMigrationProviderInput {
                        id: "first".to_string(),
                        kind: OPENAI_COMPATIBLE_KIND.to_string(),
                        base_url: Some("https://api.example.com/v1".to_string()),
                        active_account_id: Some("acct-first".to_string()),
                        accounts: vec![LegacyMigrationProviderAccountInput {
                            id: "acct-first".to_string(),
                            openai_account_id: None,
                        }],
                    },
                    LegacyMigrationProviderInput {
                        id: "second".to_string(),
                        kind: OPENAI_COMPATIBLE_KIND.to_string(),
                        base_url: Some("https://api.second.example/v1".to_string()),
                        active_account_id: Some("acct-second".to_string()),
                        accounts: vec![LegacyMigrationProviderAccountInput {
                            id: "acct-second".to_string(),
                            openai_account_id: None,
                        }],
                    },
                ],
            },
        );

        assert_eq!(result.provider_id.as_deref(), Some("first"));
        assert_eq!(result.account_id.as_deref(), Some("acct-first"));
    }

    #[test]
    fn plan_legacy_imported_provider_normalizes_url_and_skips_duplicate_base_url() {
        let created = plan_legacy_imported_provider(LegacyImportedProviderPlanRequest {
            base_url: Some("https://openrouter.ai/api/v1".to_string()),
            api_key: "sk-test".to_string(),
            existing_base_urls: vec!["https://other.example/v1".to_string()],
        });

        assert!(created.should_create);
        assert_eq!(created.provider_id.as_deref(), Some("openrouter-ai"));
        assert_eq!(created.label.as_deref(), Some("openrouter.ai"));
        assert_eq!(
            created.normalized_base_url.as_deref(),
            Some("https://openrouter.ai/api/v1")
        );
        assert_eq!(created.account_label.as_deref(), Some("Imported"));

        let skipped = plan_legacy_imported_provider(LegacyImportedProviderPlanRequest {
            base_url: Some("https://openrouter.ai/api/v1".to_string()),
            api_key: "sk-test".to_string(),
            existing_base_urls: vec!["https://openrouter.ai/api/v1".to_string()],
        });

        assert!(!skipped.should_create);
        assert!(skipped.provider_id.is_none());
    }

    #[test]
    fn normalize_oauth_account_identities_remaps_local_id_and_merges_duplicates() {
        let access_token = "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdC1zaGFyZWQiLCJjaGF0Z3B0X2FjY291bnRfdXNlcl9pZCI6InVzZXItMV9fYWNjdC1zaGFyZWQifX0.";
        let result = normalize_oauth_account_identities(OAuthIdentityNormalizationRequest {
            accounts: vec![
                OAuthStoredAccountInput {
                    id: "acct-shared".to_string(),
                    kind: "oauth_tokens".to_string(),
                    label: "first@example.com".to_string(),
                    email: Some("first@example.com".to_string()),
                    openai_account_id: Some("acct-shared".to_string()),
                    access_token: Some(access_token.to_string()),
                    refresh_token: Some("refresh".to_string()),
                    id_token: Some("id".to_string()),
                    plan_type: Some("team".to_string()),
                    ..empty_oauth_stored_account()
                },
                OAuthStoredAccountInput {
                    id: "user-1__acct-shared".to_string(),
                    kind: "oauth_tokens".to_string(),
                    label: "duplicate@example.com".to_string(),
                    email: None,
                    openai_account_id: Some("acct-shared".to_string()),
                    access_token: Some(access_token.to_string()),
                    refresh_token: Some("refresh-2".to_string()),
                    id_token: Some("id-2".to_string()),
                    token_last_refresh_at: Some(1_710_000_000.0),
                    ..empty_oauth_stored_account()
                },
            ],
        });

        assert!(result.changed);
        assert_eq!(
            result.migrated_account_ids.get("acct-shared").map(String::as_str),
            Some("user-1__acct-shared")
        );
        assert_eq!(result.accounts.len(), 1);
        assert_eq!(result.accounts[0].id, "user-1__acct-shared");
        assert_eq!(result.accounts[0].label, "first@example.com");
        assert_eq!(result.accounts[0].token_last_refresh_at, Some(1_710_000_000.0));
    }

    #[test]
    fn sanitize_oauth_quota_snapshots_clamps_reset_into_window() {
        let result = sanitize_oauth_quota_snapshots(OAuthQuotaSnapshotSanitizationRequest {
            now: 1_700_000_000.0,
            accounts: vec![OAuthStoredAccountInput {
                id: "acct-over-window".to_string(),
                kind: "oauth_tokens".to_string(),
                label: "over-window@example.com".to_string(),
                email: Some("over-window@example.com".to_string()),
                openai_account_id: Some("acct-over-window".to_string()),
                access_token: Some("token".to_string()),
                refresh_token: Some("refresh".to_string()),
                id_token: Some("id".to_string()),
                plan_type: Some("plus".to_string()),
                primary_used_percent: Some(80.0),
                secondary_used_percent: Some(0.0),
                primary_reset_at: Some(1_700_000_000.0 + 8.0 * 3_600.0),
                primary_limit_window_seconds: Some(18_000),
                last_checked: Some(1_700_000_000.0),
                ..empty_oauth_stored_account()
            }],
        });

        assert!(result.changed);
        assert_eq!(result.accounts[0].primary_reset_at, Some(1_700_000_000.0 + 5.0 * 3_600.0));
    }

    #[test]
    fn assemble_oauth_provider_merges_token_pool_and_auth_snapshot() {
        let result = assemble_oauth_provider(OAuthProviderAssemblyRequest {
            imported_accounts: vec![OAuthStoredAccountInput {
                id: "acct-existing".to_string(),
                kind: "oauth_tokens".to_string(),
                label: "existing@example.com".to_string(),
                email: Some("existing@example.com".to_string()),
                openai_account_id: Some("acct-existing".to_string()),
                access_token: Some("token-existing".to_string()),
                refresh_token: Some("refresh-existing".to_string()),
                id_token: Some("id-existing".to_string()),
                ..empty_oauth_stored_account()
            }],
            snapshot: Some(AuthJsonSnapshotInput {
                local_account_id: "user-import__acct-import".to_string(),
                remote_account_id: "acct-import".to_string(),
                email: Some("import@example.com".to_string()),
                token_last_refresh_at: Some(1_720_000_000.0),
                account: AuthJsonSnapshotAccountInput {
                    access_token: "token-import".to_string(),
                    refresh_token: "refresh-import".to_string(),
                    id_token: "id-import".to_string(),
                    expires_at: Some(1_720_003_600.0),
                    oauth_client_id: Some("app-import-client".to_string()),
                    token_last_refresh_at: Some(1_720_000_000.0),
                    plan_type: Some("team".to_string()),
                },
            }),
        });

        assert!(result.should_create);
        assert_eq!(result.active_account_id.as_deref(), Some("acct-existing"));
        assert_eq!(result.accounts.len(), 2);
        assert_eq!(result.accounts[1].id, "user-import__acct-import");
        assert_eq!(result.accounts[1].openai_account_id.as_deref(), Some("acct-import"));
        assert_eq!(result.accounts[1].oauth_client_id.as_deref(), Some("app-import-client"));
    }

    #[test]
    fn refresh_oauth_account_metadata_backfills_missing_fields_from_tokens() {
        let access_token = "eyJhbGciOiJub25lIn0.eyJleHAiOjE3NjcxNjgwMDAuMCwiY2xpZW50X2lkIjoiYXBwX3JvdW5kdHJpcF9jbGllbnQiLCJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdF9tZXRhZGF0YSIsImNoYXRncHRfYWNjb3VudF91c2VyX2lkIjoidXNlci1tZXRhZGF0YV9fYWNjdF9tZXRhZGF0YSJ9fQ.";
        let id_token = "eyJhbGciOiJub25lIn0.eyJlbWFpbCI6Im1ldGFkYXRhQGV4YW1wbGUuY29tIn0.";
        let result = refresh_oauth_account_metadata(OAuthMetadataRefreshRequest {
            accounts: vec![OAuthStoredAccountInput {
                id: "user-metadata__acct_metadata".to_string(),
                kind: "oauth_tokens".to_string(),
                label: "metadata@example.com".to_string(),
                email: None,
                openai_account_id: None,
                access_token: Some(access_token.to_string()),
                refresh_token: Some("refresh-acct_metadata".to_string()),
                id_token: Some(id_token.to_string()),
                expires_at: None,
                oauth_client_id: None,
                token_last_refresh_at: None,
                last_refresh: Some(1_710_000_000.0),
                api_key: None,
                plan_type: Some("plus".to_string()),
                primary_used_percent: Some(12.0),
                secondary_used_percent: Some(34.0),
                primary_reset_at: Some(1_720_000_000.0),
                secondary_reset_at: Some(1_720_000_123.0),
                primary_limit_window_seconds: Some(3600),
                secondary_limit_window_seconds: Some(86400),
                last_checked: Some(1_719_999_999.0),
                is_suspended: Some(false),
                token_expired: Some(false),
                organization_name: None,
                interop_proxy_key: Some("http|127.0.0.1|7890||".to_string()),
                interop_notes: Some("imported".to_string()),
                interop_concurrency: Some(10),
                interop_priority: Some(1),
                interop_rate_multiplier: Some(1.0),
                interop_auto_pause_on_expired: Some(true),
                interop_credentials_json: Some(
                    "{\"client_id\":\"app_roundtrip_client\"}".to_string(),
                ),
                interop_extra_json: Some("{\"privacy_mode\":\"training_off\"}".to_string()),
                ..empty_oauth_stored_account()
            }],
        });

        assert!(result.changed);
        let account = &result.accounts[0];
        assert_eq!(account.email.as_deref(), Some("metadata@example.com"));
        assert_eq!(account.openai_account_id.as_deref(), Some("acct_metadata"));
        assert_eq!(
            account.oauth_client_id.as_deref(),
            Some("app_roundtrip_client")
        );
        assert_eq!(account.expires_at, Some(1_767_168_000.0));
        assert_eq!(account.token_last_refresh_at, Some(1_710_000_000.0));
        assert_eq!(
            account.interop_proxy_key.as_deref(),
            Some("http|127.0.0.1|7890||")
        );
        assert_eq!(account.primary_limit_window_seconds, Some(3600));
        assert_eq!(account.interop_auto_pause_on_expired, Some(true));
    }
}
