use std::collections::{BTreeMap, BTreeSet};

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

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionRecordInput {
    pub session_id: String,
    pub started_at: f64,
    pub last_activity_at: f64,
    pub is_archived: bool,
    pub model: String,
    pub usage: TokenUsage,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UsageEventInput {
    pub timestamp: f64,
    pub usage: TokenUsage,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CachedSessionRecordInput {
    #[serde(default)]
    pub record: Option<SessionRecordInput>,
    #[serde(default)]
    pub usage_events: Vec<UsageEventInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PersistedLedgerEvent {
    pub timestamp: f64,
    pub usage: TokenUsage,
    pub cost_usd: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct PersistedLedgerSession {
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub events: Vec<PersistedLedgerEvent>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PersistedUsageLedger {
    pub version: i64,
    pub did_seed_from_session_cache: bool,
    #[serde(default)]
    pub sessions: BTreeMap<String, PersistedLedgerSession>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HistoricalSessionRecord {
    pub session_id: String,
    pub model_id: String,
    pub started_at: f64,
    pub last_activity_at: f64,
    pub is_archived: bool,
    pub total_tokens: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionUsageLedgerProjectionRequest {
    #[serde(default)]
    pub current_sessions: Vec<CachedSessionRecordInput>,
    pub persisted_ledger: PersistedUsageLedger,
    #[serde(default)]
    pub seed_sessions: Vec<CachedSessionRecordInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SessionUsageLedgerProjectionResult {
    pub ledger: PersistedUsageLedger,
    #[serde(default)]
    pub historical_sessions: Vec<HistoricalSessionRecord>,
}

pub fn project_session_usage_ledger(
    request: SessionUsageLedgerProjectionRequest,
) -> SessionUsageLedgerProjectionResult {
    let mut ledger = request.persisted_ledger;

    if ledger.did_seed_from_session_cache == false {
        let aligned_seed_sessions = aligned_seed_sessions(&request.seed_sessions, &request.current_sessions);
        let _ = ingest_billable_events(&aligned_seed_sessions, &mut ledger);
        ledger.did_seed_from_session_cache = true;
    }

    let _ = ingest_billable_events(&request.current_sessions, &mut ledger);
    let historical_sessions = historical_session_records(&request.current_sessions);

    SessionUsageLedgerProjectionResult {
        ledger,
        historical_sessions,
    }
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

fn historical_session_records(
    cached_sessions: &[CachedSessionRecordInput],
) -> Vec<HistoricalSessionRecord> {
    let mut preferred_record_by_session_id = BTreeMap::<String, CachedSessionRecordInput>::new();

    for cached in cached_sessions {
        let Some(record) = cached.record.as_ref() else {
            continue;
        };

        let should_keep_existing = preferred_record_by_session_id
            .get(&record.session_id)
            .map(|existing| should_ingest_before(existing, cached))
            .unwrap_or(false);
        if should_keep_existing {
            continue;
        }
        preferred_record_by_session_id.insert(record.session_id.clone(), cached.clone());
    }

    let mut records = preferred_record_by_session_id
        .into_values()
        .filter_map(|cached| {
            let record = cached.record?;
            Some(HistoricalSessionRecord {
                session_id: record.session_id,
                model_id: record.model,
                started_at: record.started_at,
                last_activity_at: record.last_activity_at,
                is_archived: record.is_archived,
                total_tokens: record.usage.total_tokens(),
            })
        })
        .collect::<Vec<_>>();

    records.sort_by(|lhs, rhs| {
        rhs.last_activity_at
            .total_cmp(&lhs.last_activity_at)
            .then_with(|| rhs.started_at.total_cmp(&lhs.started_at))
            .then_with(|| lhs.session_id.cmp(&rhs.session_id))
    });
    records
}

fn aligned_seed_sessions(
    seed_sessions: &[CachedSessionRecordInput],
    current_sessions: &[CachedSessionRecordInput],
) -> Vec<CachedSessionRecordInput> {
    let mut current_usage_events_by_session_id = BTreeMap::<String, Vec<CachedSessionRecordInput>>::new();
    for cached in current_sessions {
        let Some(record) = cached.record.as_ref() else {
            continue;
        };
        if cached.usage_events.is_empty() {
            continue;
        }
        current_usage_events_by_session_id
            .entry(record.session_id.clone())
            .or_default()
            .push(cached.clone());
    }

    seed_sessions
        .iter()
        .map(|cached| {
            let Some(record) = cached.record.as_ref() else {
                return cached.clone();
            };
            if cached.usage_events.is_empty() {
                return cached.clone();
            }
            let Some(current_matches) = current_usage_events_by_session_id.get(&record.session_id) else {
                return cached.clone();
            };

            let mut sorted_matches = current_matches.clone();
            sorted_matches.sort_by(compare_cached_session_records);
            let current_usage_events = sorted_matches
                .into_iter()
                .flat_map(|current| current.usage_events.into_iter())
                .collect::<Vec<_>>();

            CachedSessionRecordInput {
                record: cached.record.clone(),
                usage_events: aligned_seed_usage_events(&cached.usage_events, &current_usage_events),
            }
        })
        .collect()
}

fn aligned_seed_usage_events(
    seed_events: &[UsageEventInput],
    current_usage_events: &[UsageEventInput],
) -> Vec<UsageEventInput> {
    if current_usage_events.is_empty() {
        return seed_events.to_vec();
    }

    let mut timestamps_by_usage = BTreeMap::<String, Vec<f64>>::new();
    for event in current_usage_events {
        timestamps_by_usage
            .entry(usage_key(&event.usage))
            .or_default()
            .push(event.timestamp);
    }

    seed_events
        .iter()
        .map(|event| {
            let Some(timestamps) = timestamps_by_usage.get_mut(&usage_key(&event.usage)) else {
                return event.clone();
            };
            let Some(matched_timestamp) = timestamps.first().copied() else {
                return event.clone();
            };
            timestamps.remove(0);
            UsageEventInput {
                timestamp: matched_timestamp,
                usage: event.usage.clone(),
            }
        })
        .collect()
}

fn ingest_billable_events(
    cached_sessions: &[CachedSessionRecordInput],
    ledger: &mut PersistedUsageLedger,
) -> bool {
    let mut grouped_by_session_id = BTreeMap::<String, Vec<CachedSessionRecordInput>>::new();
    for cached in cached_sessions {
        let Some(record) = cached.record.as_ref() else {
            continue;
        };
        if cached.usage_events.is_empty() {
            continue;
        }
        grouped_by_session_id
            .entry(record.session_id.clone())
            .or_default()
            .push(cached.clone());
    }

    if grouped_by_session_id.is_empty() {
        return false;
    }

    let mut changed = false;

    for (session_id, mut records) in grouped_by_session_id {
        records.sort_by(compare_cached_session_records);

        let existing_session = ledger.sessions.get(&session_id).cloned();
        if let Some(current_record) = records
            .iter()
            .find(|cached| cached.record.as_ref().map(|record| record.is_archived == false).unwrap_or(false))
            .cloned()
        {
            if let Some(rebuilt_session) = rebuilt_ledger_session(
                &session_id,
                &current_record,
                existing_session.as_ref(),
            ) {
                if existing_session.as_ref() != Some(&rebuilt_session) {
                    ledger.sessions.insert(session_id.clone(), rebuilt_session);
                    changed = true;
                }
                continue;
            }
        }

        let mut ledger_session = existing_session.clone().unwrap_or_default();
        let mut known_event_keys = ledger_session
            .events
            .iter()
            .map(|event| ledger_event_key(&session_id, event.timestamp, &event.usage))
            .collect::<BTreeSet<_>>();
        let mut observed_usage_total = ledger_session
            .events
            .iter()
            .fold(TokenUsage::default(), |partial, event| partial.add(&event.usage));
        let mut changed_session = false;
        let mut updated_model = false;

        for cached in records {
            let Some(record) = cached.record.as_ref() else {
                continue;
            };
            if ledger_session.model != record.model {
                ledger_session.model = record.model.clone();
                updated_model = true;
            }

            let should_normalize_single_snapshot = cached.usage_events.len() == 1
                && cached
                    .usage_events
                    .first()
                    .map(|event| event.usage == record.usage)
                    .unwrap_or(false);

            for usage_event in &cached.usage_events {
                let normalized_usage = if should_normalize_single_snapshot {
                    usage_event.usage.delta_from(&observed_usage_total)
                } else {
                    usage_event.usage.clone()
                };
                if normalized_usage.is_zero() {
                    continue;
                }

                let event_key = ledger_event_key(&session_id, usage_event.timestamp, &normalized_usage);
                if known_event_keys.contains(&event_key) {
                    continue;
                }

                ledger_session.events.push(PersistedLedgerEvent {
                    timestamp: usage_event.timestamp,
                    usage: normalized_usage.clone(),
                    cost_usd: cost_usd(
                        &record.model,
                        &normalized_usage,
                        Some(&record.usage),
                        &BTreeMap::new(),
                    ),
                });
                known_event_keys.insert(event_key);
                observed_usage_total = observed_usage_total.add(&normalized_usage);
                changed = true;
                changed_session = true;
            }
        }

        if changed_session || updated_model {
            ledger_session.events.sort_by(compare_ledger_events);
            if existing_session.as_ref() != Some(&ledger_session) {
                ledger.sessions.insert(session_id.clone(), ledger_session);
                changed = true;
            }
        } else if ledger.sessions.contains_key(&session_id) == false && ledger_session.events.is_empty() == false {
            ledger.sessions.insert(session_id.clone(), ledger_session);
            changed = true;
        }
    }

    changed
}

fn rebuilt_ledger_session(
    session_id: &str,
    cached: &CachedSessionRecordInput,
    existing_session: Option<&PersistedLedgerSession>,
) -> Option<PersistedLedgerSession> {
    let record = cached.record.as_ref()?;
    if cached.usage_events.is_empty() {
        return None;
    }

    let mut persisted_cost_by_key = BTreeMap::<String, f64>::new();
    for event in existing_session.map(|session| session.events.iter()).into_iter().flatten() {
        let event_key = ledger_event_key(session_id, event.timestamp, &event.usage);
        persisted_cost_by_key.entry(event_key).or_insert(event.cost_usd);
    }

    let mut known_event_keys = BTreeSet::<String>::new();
    let mut events = Vec::<PersistedLedgerEvent>::new();
    events.reserve(cached.usage_events.len());

    for usage_event in &cached.usage_events {
        let event_key = ledger_event_key(session_id, usage_event.timestamp, &usage_event.usage);
        if known_event_keys.contains(&event_key) {
            continue;
        }
        let cost_usd = persisted_cost_by_key
            .get(&event_key)
            .copied()
            .unwrap_or_else(|| cost_usd(&record.model, &usage_event.usage, Some(&record.usage), &BTreeMap::new()));
        events.push(PersistedLedgerEvent {
            timestamp: usage_event.timestamp,
            usage: usage_event.usage.clone(),
            cost_usd,
        });
        known_event_keys.insert(event_key);
    }

    if events.is_empty() {
        return None;
    }
    events.sort_by(compare_ledger_events);
    Some(PersistedLedgerSession {
        model: record.model.clone(),
        events,
    })
}

fn should_ingest_before(lhs: &CachedSessionRecordInput, rhs: &CachedSessionRecordInput) -> bool {
    compare_cached_session_records(lhs, rhs).is_lt()
}

fn compare_cached_session_records(
    lhs: &CachedSessionRecordInput,
    rhs: &CachedSessionRecordInput,
) -> std::cmp::Ordering {
    lhs.usage_events
        .len()
        .cmp(&rhs.usage_events.len())
        .reverse()
        .then_with(|| {
            let left_tokens = lhs
                .usage_events
                .iter()
                .fold(0_i64, |partial, event| partial + event.usage.total_tokens());
            let right_tokens = rhs
                .usage_events
                .iter()
                .fold(0_i64, |partial, event| partial + event.usage.total_tokens());
            right_tokens.cmp(&left_tokens)
        })
        .then_with(|| {
            let left_archived = lhs.record.as_ref().map(|record| record.is_archived).unwrap_or(false);
            let right_archived = rhs.record.as_ref().map(|record| record.is_archived).unwrap_or(false);
            left_archived.cmp(&right_archived)
        })
        .then_with(|| {
            let left_activity = lhs
                .record
                .as_ref()
                .map(|record| record.last_activity_at)
                .unwrap_or(f64::NEG_INFINITY);
            let right_activity = rhs
                .record
                .as_ref()
                .map(|record| record.last_activity_at)
                .unwrap_or(f64::NEG_INFINITY);
            right_activity.total_cmp(&left_activity)
        })
        .then_with(|| {
            let left_started = lhs
                .record
                .as_ref()
                .map(|record| record.started_at)
                .unwrap_or(f64::NEG_INFINITY);
            let right_started = rhs
                .record
                .as_ref()
                .map(|record| record.started_at)
                .unwrap_or(f64::NEG_INFINITY);
            left_started.total_cmp(&right_started)
        })
        .then_with(|| {
            let left_id = lhs
                .record
                .as_ref()
                .map(|record| record.session_id.as_str())
                .unwrap_or_default();
            let right_id = rhs
                .record
                .as_ref()
                .map(|record| record.session_id.as_str())
                .unwrap_or_default();
            left_id.cmp(right_id)
        })
}

fn compare_ledger_events(lhs: &PersistedLedgerEvent, rhs: &PersistedLedgerEvent) -> std::cmp::Ordering {
    lhs.timestamp
        .total_cmp(&rhs.timestamp)
        .then_with(|| lhs.usage.input_tokens.cmp(&rhs.usage.input_tokens))
        .then_with(|| lhs.usage.cached_input_tokens.cmp(&rhs.usage.cached_input_tokens))
        .then_with(|| lhs.usage.output_tokens.cmp(&rhs.usage.output_tokens))
}

fn ledger_event_key(session_id: &str, timestamp: f64, usage: &TokenUsage) -> String {
    format!(
        "{}|{}|{}|{}|{}",
        session_id,
        normalized_timestamp_key(timestamp),
        usage.input_tokens,
        usage.cached_input_tokens,
        usage.output_tokens
    )
}

fn usage_key(usage: &TokenUsage) -> String {
    format!(
        "{}|{}|{}",
        usage.input_tokens, usage.cached_input_tokens, usage.output_tokens
    )
}

fn normalized_timestamp_key(timestamp: f64) -> i64 {
    (timestamp * 1_000_000.0).round() as i64
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

impl TokenUsage {
    fn is_zero(&self) -> bool {
        self.input_tokens == 0 && self.cached_input_tokens == 0 && self.output_tokens == 0
    }

    fn add(&self, other: &Self) -> Self {
        Self {
            input_tokens: self.input_tokens + other.input_tokens,
            cached_input_tokens: self.cached_input_tokens + other.cached_input_tokens,
            output_tokens: self.output_tokens + other.output_tokens,
        }
    }

    fn delta_from(&self, previous: &Self) -> Self {
        Self {
            input_tokens: (self.input_tokens - previous.input_tokens).max(0),
            cached_input_tokens: (self.cached_input_tokens - previous.cached_input_tokens).max(0),
            output_tokens: (self.output_tokens - previous.output_tokens).max(0),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn usage(input_tokens: i64, cached_input_tokens: i64, output_tokens: i64) -> TokenUsage {
        TokenUsage {
            input_tokens,
            cached_input_tokens,
            output_tokens,
        }
    }

    fn session_record(
        session_id: &str,
        started_at: f64,
        last_activity_at: f64,
        is_archived: bool,
        model: &str,
        usage: TokenUsage,
    ) -> SessionRecordInput {
        SessionRecordInput {
            session_id: session_id.to_string(),
            started_at,
            last_activity_at,
            is_archived,
            model: model.to_string(),
            usage,
        }
    }

    fn usage_event(timestamp: f64, usage: TokenUsage) -> UsageEventInput {
        UsageEventInput { timestamp, usage }
    }

    fn cached_session(
        record: SessionRecordInput,
        usage_events: Vec<UsageEventInput>,
    ) -> CachedSessionRecordInput {
        CachedSessionRecordInput {
            record: Some(record),
            usage_events,
        }
    }

    #[test]
    fn project_session_usage_ledger_repairs_duplicate_current_ledger_and_prefers_current_record() {
        let request = SessionUsageLedgerProjectionRequest {
            current_sessions: vec![
                cached_session(
                    session_record("shared", 100.0, 200.0, false, "gpt-5.4", usage(170, 30, 30)),
                    vec![
                        usage_event(105.0, usage(100, 20, 20)),
                        usage_event(190.0, usage(70, 10, 10)),
                        usage_event(190.0, usage(70, 10, 10)),
                    ],
                ),
                cached_session(
                    session_record("shared", 100.0, 190.0, true, "gpt-5.4", usage(170, 30, 30)),
                    vec![usage_event(190.0, usage(170, 30, 30))],
                ),
            ],
            persisted_ledger: PersistedUsageLedger {
                version: 2,
                did_seed_from_session_cache: true,
                sessions: BTreeMap::from([(
                    "shared".to_string(),
                    PersistedLedgerSession {
                        model: "gpt-5.4".to_string(),
                        events: vec![
                            PersistedLedgerEvent {
                                timestamp: 105.0,
                                usage: usage(100, 20, 20),
                                cost_usd: 0.505,
                            },
                            PersistedLedgerEvent {
                                timestamp: 105.5,
                                usage: usage(100, 20, 20),
                                cost_usd: 0.505,
                            },
                        ],
                    },
                )]),
            },
            seed_sessions: Vec::new(),
        };

        let result = project_session_usage_ledger(request);
        let ledger_session = result.ledger.sessions.get("shared").unwrap();

        assert_eq!(ledger_session.model, "gpt-5.4");
        assert_eq!(ledger_session.events.len(), 2);
        assert_eq!(ledger_session.events[0].usage, usage(100, 20, 20));
        assert_eq!(ledger_session.events[1].usage, usage(70, 10, 10));
        assert_eq!(result.historical_sessions.len(), 1);
        assert_eq!(result.historical_sessions[0].session_id, "shared");
        assert_eq!(result.historical_sessions[0].total_tokens, 230);
        assert_eq!(result.historical_sessions[0].is_archived, false);
    }

    #[test]
    fn project_session_usage_ledger_aligns_seed_timestamps_to_current_usage_events() {
        let request = SessionUsageLedgerProjectionRequest {
            current_sessions: vec![cached_session(
                session_record("seeded", 100.0, 210.0, false, "gpt-5.4", usage(170, 30, 30)),
                vec![
                    usage_event(105.123, usage(100, 20, 20)),
                    usage_event(190.456, usage(70, 10, 10)),
                ],
            )],
            persisted_ledger: PersistedUsageLedger {
                version: 2,
                did_seed_from_session_cache: false,
                sessions: BTreeMap::new(),
            },
            seed_sessions: vec![cached_session(
                session_record("seeded", 100.0, 190.0, false, "gpt-5.4", usage(170, 30, 30)),
                vec![
                    usage_event(105.0, usage(100, 20, 20)),
                    usage_event(190.0, usage(70, 10, 10)),
                ],
            )],
        };

        let result = project_session_usage_ledger(request);
        let ledger_session = result.ledger.sessions.get("seeded").unwrap();

        assert!(result.ledger.did_seed_from_session_cache);
        assert_eq!(ledger_session.events.len(), 2);
        assert_eq!(ledger_session.events[0].timestamp, 105.123);
        assert_eq!(ledger_session.events[1].timestamp, 190.456);
    }

    #[test]
    fn project_session_usage_ledger_normalizes_archived_single_snapshot_delta() {
        let request = SessionUsageLedgerProjectionRequest {
            current_sessions: vec![cached_session(
                session_record("archived-only", 100.0, 300.0, true, "gpt-5.4", usage(170, 30, 30)),
                vec![usage_event(300.0, usage(170, 30, 30))],
            )],
            persisted_ledger: PersistedUsageLedger {
                version: 2,
                did_seed_from_session_cache: true,
                sessions: BTreeMap::from([(
                    "archived-only".to_string(),
                    PersistedLedgerSession {
                        model: "gpt-5.4".to_string(),
                        events: vec![PersistedLedgerEvent {
                            timestamp: 105.0,
                            usage: usage(100, 20, 20),
                            cost_usd: 0.505,
                        }],
                    },
                )]),
            },
            seed_sessions: Vec::new(),
        };

        let result = project_session_usage_ledger(request);
        let ledger_session = result.ledger.sessions.get("archived-only").unwrap();

        assert_eq!(ledger_session.events.len(), 2);
        assert_eq!(ledger_session.events[0].usage, usage(100, 20, 20));
        assert_eq!(ledger_session.events[1].usage, usage(70, 10, 10));
    }
}
