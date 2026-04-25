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
    #[serde(default)]
    pub state_sqlite_resolved_version: Option<i32>,
    #[serde(default)]
    pub logs_sqlite_resolved_version: Option<i32>,
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
    pub menu_host_root_path: String,
    pub menu_host_app_path: String,
    pub menu_host_lease_path: String,
    pub bar_config_path: String,
    pub cost_cache_path: String,
    pub cost_session_cache_path: String,
    pub cost_event_ledger_path: String,
    pub switch_journal_path: String,
    pub managed_launch_root_path: String,
    pub managed_launch_bin_path: String,
    pub managed_launch_hits_path: String,
    pub managed_launch_state_path: String,
    pub openai_gateway_root_path: String,
    pub openai_gateway_state_path: String,
    pub openai_gateway_route_journal_path: String,
    pub openrouter_gateway_root_path: String,
    pub openrouter_gateway_state_path: String,
    pub config_backup_path: String,
    pub auth_backup_path: String,
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
    let state_sqlite_version = request
        .state_sqlite_resolved_version
        .unwrap_or(request.state_sqlite_default_version)
        .max(1);
    let logs_sqlite_version = request
        .logs_sqlite_resolved_version
        .unwrap_or(request.logs_sqlite_default_version)
        .max(1);
    let menu_host_root = join_path(&codexbar_root, "menu-host");
    let managed_launch_root = join_path(&codexbar_root, "managed-launch");
    let openai_gateway_root = join_path(&codexbar_root, "openai-gateway");
    let openrouter_gateway_root = join_path(&codexbar_root, "openrouter-gateway");

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
            &format!("state_{}.sqlite", state_sqlite_version),
        ),
        logs_sqlite_path: join_path(
            &codex_root,
            &format!("logs_{}.sqlite", logs_sqlite_version),
        ),
        oauth_flows_directory_path: join_path(&codexbar_root, "oauth-flows"),
        menu_host_root_path: menu_host_root.clone(),
        menu_host_app_path: join_path(&menu_host_root, "codexbar.app"),
        menu_host_lease_path: join_path(&menu_host_root, "host.pid"),
        bar_config_path: join_path(&codexbar_root, "config.json"),
        cost_cache_path: join_path(&codexbar_root, "cost-cache.json"),
        cost_session_cache_path: join_path(&codexbar_root, "cost-session-cache.json"),
        cost_event_ledger_path: join_path(&codexbar_root, "cost-event-ledger.json"),
        switch_journal_path: join_path(&codexbar_root, "switch-journal.jsonl"),
        managed_launch_root_path: managed_launch_root.clone(),
        managed_launch_bin_path: join_path(&managed_launch_root, "bin"),
        managed_launch_hits_path: join_path(&managed_launch_root, "hits"),
        managed_launch_state_path: join_path(&managed_launch_root, "last-launch.json"),
        openai_gateway_root_path: openai_gateway_root.clone(),
        openai_gateway_state_path: join_path(&openai_gateway_root, "state.json"),
        openai_gateway_route_journal_path: join_path(&openai_gateway_root, "route-journal.json"),
        openrouter_gateway_root_path: openrouter_gateway_root.clone(),
        openrouter_gateway_state_path: join_path(&openrouter_gateway_root, "state.json"),
        config_backup_path: join_path(&codex_root, "config.toml.bak-codexbar-last"),
        auth_backup_path: join_path(&codex_root, "auth.json.bak-codexbar-last"),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plan_store_paths_uses_resolved_versions_and_extended_paths() {
        let plan = plan_store_paths(StorePathPlanRequest {
            home_root: Some("/tmp/codex-home/".into()),
            codex_root: None,
            codexbar_root: None,
            state_sqlite_default_version: 5,
            logs_sqlite_default_version: 2,
            state_sqlite_resolved_version: Some(8),
            logs_sqlite_resolved_version: Some(4),
        });

        assert_eq!(plan.codex_root, "/tmp/codex-home/.codex");
        assert_eq!(plan.codexbar_root, "/tmp/codex-home/.codexbar");
        assert_eq!(plan.state_sqlite_path, "/tmp/codex-home/.codex/state_8.sqlite");
        assert_eq!(plan.logs_sqlite_path, "/tmp/codex-home/.codex/logs_4.sqlite");
        assert_eq!(plan.menu_host_root_path, "/tmp/codex-home/.codexbar/menu-host");
        assert_eq!(plan.menu_host_app_path, "/tmp/codex-home/.codexbar/menu-host/codexbar.app");
        assert_eq!(plan.managed_launch_bin_path, "/tmp/codex-home/.codexbar/managed-launch/bin");
        assert_eq!(plan.openai_gateway_root_path, "/tmp/codex-home/.codexbar/openai-gateway");
        assert_eq!(plan.openrouter_gateway_root_path, "/tmp/codex-home/.codexbar/openrouter-gateway");
        assert_eq!(plan.config_backup_path, "/tmp/codex-home/.codex/config.toml.bak-codexbar-last");
        assert_eq!(plan.auth_backup_path, "/tmp/codex-home/.codex/auth.json.bak-codexbar-last");
    }
}
