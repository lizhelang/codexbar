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
