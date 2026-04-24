use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StorePathPlanRequest {
    #[serde(default)]
    pub home_root: Option<String>,
    #[serde(default)]
    pub codex_root: Option<String>,
    #[serde(default)]
    pub codexbar_root: Option<String>,
    pub state_sqlite_default_version: i32,
    pub logs_sqlite_default_version: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct StorePathPlan {
    pub home_root: String,
    pub codex_root: String,
    pub codexbar_root: String,
    pub auth_path: String,
    pub token_pool_path: String,
    pub config_toml_path: String,
    pub provider_secrets_path: String,
    pub state_sqlite_path: String,
    pub logs_sqlite_path: String,
    pub oauth_flows_directory_path: String,
    pub bar_config_path: String,
    pub cost_cache_path: String,
    pub cost_session_cache_path: String,
    pub cost_event_ledger_path: String,
    pub switch_journal_path: String,
    pub openai_gateway_state_path: String,
    pub openai_gateway_route_journal_path: String,
    pub openrouter_gateway_state_path: String,
    pub path_policy_summary: String,
}

pub fn plan_store_paths(request: StorePathPlanRequest) -> StorePathPlan {
    let home_root = normalize_path(
        request
            .home_root
            .unwrap_or_else(|| "~".to_string()),
    );
    let codex_root = normalize_path(
        request
            .codex_root
            .unwrap_or_else(|| join_path(&home_root, ".codex")),
    );
    let codexbar_root = normalize_path(
        request
            .codexbar_root
            .unwrap_or_else(|| join_path(&home_root, ".codexbar")),
    );

    StorePathPlan {
        home_root: home_root.clone(),
        codex_root: codex_root.clone(),
        codexbar_root: codexbar_root.clone(),
        auth_path: join_path(&codex_root, "auth.json"),
        token_pool_path: join_path(&codex_root, "token_pool.json"),
        config_toml_path: join_path(&codex_root, "config.toml"),
        provider_secrets_path: join_path(&codex_root, "provider-secrets.env"),
        state_sqlite_path: join_path(
            &codex_root,
            &format!("state_{}.sqlite", request.state_sqlite_default_version.max(1)),
        ),
        logs_sqlite_path: join_path(
            &codex_root,
            &format!("logs_{}.sqlite", request.logs_sqlite_default_version.max(1)),
        ),
        oauth_flows_directory_path: join_path(&codexbar_root, "oauth-flows"),
        bar_config_path: join_path(&codexbar_root, "config.json"),
        cost_cache_path: join_path(&codexbar_root, "cost-cache.json"),
        cost_session_cache_path: join_path(&codexbar_root, "cost-session-cache.json"),
        cost_event_ledger_path: join_path(&codexbar_root, "cost-event-ledger.json"),
        switch_journal_path: join_path(&codexbar_root, "switch-journal.jsonl"),
        openai_gateway_state_path: join_path(&join_path(&codexbar_root, "openai-gateway"), "state.json"),
        openai_gateway_route_journal_path: join_path(&join_path(&codexbar_root, "openai-gateway"), "route-journal.json"),
        openrouter_gateway_state_path: join_path(&join_path(&codexbar_root, "openrouter-gateway"), "state.json"),
        path_policy_summary: "Rust owns path composition; Swift host adapters only resolve raw platform roots.".to_string(),
    }
}

fn normalize_path(path: String) -> String {
    if path.ends_with('/') && path.len() > 1 {
        path.trim_end_matches('/').to_string()
    } else {
        path
    }
}

fn join_path(base: &str, component: &str) -> String {
    let trimmed_base = base.trim_end_matches('/');
    let trimmed_component = component.trim_start_matches('/');
    if trimmed_base.is_empty() {
        format!("/{}", trimmed_component)
    } else {
        format!("{}/{}", trimmed_base, trimmed_component)
    }
}
