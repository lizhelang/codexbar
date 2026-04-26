use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use core_model::{
    FfiError, FfiRequest, FfiResponse, RefreshOutcomeRequest, RefreshPlanRequest,
    RenderCodecRequest, RouteRuntimeInput, UsageMergeSuccessRequest,
};

#[unsafe(no_mangle)]
pub extern "C" fn codexbar_portable_core_execute(request_json: *const c_char) -> *mut c_char {
    let response = match parse_request(request_json).and_then(dispatch_request) {
        Ok(result) => FfiResponse {
            ok: true,
            result: Some(result),
            error: None,
        },
        Err(error) => FfiResponse {
            ok: false,
            result: None,
            error: Some(error),
        },
    };

    let response_json = serde_json::to_string(&response).unwrap_or_else(|error| {
        format!(
            "{{\"ok\":false,\"error\":{{\"code\":\"serializationFailure\",\"message\":\"{}\"}}}}",
            error
        )
    });
    CString::new(response_json).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn codexbar_portable_core_free_string(value: *mut c_char) {
    if value.is_null() {
        return;
    }
    unsafe {
        let _ = CString::from_raw(value);
    }
}

fn parse_request(request_json: *const c_char) -> Result<FfiRequest, FfiError> {
    if request_json.is_null() {
        return Err(ffi_error("nullRequest", "request pointer is null"));
    }
    let request_str = unsafe { CStr::from_ptr(request_json) }
        .to_str()
        .map_err(|error| ffi_error("invalidUtf8", &error.to_string()))?;
    serde_json::from_str(request_str)
        .map_err(|error| ffi_error("invalidRequestJson", &error.to_string()))
}

fn dispatch_request(request: FfiRequest) -> Result<serde_json::Value, FfiError> {
    match request.operation.as_str() {
        "canonicalizeConfigAndAccounts" => {
            encode(core_policy::canonicalize_config_and_accounts(decode::<
                core_model::RawConfigInput,
            >(
                request.payload,
            )?))
        }
        "computeRouteRuntimeSnapshot" => {
            encode(core_policy::compute_route_runtime_snapshot(decode::<
                RouteRuntimeInput,
            >(
                request.payload,
            )?))
        }
        "renderCodecBundle" => encode(
            core_codec::render_codec_bundle(decode::<RenderCodecRequest>(request.payload)?)
                .map_err(|message| ffi_error("codecFailure", &message))?,
        ),
        "planRefresh" => encode(core_policy::plan_refresh(decode::<RefreshPlanRequest>(
            request.payload,
        )?)),
        "applyRefreshOutcome" => encode(core_policy::apply_refresh_outcome(decode::<
            RefreshOutcomeRequest,
        >(
            request.payload
        )?)),
        "mergeUsageSuccess" => encode(core_policy::merge_usage_success(decode::<
            UsageMergeSuccessRequest,
        >(request.payload)?)),
        "parseWhamUsage" => encode(core_policy::parse_wham_usage(decode::<
            core_policy::WhamUsageParseRequest,
        >(request.payload)?)),
        "parseWhamUsageText" => encode(core_policy::parse_wham_usage_text(decode::<
            core_policy::WhamUsageTextParseRequest,
        >(request.payload)?)),
        "parseWhamOrganizationName" => encode(core_policy::parse_wham_organization_name(decode::<
            core_policy::WhamOrganizationNameParseRequest,
        >(request.payload)?)),
        "markUsageForbidden" => encode(core_policy::mark_usage_forbidden(decode::<
            core_model::CanonicalAccountSnapshot,
        >(
            request.payload
        )?)),
        "markUsageTokenExpired" => encode(core_policy::mark_usage_token_expired(decode::<
            core_model::CanonicalAccountSnapshot,
        >(
            request.payload,
        )?)),
        "normalizeOpenRouterProviders" => {
            encode(core_policy::normalize_openrouter_providers(decode::<
                core_policy::OpenRouterNormalizationRequest,
            >(
                request.payload,
            )?))
        }
        "makeOpenRouterCompatPersistence" => {
            encode(core_policy::make_openrouter_compat_persistence(decode::<
                core_policy::OpenRouterCompatPersistenceRequest,
            >(
                request.payload,
            )?))
        }
        "reconcileOAuthAuthSnapshot" => {
            encode(core_policy::reconcile_oauth_auth_snapshot(decode::<
                core_policy::OAuthAuthReconciliationRequest,
            >(
                request.payload,
            )?))
        }
        "normalizeSharedTeamOrganizationNames" => {
            encode(core_policy::normalize_shared_team_organization_names(
                decode::<core_policy::SharedTeamOrganizationNormalizationRequest>(request.payload)?,
            ))
        }
        "normalizeReservedProviderIds" => {
            encode(core_policy::normalize_reserved_provider_ids(decode::<
                core_policy::ReservedProviderIdNormalizationRequest,
            >(
                request.payload,
            )?))
        }
        "refreshOAuthAccountMetadata" => {
            encode(core_policy::refresh_oauth_account_metadata(decode::<
                core_policy::OAuthMetadataRefreshRequest,
            >(
                request.payload,
            )?))
        }
        "parseLegacyCodexToml" => encode(core_policy::parse_legacy_codex_toml(decode::<
            core_policy::LegacyCodexTomlParseRequest,
        >(
            request.payload
        )?)),
        "parseProviderSecretsEnv" => encode(core_policy::parse_provider_secrets_env(decode::<
            core_policy::ProviderSecretsEnvParseRequest,
        >(
            request.payload,
        )?)),
        "mergeInteropProxiesJSON" => encode(core_policy::merge_interop_proxies_json(decode::<
            core_policy::InteropProxyMergeRequest,
        >(
            request.payload,
        )?)),
        "applyOAuthInteropContext" => encode(core_policy::apply_oauth_interop_context(decode::<
            core_policy::OAuthInteropContextApplyRequest,
        >(
            request.payload,
        )?)),
        "renderOAuthInteropExportAccounts" => encode(
            core_policy::render_oauth_interop_export_accounts(decode::<
                core_policy::OAuthInteropExportRequest,
            >(request.payload)?),
        ),
        "parseOAuthInteropBundle" => encode(
            core_policy::parse_oauth_interop_bundle(
                decode::<core_policy::OAuthInteropBundleParseRequest>(request.payload)?,
            )
            .map_err(|message| ffi_error("oauthInteropBundleParse", &message))?,
        ),
        "parseOAuthAccountImport" => encode(
            core_policy::parse_oauth_account_import(
                decode::<core_policy::OAuthAccountImportParseRequest>(request.payload)?,
            )
            .map_err(|message| ffi_error("oauthAccountImportParse", &message))?,
        ),
        "parseLegacyOAuthCSV" => encode(
            core_policy::parse_legacy_oauth_csv(
                decode::<core_policy::OAuthLegacyCsvParseRequest>(request.payload)?,
            )
            .map_err(|message| ffi_error("oauthLegacyCsvParse", &message))?,
        ),
        "resolveLegacyMigrationActiveSelection" => encode(
            core_policy::resolve_legacy_migration_active_selection(decode::<
                core_policy::LegacyMigrationActiveSelectionRequest,
            >(request.payload)?),
        ),
        "planLegacyImportedProvider" => encode(core_policy::plan_legacy_imported_provider(
            decode::<core_policy::LegacyImportedProviderPlanRequest>(request.payload)?,
        )),
        "normalizeOAuthAccountIdentities" => encode(core_policy::normalize_oauth_account_identities(
            decode::<core_policy::OAuthIdentityNormalizationRequest>(request.payload)?,
        )),
        "sanitizeOAuthQuotaSnapshots" => encode(core_policy::sanitize_oauth_quota_snapshots(
            decode::<core_policy::OAuthQuotaSnapshotSanitizationRequest>(request.payload)?,
        )),
        "assembleOAuthProvider" => encode(core_policy::assemble_oauth_provider(
            decode::<core_policy::OAuthProviderAssemblyRequest>(request.payload)?,
        )),
        "parseAuthJsonSnapshot" => encode(core_policy::parse_auth_json_snapshot(decode::<
            core_policy::AuthJsonSnapshotParseRequest,
        >(
            request.payload,
        )?)),
        "describeFullRustCutoverContract" => {
            encode(host_contract::default_full_rust_cutover_contract())
        }
        "planStorePaths" => encode(core_store::plan_store_paths(decode::<
            core_store::StorePathPlanRequest,
        >(request.payload)?)),
        "planUsagePolling" => encode(core_runtime::plan_usage_polling(decode::<
            core_runtime::UsagePollingPlanRequest,
        >(request.payload)?)),
        "resolveUsageModeTransition" => {
            encode(core_runtime::resolve_usage_mode_transition(decode::<
                core_runtime::UsageModeTransitionRequest,
            >(
                request.payload,
            )?))
        }
        "decideSettingsSaveSync" => encode(core_runtime::decide_settings_save_sync(
            decode::<core_runtime::SettingsSaveSyncRequest>(request.payload)?,
        )),
        "decideOAuthAccountSync" => encode(core_runtime::decide_oauth_account_sync(
            decode::<core_runtime::OAuthAccountSyncRequest>(request.payload)?,
        )),
        "resolveCustomProviderId" => encode(core_policy::resolve_custom_provider_id(
            decode::<core_policy::CustomProviderIdResolutionRequest>(request.payload)?,
        )),
        "planCompatibleProviderCreation" => encode(core_policy::plan_compatible_provider_creation(
            decode::<core_policy::CompatibleProviderCreationRequest>(request.payload)?,
        )),
        "planCompatibleProviderAccountCreation" => encode(
            core_policy::plan_compatible_provider_account_creation(
                decode::<core_policy::CompatibleProviderAccountCreationRequest>(request.payload)?,
            ),
        ),
        "planOpenRouterProviderAccountCreation" => encode(
            core_policy::plan_openrouter_provider_account_creation(
                decode::<core_policy::OpenRouterProviderAccountCreationRequest>(request.payload)?,
            ),
        ),
        "planOpenRouterModelSelection" => encode(core_policy::plan_openrouter_model_selection(
            decode::<core_policy::OpenRouterModelSelectionPlanRequest>(request.payload)?,
        )),
        "summarizeLocalCost" => encode(core_session::summarize_local_cost(decode::<
            core_session::LocalCostSummaryRequest,
        >(
            request.payload
        )?)),
        "resolveLocalCostPricing" => encode(core_session::resolve_local_cost_pricing(
            decode::<core_session::LocalCostPricingRequest>(request.payload)?,
        )),
        "resolveLocalCostCachePolicy" => encode(core_session::resolve_local_cost_cache_policy(
            decode::<core_session::LocalCostCachePolicyRequest>(request.payload)?,
        )),
        "mergeHistoricalModels" => encode(core_session::merge_historical_models(
            decode::<core_session::HistoricalModelsMergeRequest>(request.payload)?,
        )),
        "collectHistoricalModels" => encode(core_session::collect_historical_models(
            decode::<core_session::HistoricalModelsCollectionRequest>(request.payload)?,
        )),
        "attributeLiveSessions" => encode(core_session::attribute_live_sessions(decode::<
            core_session::LiveSessionAttributionRequest,
        >(
            request.payload,
        )?)),
        "attributeRunningThreads" => encode(core_session::attribute_running_threads(decode::<
            core_session::RunningThreadAttributionRequest,
        >(
            request.payload,
        )?)),
        "parseSessionTranscript" => encode(core_session::parse_session_transcript(decode::<
            core_session::SessionTranscriptParseRequest,
        >(
            request.payload,
        )?)),
        "resolveRecentOpenRouterModel" => encode(core_session::resolve_recent_openrouter_model(
            decode::<core_session::RecentOpenRouterModelRequest>(request.payload)?,
        )),
        "projectSessionUsageLedger" => {
            encode(core_session::project_session_usage_ledger(decode::<
                core_session::SessionUsageLedgerProjectionRequest,
            >(
                request.payload,
            )?))
        }
        "resolveGatewayTransportPolicy" => {
            encode(core_gateway::resolve_transport_policy(decode::<
                core_gateway::GatewayTransportPolicyRequest,
            >(
                request.payload
            )?))
        }
        "classifyGatewayTransportFailure" => {
            encode(core_gateway::classify_gateway_transport_failure(decode::<
                core_gateway::GatewayTransportFailureClassificationRequest,
            >(
                request.payload,
            )?))
        }
        "resolveGatewayStatusPolicy" => {
            encode(core_gateway::resolve_gateway_status_policy(decode::<
                core_gateway::GatewayStatusPolicyRequest,
            >(
                request.payload,
            )?))
        }
        "resolveGatewayStickyRecoveryPolicy" => {
            encode(core_gateway::resolve_gateway_sticky_recovery_policy(
                decode::<core_gateway::GatewayStickyRecoveryPolicyRequest>(request.payload)?,
            ))
        }
        "interpretGatewayProtocolSignal" => {
            encode(core_gateway::interpret_gateway_protocol_signal(decode::<
                core_gateway::GatewayProtocolSignalInterpretationRequest,
            >(
                request.payload,
            )?))
        }
        "decideGatewayProtocolPreview" => {
            encode(core_gateway::decide_gateway_protocol_preview(decode::<
                core_gateway::GatewayProtocolPreviewDecisionRequest,
            >(
                request.payload,
            )?))
        }
        "parseGatewayRequest" => encode(core_gateway::parse_gateway_request(decode::<
            core_gateway::GatewayRequestParseRequest,
        >(
            request.payload,
        )?)),
        "planGatewayCandidates" => encode(core_gateway::plan_gateway_candidates(decode::<
            core_gateway::GatewayCandidatePlanRequest,
        >(
            request.payload,
        )?)),
        "resolveGatewayStickyKey" => encode(core_gateway::resolve_gateway_sticky_key(
            decode::<core_gateway::GatewayStickyKeyResolutionRequest>(request.payload)?,
        )),
        "renderGatewayResponseHead" => encode(core_gateway::render_gateway_response_head(
            decode::<core_gateway::GatewayResponseHeadRenderRequest>(request.payload)?,
        )),
        "renderGatewayWebSocketHandshake" => encode(core_gateway::render_gateway_websocket_handshake(
            decode::<core_gateway::GatewayWebSocketHandshakeRequest>(request.payload)?,
        )),
        "renderGatewayWebSocketFrame" => encode(core_gateway::render_gateway_websocket_frame(
            decode::<core_gateway::GatewayWebSocketFrameRenderRequest>(request.payload)?,
        )),
        "renderGatewayWebSocketClosePayload" => encode(core_gateway::render_gateway_websocket_close_payload(
            decode::<core_gateway::GatewayWebSocketClosePayloadRequest>(request.payload)?,
        )),
        "parseGatewayWebSocketFrame" => encode(core_gateway::parse_gateway_websocket_frame(
            decode::<core_gateway::GatewayWebSocketFrameParseRequest>(request.payload)?,
        )),
        "validateGatewayWebSocketReady" => encode(core_gateway::validate_gateway_websocket_ready(
            decode::<core_gateway::GatewayWebSocketReadyValidationRequest>(request.payload)?,
        )),
        "bindGatewayStickyState" => encode(core_gateway::bind_gateway_sticky_state(decode::<
            core_gateway::GatewayStickyBindRequest,
        >(
            request.payload,
        )?)),
        "clearGatewayStickyState" => encode(core_gateway::clear_gateway_sticky_state(decode::<
            core_gateway::GatewayStickyClearRequest,
        >(
            request.payload,
        )?)),
        "applyGatewayRuntimeBlock" => encode(core_gateway::apply_gateway_runtime_block(decode::<
            core_gateway::GatewayRuntimeBlockApplyRequest,
        >(
            request.payload,
        )?)),
        "normalizeGatewayState" => encode(core_gateway::normalize_gateway_state(decode::<
            core_gateway::GatewayStateNormalizationRequest,
        >(
            request.payload,
        )?)),
        "normalizeOpenAIResponsesRequest" => {
            encode(core_gateway::normalize_openai_responses_request(decode::<
                core_gateway::OpenAIResponsesRequestNormalizationRequest,
            >(
                request.payload,
            )?))
        }
        "normalizeOpenRouterRequest" => {
            encode(core_gateway::normalize_openrouter_request(decode::<
                core_gateway::OpenRouterRequestNormalizationRequest,
            >(
                request.payload,
            )?))
        }
        "resolveOpenRouterGatewayAccountState" => {
            encode(core_gateway::resolve_openrouter_gateway_account_state(
                decode::<core_gateway::OpenRouterGatewayAccountStateRequest>(request.payload)?,
            ))
        }
        "parseOpenRouterModelCatalog" => encode(core_gateway::parse_openrouter_model_catalog(
            decode::<core_gateway::OpenRouterModelCatalogParseRequest>(request.payload)?,
        )),
        "planGatewayLifecycle" => encode(core_gateway::plan_gateway_lifecycle(decode::<
            core_gateway::GatewayLifecyclePlanRequest,
        >(
            request.payload
        )?)),
        "planAggregateGatewayLeaseTransition" => encode(
            core_gateway::plan_aggregate_gateway_lease_transition(decode::<
                core_gateway::AggregateGatewayLeaseTransitionPlanRequest,
            >(request.payload)?),
        ),
        "planAggregateGatewayLeaseRefresh" => encode(
            core_gateway::plan_aggregate_gateway_lease_refresh(decode::<
                core_gateway::AggregateGatewayLeaseRefreshPlanRequest,
            >(request.payload)?),
        ),
        "decideGatewayPostCompletionBinding" => encode(
            core_gateway::decide_gateway_post_completion_binding(decode::<
                core_gateway::GatewayPostCompletionBindingDecisionRequest,
            >(request.payload)?),
        ),
        "buildOAuthAuthorizationUrl" => {
            encode(core_gateway::build_oauth_authorization_url(decode::<
                core_gateway::OAuthAuthorizationUrlRequest,
            >(
                request.payload,
            )?))
        }
        "interpretOAuthCallback" => encode(core_gateway::interpret_oauth_callback(decode::<
            core_gateway::OAuthCallbackInterpretationRequest,
        >(
            request.payload,
        )?)),
        "parseOAuthTokenResponse" => encode(
            core_policy::parse_oauth_token_response(decode::<
                core_policy::OAuthTokenResponseParseRequest,
            >(request.payload)?)
            .map_err(|message| ffi_error("oauthTokenResponseParse", &message))?,
        ),
        "buildOAuthAccountFromTokens" => encode(core_policy::build_oauth_account_from_tokens(
            decode::<core_policy::OAuthAccountBuildRequest>(request.payload)?,
        )),
        "refreshOAuthAccountFromTokens" => encode(core_policy::refresh_oauth_account_from_tokens(
            decode::<core_policy::RefreshOAuthAccountFromTokensRequest>(request.payload)?,
        )),
        "inspectOAuthTokenMetadata" => encode(core_policy::inspect_oauth_token_metadata(
            decode::<core_policy::OAuthTokenMetadataRequest>(request.payload)?,
        )),
        "resolveUpdateAvailability" => encode(
            core_update::resolve_update_availability(
                decode::<core_update::UpdateResolutionRequest>(request.payload)?,
            )
            .map_err(|message| ffi_error("updateResolutionFailure", &message))?,
        ),
        "selectUpdateArtifact" => encode(
            core_update::select_update_artifact(decode::<
                core_update::UpdateArtifactSelectionRequest,
            >(request.payload)?)
            .map_err(|message| ffi_error("updateArtifactSelectionFailure", &message))?,
        ),
        "evaluateUpdateBlockers" => encode(
            core_update::evaluate_update_blockers(decode::<
                core_update::UpdateBlockerEvaluationRequest,
            >(request.payload)?)
            .map_err(|message| ffi_error("updateBlockerEvaluationFailure", &message))?,
        ),
        "parseUpdateSignatureInspection" => encode(core_update::parse_update_signature_inspection(
            decode::<core_update::UpdateSignatureInspectionParseRequest>(request.payload)?,
        )),
        "parseUpdateGatekeeperInspection" => encode(core_update::parse_update_gatekeeper_inspection(
            decode::<core_update::UpdateGatekeeperInspectionParseRequest>(request.payload)?,
        )),
        "selectInstallableGitHubReleaseFromJSON" => {
            encode(core_update::select_installable_github_release_from_json(
                decode::<core_update::GitHubInstallableReleaseSelectionFromJsonRequest>(
                    request.payload,
                )?,
            ))
        }
        "selectInstallableGitHubRelease" => {
            encode(core_update::select_installable_github_release(decode::<
                core_update::GitHubInstallableReleaseSelectionRequest,
            >(
                request.payload,
            )?))
        }
        _ => Err(ffi_error(
            "unknownOperation",
            &format!("unknown operation: {}", request.operation),
        )),
    }
}

fn decode<T: serde::de::DeserializeOwned>(payload: serde_json::Value) -> Result<T, FfiError> {
    serde_json::from_value(payload).map_err(|error| ffi_error("invalidPayload", &error.to_string()))
}

fn encode<T: serde::Serialize>(result: T) -> Result<serde_json::Value, FfiError> {
    serde_json::to_value(result)
        .map_err(|error| ffi_error("serializationFailure", &error.to_string()))
}

fn ffi_error(code: &str, message: &str) -> FfiError {
    FfiError {
        code: code.to_string(),
        message: message.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::CString;

    use core_model::{CanonicalAccountSnapshot, RefreshPlanRequest};

    use super::*;

    #[test]
    fn executes_plan_refresh_request() {
        let request = FfiRequest {
            operation: "planRefresh".into(),
            payload: serde_json::to_value(RefreshPlanRequest {
                account: CanonicalAccountSnapshot {
                    local_account_id: "acct-1".into(),
                    remote_account_id: "remote-1".into(),
                    email: "acct@example.com".into(),
                    access_token: "access".into(),
                    refresh_token: "refresh".into(),
                    id_token: "id".into(),
                    expires_at: Some(100.0),
                    oauth_client_id: None,
                    plan_type: "free".into(),
                    primary_used_percent: 0.0,
                    secondary_used_percent: 0.0,
                    primary_reset_at: None,
                    secondary_reset_at: None,
                    primary_limit_window_seconds: None,
                    secondary_limit_window_seconds: None,
                    last_checked: None,
                    is_active: true,
                    is_suspended: false,
                    token_expired: false,
                    token_last_refresh_at: None,
                    organization_name: None,
                    quota_exhausted: false,
                    is_available_for_next_use_routing: true,
                    is_degraded_for_next_use_routing: false,
                },
                force: false,
                now: 80.0,
                refresh_window_seconds: 30.0,
                existing_retry_state: None,
                in_flight: false,
            })
            .unwrap(),
        };
        let raw_request = CString::new(serde_json::to_string(&request).unwrap()).unwrap();

        let response_ptr = codexbar_portable_core_execute(raw_request.as_ptr());
        let response = unsafe { CStr::from_ptr(response_ptr) }
            .to_str()
            .unwrap()
            .to_string();
        codexbar_portable_core_free_string(response_ptr);

        assert!(response.contains("\"ok\":true"));
        assert!(response.contains("\"shouldRefresh\":true"));
    }
}
