use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

const GPT_54_LONG_CONTEXT_INPUT_THRESHOLD: i64 = 272_000;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash, Default)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    pub output_tokens: i64,
}

impl TokenUsage {
    pub fn total_tokens(&self) -> i64 {
        self.input_tokens.max(0) + self.cached_input_tokens.max(0) + self.output_tokens.max(0)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ModelPricing {
    pub input_usd_per_token: f64,
    pub cached_input_usd_per_token: f64,
    pub output_usd_per_token: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LocalCostEvent {
    pub model: String,
    pub timestamp: f64,
    pub usage: TokenUsage,
    #[serde(default)]
    pub session_usage: Option<TokenUsage>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LocalCostSummaryRequest {
    pub now: f64,
    #[serde(default)]
    pub pricing_overrides: BTreeMap<String, ModelPricing>,
    #[serde(default)]
    pub events: Vec<LocalCostEvent>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LocalCostDailyEntry {
    pub id: String,
    pub timestamp: f64,
    pub cost_usd: f64,
    pub total_tokens: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LocalCostSummarySnapshot {
    pub today_cost_usd: f64,
    pub today_tokens: i64,
    pub last30_days_cost_usd: f64,
    pub last30_days_tokens: i64,
    pub lifetime_cost_usd: f64,
    pub lifetime_tokens: i64,
    pub daily_entries: Vec<LocalCostDailyEntry>,
    pub updated_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ActivationRecordInput {
    pub timestamp: f64,
    #[serde(default)]
    pub provider_id: Option<String>,
    #[serde(default)]
    pub account_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LiveSessionInput {
    pub session_id: String,
    pub started_at: f64,
    pub last_activity_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LiveSessionAttributionRequest {
    pub now: f64,
    pub recent_activity_window_seconds: f64,
    #[serde(default)]
    pub sessions: Vec<LiveSessionInput>,
    #[serde(default)]
    pub activations: Vec<ActivationRecordInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LiveSessionAttribution {
    pub session_id: String,
    pub started_at: f64,
    pub last_activity_at: f64,
    #[serde(default)]
    pub account_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct LiveSessionAttributionSummary {
    #[serde(default)]
    pub in_use_session_counts: BTreeMap<String, i64>,
    pub unknown_session_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LiveSessionAttributionResult {
    pub recent_activity_window_seconds: f64,
    pub sessions: Vec<LiveSessionAttribution>,
    pub summary: LiveSessionAttributionSummary,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeThreadInput {
    pub thread_id: String,
    pub source: String,
    pub cwd: String,
    pub title: String,
    pub last_runtime_at: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionLifecycleInput {
    pub session_id: String,
    pub last_activity_at: f64,
    pub task_lifecycle_state: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AggregateRouteRecordInput {
    pub timestamp: f64,
    pub thread_id: String,
    pub account_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RunningThreadAttributionRequest {
    pub recent_activity_window_seconds: f64,
    #[serde(default)]
    pub unavailable_reason: Option<String>,
    #[serde(default)]
    pub threads: Vec<RuntimeThreadInput>,
    #[serde(default)]
    pub completed_sessions: Vec<SessionLifecycleInput>,
    #[serde(default)]
    pub aggregate_routes: Vec<AggregateRouteRecordInput>,
    #[serde(default)]
    pub activations: Vec<ActivationRecordInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RunningThreadAttribution {
    pub thread_id: String,
    pub source: String,
    pub cwd: String,
    pub title: String,
    pub last_runtime_at: f64,
    #[serde(default)]
    pub account_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct RunningThreadSummary {
    pub summary_is_unavailable: bool,
    #[serde(default)]
    pub running_thread_counts: BTreeMap<String, i64>,
    pub unknown_thread_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RunningThreadAttributionResult {
    pub recent_activity_window_seconds: f64,
    #[serde(default)]
    pub diagnostic_message: Option<String>,
    #[serde(default)]
    pub unavailable_reason: Option<String>,
    pub threads: Vec<RunningThreadAttribution>,
    pub summary: RunningThreadSummary,
}

pub fn summarize_local_cost(request: LocalCostSummaryRequest) -> LocalCostSummarySnapshot {
    let today_start = (request.now / 86_400.0).floor() * 86_400.0;
    let last30_start = today_start - (29.0 * 86_400.0);

    let mut today_cost_usd = 0.0;
    let mut today_tokens = 0_i64;
    let mut last30_days_cost_usd = 0.0;
    let mut last30_days_tokens = 0_i64;
    let mut lifetime_cost_usd = 0.0;
    let mut lifetime_tokens = 0_i64;
    let mut daily = BTreeMap::<i64, (f64, i64)>::new();

    for event in request.events {
        let event_cost = cost_usd(
            &event.model,
            &event.usage,
            event.session_usage.as_ref(),
            &request.pricing_overrides,
        );
        let total_tokens = event.usage.total_tokens();
        let day_key = (event.timestamp / 86_400.0).floor() as i64;
        let entry = daily.entry(day_key).or_insert((0.0, 0));
        entry.0 += event_cost;
        entry.1 += total_tokens;

        if event.timestamp >= last30_start {
            last30_days_cost_usd += event_cost;
            last30_days_tokens += total_tokens;
        }
        if event.timestamp >= today_start {
            today_cost_usd += event_cost;
            today_tokens += total_tokens;
        }

        lifetime_cost_usd += event_cost;
        lifetime_tokens += total_tokens;
    }

    let mut daily_entries = daily
        .into_iter()
        .map(|(day_key, (cost_usd, total_tokens))| LocalCostDailyEntry {
            id: format!("day-{}", day_key),
            timestamp: (day_key as f64) * 86_400.0,
            cost_usd,
            total_tokens,
        })
        .collect::<Vec<_>>();
    daily_entries.sort_by(|lhs, rhs| rhs.timestamp.total_cmp(&lhs.timestamp));

    LocalCostSummarySnapshot {
        today_cost_usd,
        today_tokens,
        last30_days_cost_usd,
        last30_days_tokens,
        lifetime_cost_usd,
        lifetime_tokens,
        daily_entries,
        updated_at: request.now,
    }
}

pub fn attribute_live_sessions(request: LiveSessionAttributionRequest) -> LiveSessionAttributionResult {
    let mut sessions = request
        .sessions
        .into_iter()
        .filter(|session| (request.now - session.last_activity_at).max(0.0) <= request.recent_activity_window_seconds)
        .collect::<Vec<_>>();
    sessions.sort_by(|lhs, rhs| lhs.started_at.total_cmp(&rhs.started_at));

    let mut in_use_session_counts = BTreeMap::<String, i64>::new();
    let mut unknown_session_count = 0_i64;
    let attributions = sessions
        .into_iter()
        .map(|session| {
            let account_id = latest_activation_account(
                &request.activations,
                session.started_at,
            );
            if let Some(account_id_ref) = account_id.as_ref() {
                *in_use_session_counts.entry(account_id_ref.clone()).or_insert(0) += 1;
            } else {
                unknown_session_count += 1;
            }
            LiveSessionAttribution {
                session_id: session.session_id,
                started_at: session.started_at,
                last_activity_at: session.last_activity_at,
                account_id,
            }
        })
        .collect::<Vec<_>>();

    LiveSessionAttributionResult {
        recent_activity_window_seconds: request.recent_activity_window_seconds,
        sessions: attributions,
        summary: LiveSessionAttributionSummary {
            in_use_session_counts,
            unknown_session_count,
        },
    }
}

pub fn attribute_running_threads(
    request: RunningThreadAttributionRequest,
) -> RunningThreadAttributionResult {
    if let Some(unavailable_reason) = request.unavailable_reason {
        return RunningThreadAttributionResult {
            recent_activity_window_seconds: request.recent_activity_window_seconds,
            diagnostic_message: Some(unavailable_reason.clone()),
            unavailable_reason: Some(unavailable_reason),
            threads: Vec::new(),
            summary: RunningThreadSummary {
                summary_is_unavailable: true,
                running_thread_counts: BTreeMap::new(),
                unknown_thread_count: 0,
            },
        };
    }

    let completed_sessions = request
        .completed_sessions
        .into_iter()
        .filter(|session| session.task_lifecycle_state == "completed")
        .map(|session| (session.session_id, session.last_activity_at))
        .collect::<BTreeMap<_, _>>();
    let mut running_thread_counts = BTreeMap::<String, i64>::new();
    let mut unknown_thread_count = 0_i64;
    let mut threads = Vec::new();

    for thread in request.threads {
        if let Some(last_activity_at) = completed_sessions.get(&thread.thread_id) {
            if *last_activity_at >= thread.last_runtime_at {
                continue;
            }
        }

        let account_id = request
            .aggregate_routes
            .iter()
            .filter(|record| {
                record.thread_id == thread.thread_id
                    && record.timestamp <= thread.last_runtime_at
                    && record.account_id.is_empty() == false
            })
            .max_by(|lhs, rhs| lhs.timestamp.total_cmp(&rhs.timestamp))
            .map(|record| record.account_id.clone())
            .or_else(|| latest_activation_account(&request.activations, thread.last_runtime_at));

        if let Some(account_id_ref) = account_id.as_ref() {
            *running_thread_counts.entry(account_id_ref.clone()).or_insert(0) += 1;
        } else {
            unknown_thread_count += 1;
        }

        threads.push(RunningThreadAttribution {
            thread_id: thread.thread_id,
            source: thread.source,
            cwd: thread.cwd,
            title: thread.title,
            last_runtime_at: thread.last_runtime_at,
            account_id,
        });
    }

    RunningThreadAttributionResult {
        recent_activity_window_seconds: request.recent_activity_window_seconds,
        diagnostic_message: None,
        unavailable_reason: None,
        threads,
        summary: RunningThreadSummary {
            summary_is_unavailable: false,
            running_thread_counts,
            unknown_thread_count,
        },
    }
}

fn latest_activation_account(
    activations: &[ActivationRecordInput],
    cutoff: f64,
) -> Option<String> {
    activations
        .iter()
        .filter(|activation| activation.timestamp <= cutoff)
        .max_by(|lhs, rhs| lhs.timestamp.total_cmp(&rhs.timestamp))
        .and_then(|activation| {
            if activation.provider_id.as_deref() == Some("openai-oauth")
                && activation.account_id.as_deref().unwrap_or_default().is_empty() == false
            {
                activation.account_id.clone()
            } else {
                None
            }
        })
}

fn normalized_model_id(model: &str) -> String {
    let trimmed = model.trim();
    if let Some(stripped) = trimmed.strip_prefix("openai/") {
        stripped.to_string()
    } else {
        trimmed.to_string()
    }
}

fn default_pricing(model: &str) -> ModelPricing {
    let exact = [
        ("gpt-5", ModelPricing { input_usd_per_token: 1.25e-6, cached_input_usd_per_token: 1.25e-7, output_usd_per_token: 1e-5 }),
        ("gpt-5-codex", ModelPricing { input_usd_per_token: 1.25e-6, cached_input_usd_per_token: 1.25e-7, output_usd_per_token: 1e-5 }),
        ("gpt-5-mini", ModelPricing { input_usd_per_token: 2.5e-7, cached_input_usd_per_token: 2.5e-8, output_usd_per_token: 2e-6 }),
        ("gpt-5-nano", ModelPricing { input_usd_per_token: 5e-8, cached_input_usd_per_token: 5e-9, output_usd_per_token: 4e-7 }),
        ("gpt-5.1", ModelPricing { input_usd_per_token: 1.25e-6, cached_input_usd_per_token: 1.25e-7, output_usd_per_token: 1e-5 }),
        ("gpt-5.1-codex", ModelPricing { input_usd_per_token: 1.25e-6, cached_input_usd_per_token: 1.25e-7, output_usd_per_token: 1e-5 }),
        ("gpt-5.1-codex-max", ModelPricing { input_usd_per_token: 1.25e-6, cached_input_usd_per_token: 1.25e-7, output_usd_per_token: 1e-5 }),
        ("gpt-5.1-codex-mini", ModelPricing { input_usd_per_token: 2.5e-7, cached_input_usd_per_token: 2.5e-8, output_usd_per_token: 2e-6 }),
        ("gpt-5.2", ModelPricing { input_usd_per_token: 1.75e-6, cached_input_usd_per_token: 1.75e-7, output_usd_per_token: 1.4e-5 }),
        ("gpt-5.2-codex", ModelPricing { input_usd_per_token: 1.75e-6, cached_input_usd_per_token: 1.75e-7, output_usd_per_token: 1.4e-5 }),
        ("gpt-5.3-codex", ModelPricing { input_usd_per_token: 1.75e-6, cached_input_usd_per_token: 1.75e-7, output_usd_per_token: 1.4e-5 }),
        ("gpt-5.4", ModelPricing { input_usd_per_token: 2.5e-6, cached_input_usd_per_token: 2.5e-7, output_usd_per_token: 1.5e-5 }),
        ("gpt-5.4-mini", ModelPricing { input_usd_per_token: 7.5e-7, cached_input_usd_per_token: 7.5e-8, output_usd_per_token: 4.5e-6 }),
        ("gpt-5.4-nano", ModelPricing { input_usd_per_token: 2e-7, cached_input_usd_per_token: 2e-8, output_usd_per_token: 1.25e-6 }),
        ("qwen35_4b", ModelPricing::default()),
    ];
    if let Some((_, pricing)) = exact.iter().find(|(key, _)| *key == model) {
        return pricing.clone();
    }

    let mut keys = exact.iter().map(|(key, _)| *key).collect::<Vec<_>>();
    keys.sort_by(|lhs, rhs| rhs.len().cmp(&lhs.len()).then_with(|| lhs.cmp(rhs)));
    for key in keys {
        if model_is_variant_of(model, key) {
            return exact
                .iter()
                .find(|(candidate, _)| *candidate == key)
                .map(|(_, pricing)| pricing.clone())
                .unwrap_or_default();
        }
    }

    ModelPricing::default()
}

fn cost_usd(
    model: &str,
    usage: &TokenUsage,
    session_usage: Option<&TokenUsage>,
    pricing_overrides: &BTreeMap<String, ModelPricing>,
) -> f64 {
    let normalized_model = normalized_model_id(model);
    let pricing = pricing_overrides
        .get(&normalized_model)
        .cloned()
        .unwrap_or_else(|| default_pricing(&normalized_model));
    let cached = usage.cached_input_tokens.max(0).min(usage.input_tokens.max(0));
    let non_cached = usage.input_tokens.max(0) - cached;
    let long_context_multiplier = if session_usage
        .map(|session_usage| session_usage.input_tokens > GPT_54_LONG_CONTEXT_INPUT_THRESHOLD)
        .unwrap_or(false)
        && normalized_model.starts_with("gpt-5.4")
    {
        2.0
    } else {
        1.0
    };
    let output_multiplier = if long_context_multiplier > 1.0 { 1.5 } else { 1.0 };
    (non_cached as f64) * pricing.input_usd_per_token * long_context_multiplier
        + (cached as f64) * pricing.cached_input_usd_per_token
        + (usage.output_tokens.max(0) as f64) * pricing.output_usd_per_token * output_multiplier
}

fn model_is_variant_of(model: &str, base_model: &str) -> bool {
    if model.len() <= base_model.len() || model.starts_with(base_model) == false {
        return false;
    }
    model
        .chars()
        .nth(base_model.len())
        .map(|delimiter| matches!(delimiter, '-' | '.' | '_' | ':'))
        .unwrap_or(false)
}
