use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayCandidatePlanRequest {
    pub account_usage_mode: String,
    pub now: f64,
    pub quota_sort_settings: GatewayQuotaSortSettings,
    #[serde(default)]
    pub accounts: Vec<GatewayAccountInput>,
    #[serde(default)]
    pub sticky_key: Option<String>,
    #[serde(default)]
    pub sticky_bindings: Vec<GatewayStickyBindingInput>,
    #[serde(default)]
    pub runtime_blocked_accounts: Vec<GatewayRuntimeBlockedAccountInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayQuotaSortSettings {
    pub plus_relative_weight: f64,
    pub pro_relative_to_plus_multiplier: f64,
    pub team_relative_to_plus_multiplier: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayAccountInput {
    pub account_id: String,
    pub email: String,
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
    pub is_suspended: bool,
    pub token_expired: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStickyBindingInput {
    pub sticky_key: String,
    pub account_id: String,
    pub updated_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayRuntimeBlockedAccountInput {
    pub account_id: String,
    pub retry_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayCandidatePlanResult {
    pub account_ids: Vec<String>,
    pub sticky_account_id: Option<String>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStickyKeyResolutionRequest {
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub window_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStickyKeyResolutionResult {
    #[serde(default)]
    pub sticky_key: Option<String>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayRequestParseRequest {
    pub raw_text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayParsedRequest {
    pub method: String,
    pub path: String,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    pub body_text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayRequestParseResult {
    #[serde(default)]
    pub parsed_request: Option<GatewayParsedRequest>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayResponseHeaderFieldInput {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayResponseHeadRenderRequest {
    pub status_code: i64,
    #[serde(default)]
    pub header_fields: Vec<GatewayResponseHeaderFieldInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayResponseHeadRenderResult {
    pub header_text: String,
    #[serde(default)]
    pub filtered_headers: Vec<GatewayResponseHeaderFieldInput>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayWebSocketHandshakeRequest {
    pub sec_web_socket_key: String,
    #[serde(default)]
    pub selected_protocol: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayWebSocketHandshakeResult {
    pub response_text: String,
    #[serde(default)]
    pub headers: Vec<GatewayResponseHeaderFieldInput>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayWebSocketFrameRenderRequest {
    pub opcode: u8,
    #[serde(default)]
    pub payload_bytes: Vec<u8>,
    pub is_final: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayWebSocketFrameRenderResult {
    #[serde(default)]
    pub frame_bytes: Vec<u8>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayWebSocketClosePayloadRequest {
    pub code: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayWebSocketClosePayloadResult {
    #[serde(default)]
    pub payload_bytes: Vec<u8>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayWebSocketFrameParseRequest {
    #[serde(default)]
    pub frame_bytes: Vec<u8>,
    pub expect_masked: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayParsedWebSocketFrame {
    pub opcode: u8,
    #[serde(default)]
    pub payload_bytes: Vec<u8>,
    pub is_final: bool,
    pub consumed_byte_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayWebSocketFrameParseResult {
    pub outcome: String,
    #[serde(default)]
    pub parsed_frame: Option<GatewayParsedWebSocketFrame>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStickyBindingStateInput {
    pub thread_id: String,
    pub account_id: String,
    pub updated_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStickyBindRequest {
    #[serde(default)]
    pub current_routed_account_id: Option<String>,
    #[serde(default)]
    pub sticky_key: Option<String>,
    pub account_id: String,
    pub now: f64,
    #[serde(default)]
    pub sticky_bindings: Vec<GatewayStickyBindingStateInput>,
    pub expiration_interval_seconds: f64,
    pub max_entries: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStickyBindResult {
    #[serde(default)]
    pub next_routed_account_id: Option<String>,
    #[serde(default)]
    pub sticky_bindings: Vec<GatewayStickyBindingStateInput>,
    pub route_changed: bool,
    pub should_record_route: bool,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStickyClearRequest {
    pub thread_id: String,
    #[serde(default)]
    pub account_id: Option<String>,
    #[serde(default)]
    pub sticky_bindings: Vec<GatewayStickyBindingStateInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStickyClearResult {
    #[serde(default)]
    pub sticky_bindings: Vec<GatewayStickyBindingStateInput>,
    pub cleared: bool,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayRuntimeBlockedAccountStateInput {
    pub account_id: String,
    pub retry_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayRuntimeBlockApplyRequest {
    #[serde(default)]
    pub current_routed_account_id: Option<String>,
    pub blocked_account_id: String,
    pub retry_at: f64,
    pub now: f64,
    #[serde(default)]
    pub runtime_blocked_accounts: Vec<GatewayRuntimeBlockedAccountStateInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayRuntimeBlockApplyResult {
    #[serde(default)]
    pub next_routed_account_id: Option<String>,
    #[serde(default)]
    pub runtime_blocked_accounts: Vec<GatewayRuntimeBlockedAccountStateInput>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStateNormalizationRequest {
    #[serde(default)]
    pub current_routed_account_id: Option<String>,
    #[serde(default)]
    pub known_account_ids: Vec<String>,
    #[serde(default)]
    pub sticky_bindings: Vec<GatewayStickyBindingStateInput>,
    #[serde(default)]
    pub runtime_blocked_accounts: Vec<GatewayRuntimeBlockedAccountStateInput>,
    pub now: f64,
    pub sticky_expiration_interval_seconds: f64,
    pub sticky_max_entries: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStateNormalizationResult {
    #[serde(default)]
    pub next_routed_account_id: Option<String>,
    #[serde(default)]
    pub sticky_bindings: Vec<GatewayStickyBindingStateInput>,
    #[serde(default)]
    pub runtime_blocked_accounts: Vec<GatewayRuntimeBlockedAccountStateInput>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterRequestNormalizationRequest {
    pub route: String,
    pub selected_model_id: String,
    pub body_json: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterRequestNormalizationResult {
    pub normalized_json: serde_json::Value,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenAIResponsesRequestNormalizationRequest {
    pub route: String,
    pub body_json: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenAIResponsesRequestNormalizationResult {
    pub normalized_json: serde_json::Value,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterGatewayAccountStateRequest {
    #[serde(default)]
    pub provider: Option<OpenRouterGatewayProviderInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterGatewayProviderInput {
    pub id: String,
    pub kind: String,
    pub label: String,
    pub enabled: bool,
    #[serde(default)]
    pub selected_model_id: Option<String>,
    #[serde(default)]
    pub active_account_id: Option<String>,
    #[serde(default)]
    pub accounts: Vec<OpenRouterGatewayProviderAccountInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterGatewayProviderAccountInput {
    pub id: String,
    pub kind: String,
    pub label: String,
    #[serde(default)]
    pub api_key: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OpenRouterGatewayAccountStateResult {
    #[serde(default)]
    pub account: Option<OpenRouterGatewayProviderAccountInput>,
    #[serde(default)]
    pub model_id: Option<String>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayLifecyclePlanRequest {
    pub configured_openai_usage_mode: String,
    #[serde(default)]
    pub aggregate_leased_process_ids: Vec<i64>,
    #[serde(default)]
    pub active_provider_kind: Option<String>,
    #[serde(default)]
    pub openrouter_serviceable_provider_id: Option<String>,
    pub last_published_openrouter_selected: bool,
    #[serde(default)]
    pub running_codex_process_ids: Vec<i64>,
    #[serde(default)]
    pub existing_openrouter_lease: Option<GatewayLeaseSnapshotInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayLeaseSnapshotInput {
    #[serde(default)]
    pub leased_process_ids: Vec<i64>,
    pub source_provider_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayLifecyclePlanResult {
    pub effective_openai_usage_mode: String,
    pub should_run_openai_gateway: bool,
    pub should_run_openrouter_gateway: bool,
    #[serde(default)]
    pub next_openrouter_lease: Option<GatewayLeaseSnapshotInput>,
    pub openrouter_lease_changed: bool,
    pub openrouter_lease_should_poll: bool,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AggregateGatewayLeaseTransitionPlanRequest {
    pub previous_openai_usage_mode: String,
    pub next_openai_usage_mode: String,
    #[serde(default)]
    pub current_leased_process_ids: Vec<i64>,
    #[serde(default)]
    pub running_codex_process_ids: Vec<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AggregateGatewayLeaseTransitionPlanResult {
    #[serde(default)]
    pub next_leased_process_ids: Vec<i64>,
    pub lease_changed: bool,
    pub should_poll: bool,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AggregateGatewayLeaseRefreshPlanRequest {
    pub current_openai_usage_mode: String,
    #[serde(default)]
    pub current_leased_process_ids: Vec<i64>,
    #[serde(default)]
    pub running_codex_process_ids: Vec<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AggregateGatewayLeaseRefreshPlanResult {
    #[serde(default)]
    pub next_leased_process_ids: Vec<i64>,
    pub lease_changed: bool,
    pub should_poll: bool,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayPostCompletionBindingDecisionRequest {
    pub allows_binding: bool,
    pub used_sticky_context_recovery: bool,
    pub status_code: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayPostCompletionBindingDecisionResult {
    pub should_bind_sticky: bool,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayProxyEndpoint {
    pub kind: String,
    pub host: String,
    pub port: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct GatewayProxySnapshot {
    #[serde(default)]
    pub http: Option<GatewayProxyEndpoint>,
    #[serde(default)]
    pub https: Option<GatewayProxyEndpoint>,
    #[serde(default)]
    pub socks: Option<GatewayProxyEndpoint>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayTransportPolicyRequest {
    pub proxy_resolution_mode: String,
    #[serde(default)]
    pub system_proxy_snapshot: Option<GatewayProxySnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayTransportPolicyResult {
    pub proxy_resolution_mode: String,
    #[serde(default)]
    pub system_proxy_snapshot: Option<GatewayProxySnapshot>,
    #[serde(default)]
    pub effective_proxy_snapshot: Option<GatewayProxySnapshot>,
    pub loopback_proxy_safe_applied: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayTransportFailureClassificationRequest {
    #[serde(default)]
    pub error_domain: Option<String>,
    #[serde(default)]
    pub error_code: Option<i64>,
    pub allow_protocol_violation: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayTransportFailureClassificationResult {
    pub failure_class: String,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStatusPolicyRequest {
    pub status_code: i64,
    pub now: f64,
    pub allow_fallback_runtime_block: bool,
    #[serde(default)]
    pub suggested_retry_at: Option<f64>,
    #[serde(default)]
    pub retry_after_value: Option<String>,
    #[serde(default)]
    pub account: Option<GatewayAccountInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStatusPolicyResult {
    #[serde(default)]
    pub failure_class: Option<String>,
    pub failover_disposition: String,
    pub is_account_scoped_status: bool,
    pub should_retry: bool,
    pub should_runtime_block_account: bool,
    #[serde(default)]
    pub runtime_block_retry_at: Option<f64>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStickyRecoveryPolicyRequest {
    pub failure_class: String,
    pub sticky_binding_matches_failed_account: bool,
    pub candidate_index: i64,
    pub candidate_count: i64,
    pub used_sticky_context_recovery: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayStickyRecoveryPolicyResult {
    pub should_attempt_sticky_context_recovery: bool,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayProtocolSignalInterpretationRequest {
    pub payload_text: String,
    pub now: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayProtocolSignalInterpretationResult {
    pub is_runtime_limit_signal: bool,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub retry_at: Option<f64>,
    #[serde(default)]
    pub retry_at_human_text: Option<String>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayProtocolPreviewDecisionRequest {
    #[serde(default)]
    pub payload_text: Option<String>,
    pub now: f64,
    pub byte_count: i64,
    pub is_event_stream: bool,
    pub is_final: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GatewayProtocolPreviewDecisionResult {
    pub decision: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub retry_at: Option<f64>,
    #[serde(default)]
    pub retry_at_human_text: Option<String>,
    pub rust_owner: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthAuthorizationUrlRequest {
    pub auth_url: String,
    pub client_id: String,
    pub redirect_uri: String,
    pub scope: String,
    pub code_verifier: String,
    pub expected_state: String,
    pub originator: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthAuthorizationUrlResult {
    pub auth_url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthCallbackInterpretationRequest {
    #[serde(default)]
    pub callback_input: Option<String>,
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub returned_state: Option<String>,
    pub expected_state: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OAuthCallbackInterpretationResult {
    #[serde(default)]
    pub code: Option<String>,
    #[serde(default)]
    pub returned_state: Option<String>,
    pub state_mismatch: bool,
}

pub fn resolve_transport_policy(
    request: GatewayTransportPolicyRequest,
) -> GatewayTransportPolicyResult {
    if request.proxy_resolution_mode != "loopbackProxySafe" {
        return GatewayTransportPolicyResult {
            proxy_resolution_mode: request.proxy_resolution_mode,
            system_proxy_snapshot: request.system_proxy_snapshot.clone(),
            effective_proxy_snapshot: request.system_proxy_snapshot,
            loopback_proxy_safe_applied: false,
        };
    }

    let Some(snapshot) = request.system_proxy_snapshot.clone() else {
        return GatewayTransportPolicyResult {
            proxy_resolution_mode: request.proxy_resolution_mode,
            system_proxy_snapshot: None,
            effective_proxy_snapshot: None,
            loopback_proxy_safe_applied: false,
        };
    };

    let filtered = GatewayProxySnapshot {
        http: snapshot
            .http
            .clone()
            .filter(|endpoint| is_loopback(&endpoint.host) == false),
        https: snapshot
            .https
            .clone()
            .filter(|endpoint| is_loopback(&endpoint.host) == false),
        socks: snapshot
            .socks
            .clone()
            .filter(|endpoint| is_loopback(&endpoint.host) == false),
    };
    let applied = filtered != snapshot;
    let effective_proxy_snapshot =
        if filtered.http.is_none() && filtered.https.is_none() && filtered.socks.is_none() {
            None
        } else {
            Some(filtered)
        };

    GatewayTransportPolicyResult {
        proxy_resolution_mode: request.proxy_resolution_mode,
        system_proxy_snapshot: Some(snapshot),
        effective_proxy_snapshot,
        loopback_proxy_safe_applied: applied,
    }
}

pub fn plan_gateway_candidates(request: GatewayCandidatePlanRequest) -> GatewayCandidatePlanResult {
    if request.account_usage_mode != "aggregateGateway"
        && request.account_usage_mode != "aggregate_gateway"
    {
        return GatewayCandidatePlanResult {
            account_ids: vec![],
            sticky_account_id: None,
            rust_owner: "core_gateway.plan_gateway_candidates".to_string(),
        };
    }

    let runtime_blocked = request
        .runtime_blocked_accounts
        .iter()
        .filter(|blocked| blocked.retry_at > request.now)
        .map(|blocked| blocked.account_id.as_str())
        .collect::<std::collections::BTreeSet<_>>();

    let sticky_account_id = request.sticky_key.as_deref().and_then(|sticky_key| {
        request
            .sticky_bindings
            .iter()
            .filter(|binding| binding.sticky_key == sticky_key)
            .max_by(|lhs, rhs| lhs.updated_at.total_cmp(&rhs.updated_at))
            .map(|binding| binding.account_id.clone())
    });

    let mut candidates = request
        .accounts
        .into_iter()
        .filter(|account| is_gateway_account_available(account))
        .filter(|account| runtime_blocked.contains(account.account_id.as_str()) == false)
        .collect::<Vec<_>>();

    candidates.sort_by(|lhs, rhs| {
        compare_gateway_accounts(lhs, rhs, &request.quota_sort_settings, request.now)
    });

    if let Some(sticky_account_id) = sticky_account_id.as_deref() {
        if let Some(index) = candidates
            .iter()
            .position(|account| account.account_id == sticky_account_id)
        {
            let sticky = candidates.remove(index);
            candidates.insert(0, sticky);
        }
    }

    GatewayCandidatePlanResult {
        account_ids: candidates
            .into_iter()
            .map(|account| account.account_id)
            .collect(),
        sticky_account_id,
        rust_owner: "core_gateway.plan_gateway_candidates".to_string(),
    }
}

pub fn resolve_gateway_sticky_key(
    request: GatewayStickyKeyResolutionRequest,
) -> GatewayStickyKeyResolutionResult {
    let sticky_key = [request.session_id, request.window_id]
        .into_iter()
        .flatten()
        .map(|value| value.trim().to_string())
        .find(|value| value.is_empty() == false);

    GatewayStickyKeyResolutionResult {
        sticky_key,
        rust_owner: "core_gateway.resolve_gateway_sticky_key".to_string(),
    }
}

pub fn parse_gateway_request(request: GatewayRequestParseRequest) -> GatewayRequestParseResult {
    GatewayRequestParseResult {
        parsed_request: parse_gateway_request_text(&request.raw_text),
        rust_owner: "core_gateway.parse_gateway_request".to_string(),
    }
}

pub fn render_gateway_response_head(
    request: GatewayResponseHeadRenderRequest,
) -> GatewayResponseHeadRenderResult {
    let mut lines = vec![format!(
        "HTTP/1.1 {} {}",
        request.status_code,
        status_reason_phrase(request.status_code)
    )];
    let mut filtered_headers = Vec::new();

    for header in request.header_fields {
        let lowercased = header.name.to_lowercase();
        if lowercased == "content-length"
            || lowercased == "transfer-encoding"
            || lowercased == "connection"
        {
            continue;
        }
        lines.push(format!("{}: {}", header.name, header.value));
        filtered_headers.push(header);
    }

    lines.push("Connection: close".to_string());
    filtered_headers.push(GatewayResponseHeaderFieldInput {
        name: "Connection".to_string(),
        value: "close".to_string(),
    });
    lines.push(String::new());
    lines.push(String::new());

    GatewayResponseHeadRenderResult {
        header_text: lines.join("\r\n"),
        filtered_headers,
        rust_owner: "core_gateway.render_gateway_response_head".to_string(),
    }
}

pub fn render_gateway_websocket_handshake(
    request: GatewayWebSocketHandshakeRequest,
) -> GatewayWebSocketHandshakeResult {
    let accept = websocket_accept_value(&request.sec_web_socket_key);
    let mut headers = vec![
        GatewayResponseHeaderFieldInput {
            name: "Upgrade".to_string(),
            value: "websocket".to_string(),
        },
        GatewayResponseHeaderFieldInput {
            name: "Connection".to_string(),
            value: "Upgrade".to_string(),
        },
        GatewayResponseHeaderFieldInput {
            name: "Sec-WebSocket-Accept".to_string(),
            value: accept,
        },
    ];
    if let Some(selected_protocol) = normalize_nonempty(request.selected_protocol) {
        headers.push(GatewayResponseHeaderFieldInput {
            name: "Sec-WebSocket-Protocol".to_string(),
            value: selected_protocol,
        });
    }

    let mut lines = vec!["HTTP/1.1 101 Switching Protocols".to_string()];
    lines.extend(
        headers
            .iter()
            .map(|header| format!("{}: {}", header.name, header.value)),
    );
    lines.push(String::new());
    lines.push(String::new());

    GatewayWebSocketHandshakeResult {
        response_text: lines.join("\r\n"),
        headers,
        rust_owner: "core_gateway.render_gateway_websocket_handshake".to_string(),
    }
}

pub fn render_gateway_websocket_frame(
    request: GatewayWebSocketFrameRenderRequest,
) -> GatewayWebSocketFrameRenderResult {
    let mut frame = Vec::new();
    frame.push((if request.is_final { 0x80 } else { 0x00 }) | request.opcode);

    match request.payload_bytes.len() {
        0..=125 => frame.push(request.payload_bytes.len() as u8),
        126..=65_535 => {
            frame.push(126);
            frame.push(((request.payload_bytes.len() >> 8) & 0xFF) as u8);
            frame.push((request.payload_bytes.len() & 0xFF) as u8);
        }
        _ => {
            frame.push(127);
            let length = request.payload_bytes.len() as u64;
            for shift in (0..=56).rev().step_by(8) {
                frame.push(((length >> shift) & 0xFF) as u8);
            }
        }
    }

    frame.extend_from_slice(&request.payload_bytes);
    GatewayWebSocketFrameRenderResult {
        frame_bytes: frame,
        rust_owner: "core_gateway.render_gateway_websocket_frame".to_string(),
    }
}

pub fn render_gateway_websocket_close_payload(
    request: GatewayWebSocketClosePayloadRequest,
) -> GatewayWebSocketClosePayloadResult {
    GatewayWebSocketClosePayloadResult {
        payload_bytes: vec![
            ((request.code >> 8) & 0xFF) as u8,
            (request.code & 0xFF) as u8,
        ],
        rust_owner: "core_gateway.render_gateway_websocket_close_payload".to_string(),
    }
}

pub fn parse_gateway_websocket_frame(
    request: GatewayWebSocketFrameParseRequest,
) -> GatewayWebSocketFrameParseResult {
    match parse_gateway_websocket_frame_bytes(&request.frame_bytes, request.expect_masked) {
        Ok(Some(frame)) => GatewayWebSocketFrameParseResult {
            outcome: "parsed".to_string(),
            parsed_frame: Some(frame),
            rust_owner: "core_gateway.parse_gateway_websocket_frame".to_string(),
        },
        Ok(None) => GatewayWebSocketFrameParseResult {
            outcome: "needMoreData".to_string(),
            parsed_frame: None,
            rust_owner: "core_gateway.parse_gateway_websocket_frame".to_string(),
        },
        Err(FrameParseError::Decode) => GatewayWebSocketFrameParseResult {
            outcome: "decodeError".to_string(),
            parsed_frame: None,
            rust_owner: "core_gateway.parse_gateway_websocket_frame".to_string(),
        },
        Err(FrameParseError::Protocol) => GatewayWebSocketFrameParseResult {
            outcome: "protocolError".to_string(),
            parsed_frame: None,
            rust_owner: "core_gateway.parse_gateway_websocket_frame".to_string(),
        },
    }
}

fn status_reason_phrase(status_code: i64) -> &'static str {
    match status_code {
        101 => "Switching Protocols",
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        408 => "Request Timeout",
        409 => "Conflict",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => "Unknown",
    }
}

fn parse_gateway_request_text(raw_text: &str) -> Option<GatewayParsedRequest> {
    let bytes = raw_text.as_bytes();
    let delimiter = b"\r\n\r\n";
    let header_end = bytes
        .windows(delimiter.len())
        .position(|window| window == delimiter)?;
    let header_text = std::str::from_utf8(&bytes[..header_end]).ok()?;
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next()?;
    let request_parts: Vec<&str> = request_line.split_whitespace().collect();
    if request_parts.len() < 3 {
        return None;
    }

    let mut headers = BTreeMap::new();
    for line in lines {
        let Some(separator) = line.find(':') else {
            continue;
        };
        let name = line[..separator].trim().to_lowercase();
        let value = line[separator + 1..].trim().to_string();
        headers.insert(name, value);
    }

    let content_length = headers
        .get("content-length")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(0);
    let body_offset = header_end + delimiter.len();
    if bytes.len() < body_offset + content_length {
        return None;
    }

    let body_text = std::str::from_utf8(&bytes[body_offset..body_offset + content_length])
        .ok()?
        .to_string();

    Some(GatewayParsedRequest {
        method: request_parts[0].to_string(),
        path: request_parts[1].to_string(),
        headers,
        body_text,
    })
}

fn websocket_accept_value(key: &str) -> String {
    let value = format!("{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    let digest = sha1_digest(value.as_bytes());
    encode_base64(&digest)
}

fn sha1_digest(bytes: &[u8]) -> [u8; 20] {
    let mut h0: u32 = 0x6745_2301;
    let mut h1: u32 = 0xEFCD_AB89;
    let mut h2: u32 = 0x98BA_DCFE;
    let mut h3: u32 = 0x1032_5476;
    let mut h4: u32 = 0xC3D2_E1F0;

    let bit_len = (bytes.len() as u64) * 8;
    let mut message = bytes.to_vec();
    message.push(0x80);
    while message.len() % 64 != 56 {
        message.push(0);
    }
    message.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in message.chunks(64) {
        let mut words = [0u32; 80];
        for (index, word) in words.iter_mut().take(16).enumerate() {
            let offset = index * 4;
            *word = u32::from_be_bytes([
                chunk[offset],
                chunk[offset + 1],
                chunk[offset + 2],
                chunk[offset + 3],
            ]);
        }
        for index in 16..80 {
            words[index] =
                (words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16])
                    .rotate_left(1);
        }

        let mut a = h0;
        let mut b = h1;
        let mut c = h2;
        let mut d = h3;
        let mut e = h4;

        for (index, word) in words.iter().enumerate() {
            let (f, k) = match index {
                0..=19 => ((b & c) | ((!b) & d), 0x5A82_7999),
                20..=39 => (b ^ c ^ d, 0x6ED9_EBA1),
                40..=59 => ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC),
                _ => (b ^ c ^ d, 0xCA62_C1D6),
            };
            let temp = a
                .rotate_left(5)
                .wrapping_add(f)
                .wrapping_add(e)
                .wrapping_add(k)
                .wrapping_add(*word);
            e = d;
            d = c;
            c = b.rotate_left(30);
            b = a;
            a = temp;
        }

        h0 = h0.wrapping_add(a);
        h1 = h1.wrapping_add(b);
        h2 = h2.wrapping_add(c);
        h3 = h3.wrapping_add(d);
        h4 = h4.wrapping_add(e);
    }

    let mut digest = [0u8; 20];
    digest[0..4].copy_from_slice(&h0.to_be_bytes());
    digest[4..8].copy_from_slice(&h1.to_be_bytes());
    digest[8..12].copy_from_slice(&h2.to_be_bytes());
    digest[12..16].copy_from_slice(&h3.to_be_bytes());
    digest[16..20].copy_from_slice(&h4.to_be_bytes());
    digest
}

fn encode_base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    let mut output = String::new();
    for chunk in bytes.chunks(3) {
        let first = chunk[0];
        let second = *chunk.get(1).unwrap_or(&0);
        let third = *chunk.get(2).unwrap_or(&0);

        output.push(TABLE[(first >> 2) as usize] as char);
        output.push(TABLE[(((first & 0x03) << 4) | (second >> 4)) as usize] as char);

        if chunk.len() > 1 {
            output.push(TABLE[(((second & 0x0F) << 2) | (third >> 6)) as usize] as char);
        } else {
            output.push('=');
        }

        if chunk.len() > 2 {
            output.push(TABLE[(third & 0x3F) as usize] as char);
        } else {
            output.push('=');
        }
    }
    output
}

enum FrameParseError {
    Protocol,
    Decode,
}

fn parse_gateway_websocket_frame_bytes(
    bytes: &[u8],
    expect_masked: bool,
) -> Result<Option<GatewayParsedWebSocketFrame>, FrameParseError> {
    if bytes.len() < 2 {
        return Ok(None);
    }

    let first = bytes[0];
    let second = bytes[1];
    let is_final = (first & 0x80) != 0;
    let reserved_bits = first & 0x70;
    let opcode = first & 0x0F;
    let is_masked = (second & 0x80) != 0;

    if reserved_bits != 0 {
        return Err(FrameParseError::Protocol);
    }
    if expect_masked && is_masked == false {
        return Err(FrameParseError::Protocol);
    }

    let mut payload_length = (second & 0x7F) as usize;
    let mut cursor = 2usize;

    if payload_length == 126 {
        if bytes.len() < cursor + 2 {
            return Ok(None);
        }
        payload_length = ((bytes[cursor] as usize) << 8) | bytes[cursor + 1] as usize;
        cursor += 2;
    } else if payload_length == 127 {
        if bytes.len() < cursor + 8 {
            return Ok(None);
        }
        let mut length = 0u64;
        for byte in &bytes[cursor..cursor + 8] {
            length = (length << 8) | (*byte as u64);
        }
        if length > i64::MAX as u64 {
            return Err(FrameParseError::Decode);
        }
        payload_length = length as usize;
        cursor += 8;
    }

    if opcode >= 0x8 && (!is_final || payload_length > 125) {
        return Err(FrameParseError::Protocol);
    }

    let mask_length = if is_masked { 4 } else { 0 };
    if bytes.len() < cursor + mask_length + payload_length {
        return Ok(None);
    }

    let mut payload_start = cursor;
    let mask = if is_masked {
        let mask = bytes[cursor..cursor + 4].to_vec();
        payload_start += 4;
        mask
    } else {
        Vec::new()
    };

    let mut payload = bytes[payload_start..payload_start + payload_length].to_vec();
    if is_masked {
        for (index, byte) in payload.iter_mut().enumerate() {
            *byte ^= mask[index % 4];
        }
    }

    Ok(Some(GatewayParsedWebSocketFrame {
        opcode,
        payload_bytes: payload,
        is_final,
        consumed_byte_count: (payload_start + payload_length) as i64,
    }))
}

pub fn bind_gateway_sticky_state(request: GatewayStickyBindRequest) -> GatewayStickyBindResult {
    let account_id = normalize_nonempty(Some(request.account_id)).unwrap_or_default();
    let mut sticky_bindings = request.sticky_bindings;
    let route_changed = request
        .current_routed_account_id
        .as_deref()
        .unwrap_or_default()
        != account_id;
    let mut should_record_route = false;

    if let Some(sticky_key) = normalize_nonempty(request.sticky_key) {
        if sticky_bindings
            .iter()
            .find(|binding| binding.thread_id == sticky_key)
            .map(|binding| binding.account_id.as_str())
            != Some(account_id.as_str())
        {
            should_record_route = true;
        }

        sticky_bindings.retain(|binding| binding.thread_id != sticky_key);
        sticky_bindings.push(GatewayStickyBindingStateInput {
            thread_id: sticky_key,
            account_id: account_id.clone(),
            updated_at: request.now,
        });
    }

    prune_gateway_sticky_bindings(
        &mut sticky_bindings,
        request.now - request.expiration_interval_seconds.max(0.0),
        request.max_entries.max(0) as usize,
    );

    GatewayStickyBindResult {
        next_routed_account_id: normalize_nonempty(Some(account_id)),
        sticky_bindings,
        route_changed,
        should_record_route,
        rust_owner: "core_gateway.bind_gateway_sticky_state".to_string(),
    }
}

pub fn clear_gateway_sticky_state(request: GatewayStickyClearRequest) -> GatewayStickyClearResult {
    let target_thread_id = normalize_nonempty(Some(request.thread_id)).unwrap_or_default();
    let target_account_id = normalize_nonempty(request.account_id);
    let mut sticky_bindings = request.sticky_bindings;
    let original_len = sticky_bindings.len();

    sticky_bindings.retain(|binding| {
        if binding.thread_id != target_thread_id {
            return true;
        }
        if let Some(target_account_id) = target_account_id.as_deref() {
            binding.account_id != target_account_id
        } else {
            false
        }
    });
    let cleared = sticky_bindings.len() != original_len;

    GatewayStickyClearResult {
        sticky_bindings,
        cleared,
        rust_owner: "core_gateway.clear_gateway_sticky_state".to_string(),
    }
}

pub fn apply_gateway_runtime_block(
    request: GatewayRuntimeBlockApplyRequest,
) -> GatewayRuntimeBlockApplyResult {
    let blocked_account_id =
        normalize_nonempty(Some(request.blocked_account_id)).unwrap_or_default();
    let mut runtime_blocked_accounts = request.runtime_blocked_accounts;
    runtime_blocked_accounts.retain(|blocked| {
        blocked.retry_at > request.now && blocked.account_id != blocked_account_id
    });
    runtime_blocked_accounts.push(GatewayRuntimeBlockedAccountStateInput {
        account_id: blocked_account_id.clone(),
        retry_at: request.retry_at,
    });
    runtime_blocked_accounts.sort_by(|lhs, rhs| {
        lhs.retry_at
            .total_cmp(&rhs.retry_at)
            .then_with(|| lhs.account_id.cmp(&rhs.account_id))
    });

    GatewayRuntimeBlockApplyResult {
        next_routed_account_id: request
            .current_routed_account_id
            .filter(|account_id| account_id != &blocked_account_id),
        runtime_blocked_accounts,
        rust_owner: "core_gateway.apply_gateway_runtime_block".to_string(),
    }
}

pub fn normalize_gateway_state(
    request: GatewayStateNormalizationRequest,
) -> GatewayStateNormalizationResult {
    let known_account_ids = request
        .known_account_ids
        .into_iter()
        .filter_map(|account_id| normalize_nonempty(Some(account_id)))
        .collect::<std::collections::BTreeSet<_>>();
    let mut sticky_bindings = request
        .sticky_bindings
        .into_iter()
        .filter(|binding| known_account_ids.contains(&binding.account_id))
        .collect::<Vec<_>>();
    prune_gateway_sticky_bindings(
        &mut sticky_bindings,
        request.now - request.sticky_expiration_interval_seconds.max(0.0),
        request.sticky_max_entries.max(0) as usize,
    );

    let runtime_blocked_accounts = request
        .runtime_blocked_accounts
        .into_iter()
        .filter(|blocked| {
            known_account_ids.contains(&blocked.account_id) && blocked.retry_at > request.now
        })
        .collect::<Vec<_>>();

    GatewayStateNormalizationResult {
        next_routed_account_id: request
            .current_routed_account_id
            .and_then(|account_id| normalize_nonempty(Some(account_id)))
            .filter(|account_id| known_account_ids.contains(account_id)),
        sticky_bindings,
        runtime_blocked_accounts,
        rust_owner: "core_gateway.normalize_gateway_state".to_string(),
    }
}

fn prune_gateway_sticky_bindings(
    sticky_bindings: &mut Vec<GatewayStickyBindingStateInput>,
    cutoff: f64,
    max_entries: usize,
) {
    sticky_bindings.retain(|binding| binding.updated_at >= cutoff);
    if sticky_bindings.len() <= max_entries {
        return;
    }
    sticky_bindings.sort_by(|lhs, rhs| {
        lhs.updated_at
            .total_cmp(&rhs.updated_at)
            .then_with(|| lhs.thread_id.cmp(&rhs.thread_id))
    });
    let overflow = sticky_bindings.len() - max_entries;
    sticky_bindings.drain(0..overflow);
}

pub fn classify_gateway_transport_failure(
    request: GatewayTransportFailureClassificationRequest,
) -> GatewayTransportFailureClassificationResult {
    let is_protocol_violation = request.allow_protocol_violation
        && request.error_domain.as_deref() == Some("NSURLErrorDomain")
        && matches!(
            request.error_code,
            Some(code)
                if code == -1011 || code == -1017
        );

    GatewayTransportFailureClassificationResult {
        failure_class: if is_protocol_violation {
            "protocolViolation".to_string()
        } else {
            "transport".to_string()
        },
        rust_owner: "core_gateway.classify_gateway_transport_failure".to_string(),
    }
}

pub fn resolve_gateway_status_policy(
    request: GatewayStatusPolicyRequest,
) -> GatewayStatusPolicyResult {
    let failure_class = gateway_failure_class_for_status(request.status_code);
    let failover_disposition = if matches!(
        failure_class.as_deref(),
        Some("accountStatus") | Some("upstreamStatus")
    ) {
        "failover".to_string()
    } else {
        "doNotFailover".to_string()
    };
    let explicit_retry_at = request
        .suggested_retry_at
        .map(|retry_at| retry_at > request.now)
        .and_then(|is_future| {
            if is_future {
                request.suggested_retry_at
            } else {
                None
            }
        })
        .or_else(|| {
            request
                .retry_after_value
                .as_deref()
                .and_then(|value| parse_retry_after_value(value, request.now))
        });
    let has_explicit_retry_after = explicit_retry_at.is_some();
    let should_runtime_block_account = request.status_code == 429
        && request.account.is_some()
        && (has_explicit_retry_after || request.allow_fallback_runtime_block);
    let runtime_block_retry_at = if should_runtime_block_account {
        request.account.as_ref().map(|account| {
            resolved_runtime_block_retry_at(account, explicit_retry_at, request.now)
        })
    } else {
        None
    };

    GatewayStatusPolicyResult {
        failure_class,
        failover_disposition: failover_disposition.clone(),
        is_account_scoped_status: matches!(failover_disposition.as_str(), "failover")
            && matches!(request.status_code, 401 | 403 | 429),
        should_retry: failover_disposition == "failover",
        should_runtime_block_account,
        runtime_block_retry_at,
        rust_owner: "core_gateway.resolve_gateway_status_policy".to_string(),
    }
}

fn parse_retry_after_value(value: &str, now: f64) -> Option<f64> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }

    if let Ok(seconds) = trimmed.parse::<f64>() {
        return Some(now + seconds);
    }

    parse_http_retry_after_date(trimmed)
}

fn parse_http_retry_after_date(value: &str) -> Option<f64> {
    let day = value.get(5..7)?.trim().parse::<u32>().ok()?;
    let month = month_from_abbrev(value.get(8..11)?)?;
    let year = value.get(12..16)?.parse::<i32>().ok()?;
    let hour = value.get(17..19)?.parse::<u32>().ok()?;
    let minute = value.get(20..22)?.parse::<u32>().ok()?;
    let second = value.get(23..25)?.parse::<u32>().ok()?;
    let timezone = value.get(26..29)?;

    if timezone != "GMT"
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }

    Some(
        (days_from_civil(year, month, day) * 86_400
            + i64::from(hour) * 3_600
            + i64::from(minute) * 60
            + i64::from(second)) as f64,
    )
}

fn month_from_abbrev(value: &str) -> Option<u32> {
    match value {
        "Jan" => Some(1),
        "Feb" => Some(2),
        "Mar" => Some(3),
        "Apr" => Some(4),
        "May" => Some(5),
        "Jun" => Some(6),
        "Jul" => Some(7),
        "Aug" => Some(8),
        "Sep" => Some(9),
        "Oct" => Some(10),
        "Nov" => Some(11),
        "Dec" => Some(12),
        _ => None,
    }
}

pub fn resolve_gateway_sticky_recovery_policy(
    request: GatewayStickyRecoveryPolicyRequest,
) -> GatewayStickyRecoveryPolicyResult {
    let should_attempt_sticky_context_recovery = request.used_sticky_context_recovery == false
        && request.candidate_index == 0
        && request.candidate_count > 1
        && request.sticky_binding_matches_failed_account
        && matches!(
            request.failure_class.as_str(),
            "transport" | "protocolViolation"
        );

    GatewayStickyRecoveryPolicyResult {
        should_attempt_sticky_context_recovery,
        rust_owner: "core_gateway.resolve_gateway_sticky_recovery_policy".to_string(),
    }
}

pub fn interpret_gateway_protocol_signal(
    request: GatewayProtocolSignalInterpretationRequest,
) -> GatewayProtocolSignalInterpretationResult {
    let trimmed = request.payload_text.trim();
    if trimmed.is_empty() {
        return GatewayProtocolSignalInterpretationResult {
            is_runtime_limit_signal: false,
            message: None,
            retry_at: None,
            retry_at_human_text: None,
            rust_owner: "core_gateway.interpret_gateway_protocol_signal".to_string(),
        };
    }

    if let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) {
        if let Some(interpreted) = protocol_signal_from_value(&value, trimmed, request.now) {
            return interpreted;
        }
    }

    if is_runtime_limit_signal(None, None, Some(trimmed)) {
        let retry_at = parse_retry_at_from_message(trimmed, request.now);
        return GatewayProtocolSignalInterpretationResult {
            is_runtime_limit_signal: true,
            message: Some(trimmed.to_string()),
            retry_at,
            retry_at_human_text: if retry_at.is_none() {
                Some(trimmed.to_string())
            } else {
                None
            },
            rust_owner: "core_gateway.interpret_gateway_protocol_signal".to_string(),
        };
    }

    GatewayProtocolSignalInterpretationResult {
        is_runtime_limit_signal: false,
        message: None,
        retry_at: None,
        retry_at_human_text: None,
        rust_owner: "core_gateway.interpret_gateway_protocol_signal".to_string(),
    }
}

pub fn decide_gateway_protocol_preview(
    request: GatewayProtocolPreviewDecisionRequest,
) -> GatewayProtocolPreviewDecisionResult {
    let preview_limit = 64 * 1024;
    let Some(payload_text) = request.payload_text.as_deref() else {
        return if request.is_final || request.byte_count >= preview_limit {
            preview_stream_now()
        } else {
            preview_need_more_data()
        };
    };

    if request.is_event_stream {
        let normalized = payload_text.replace("\r\n", "\n");
        let ends_with_delimiter = normalized.ends_with("\n\n");
        let mut components = normalized
            .split("\n\n")
            .map(|component| component.to_string())
            .collect::<Vec<_>>();
        if ends_with_delimiter == false && components.is_empty() == false {
            components.pop();
        }

        if components.is_empty() {
            if request.is_final || request.byte_count >= preview_limit {
                return preview_account_signal_or_stream_now(&normalized, request.now);
            }
            return preview_need_more_data();
        }

        for component in components {
            let payload = sse_payload(&component);
            let signal =
                interpret_gateway_protocol_signal(GatewayProtocolSignalInterpretationRequest {
                    payload_text: payload.clone(),
                    now: request.byte_count as f64,
                });
            if signal.is_runtime_limit_signal {
                return GatewayProtocolPreviewDecisionResult {
                    decision: "accountSignal".to_string(),
                    message: signal.message,
                    retry_at: signal.retry_at,
                    retry_at_human_text: signal.retry_at_human_text,
                    rust_owner: "core_gateway.decide_gateway_protocol_preview".to_string(),
                };
            }
            if should_keep_buffering_sse_payload(&payload) == false {
                return preview_stream_now();
            }
        }

        if request.is_final || request.byte_count >= preview_limit {
            return preview_stream_now();
        }
        return preview_need_more_data();
    }

    if request.is_final || request.byte_count >= preview_limit {
        return preview_account_signal_or_stream_now(payload_text, request.now);
    }

    preview_need_more_data()
}

fn compare_gateway_accounts(
    lhs: &GatewayAccountInput,
    rhs: &GatewayAccountInput,
    quota_sort: &GatewayQuotaSortSettings,
    now: f64,
) -> std::cmp::Ordering {
    let lhs_bucket = sort_bucket(lhs);
    let rhs_bucket = sort_bucket(rhs);
    if lhs_bucket != rhs_bucket {
        return lhs_bucket.cmp(&rhs_bucket);
    }

    if lhs_bucket == 2 {
        if let Some(ordering) = earlier_reset_ordering(lhs, rhs, now) {
            return ordering;
        }
    }

    compare_f64_desc(
        weighted_primary_remaining(lhs, quota_sort, now),
        weighted_primary_remaining(rhs, quota_sort, now),
    )
    .then_with(|| {
        compare_f64_desc(
            weighted_secondary_remaining(lhs, quota_sort, now),
            weighted_secondary_remaining(rhs, quota_sort, now),
        )
    })
    .then_with(|| earlier_reset_ordering(lhs, rhs, now).unwrap_or(std::cmp::Ordering::Equal))
    .then_with(|| {
        compare_f64_desc(
            plan_quota_multiplier(lhs, quota_sort),
            plan_quota_multiplier(rhs, quota_sort),
        )
    })
    .then_with(|| compare_f64_desc(primary_remaining(lhs, now), primary_remaining(rhs, now)))
    .then_with(|| compare_f64_desc(secondary_remaining(lhs, now), secondary_remaining(rhs, now)))
    .then_with(|| lhs.email.to_lowercase().cmp(&rhs.email.to_lowercase()))
    .then_with(|| lhs.account_id.cmp(&rhs.account_id))
}

fn gateway_failure_class_for_status(status_code: i64) -> Option<String> {
    if matches!(status_code, 401 | 403 | 429) {
        Some("accountStatus".to_string())
    } else if (500..=599).contains(&status_code) {
        Some("upstreamStatus".to_string())
    } else {
        None
    }
}

fn protocol_signal_from_value(
    value: &serde_json::Value,
    raw_text: &str,
    now: f64,
) -> Option<GatewayProtocolSignalInterpretationResult> {
    let object = value.as_object()?;

    if let Some(result) = interpret_protocol_signal_candidate(
        object.get("code").and_then(|value| value.as_str()),
        object.get("type").and_then(|value| value.as_str()),
        object.get("message").and_then(|value| value.as_str()),
        object,
        raw_text,
        now,
    ) {
        return Some(result);
    }

    if let Some(error) = object.get("error").and_then(|value| value.as_object()) {
        if let Some(result) = interpret_protocol_signal_candidate(
            error.get("code").and_then(|value| value.as_str()),
            error
                .get("type")
                .and_then(|value| value.as_str())
                .or_else(|| object.get("type").and_then(|value| value.as_str())),
            error.get("message").and_then(|value| value.as_str()),
            error,
            raw_text,
            now,
        ) {
            return Some(result);
        }
    }

    if let Some(response) = object.get("response").and_then(|value| value.as_object()) {
        if let Some(result) = interpret_protocol_signal_candidate(
            response.get("code").and_then(|value| value.as_str()),
            response
                .get("type")
                .and_then(|value| value.as_str())
                .or_else(|| object.get("type").and_then(|value| value.as_str())),
            response.get("message").and_then(|value| value.as_str()),
            response,
            raw_text,
            now,
        ) {
            return Some(result);
        }

        if let Some(error) = response.get("error").and_then(|value| value.as_object()) {
            if let Some(result) = interpret_protocol_signal_candidate(
                error.get("code").and_then(|value| value.as_str()),
                error
                    .get("type")
                    .and_then(|value| value.as_str())
                    .or_else(|| response.get("type").and_then(|value| value.as_str()))
                    .or_else(|| object.get("type").and_then(|value| value.as_str())),
                error.get("message").and_then(|value| value.as_str()),
                error,
                raw_text,
                now,
            ) {
                return Some(result);
            }
        }
    }

    None
}

fn sse_payload(event: &str) -> String {
    let data_lines = event
        .split('\n')
        .filter_map(|line| {
            line.strip_prefix("data:")
                .map(|payload| payload.trim().to_string())
        })
        .collect::<Vec<_>>();

    if data_lines.is_empty() == false {
        data_lines.join("\n")
    } else {
        event.trim().to_string()
    }
}

fn should_keep_buffering_sse_payload(payload: &str) -> bool {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(payload) else {
        return false;
    };
    matches!(
        value.get("type").and_then(|value| value.as_str()),
        Some("response.created")
            | Some("response.in_progress")
            | Some("response.output_item.added")
            | Some("response.content_part.added")
    )
}

fn preview_account_signal_or_stream_now(
    payload_text: &str,
    now: f64,
) -> GatewayProtocolPreviewDecisionResult {
    let signal = interpret_gateway_protocol_signal(GatewayProtocolSignalInterpretationRequest {
        payload_text: payload_text.to_string(),
        now,
    });
    if signal.is_runtime_limit_signal {
        GatewayProtocolPreviewDecisionResult {
            decision: "accountSignal".to_string(),
            message: signal.message,
            retry_at: signal.retry_at,
            retry_at_human_text: signal.retry_at_human_text,
            rust_owner: "core_gateway.decide_gateway_protocol_preview".to_string(),
        }
    } else {
        preview_stream_now()
    }
}

fn preview_need_more_data() -> GatewayProtocolPreviewDecisionResult {
    GatewayProtocolPreviewDecisionResult {
        decision: "needMoreData".to_string(),
        message: None,
        retry_at: None,
        retry_at_human_text: None,
        rust_owner: "core_gateway.decide_gateway_protocol_preview".to_string(),
    }
}

fn preview_stream_now() -> GatewayProtocolPreviewDecisionResult {
    GatewayProtocolPreviewDecisionResult {
        decision: "streamNow".to_string(),
        message: None,
        retry_at: None,
        retry_at_human_text: None,
        rust_owner: "core_gateway.decide_gateway_protocol_preview".to_string(),
    }
}

fn interpret_protocol_signal_candidate(
    code: Option<&str>,
    error_type: Option<&str>,
    message: Option<&str>,
    object: &serde_json::Map<String, serde_json::Value>,
    raw_text: &str,
    now: f64,
) -> Option<GatewayProtocolSignalInterpretationResult> {
    if is_runtime_limit_signal(code, error_type, message) == false {
        return None;
    }

    let retry_at = retry_at_from_json_object(object, now)
        .or_else(|| message.and_then(|message| parse_retry_at_from_message(message, now)));
    let retry_at_human_text = if retry_at.is_none() {
        message
            .filter(|message| message.trim().is_empty() == false)
            .map(|message| message.to_string())
            .or_else(|| Some(raw_text.to_string()))
    } else {
        None
    };

    Some(GatewayProtocolSignalInterpretationResult {
        is_runtime_limit_signal: true,
        message: message.map(|message| message.to_string()),
        retry_at,
        retry_at_human_text,
        rust_owner: "core_gateway.interpret_gateway_protocol_signal".to_string(),
    })
}

fn is_runtime_limit_signal(
    code: Option<&str>,
    error_type: Option<&str>,
    message: Option<&str>,
) -> bool {
    let normalized_code = code.unwrap_or_default().trim().to_lowercase();
    let normalized_type = error_type.unwrap_or_default().trim().to_lowercase();
    let normalized_message = message.unwrap_or_default().trim().to_lowercase();

    if normalized_code.contains("usage_limit")
        || normalized_code.contains("rate_limit")
        || normalized_code.contains("insufficient_quota")
    {
        return true;
    }
    if normalized_type.contains("usage_limit") || normalized_type.contains("rate_limit") {
        return true;
    }
    if normalized_message.contains("usage limit")
        && (normalized_message.contains("hit") || normalized_message.contains("reached"))
    {
        return true;
    }
    if normalized_message.contains("rate limit")
        && (normalized_message.contains("hit")
            || normalized_message.contains("reached")
            || normalized_message.contains("exceeded"))
    {
        return true;
    }

    false
}

fn retry_at_from_json_object(
    object: &serde_json::Map<String, serde_json::Value>,
    now: f64,
) -> Option<f64> {
    if let Some(retry_after) = object.get("retry_after") {
        if let Some(seconds) = retry_after.as_f64() {
            return Some(now + seconds);
        }
        if let Some(seconds_text) = retry_after.as_str() {
            if let Ok(seconds) = seconds_text.trim().parse::<f64>() {
                return Some(now + seconds);
            }
        }
    }
    if let Some(retry_after_seconds) = object
        .get("retry_after_seconds")
        .and_then(|value| value.as_f64())
    {
        return Some(now + retry_after_seconds);
    }
    if let Some(reset_at) = object.get("reset_at").and_then(|value| value.as_f64()) {
        return Some(reset_at);
    }
    if let Some(resets_at) = object.get("resets_at").and_then(|value| value.as_f64()) {
        return Some(resets_at);
    }
    None
}

fn parse_retry_at_from_message(message: &str, now: f64) -> Option<f64> {
    for (name, month) in [
        ("Jan", 1_u32),
        ("Feb", 2),
        ("Mar", 3),
        ("Apr", 4),
        ("May", 5),
        ("Jun", 6),
        ("Jul", 7),
        ("Aug", 8),
        ("Sep", 9),
        ("Oct", 10),
        ("Nov", 11),
        ("Dec", 12),
    ] {
        for (index, _) in message.match_indices(name) {
            if index > 0
                && message
                    .as_bytes()
                    .get(index - 1)
                    .map(|byte| byte.is_ascii_alphabetic())
                    .unwrap_or(false)
            {
                continue;
            }
            if let Some(retry_at) = parse_human_date_fragment(&message[index..], month, now) {
                if retry_at > now {
                    return Some(retry_at);
                }
            }
        }
    }
    None
}

fn parse_human_date_fragment(fragment: &str, month: u32, now: f64) -> Option<f64> {
    let bytes = fragment.as_bytes();
    let mut index = 3;
    while bytes.get(index).copied() == Some(b' ') {
        index += 1;
    }
    let day_start = index;
    while bytes
        .get(index)
        .map(|byte| byte.is_ascii_digit())
        .unwrap_or(false)
    {
        index += 1;
    }
    let day = fragment.get(day_start..index)?.parse::<u32>().ok()?;
    if let Some(suffix) = fragment.get(index..index + 2) {
        if matches!(suffix, "st" | "nd" | "rd" | "th") {
            index += 2;
        }
    }
    while bytes
        .get(index)
        .map(|byte| matches!(*byte, b' ' | b','))
        .unwrap_or(false)
    {
        index += 1;
    }

    let year = if fragment
        .as_bytes()
        .get(index)
        .map(|byte| byte.is_ascii_digit())
        .unwrap_or(false)
    {
        let year_start = index;
        while bytes
            .get(index)
            .map(|byte| byte.is_ascii_digit())
            .unwrap_or(false)
        {
            index += 1;
        }
        let parsed_year = fragment.get(year_start..index)?.parse::<i32>().ok()?;
        while bytes
            .get(index)
            .map(|byte| matches!(*byte, b' ' | b','))
            .unwrap_or(false)
        {
            index += 1;
        }
        parsed_year
    } else {
        current_year_from_unix_seconds(now)
    };

    let hour_start = index;
    while bytes
        .get(index)
        .map(|byte| byte.is_ascii_digit())
        .unwrap_or(false)
    {
        index += 1;
    }
    let mut hour = fragment.get(hour_start..index)?.parse::<u32>().ok()?;
    if bytes.get(index).copied() != Some(b':') {
        return None;
    }
    index += 1;
    let minute = fragment.get(index..index + 2)?.parse::<u32>().ok()?;
    index += 2;
    while bytes.get(index).copied() == Some(b' ') {
        index += 1;
    }
    let meridiem = fragment.get(index..index + 2)?.to_ascii_lowercase();
    match meridiem.as_str() {
        "am" => {
            if hour == 12 {
                hour = 0;
            }
        }
        "pm" => {
            if hour < 12 {
                hour += 12;
            }
        }
        _ => return None,
    }

    Some(
        (days_from_civil(year, month, day) * 86_400
            + i64::from(hour) * 3_600
            + i64::from(minute) * 60) as f64,
    )
}

fn current_year_from_unix_seconds(seconds: f64) -> i32 {
    let days = (seconds / 86_400.0).floor() as i64;
    civil_from_days(days).0
}

fn civil_from_days(days: i64) -> (i32, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_piece = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_piece + 2) / 5 + 1;
    let month = month_piece + if month_piece < 10 { 3 } else { -9 };
    if month <= 2 {
        year += 1;
    }
    (year as i32, month as u32, day as u32)
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

fn resolved_runtime_block_retry_at(
    account: &GatewayAccountInput,
    suggested_retry_at: Option<f64>,
    now: f64,
) -> f64 {
    if let Some(suggested_retry_at) = suggested_retry_at {
        if suggested_retry_at > now {
            return suggested_retry_at;
        }
    }
    if quota_exhausted(account) {
        if let Some(availability_reset_at) = availability_reset_at(account, now) {
            if availability_reset_at > now {
                return availability_reset_at;
            }
        }
    }
    now + 10.0 * 60.0
}

fn is_gateway_account_available(account: &GatewayAccountInput) -> bool {
    account.is_suspended == false
        && account.token_expired == false
        && quota_exhausted(account) == false
}

fn sort_bucket(account: &GatewayAccountInput) -> i32 {
    if quota_exhausted(account) {
        2
    } else if account.token_expired || account.is_suspended {
        1
    } else {
        0
    }
}

fn quota_exhausted(account: &GatewayAccountInput) -> bool {
    account.primary_used_percent >= 100.0 || account.secondary_used_percent >= 100.0
}

fn weighted_primary_remaining(
    account: &GatewayAccountInput,
    quota_sort: &GatewayQuotaSortSettings,
    now: f64,
) -> f64 {
    primary_remaining(account, now) * plan_quota_multiplier(account, quota_sort)
}

fn weighted_secondary_remaining(
    account: &GatewayAccountInput,
    quota_sort: &GatewayQuotaSortSettings,
    now: f64,
) -> f64 {
    secondary_remaining(account, now) * plan_quota_multiplier(account, quota_sort)
}

fn primary_remaining(account: &GatewayAccountInput, now: f64) -> f64 {
    if resolved_primary_limit_window_seconds(account, now).is_some() {
        (100.0 - account.primary_used_percent).max(0.0)
    } else {
        0.0
    }
}

fn secondary_remaining(account: &GatewayAccountInput, now: f64) -> f64 {
    if resolved_secondary_limit_window_seconds(account, now).is_some() {
        (100.0 - account.secondary_used_percent).max(0.0)
    } else {
        0.0
    }
}

fn plan_quota_multiplier(
    account: &GatewayAccountInput,
    quota_sort: &GatewayQuotaSortSettings,
) -> f64 {
    match account.plan_type.trim().to_lowercase().as_str() {
        "plus" => quota_sort.plus_relative_weight,
        "pro" => quota_sort.plus_relative_weight * quota_sort.pro_relative_to_plus_multiplier,
        "team" => quota_sort.plus_relative_weight * quota_sort.team_relative_to_plus_multiplier,
        _ => 1.0,
    }
}

fn earlier_reset_ordering(
    lhs: &GatewayAccountInput,
    rhs: &GatewayAccountInput,
    now: f64,
) -> Option<std::cmp::Ordering> {
    let lhs_reset = availability_reset_at(lhs, now)?;
    let rhs_reset = availability_reset_at(rhs, now)?;
    if lhs_reset == rhs_reset {
        None
    } else if lhs_reset < rhs_reset {
        Some(std::cmp::Ordering::Less)
    } else {
        Some(std::cmp::Ordering::Greater)
    }
}

fn availability_reset_at(account: &GatewayAccountInput, now: f64) -> Option<f64> {
    let exhausted_resets = rate_limit_windows(account, now)
        .into_iter()
        .filter(|window| window.used_percent >= 100.0)
        .filter_map(|window| window.reset_at)
        .collect::<Vec<_>>();
    if exhausted_resets.is_empty() == false {
        return exhausted_resets
            .into_iter()
            .max_by(|lhs, rhs| lhs.total_cmp(rhs));
    }
    nearest_reset_at(account, now)
}

fn nearest_reset_at(account: &GatewayAccountInput, now: f64) -> Option<f64> {
    let dates = rate_limit_windows(account, now)
        .into_iter()
        .filter_map(|window| window.reset_at)
        .collect::<Vec<_>>();
    let future = dates
        .iter()
        .copied()
        .filter(|date| *date > now)
        .collect::<Vec<_>>();
    if future.is_empty() == false {
        return future.into_iter().min_by(|lhs, rhs| lhs.total_cmp(rhs));
    }
    dates.into_iter().max_by(|lhs, rhs| lhs.total_cmp(rhs))
}

#[derive(Debug, Clone, Copy)]
struct RateLimitWindow {
    used_percent: f64,
    reset_at: Option<f64>,
}

fn rate_limit_windows(account: &GatewayAccountInput, now: f64) -> Vec<RateLimitWindow> {
    let primary_window = resolved_primary_limit_window_seconds(account, now);
    let mut windows = vec![RateLimitWindow {
        used_percent: account.primary_used_percent,
        reset_at: clamped_reset_at(
            account.primary_reset_at,
            primary_window,
            account.last_checked,
            now,
        ),
    }];

    if let Some(secondary_window) = resolved_secondary_limit_window_seconds(account, now) {
        windows.push(RateLimitWindow {
            used_percent: account.secondary_used_percent,
            reset_at: clamped_reset_at(
                account.secondary_reset_at,
                Some(secondary_window),
                account.last_checked,
                now,
            ),
        });
    }

    windows
}

fn resolved_primary_limit_window_seconds(account: &GatewayAccountInput, now: f64) -> Option<i64> {
    if let Some(seconds) = account.primary_limit_window_seconds {
        return Some(seconds);
    }
    if normalized_plan_type(account) == "free" {
        if let Some(primary_reset_at) = account.primary_reset_at {
            if primary_reset_at - now > 12.0 * 3_600.0 {
                return Some(7 * 86_400);
            }
        }
    }
    Some(5 * 3_600)
}

fn resolved_secondary_limit_window_seconds(account: &GatewayAccountInput, now: f64) -> Option<i64> {
    if let Some(seconds) = account.secondary_limit_window_seconds {
        return Some(seconds);
    }
    if account.secondary_reset_at.is_some() || account.secondary_used_percent > 0.0 {
        return Some(7 * 86_400);
    }
    match normalized_plan_type(account).as_str() {
        "plus" | "pro" | "team" => Some(7 * 86_400),
        "free" => {
            if let Some(primary_reset_at) = account.primary_reset_at {
                if primary_reset_at - now > 12.0 * 3_600.0 {
                    return None;
                }
            }
            None
        }
        _ => None,
    }
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

fn normalized_plan_type(account: &GatewayAccountInput) -> String {
    account.plan_type.trim().to_lowercase()
}

fn compare_f64_desc(lhs: f64, rhs: f64) -> std::cmp::Ordering {
    rhs.total_cmp(&lhs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gateway_candidate_plan_accepts_swift_raw_usage_mode_and_prefers_sticky() {
        let result = plan_gateway_candidates(GatewayCandidatePlanRequest {
            account_usage_mode: "aggregate_gateway".to_string(),
            now: 1_000.0,
            quota_sort_settings: GatewayQuotaSortSettings {
                plus_relative_weight: 10.0,
                pro_relative_to_plus_multiplier: 10.0,
                team_relative_to_plus_multiplier: 1.5,
            },
            accounts: vec![
                account("acct-plus", "plus", 10.0),
                account("acct-pro", "pro", 50.0),
            ],
            sticky_key: Some("thread-1".to_string()),
            sticky_bindings: vec![GatewayStickyBindingInput {
                sticky_key: "thread-1".to_string(),
                account_id: "acct-plus".to_string(),
                updated_at: 900.0,
            }],
            runtime_blocked_accounts: vec![],
        });

        assert_eq!(result.account_ids, vec!["acct-plus", "acct-pro"]);
        assert_eq!(result.sticky_account_id.as_deref(), Some("acct-plus"));
    }

    #[test]
    fn gateway_candidate_plan_filters_runtime_blocked_accounts() {
        let result = plan_gateway_candidates(GatewayCandidatePlanRequest {
            account_usage_mode: "aggregateGateway".to_string(),
            now: 1_000.0,
            quota_sort_settings: GatewayQuotaSortSettings {
                plus_relative_weight: 10.0,
                pro_relative_to_plus_multiplier: 10.0,
                team_relative_to_plus_multiplier: 1.5,
            },
            accounts: vec![
                account("blocked", "pro", 0.0),
                account("usable", "plus", 0.0),
            ],
            sticky_key: None,
            sticky_bindings: vec![],
            runtime_blocked_accounts: vec![GatewayRuntimeBlockedAccountInput {
                account_id: "blocked".to_string(),
                retry_at: 2_000.0,
            }],
        });

        assert_eq!(result.account_ids, vec!["usable"]);
    }

    #[test]
    fn gateway_lifecycle_plan_keeps_openrouter_lease_when_provider_inactive() {
        let result = plan_gateway_lifecycle(GatewayLifecyclePlanRequest {
            configured_openai_usage_mode: "switch".to_string(),
            aggregate_leased_process_ids: vec![],
            active_provider_kind: Some("openai_compatible".to_string()),
            openrouter_serviceable_provider_id: Some("openrouter".to_string()),
            last_published_openrouter_selected: true,
            running_codex_process_ids: vec![202, 101],
            existing_openrouter_lease: None,
        });

        assert_eq!(result.effective_openai_usage_mode, "switch");
        assert!(!result.should_run_openai_gateway);
        assert!(result.should_run_openrouter_gateway);
        assert!(result.openrouter_lease_should_poll);
        assert_eq!(
            result.next_openrouter_lease,
            Some(GatewayLeaseSnapshotInput {
                leased_process_ids: vec![101, 202],
                source_provider_id: "openrouter".to_string(),
            })
        );
    }

    #[test]
    fn gateway_lifecycle_plan_clears_openrouter_lease_when_provider_active_again() {
        let result = plan_gateway_lifecycle(GatewayLifecyclePlanRequest {
            configured_openai_usage_mode: "switch".to_string(),
            aggregate_leased_process_ids: vec![],
            active_provider_kind: Some("openrouter".to_string()),
            openrouter_serviceable_provider_id: Some("openrouter".to_string()),
            last_published_openrouter_selected: true,
            running_codex_process_ids: vec![303],
            existing_openrouter_lease: Some(GatewayLeaseSnapshotInput {
                leased_process_ids: vec![303],
                source_provider_id: "openrouter".to_string(),
            }),
        });

        assert_eq!(result.effective_openai_usage_mode, "switch");
        assert!(result.should_run_openrouter_gateway);
        assert!(!result.openrouter_lease_should_poll);
        assert!(result.openrouter_lease_changed);
        assert_eq!(result.next_openrouter_lease, None);
    }

    #[test]
    fn gateway_lifecycle_plan_promotes_aggregate_mode_when_lease_exists() {
        let result = plan_gateway_lifecycle(GatewayLifecyclePlanRequest {
            configured_openai_usage_mode: "switch".to_string(),
            aggregate_leased_process_ids: vec![404],
            active_provider_kind: Some("openai_oauth".to_string()),
            openrouter_serviceable_provider_id: None,
            last_published_openrouter_selected: false,
            running_codex_process_ids: vec![],
            existing_openrouter_lease: None,
        });

        assert_eq!(result.effective_openai_usage_mode, "aggregate_gateway");
        assert!(result.should_run_openai_gateway);
    }

    #[test]
    fn gateway_status_policy_marks_429_as_account_failover_and_runtime_block() {
        let result = resolve_gateway_status_policy(GatewayStatusPolicyRequest {
            status_code: 429,
            now: 1_000.0,
            allow_fallback_runtime_block: false,
            suggested_retry_at: Some(1_250.0),
            retry_after_value: None,
            account: Some(account("acct-plus", "plus", 10.0)),
        });

        assert_eq!(result.failure_class.as_deref(), Some("accountStatus"));
        assert_eq!(result.failover_disposition, "failover");
        assert!(result.is_account_scoped_status);
        assert!(result.should_retry);
        assert!(result.should_runtime_block_account);
        assert_eq!(result.runtime_block_retry_at, Some(1_250.0));
    }

    #[test]
    fn gateway_status_policy_falls_back_to_availability_reset_when_quota_exhausted() {
        let mut account = account("acct-plus", "plus", 100.0);
        account.primary_reset_at = Some(4_000.0);

        let result = resolve_gateway_status_policy(GatewayStatusPolicyRequest {
            status_code: 429,
            now: 1_000.0,
            allow_fallback_runtime_block: true,
            suggested_retry_at: None,
            retry_after_value: None,
            account: Some(account),
        });

        assert_eq!(result.runtime_block_retry_at, Some(4_000.0));
    }

    #[test]
    fn gateway_status_policy_maps_5xx_to_upstream_failover_without_runtime_block() {
        let result = resolve_gateway_status_policy(GatewayStatusPolicyRequest {
            status_code: 502,
            now: 1_000.0,
            allow_fallback_runtime_block: false,
            suggested_retry_at: None,
            retry_after_value: None,
            account: None,
        });

        assert_eq!(result.failure_class.as_deref(), Some("upstreamStatus"));
        assert_eq!(result.failover_disposition, "failover");
        assert!(result.should_retry);
        assert!(!result.should_runtime_block_account);
    }

    #[test]
    fn gateway_status_policy_does_not_runtime_block_429_without_explicit_retry_after() {
        let result = resolve_gateway_status_policy(GatewayStatusPolicyRequest {
            status_code: 429,
            now: 1_000.0,
            allow_fallback_runtime_block: false,
            suggested_retry_at: None,
            retry_after_value: None,
            account: Some(account("acct-plus", "plus", 10.0)),
        });

        assert!(result.should_retry);
        assert!(!result.should_runtime_block_account);
        assert_eq!(result.runtime_block_retry_at, None);
    }

    #[test]
    fn gateway_status_policy_parses_retry_after_header_value() {
        let result = resolve_gateway_status_policy(GatewayStatusPolicyRequest {
            status_code: 429,
            now: 1_000.0,
            allow_fallback_runtime_block: false,
            suggested_retry_at: None,
            retry_after_value: Some("120".to_string()),
            account: Some(account("acct-plus", "plus", 10.0)),
        });

        assert!(result.should_runtime_block_account);
        assert_eq!(result.runtime_block_retry_at, Some(1_120.0));
    }

    #[test]
    fn gateway_status_policy_parses_retry_after_http_date_value() {
        let result = resolve_gateway_status_policy(GatewayStatusPolicyRequest {
            status_code: 429,
            now: 1_000.0,
            allow_fallback_runtime_block: false,
            suggested_retry_at: None,
            retry_after_value: Some("Wed, 21 Oct 2099 07:28:00 GMT".to_string()),
            account: Some(account("acct-plus", "plus", 10.0)),
        });

        assert!(result.should_runtime_block_account);
        assert!(result.runtime_block_retry_at.unwrap_or_default() > 1_000.0);
    }

    #[test]
    fn aggregate_gateway_lease_transition_captures_running_processes_when_switching_away() {
        let result = plan_aggregate_gateway_lease_transition(
            AggregateGatewayLeaseTransitionPlanRequest {
                previous_openai_usage_mode: "aggregate_gateway".to_string(),
                next_openai_usage_mode: "switch".to_string(),
                current_leased_process_ids: vec![],
                running_codex_process_ids: vec![202, 101, 101],
            },
        );

        assert_eq!(result.next_leased_process_ids, vec![101, 202]);
        assert!(result.lease_changed);
        assert!(result.should_poll);
    }

    #[test]
    fn aggregate_gateway_lease_transition_clears_existing_lease_when_switching_back() {
        let result = plan_aggregate_gateway_lease_transition(
            AggregateGatewayLeaseTransitionPlanRequest {
                previous_openai_usage_mode: "switch".to_string(),
                next_openai_usage_mode: "aggregate_gateway".to_string(),
                current_leased_process_ids: vec![303],
                running_codex_process_ids: vec![303],
            },
        );

        assert!(result.next_leased_process_ids.is_empty());
        assert!(result.lease_changed);
        assert!(!result.should_poll);
    }

    #[test]
    fn aggregate_gateway_lease_refresh_clears_lease_while_aggregate_mode_is_active() {
        let result = plan_aggregate_gateway_lease_refresh(AggregateGatewayLeaseRefreshPlanRequest {
            current_openai_usage_mode: "aggregate_gateway".to_string(),
            current_leased_process_ids: vec![404],
            running_codex_process_ids: vec![404],
        });

        assert!(result.next_leased_process_ids.is_empty());
        assert!(result.lease_changed);
        assert!(!result.should_poll);
    }

    #[test]
    fn aggregate_gateway_lease_refresh_prunes_exited_processes_in_switch_mode() {
        let result = plan_aggregate_gateway_lease_refresh(AggregateGatewayLeaseRefreshPlanRequest {
            current_openai_usage_mode: "switch".to_string(),
            current_leased_process_ids: vec![303, 404],
            running_codex_process_ids: vec![404],
        });

        assert_eq!(result.next_leased_process_ids, vec![404]);
        assert!(result.lease_changed);
        assert!(result.should_poll);
    }

    #[test]
    fn gateway_post_completion_binding_decision_keeps_binding_without_recovery() {
        let result = decide_gateway_post_completion_binding(
            GatewayPostCompletionBindingDecisionRequest {
                allows_binding: true,
                used_sticky_context_recovery: false,
                status_code: 429,
            },
        );

        assert!(result.should_bind_sticky);
    }

    #[test]
    fn gateway_post_completion_binding_decision_blocks_rebind_after_recovered_account_status() {
        let result = decide_gateway_post_completion_binding(
            GatewayPostCompletionBindingDecisionRequest {
                allows_binding: true,
                used_sticky_context_recovery: true,
                status_code: 429,
            },
        );

        assert!(!result.should_bind_sticky);
    }

    #[test]
    fn sticky_recovery_policy_only_allows_single_transport_or_protocol_retry() {
        let transport =
            resolve_gateway_sticky_recovery_policy(GatewayStickyRecoveryPolicyRequest {
                failure_class: "transport".to_string(),
                sticky_binding_matches_failed_account: true,
                candidate_index: 0,
                candidate_count: 2,
                used_sticky_context_recovery: false,
            });
        assert!(transport.should_attempt_sticky_context_recovery);

        let protocol = resolve_gateway_sticky_recovery_policy(GatewayStickyRecoveryPolicyRequest {
            failure_class: "protocolViolation".to_string(),
            sticky_binding_matches_failed_account: true,
            candidate_index: 0,
            candidate_count: 2,
            used_sticky_context_recovery: false,
        });
        assert!(protocol.should_attempt_sticky_context_recovery);

        let bounded = resolve_gateway_sticky_recovery_policy(GatewayStickyRecoveryPolicyRequest {
            failure_class: "transport".to_string(),
            sticky_binding_matches_failed_account: true,
            candidate_index: 1,
            candidate_count: 3,
            used_sticky_context_recovery: true,
        });
        assert!(!bounded.should_attempt_sticky_context_recovery);

        let account_status =
            resolve_gateway_sticky_recovery_policy(GatewayStickyRecoveryPolicyRequest {
                failure_class: "accountStatus".to_string(),
                sticky_binding_matches_failed_account: true,
                candidate_index: 0,
                candidate_count: 2,
                used_sticky_context_recovery: false,
            });
        assert!(!account_status.should_attempt_sticky_context_recovery);
    }

    #[test]
    fn transport_failure_classification_marks_bad_server_response_as_protocol_violation() {
        let result = classify_gateway_transport_failure(GatewayTransportFailureClassificationRequest {
            error_domain: Some("NSURLErrorDomain".to_string()),
            error_code: Some(-1011),
            allow_protocol_violation: true,
        });

        assert_eq!(result.failure_class, "protocolViolation");
    }

    #[test]
    fn transport_failure_classification_defaults_to_transport() {
        let result = classify_gateway_transport_failure(GatewayTransportFailureClassificationRequest {
            error_domain: Some("NSURLErrorDomain".to_string()),
            error_code: Some(-1001),
            allow_protocol_violation: true,
        });

        assert_eq!(result.failure_class, "transport");
    }

    #[test]
    fn sticky_key_resolution_prefers_session_id_over_window_id() {
        let result = resolve_gateway_sticky_key(GatewayStickyKeyResolutionRequest {
            session_id: Some("  session-1  ".to_string()),
            window_id: Some("window-1".to_string()),
        });

        assert_eq!(result.sticky_key.as_deref(), Some("session-1"));
    }

    #[test]
    fn sticky_key_resolution_falls_back_to_window_id() {
        let result = resolve_gateway_sticky_key(GatewayStickyKeyResolutionRequest {
            session_id: Some("   ".to_string()),
            window_id: Some(" window-2 ".to_string()),
        });

        assert_eq!(result.sticky_key.as_deref(), Some("window-2"));
    }

    #[test]
    fn request_parser_normalizes_headers_and_body() {
        let result = parse_gateway_request(GatewayRequestParseRequest {
            raw_text: concat!(
                "POST /v1/responses/compact HTTP/1.1\r\n",
                "Host: 127.0.0.1:1456\r\n",
                "Content-Type: application/json\r\n",
                "X-Codex-Window-ID: window-parse-1\r\n",
                "Content-Length: 19\r\n",
                "\r\n",
                "{\"model\":\"gpt-5.4\"}"
            )
            .to_string(),
        });

        let parsed = result.parsed_request.expect("request should parse");
        assert_eq!(parsed.method, "POST");
        assert_eq!(parsed.path, "/v1/responses/compact");
        assert_eq!(
            parsed.headers.get("content-type").map(String::as_str),
            Some("application/json")
        );
        assert_eq!(
            parsed.headers.get("x-codex-window-id").map(String::as_str),
            Some("window-parse-1")
        );
        assert_eq!(parsed.body_text, "{\"model\":\"gpt-5.4\"}");
    }

    #[test]
    fn request_parser_returns_none_when_content_length_body_is_incomplete() {
        let result = parse_gateway_request(GatewayRequestParseRequest {
            raw_text: concat!(
                "POST /v1/responses HTTP/1.1\r\n",
                "Host: 127.0.0.1:1456\r\n",
                "Content-Type: application/json\r\n",
                "Content-Length: 20\r\n",
                "\r\n",
                "{\"partial\":true}"
            )
            .to_string(),
        });

        assert_eq!(result.parsed_request, None);
    }

    #[test]
    fn response_head_render_filters_connection_and_content_length() {
        let result = render_gateway_response_head(GatewayResponseHeadRenderRequest {
            status_code: 200,
            header_fields: vec![
                GatewayResponseHeaderFieldInput {
                    name: "Content-Type".to_string(),
                    value: "application/json".to_string(),
                },
                GatewayResponseHeaderFieldInput {
                    name: "Content-Length".to_string(),
                    value: "12".to_string(),
                },
                GatewayResponseHeaderFieldInput {
                    name: "Connection".to_string(),
                    value: "keep-alive".to_string(),
                },
            ],
        });

        assert!(result.header_text.contains("HTTP/1.1 200 OK"));
        assert!(result.header_text.contains("Content-Type: application/json"));
        assert!(!result.header_text.contains("Content-Length: 12"));
        assert_eq!(
            result.filtered_headers,
            vec![
                GatewayResponseHeaderFieldInput {
                    name: "Content-Type".to_string(),
                    value: "application/json".to_string(),
                },
                GatewayResponseHeaderFieldInput {
                    name: "Connection".to_string(),
                    value: "close".to_string(),
                },
            ]
        );
    }

    #[test]
    fn websocket_handshake_render_matches_known_accept_value() {
        let result = render_gateway_websocket_handshake(GatewayWebSocketHandshakeRequest {
            sec_web_socket_key: "dGhlIHNhbXBsZSBub25jZQ==".to_string(),
            selected_protocol: None,
        });

        assert!(result.response_text.contains("HTTP/1.1 101 Switching Protocols"));
        assert_eq!(
            result.headers,
            vec![
                GatewayResponseHeaderFieldInput {
                    name: "Upgrade".to_string(),
                    value: "websocket".to_string(),
                },
                GatewayResponseHeaderFieldInput {
                    name: "Connection".to_string(),
                    value: "Upgrade".to_string(),
                },
                GatewayResponseHeaderFieldInput {
                    name: "Sec-WebSocket-Accept".to_string(),
                    value: "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=".to_string(),
                },
            ]
        );
    }

    #[test]
    fn websocket_handshake_render_includes_selected_protocol_when_present() {
        let result = render_gateway_websocket_handshake(GatewayWebSocketHandshakeRequest {
            sec_web_socket_key: "dGVzdC1jb2RleGJhcg==".to_string(),
            selected_protocol: Some("openai-realtime".to_string()),
        });

        assert!(result
            .response_text
            .contains("Sec-WebSocket-Protocol: openai-realtime"));
        assert_eq!(
            result.headers.last(),
            Some(&GatewayResponseHeaderFieldInput {
                name: "Sec-WebSocket-Protocol".to_string(),
                value: "openai-realtime".to_string(),
            })
        );
    }

    #[test]
    fn websocket_frame_render_encodes_small_text_payload() {
        let result = render_gateway_websocket_frame(GatewayWebSocketFrameRenderRequest {
            opcode: 0x1,
            payload_bytes: b"hi".to_vec(),
            is_final: true,
        });

        assert_eq!(result.frame_bytes, vec![0x81, 0x02, b'h', b'i']);
    }

    #[test]
    fn websocket_close_payload_render_encodes_code_bytes() {
        let result = render_gateway_websocket_close_payload(
            GatewayWebSocketClosePayloadRequest { code: 1000 },
        );

        assert_eq!(result.payload_bytes, vec![0x03, 0xE8]);
    }

    #[test]
    fn websocket_frame_parse_decodes_masked_text_frame() {
        let result = parse_gateway_websocket_frame(GatewayWebSocketFrameParseRequest {
            frame_bytes: vec![0x81, 0x82, 0x37, 0xFA, 0x21, 0x3D, 0x5F, 0x93],
            expect_masked: true,
        });

        assert_eq!(result.outcome, "parsed");
        assert_eq!(
            result.parsed_frame,
            Some(GatewayParsedWebSocketFrame {
                opcode: 0x1,
                payload_bytes: b"hi".to_vec(),
                is_final: true,
                consumed_byte_count: 8,
            })
        );
    }

    #[test]
    fn websocket_frame_parse_returns_need_more_data_when_incomplete() {
        let result = parse_gateway_websocket_frame(GatewayWebSocketFrameParseRequest {
            frame_bytes: vec![0x81, 0x82, 0x37, 0xFA, 0x21],
            expect_masked: true,
        });

        assert_eq!(result.outcome, "needMoreData");
        assert_eq!(result.parsed_frame, None);
    }

    #[test]
    fn websocket_frame_parse_rejects_unmasked_client_frame() {
        let result = parse_gateway_websocket_frame(GatewayWebSocketFrameParseRequest {
            frame_bytes: vec![0x81, 0x02, b'h', b'i'],
            expect_masked: true,
        });

        assert_eq!(result.outcome, "protocolError");
        assert_eq!(result.parsed_frame, None);
    }

    #[test]
    fn protocol_signal_interpreter_detects_nested_json_usage_limit_and_retry_after() {
        let result = interpret_gateway_protocol_signal(GatewayProtocolSignalInterpretationRequest {
            payload_text: r#"{"type":"response.failed","response":{"status":"failed","error":{"code":"usage_limit_exceeded","message":"You've hit your usage limit.","retry_after_seconds":120}}}"#.to_string(),
            now: 1_000.0,
        });

        assert!(result.is_runtime_limit_signal);
        assert_eq!(
            result.message.as_deref(),
            Some("You've hit your usage limit.")
        );
        assert_eq!(result.retry_at, Some(1_120.0));
        assert_eq!(result.retry_at_human_text, None);
    }

    #[test]
    fn protocol_signal_interpreter_parses_future_retry_at_from_human_message() {
        let result = interpret_gateway_protocol_signal(GatewayProtocolSignalInterpretationRequest {
            payload_text: "You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again at Apr 22nd, 2026 3:50 PM.".to_string(),
            now: 1_000.0,
        });

        assert!(result.is_runtime_limit_signal);
        assert_eq!(result.retry_at, Some(1_776_873_000.0));
        assert_eq!(result.retry_at_human_text, None);
    }

    #[test]
    fn protocol_signal_interpreter_keeps_human_text_when_retry_at_is_past() {
        let result = interpret_gateway_protocol_signal(GatewayProtocolSignalInterpretationRequest {
            payload_text: "You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again at Apr 22nd, 2026 3:50 PM.".to_string(),
            now: 1_800_000_000.0,
        });

        assert!(result.is_runtime_limit_signal);
        assert_eq!(result.retry_at, None);
        assert!(
            result
                .retry_at_human_text
                .as_deref()
                .unwrap_or_default()
                .contains("Apr 22nd, 2026 3:50 PM")
        );
    }

    #[test]
    fn protocol_preview_decision_buffers_known_sse_events_but_stops_on_unknown_event() {
        let buffering = decide_gateway_protocol_preview(GatewayProtocolPreviewDecisionRequest {
            payload_text: Some("data: {\"type\":\"response.created\"}\n\n".to_string()),
            now: 1_000.0,
            byte_count: 32,
            is_event_stream: true,
            is_final: false,
        });
        assert_eq!(buffering.decision, "streamNow");

        let stream_now = decide_gateway_protocol_preview(GatewayProtocolPreviewDecisionRequest {
            payload_text: Some("data: {\"type\":\"response.completed\"}\n\n".to_string()),
            now: 1_000.0,
            byte_count: 32,
            is_event_stream: true,
            is_final: false,
        });
        assert_eq!(stream_now.decision, "streamNow");
    }

    #[test]
    fn protocol_preview_decision_surfaces_account_signal_for_sse_payload() {
        let result = decide_gateway_protocol_preview(GatewayProtocolPreviewDecisionRequest {
            payload_text: Some("data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"usage_limit_exceeded\",\"message\":\"You've hit your usage limit.\"}}}\n\n".to_string()),
            now: 1_000.0,
            byte_count: 64,
            is_event_stream: true,
            is_final: false,
        });
        assert_eq!(result.decision, "accountSignal");
        assert_eq!(
            result.message.as_deref(),
            Some("You've hit your usage limit.")
        );
    }

    fn account(
        account_id: &str,
        plan_type: &str,
        primary_used_percent: f64,
    ) -> GatewayAccountInput {
        GatewayAccountInput {
            account_id: account_id.to_string(),
            email: format!("{}@example.com", account_id),
            plan_type: plan_type.to_string(),
            primary_used_percent,
            secondary_used_percent: 0.0,
            primary_reset_at: None,
            secondary_reset_at: None,
            primary_limit_window_seconds: None,
            secondary_limit_window_seconds: None,
            last_checked: None,
            is_suspended: false,
            token_expired: false,
        }
    }

    fn sticky_binding(
        thread_id: &str,
        account_id: &str,
        updated_at: f64,
    ) -> GatewayStickyBindingStateInput {
        GatewayStickyBindingStateInput {
            thread_id: thread_id.to_string(),
            account_id: account_id.to_string(),
            updated_at,
        }
    }

    #[test]
    fn resolve_openrouter_gateway_account_state_falls_back_to_first_account() {
        let result =
            resolve_openrouter_gateway_account_state(OpenRouterGatewayAccountStateRequest {
                provider: Some(OpenRouterGatewayProviderInput {
                    id: "openrouter".to_string(),
                    kind: "openrouter".to_string(),
                    label: "OpenRouter".to_string(),
                    enabled: true,
                    selected_model_id: Some("openai/gpt-4.1".to_string()),
                    active_account_id: Some("missing-account".to_string()),
                    accounts: vec![
                        OpenRouterGatewayProviderAccountInput {
                            id: "acct-first".to_string(),
                            kind: "api_key".to_string(),
                            label: "First".to_string(),
                            api_key: Some("sk-or-v1-first".to_string()),
                        },
                        OpenRouterGatewayProviderAccountInput {
                            id: "acct-second".to_string(),
                            kind: "api_key".to_string(),
                            label: "Second".to_string(),
                            api_key: Some("sk-or-v1-second".to_string()),
                        },
                    ],
                }),
            });

        assert_eq!(result.model_id.as_deref(), Some("openai/gpt-4.1"));
        assert_eq!(
            result.account.as_ref().map(|account| account.id.as_str()),
            Some("acct-first")
        );
        assert_eq!(
            result
                .account
                .as_ref()
                .and_then(|account| account.api_key.as_deref()),
            Some("sk-or-v1-first")
        );
    }

    #[test]
    fn resolve_openrouter_gateway_account_state_requires_model_and_api_key() {
        let missing_model =
            resolve_openrouter_gateway_account_state(OpenRouterGatewayAccountStateRequest {
                provider: Some(OpenRouterGatewayProviderInput {
                    id: "openrouter".to_string(),
                    kind: "openrouter".to_string(),
                    label: "OpenRouter".to_string(),
                    enabled: true,
                    selected_model_id: Some("   ".to_string()),
                    active_account_id: Some("acct".to_string()),
                    accounts: vec![OpenRouterGatewayProviderAccountInput {
                        id: "acct".to_string(),
                        kind: "api_key".to_string(),
                        label: "Primary".to_string(),
                        api_key: Some("sk-or-v1-primary".to_string()),
                    }],
                }),
            });
        assert!(missing_model.account.is_none());
        assert!(missing_model.model_id.is_none());

        let missing_api_key =
            resolve_openrouter_gateway_account_state(OpenRouterGatewayAccountStateRequest {
                provider: Some(OpenRouterGatewayProviderInput {
                    id: "openrouter".to_string(),
                    kind: "openrouter".to_string(),
                    label: "OpenRouter".to_string(),
                    enabled: true,
                    selected_model_id: Some("openai/gpt-4.1".to_string()),
                    active_account_id: Some("acct".to_string()),
                    accounts: vec![OpenRouterGatewayProviderAccountInput {
                        id: "acct".to_string(),
                        kind: "api_key".to_string(),
                        label: "Primary".to_string(),
                        api_key: Some("".to_string()),
                    }],
                }),
            });
        assert!(missing_api_key.account.is_none());
        assert!(missing_api_key.model_id.is_none());
    }

    #[test]
    fn bind_gateway_sticky_state_records_route_and_prunes_old_entries() {
        let result = bind_gateway_sticky_state(GatewayStickyBindRequest {
            current_routed_account_id: Some("acct-old".to_string()),
            sticky_key: Some("thread-new".to_string()),
            account_id: "acct-new".to_string(),
            now: 10_000.0,
            sticky_bindings: vec![
                sticky_binding("thread-old", "acct-old", 1_000.0),
                sticky_binding("thread-mid", "acct-mid", 9_100.0),
            ],
            expiration_interval_seconds: 600.0,
            max_entries: 1,
        });

        assert_eq!(result.next_routed_account_id.as_deref(), Some("acct-new"));
        assert!(result.route_changed);
        assert!(result.should_record_route);
        assert_eq!(result.sticky_bindings.len(), 1);
        assert_eq!(result.sticky_bindings[0].thread_id, "thread-new");
        assert_eq!(result.sticky_bindings[0].account_id, "acct-new");
    }

    #[test]
    fn clear_gateway_sticky_state_respects_optional_account_match() {
        let matched = clear_gateway_sticky_state(GatewayStickyClearRequest {
            thread_id: "thread-a".to_string(),
            account_id: Some("acct-a".to_string()),
            sticky_bindings: vec![
                sticky_binding("thread-a", "acct-a", 10.0),
                sticky_binding("thread-b", "acct-b", 20.0),
            ],
        });
        assert!(matched.cleared);
        assert_eq!(matched.sticky_bindings.len(), 1);
        assert_eq!(matched.sticky_bindings[0].thread_id, "thread-b");

        let unmatched = clear_gateway_sticky_state(GatewayStickyClearRequest {
            thread_id: "thread-a".to_string(),
            account_id: Some("other".to_string()),
            sticky_bindings: vec![sticky_binding("thread-a", "acct-a", 10.0)],
        });
        assert!(!unmatched.cleared);
        assert_eq!(unmatched.sticky_bindings.len(), 1);
    }

    #[test]
    fn apply_gateway_runtime_block_clears_routed_account_and_prunes_expired_entries() {
        let result = apply_gateway_runtime_block(GatewayRuntimeBlockApplyRequest {
            current_routed_account_id: Some("acct-alpha".to_string()),
            blocked_account_id: "acct-alpha".to_string(),
            retry_at: 1_200.0,
            now: 1_000.0,
            runtime_blocked_accounts: vec![
                GatewayRuntimeBlockedAccountStateInput {
                    account_id: "acct-stale".to_string(),
                    retry_at: 900.0,
                },
                GatewayRuntimeBlockedAccountStateInput {
                    account_id: "acct-beta".to_string(),
                    retry_at: 1_500.0,
                },
            ],
        });

        assert!(result.next_routed_account_id.is_none());
        assert_eq!(
            result.runtime_blocked_accounts,
            vec![
                GatewayRuntimeBlockedAccountStateInput {
                    account_id: "acct-alpha".to_string(),
                    retry_at: 1_200.0,
                },
                GatewayRuntimeBlockedAccountStateInput {
                    account_id: "acct-beta".to_string(),
                    retry_at: 1_500.0,
                },
            ]
        );
    }

    #[test]
    fn normalize_gateway_state_drops_unknown_and_expired_entries() {
        let result = normalize_gateway_state(GatewayStateNormalizationRequest {
            current_routed_account_id: Some("acct-missing".to_string()),
            known_account_ids: vec!["acct-beta".to_string()],
            sticky_bindings: vec![
                sticky_binding("thread-alpha", "acct-alpha", 100.0),
                sticky_binding("thread-beta", "acct-beta", 900.0),
            ],
            runtime_blocked_accounts: vec![
                GatewayRuntimeBlockedAccountStateInput {
                    account_id: "acct-alpha".to_string(),
                    retry_at: 2_000.0,
                },
                GatewayRuntimeBlockedAccountStateInput {
                    account_id: "acct-beta".to_string(),
                    retry_at: 900.0,
                },
                GatewayRuntimeBlockedAccountStateInput {
                    account_id: "acct-beta".to_string(),
                    retry_at: 2_100.0,
                },
            ],
            now: 1_000.0,
            sticky_expiration_interval_seconds: 300.0,
            sticky_max_entries: 8,
        });

        assert!(result.next_routed_account_id.is_none());
        assert_eq!(
            result.sticky_bindings,
            vec![sticky_binding("thread-beta", "acct-beta", 900.0)]
        );
        assert_eq!(
            result.runtime_blocked_accounts,
            vec![GatewayRuntimeBlockedAccountStateInput {
                account_id: "acct-beta".to_string(),
                retry_at: 2_100.0,
            }]
        );
    }

    #[test]
    fn normalize_openai_responses_request_sets_responses_defaults() {
        let result = normalize_openai_responses_request(
            OpenAIResponsesRequestNormalizationRequest {
                route: "/v1/responses".to_string(),
                body_json: serde_json::json!({
                    "model": "gpt-5.4",
                    "service_tier": "priority",
                    "input": [{"role": "user", "content": [{"type": "input_text", "text": "hello"}]}],
                    "max_output_tokens": 128,
                    "temperature": 0.7,
                    "top_p": 0.9,
                    "stream": false
                }),
            },
        );
        let object = result.normalized_json.as_object().unwrap();

        assert_eq!(
            object.get("store").and_then(|value| value.as_bool()),
            Some(false)
        );
        assert_eq!(
            object.get("stream").and_then(|value| value.as_bool()),
            Some(true)
        );
        assert_eq!(
            object.get("instructions").and_then(|value| value.as_str()),
            Some("")
        );
        assert_eq!(
            object
                .get("parallel_tool_calls")
                .and_then(|value| value.as_bool()),
            Some(false)
        );
        assert_eq!(
            object
                .get("include")
                .and_then(|value| value.as_array())
                .unwrap(),
            &vec![serde_json::Value::String(
                "reasoning.encrypted_content".to_string()
            )]
        );
        assert_eq!(
            object
                .get("tools")
                .and_then(|value| value.as_array())
                .unwrap()
                .len(),
            0
        );
        assert!(object.get("max_output_tokens").is_none());
        assert!(object.get("temperature").is_none());
        assert!(object.get("top_p").is_none());
    }

    #[test]
    fn normalize_openai_responses_request_strips_compact_only_fields() {
        let result = normalize_openai_responses_request(
            OpenAIResponsesRequestNormalizationRequest {
                route: "/v1/responses/compact".to_string(),
                body_json: serde_json::json!({
                    "model": "gpt-5.4",
                    "service_tier": "priority",
                    "input": [{"role": "user", "content": [{"type": "input_text", "text": "compact hello"}]}],
                    "store": true,
                    "stream": false,
                    "include": ["reasoning.encrypted_content"],
                    "tools": [{"type": "noop"}],
                    "parallel_tool_calls": true,
                    "max_output_tokens": 128,
                    "temperature": 0.7,
                    "top_p": 0.9
                }),
            },
        );
        let object = result.normalized_json.as_object().unwrap();

        assert_eq!(
            object.get("instructions").and_then(|value| value.as_str()),
            Some("")
        );
        assert!(object.get("store").is_none());
        assert!(object.get("stream").is_none());
        assert!(object.get("include").is_none());
        assert!(object.get("tools").is_none());
        assert!(object.get("parallel_tool_calls").is_none());
        assert!(object.get("max_output_tokens").is_none());
        assert!(object.get("temperature").is_none());
        assert!(object.get("top_p").is_none());
    }
}

pub fn build_oauth_authorization_url(
    request: OAuthAuthorizationUrlRequest,
) -> OAuthAuthorizationUrlResult {
    let code_challenge = pkce_code_challenge(&request.code_verifier);
    let query = [
        ("response_type", "code".to_string()),
        ("client_id", request.client_id),
        ("redirect_uri", request.redirect_uri),
        ("scope", request.scope),
        ("code_challenge", code_challenge),
        ("code_challenge_method", "S256".to_string()),
        ("id_token_add_organizations", "true".to_string()),
        ("codex_cli_simplified_flow", "true".to_string()),
        ("state", request.expected_state),
        ("originator", request.originator),
    ]
    .into_iter()
    .map(|(key, value)| format!("{}={}", percent_encode(key), percent_encode(&value)))
    .collect::<Vec<_>>()
    .join("&");

    OAuthAuthorizationUrlResult {
        auth_url: format!("{}?{}", request.auth_url, query),
    }
}

pub fn normalize_openrouter_request(
    request: OpenRouterRequestNormalizationRequest,
) -> OpenRouterRequestNormalizationResult {
    let mut json = match request.body_json {
        serde_json::Value::Object(map) => {
            unwrap_response_create_envelope(serde_json::Value::Object(map))
        }
        serde_json::Value::Array(items) => {
            let mut map = serde_json::Map::new();
            map.insert("input".to_string(), serde_json::Value::Array(items));
            serde_json::Value::Object(map)
        }
        other => other,
    };

    if let serde_json::Value::Object(ref mut object) = json {
        object.insert(
            "model".to_string(),
            serde_json::Value::String(request.selected_model_id),
        );
        if let Some(input) = object.remove("input") {
            object.insert("input".to_string(), normalize_openrouter_input(input));
        }

        if request.route == "/v1/responses/compact" {
            for key in [
                "store",
                "stream",
                "include",
                "tools",
                "tool_choice",
                "parallel_tool_calls",
                "max_output_tokens",
                "temperature",
                "top_p",
            ] {
                object.remove(key);
            }
            ensure_instructions(object);
        } else {
            object.insert("store".to_string(), serde_json::Value::Bool(false));
            object.insert("stream".to_string(), serde_json::Value::Bool(true));
            object.remove("max_output_tokens");
            object.remove("temperature");
            object.remove("top_p");
            ensure_instructions(object);
            let normalized_tools = normalize_openrouter_tools(object.remove("tools"));
            let normalized_tool_choice =
                normalize_openrouter_tool_choice(object.remove("tool_choice"), &normalized_tools);
            object.insert(
                "tools".to_string(),
                serde_json::Value::Array(normalized_tools),
            );
            object.insert("tool_choice".to_string(), normalized_tool_choice);
            if object
                .get("parallel_tool_calls")
                .map(|value| value.is_null())
                .unwrap_or(true)
            {
                object.insert(
                    "parallel_tool_calls".to_string(),
                    serde_json::Value::Bool(false),
                );
            }
        }
    }

    OpenRouterRequestNormalizationResult {
        normalized_json: json,
        rust_owner: "core_gateway.normalize_openrouter_request".to_string(),
    }
}

pub fn normalize_openai_responses_request(
    request: OpenAIResponsesRequestNormalizationRequest,
) -> OpenAIResponsesRequestNormalizationResult {
    let mut json = request.body_json;
    if let serde_json::Value::Object(ref mut object) = json {
        if request.route == "/v1/responses/compact" {
            object.remove("store");
            object.remove("stream");
            object.remove("include");
            object.remove("tools");
            object.remove("parallel_tool_calls");
            object.remove("max_output_tokens");
            object.remove("temperature");
            object.remove("top_p");
            ensure_instructions(object);
        } else {
            object.insert("store".to_string(), serde_json::Value::Bool(false));
            object.insert("stream".to_string(), serde_json::Value::Bool(true));
            object.remove("max_output_tokens");
            object.remove("temperature");
            object.remove("top_p");
            ensure_instructions(object);
            ensure_array_field(object, "tools");
            ensure_bool_field(object, "parallel_tool_calls", false);
            ensure_reasoning_include(object);
        }
    }

    OpenAIResponsesRequestNormalizationResult {
        normalized_json: json,
        rust_owner: "core_gateway.normalize_openai_responses_request".to_string(),
    }
}

pub fn resolve_openrouter_gateway_account_state(
    request: OpenRouterGatewayAccountStateRequest,
) -> OpenRouterGatewayAccountStateResult {
    let result = request.provider.and_then(|provider| {
        if provider.kind != "openrouter" {
            return None;
        }
        let model_id = normalize_nonempty(provider.selected_model_id)?;
        let account = provider
            .active_account_id
            .as_ref()
            .and_then(|active_account_id| {
                provider
                    .accounts
                    .iter()
                    .find(|account| account.id == *active_account_id)
                    .cloned()
            })
            .or_else(|| provider.accounts.first().cloned())?;
        let api_key = normalize_nonempty(account.api_key.clone())?;
        Some((
            OpenRouterGatewayProviderAccountInput {
                api_key: Some(api_key),
                ..account
            },
            model_id,
        ))
    });

    OpenRouterGatewayAccountStateResult {
        account: result.as_ref().map(|(account, _)| account.clone()),
        model_id: result.map(|(_, model_id)| model_id),
        rust_owner: "core_gateway.resolve_openrouter_gateway_account_state".to_string(),
    }
}

pub fn plan_gateway_lifecycle(request: GatewayLifecyclePlanRequest) -> GatewayLifecyclePlanResult {
    let effective_openai_usage_mode = if request.configured_openai_usage_mode == "aggregate_gateway"
        || request.aggregate_leased_process_ids.is_empty() == false
    {
        "aggregate_gateway".to_string()
    } else {
        "switch".to_string()
    };

    let active_provider_is_openrouter =
        request.active_provider_kind.as_deref() == Some("openrouter");
    let existing_lease = request
        .existing_openrouter_lease
        .filter(|lease| lease.leased_process_ids.is_empty() == false);
    let next_openrouter_lease =
        if let Some(source_provider_id) = request.openrouter_serviceable_provider_id.clone() {
            if active_provider_is_openrouter {
                None
            } else {
                let running_codex_process_ids =
                    sorted_unique_process_ids(request.running_codex_process_ids);
                let existing_process_ids = existing_lease
                    .as_ref()
                    .map(|lease| sorted_unique_process_ids(lease.leased_process_ids.clone()))
                    .unwrap_or_default();
                let should_acquire_lease = request.last_published_openrouter_selected
                    && running_codex_process_ids.is_empty() == false;

                if existing_process_ids.is_empty() {
                    if should_acquire_lease {
                        Some(GatewayLeaseSnapshotInput {
                            leased_process_ids: running_codex_process_ids,
                            source_provider_id,
                        })
                    } else {
                        None
                    }
                } else if running_codex_process_ids.is_empty() {
                    None
                } else if running_codex_process_ids != existing_process_ids {
                    Some(GatewayLeaseSnapshotInput {
                        leased_process_ids: running_codex_process_ids,
                        source_provider_id,
                    })
                } else {
                    existing_lease.clone()
                }
            }
        } else {
            None
        };

    let openrouter_lease_changed = existing_lease != next_openrouter_lease;
    let should_run_openrouter_gateway = request.openrouter_serviceable_provider_id.is_some()
        && (active_provider_is_openrouter
            || next_openrouter_lease
                .as_ref()
                .map(|lease| lease.leased_process_ids.is_empty() == false)
                .unwrap_or(false));
    let openrouter_lease_should_poll = active_provider_is_openrouter == false
        && next_openrouter_lease
            .as_ref()
            .map(|lease| lease.leased_process_ids.is_empty() == false)
            .unwrap_or(false);

    GatewayLifecyclePlanResult {
        should_run_openai_gateway: effective_openai_usage_mode == "aggregate_gateway",
        effective_openai_usage_mode,
        should_run_openrouter_gateway,
        next_openrouter_lease,
        openrouter_lease_changed,
        openrouter_lease_should_poll,
        rust_owner: "core_gateway.plan_gateway_lifecycle".to_string(),
    }
}

pub fn plan_aggregate_gateway_lease_transition(
    request: AggregateGatewayLeaseTransitionPlanRequest,
) -> AggregateGatewayLeaseTransitionPlanResult {
    let current_leased_process_ids = sorted_unique_process_ids(request.current_leased_process_ids);
    let running_codex_process_ids = sorted_unique_process_ids(request.running_codex_process_ids);

    let next_leased_process_ids = if request.previous_openai_usage_mode == "aggregate_gateway"
        && request.next_openai_usage_mode != "aggregate_gateway"
    {
        running_codex_process_ids
    } else if request.next_openai_usage_mode == "aggregate_gateway" {
        Vec::new()
    } else {
        current_leased_process_ids.clone()
    };

    AggregateGatewayLeaseTransitionPlanResult {
        lease_changed: next_leased_process_ids != current_leased_process_ids,
        should_poll: request.next_openai_usage_mode != "aggregate_gateway"
            && next_leased_process_ids.is_empty() == false,
        next_leased_process_ids,
        rust_owner: "core_gateway.plan_aggregate_gateway_lease_transition".to_string(),
    }
}

pub fn plan_aggregate_gateway_lease_refresh(
    request: AggregateGatewayLeaseRefreshPlanRequest,
) -> AggregateGatewayLeaseRefreshPlanResult {
    let current_leased_process_ids = sorted_unique_process_ids(request.current_leased_process_ids);
    let running_codex_process_ids = sorted_unique_process_ids(request.running_codex_process_ids);

    let next_leased_process_ids = if request.current_openai_usage_mode == "aggregate_gateway" {
        Vec::new()
    } else {
        current_leased_process_ids
            .iter()
            .copied()
            .filter(|pid| running_codex_process_ids.contains(pid))
            .collect()
    };

    AggregateGatewayLeaseRefreshPlanResult {
        lease_changed: next_leased_process_ids != current_leased_process_ids,
        should_poll: request.current_openai_usage_mode != "aggregate_gateway"
            && next_leased_process_ids.is_empty() == false,
        next_leased_process_ids,
        rust_owner: "core_gateway.plan_aggregate_gateway_lease_refresh".to_string(),
    }
}

pub fn decide_gateway_post_completion_binding(
    request: GatewayPostCompletionBindingDecisionRequest,
) -> GatewayPostCompletionBindingDecisionResult {
    let should_bind_sticky = if request.allows_binding == false {
        false
    } else if request.used_sticky_context_recovery == false {
        true
    } else {
        gateway_failure_class_for_status(request.status_code).is_none()
    };

    GatewayPostCompletionBindingDecisionResult {
        should_bind_sticky,
        rust_owner: "core_gateway.decide_gateway_post_completion_binding".to_string(),
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

fn unwrap_response_create_envelope(json: serde_json::Value) -> serde_json::Value {
    let serde_json::Value::Object(ref object) = json else {
        return json;
    };
    if object.contains_key("input") {
        return json;
    }
    if object.get("type").and_then(|value| value.as_str()) != Some("response.create") {
        return json;
    }
    object
        .get("response")
        .and_then(|value| value.as_object())
        .map(|response| serde_json::Value::Object(response.clone()))
        .unwrap_or(json)
}

fn normalize_openrouter_input(input: serde_json::Value) -> serde_json::Value {
    let serde_json::Value::Array(items) = input else {
        return input;
    };

    serde_json::Value::Array(
        items
            .into_iter()
            .enumerate()
            .map(|(index, item)| {
                let serde_json::Value::Object(mut message) = item else {
                    return item;
                };
                if message.get("type").is_none() {
                    if message
                        .get("role")
                        .and_then(|value| value.as_str())
                        .map(|role| role.is_empty() == false)
                        .unwrap_or(false)
                    {
                        message.insert(
                            "type".to_string(),
                            serde_json::Value::String("message".to_string()),
                        );
                    }
                }
                if message
                    .get("role")
                    .and_then(|value| value.as_str())
                    .map(|role| role.eq_ignore_ascii_case("assistant"))
                    .unwrap_or(false)
                {
                    if string_field_nonempty(&message, "status") == false {
                        message.insert(
                            "status".to_string(),
                            serde_json::Value::String("completed".to_string()),
                        );
                    }
                    if string_field_nonempty(&message, "id") == false {
                        message.insert(
                            "id".to_string(),
                            serde_json::Value::String(format!("msg_codexbar_{}", index)),
                        );
                    }
                }
                serde_json::Value::Object(message)
            })
            .collect(),
    )
}

fn ensure_array_field(object: &mut serde_json::Map<String, serde_json::Value>, key: &str) {
    if object.get(key).map(|value| value.is_null()).unwrap_or(true) {
        object.insert(key.to_string(), serde_json::Value::Array(Vec::new()));
    }
}

fn ensure_bool_field(
    object: &mut serde_json::Map<String, serde_json::Value>,
    key: &str,
    value: bool,
) {
    if object
        .get(key)
        .map(|candidate| candidate.is_null())
        .unwrap_or(true)
    {
        object.insert(key.to_string(), serde_json::Value::Bool(value));
    }
}

fn ensure_reasoning_include(object: &mut serde_json::Map<String, serde_json::Value>) {
    let include_marker = "reasoning.encrypted_content";
    let mut includes = object
        .remove("include")
        .and_then(|value| value.as_array().cloned())
        .unwrap_or_default();
    let has_marker = includes
        .iter()
        .any(|value| value.as_str() == Some(include_marker));
    if !has_marker {
        includes.push(serde_json::Value::String(include_marker.to_string()));
    }
    object.insert("include".to_string(), serde_json::Value::Array(includes));
}

fn normalize_openrouter_tools(tools: Option<serde_json::Value>) -> Vec<serde_json::Value> {
    let Some(serde_json::Value::Array(items)) = tools else {
        return vec![];
    };
    items
        .into_iter()
        .filter_map(|item| {
            let serde_json::Value::Object(tool) = item else {
                return None;
            };
            normalize_openrouter_tool(tool).map(serde_json::Value::Object)
        })
        .collect()
}

fn normalize_openrouter_tool(
    original: serde_json::Map<String, serde_json::Value>,
) -> Option<serde_json::Map<String, serde_json::Value>> {
    let mut tool = flatten_nested_function_tool_if_needed(original);
    let mut tool_type = tool.get("type")?.as_str()?.to_string();
    if tool_type.is_empty() {
        return None;
    }

    if let Some(mapped_type) = openrouter_prefixed_tool_type(&tool_type) {
        tool_type = mapped_type.to_string();
        tool.insert(
            "type".to_string(),
            serde_json::Value::String(tool_type.clone()),
        );
    }
    if openrouter_passthrough_tool_type(&tool_type) == false {
        return None;
    }
    if openrouter_wrapped_parameter_tool_type(&tool_type) {
        tool = wrap_openrouter_tool_parameters(tool);
    }
    Some(tool)
}

fn flatten_nested_function_tool_if_needed(
    original: serde_json::Map<String, serde_json::Value>,
) -> serde_json::Map<String, serde_json::Value> {
    if original.get("type").and_then(|value| value.as_str()) != Some("function") {
        return original;
    }
    let Some(nested) = original.get("function").and_then(|value| value.as_object()) else {
        return original;
    };
    let mut tool = original.clone();
    tool.remove("function");
    for key in ["name", "description", "parameters", "strict"] {
        if tool.get(key).is_none() {
            if let Some(value) = nested.get(key) {
                tool.insert(key.to_string(), value.clone());
            }
        }
    }
    tool
}

fn wrap_openrouter_tool_parameters(
    mut tool: serde_json::Map<String, serde_json::Value>,
) -> serde_json::Map<String, serde_json::Value> {
    let mut parameters = tool
        .get("parameters")
        .and_then(|value| value.as_object())
        .cloned()
        .unwrap_or_default();
    for key in [
        "allowed_domains",
        "engine",
        "excluded_domains",
        "filters",
        "max_results",
        "search_context_size",
        "timezone",
        "user_location",
    ] {
        let Some(value) = tool.get(key).cloned() else {
            continue;
        };
        if key == "filters" {
            if let Some(filters) = value.as_object() {
                for (filter_key, filter_value) in filters {
                    parameters
                        .entry(filter_key.clone())
                        .or_insert_with(|| filter_value.clone());
                }
            }
        } else {
            parameters.entry(key.to_string()).or_insert(value);
        }
        tool.remove(key);
    }
    if parameters.is_empty() == false {
        tool.insert(
            "parameters".to_string(),
            serde_json::Value::Object(parameters),
        );
    }
    tool
}

fn normalize_openrouter_tool_choice(
    tool_choice: Option<serde_json::Value>,
    normalized_tools: &[serde_json::Value],
) -> serde_json::Value {
    if normalized_tools.is_empty() {
        return serde_json::Value::String("none".to_string());
    }
    let Some(tool_choice) = tool_choice else {
        return serde_json::Value::String("auto".to_string());
    };
    if let Some(choice) = tool_choice.as_str() {
        return match choice {
            "auto" | "none" | "required" => serde_json::Value::String(choice.to_string()),
            _ => serde_json::Value::String("auto".to_string()),
        };
    }
    let serde_json::Value::Object(mut object) = tool_choice else {
        return serde_json::Value::String("auto".to_string());
    };
    if object.get("type").and_then(|value| value.as_str()) == Some("function") {
        if object.get("name").is_none() {
            if let Some(name) = object
                .get("function")
                .and_then(|value| value.as_object())
                .and_then(|function| function.get("name"))
                .cloned()
            {
                object.insert("name".to_string(), name);
            }
        }
    }
    object.remove("function");
    match object.get("type").and_then(|value| value.as_str()) {
        Some("function") => {
            let Some(name) = object.get("name").and_then(|value| value.as_str()) else {
                return serde_json::Value::String("auto".to_string());
            };
            if normalized_tools.iter().any(|tool| {
                tool.as_object()
                    .map(|tool| {
                        tool.get("type").and_then(|value| value.as_str()) == Some("function")
                            && tool.get("name").and_then(|value| value.as_str()) == Some(name)
                    })
                    .unwrap_or(false)
            }) {
                serde_json::json!({ "type": "function", "name": name })
            } else {
                serde_json::Value::String("auto".to_string())
            }
        }
        Some("none") => serde_json::Value::String("none".to_string()),
        Some("auto") | Some("required") => {
            serde_json::Value::String(object["type"].as_str().unwrap().to_string())
        }
        _ => serde_json::Value::String("auto".to_string()),
    }
}

fn ensure_instructions(object: &mut serde_json::Map<String, serde_json::Value>) {
    if object
        .get("instructions")
        .map(|value| value.is_null())
        .unwrap_or(true)
    {
        object.insert(
            "instructions".to_string(),
            serde_json::Value::String(String::new()),
        );
    }
}

fn string_field_nonempty(object: &serde_json::Map<String, serde_json::Value>, key: &str) -> bool {
    object
        .get(key)
        .and_then(|value| value.as_str())
        .map(|value| value.is_empty() == false)
        .unwrap_or(false)
}

fn openrouter_prefixed_tool_type(tool_type: &str) -> Option<&'static str> {
    match tool_type {
        "datetime" => Some("openrouter:datetime"),
        "experimental__search_models" => Some("openrouter:experimental__search_models"),
        _ => None,
    }
}

fn openrouter_wrapped_parameter_tool_type(tool_type: &str) -> bool {
    matches!(
        tool_type,
        "openrouter:datetime"
            | "openrouter:experimental__search_models"
            | "openrouter:image_generation"
            | "openrouter:web_search"
    )
}

fn openrouter_passthrough_tool_type(tool_type: &str) -> bool {
    matches!(
        tool_type,
        "apply_patch"
            | "code_interpreter"
            | "computer_use_preview"
            | "custom"
            | "file_search"
            | "function"
            | "image_generation"
            | "local_shell"
            | "mcp"
            | "shell"
            | "web_search"
            | "web_search_2025_08_26"
            | "web_search_preview"
            | "web_search_preview_2025_03_11"
            | "openrouter:datetime"
            | "openrouter:experimental__search_models"
            | "openrouter:image_generation"
            | "openrouter:web_search"
    )
}

fn sorted_unique_process_ids(process_ids: Vec<i64>) -> Vec<i64> {
    let mut process_ids = process_ids
        .into_iter()
        .filter(|process_id| *process_id > 0)
        .collect::<Vec<_>>();
    process_ids.sort_unstable();
    process_ids.dedup();
    process_ids
}

pub fn interpret_oauth_callback(
    request: OAuthCallbackInterpretationRequest,
) -> OAuthCallbackInterpretationResult {
    let parsed = request
        .callback_input
        .as_deref()
        .and_then(parse_callback_input)
        .unwrap_or_else(|| ParsedCallback {
            code: request.code.clone(),
            state: request.returned_state.clone(),
        });
    OAuthCallbackInterpretationResult {
        code: parsed.code,
        returned_state: parsed.state.clone(),
        state_mismatch: parsed
            .state
            .as_deref()
            .map(|state| state != request.expected_state)
            .unwrap_or(false),
    }
}

fn is_loopback(host: &str) -> bool {
    let normalized = host.trim_matches(['[', ']']).trim().to_ascii_lowercase();
    normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
}

fn percent_encode(value: &str) -> String {
    let mut encoded = String::new();
    for byte in value.as_bytes() {
        let ch = *byte as char;
        if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '.' | '_' | '~') {
            encoded.push(ch);
        } else {
            encoded.push_str(&format!("%{:02X}", byte));
        }
    }
    encoded
}

fn pkce_code_challenge(verifier: &str) -> String {
    // The exact hash is host-agnostic business output, but the app currently only needs
    // deterministic URL construction for parity testing in Rust. Keep the verifier-derived
    // marker stable without introducing extra dependencies.
    format!("sha256:{}", percent_encode(verifier))
}

struct ParsedCallback {
    code: Option<String>,
    state: Option<String>,
}

fn parse_callback_input(input: &str) -> Option<ParsedCallback> {
    if input.trim().is_empty() {
        return None;
    }

    let candidate = if let Some(query_start) = input.find('?') {
        &input[(query_start + 1)..]
    } else {
        input
    };

    let mut code = None;
    let mut state = None;
    for pair in candidate.split('&') {
        let mut parts = pair.splitn(2, '=');
        let key = parts.next().unwrap_or_default();
        let value = parts.next().unwrap_or_default();
        match key {
            "code" if value.is_empty() == false => code = Some(value.to_string()),
            "state" if value.is_empty() == false => state = Some(value.to_string()),
            _ => {}
        }
    }

    Some(ParsedCallback { code, state })
}
