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
        "canonicalizeConfigAndAccounts" => encode(
            core_policy::canonicalize_config_and_accounts(decode::<core_model::RawConfigInput>(
                request.payload,
            )?),
        ),
        "computeRouteRuntimeSnapshot" => encode(core_policy::compute_route_runtime_snapshot(
            decode::<RouteRuntimeInput>(request.payload)?,
        )),
        "renderCodecBundle" => encode(
            core_codec::render_codec_bundle(decode::<RenderCodecRequest>(request.payload)?)
                .map_err(|message| ffi_error("codecFailure", &message))?,
        ),
        "planRefresh" => encode(core_policy::plan_refresh(decode::<RefreshPlanRequest>(
            request.payload,
        )?)),
        "applyRefreshOutcome" => encode(core_policy::apply_refresh_outcome(
            decode::<RefreshOutcomeRequest>(request.payload)?,
        )),
        "mergeUsageSuccess" => encode(core_policy::merge_usage_success(
            decode::<UsageMergeSuccessRequest>(request.payload)?,
        )),
        "markUsageForbidden" => encode(core_policy::mark_usage_forbidden(decode::<
            core_model::CanonicalAccountSnapshot,
        >(request.payload)?)),
        "markUsageTokenExpired" => encode(core_policy::mark_usage_token_expired(decode::<
            core_model::CanonicalAccountSnapshot,
        >(request.payload)?)),
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
    serde_json::to_value(result).map_err(|error| ffi_error("serializationFailure", &error.to_string()))
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
        let response = unsafe { CStr::from_ptr(response_ptr) }.to_str().unwrap().to_string();
        codexbar_portable_core_free_string(response_ptr);

        assert!(response.contains("\"ok\":true"));
        assert!(response.contains("\"shouldRefresh\":true"));
    }
}
