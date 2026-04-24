use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ControlPlaneContract {
    pub schema_version: String,
    pub single_control_plane_law: String,
    pub command_examples: Vec<String>,
    pub query_examples: Vec<String>,
    pub event_examples: Vec<String>,
    pub stream_examples: Vec<String>,
    pub route_runtime_boundary_law: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CrateNode {
    pub crate_name: String,
    pub owns_subsystems: Vec<String>,
    pub depends_on: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HostCapabilityRule {
    pub capability: String,
    pub request_response_shape: String,
    pub swift_allowed: String,
    pub swift_forbidden: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct HostCapabilityContract {
    pub schema_version: String,
    pub request_fields: Vec<String>,
    pub response_fields: Vec<String>,
    pub event_fields: Vec<String>,
    pub capabilities: Vec<HostCapabilityRule>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SubsystemAcl {
    pub subsystem: String,
    pub capabilities: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct OwnershipMatrixEntry {
    pub subsystem: String,
    pub current_swift_owner: String,
    pub target_rust_owner: String,
    pub host_capabilities: Vec<String>,
    pub dual_run_gate: String,
    pub primary_cutover_gate: String,
    pub swift_delete_condition: String,
    pub swift_owner_state: String,
    #[serde(default)]
    pub temporary_wrapper_reason: Option<String>,
    pub delete_condition_met: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BranchWorktreeLaw {
    pub integration_worktree: String,
    pub integration_branch: String,
    pub sibling_worktree: String,
    pub sibling_branch_expected: String,
    pub hot_files: Vec<String>,
    pub rules: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FullRustCutoverContract {
    pub schema_version: String,
    pub control_plane: ControlPlaneContract,
    pub crate_graph: Vec<CrateNode>,
    pub host_capability_contract: HostCapabilityContract,
    pub capability_acl: Vec<SubsystemAcl>,
    pub ownership_matrix: Vec<OwnershipMatrixEntry>,
    pub branch_worktree_law: BranchWorktreeLaw,
}

pub fn default_full_rust_cutover_contract() -> FullRustCutoverContract {
    FullRustCutoverContract {
        schema_version: "full-rust-cutover.v1".to_string(),
        control_plane: ControlPlaneContract {
            schema_version: "kernel-control-plane.v1".to_string(),
            single_control_plane_law: "Swift UI may only speak command/query/event/stream to one Rust kernel; embedded and future sidecar share the same contract and must not grow a second business API.".to_string(),
            command_examples: vec_strings(&[
                "activate_account",
                "save_config",
                "refresh_due_accounts",
                "start_gateway",
                "complete_oauth_callback",
            ]),
            query_examples: vec_strings(&[
                "load_settings_snapshot",
                "load_runtime_snapshot",
                "load_cost_summary",
                "load_gateway_health",
            ]),
            event_examples: vec_strings(&[
                "mismatch_detected",
                "rollback_triggered",
                "host_capability_failed",
            ]),
            stream_examples: vec_strings(&[
                "runtime_state_stream",
                "gateway_health_stream",
                "session_index_stream",
            ]),
            route_runtime_boundary_law: "RouteRuntimeSnapshotDTO is host-input / kernel-output only. Host collects raw sticky, lease, runtime-block, running-thread, and live-session inputs; kernel normalizes them and emits the DTO.".to_string(),
        },
        crate_graph: vec![
            crate_node("core_model", &["canonical_dto_schema", "legacy_portable_core_parity"], &[]),
            crate_node("core_policy", &["canonicalization", "refresh_policy", "usage_merge", "route_runtime_snapshot"], &["core_model"]),
            crate_node("core_codec", &["sync_render", "auth_config_codec"], &["core_model"]),
            crate_node("host_contract", &["single_control_plane", "host_capability_contract", "acl", "owner_matrix", "branch_worktree_law"], &[]),
            crate_node("core_store", &["path_resolution", "config_persistence", "journal_path_policy"], &[]),
            crate_node("core_session", &["local_cost", "live_attribution", "running_attribution"], &[]),
            crate_node("core_runtime", &["usage_polling_scheduler_policy"], &[]),
            crate_node("core_gateway", &["gateway_transport_policy", "oauth_callback_interpretation"], &[]),
            crate_node("core_update", &["update_release_selection", "update_install_policy"], &[]),
            crate_node(
                "bridge_ffi",
                &["embedded_bridge"],
                &[
                    "core_model",
                    "core_policy",
                    "core_codec",
                    "host_contract",
                    "core_store",
                    "core_session",
                    "core_runtime",
                    "core_gateway",
                    "core_update",
                ],
            ),
        ],
        host_capability_contract: HostCapabilityContract {
            schema_version: "host-capability-envelope.v1".to_string(),
            request_fields: vec_strings(&[
                "schema_version",
                "subsystem",
                "caller",
                "capability",
                "operation",
                "request_id",
                "deadline_ms",
                "payload",
            ]),
            response_fields: vec_strings(&[
                "schema_version",
                "subsystem",
                "capability",
                "request_id",
                "status",
                "payload",
                "error_code",
                "retryable",
                "rollback_hint",
            ]),
            event_fields: vec_strings(&[
                "schema_version",
                "subsystem",
                "capability",
                "request_id",
                "sequence",
                "event_kind",
                "payload",
            ]),
            capabilities: vec![
                capability("path_resolver", "root kind + scope / canonical root path", "resolve home/app-support/cache/temp/log/runtime roots", "config path policy, business path composition"),
                capability("filesystem", "op + path + bytes + mode / result + errno", "file read/write/list/mkdir/remove/rename", "config canonicalization, journal semantics"),
                capability("sqlite_access", "db role + query descriptor / rows + columns + errno", "open approved sqlite DB and execute bounded queries", "attribution policy, result interpretation"),
                capability("keychain", "credential key + op / token blob + status", "keychain save/load/delete", "auth decision, retry semantics"),
                capability("network", "request descriptor / response descriptor", "HTTP/WebSocket execution", "refresh/usage/gateway policy, quota logic"),
                capability("timer_task", "schedule/cancel + handle / tick + cancel ack", "timer, debounce, cancellation token delivery", "refresh eligibility, retry/backoff policy"),
                capability("process_supervisor", "spawn/signal/query / pid + status", "process lifecycle and health probing", "route/gateway business policy"),
                capability("socket_bind", "bind/listen/close / port + status", "local port bind/listen/close", "protocol interpretation, callback business logic"),
                capability("localhost_listener", "start/stop + raw callback stream / callback event", "localhost callback accept/close/raw payload stream", "callback parsing/business validation"),
                capability("browser", "auth URL/open request / launch status", "open external browser or system auth surface", "auth completion logic"),
                capability("file_picker", "open/save dialog request / selected bookmark or URL", "user-visible import/export selection", "codec choice, account import semantics"),
                capability("nsworkspace_open", "URL/open request / result", "open browser/download URL", "auth completion logic, release policy"),
                capability("update_install", "release/install request / progress + result", "installer launch, system prompt bridging", "release selection/gatekeeping logic"),
                capability("notification", "message payload / delivered status", "user-facing notification", "rollback policy"),
            ],
        },
        capability_acl: vec![
            acl("path_resolution", &["path_resolver"]),
            acl("config_persistence", &["path_resolver", "filesystem", "keychain"]),
            acl("sync_render", &["path_resolver", "filesystem"]),
            acl("runtime_state", &[]),
            acl("refresh_state", &["network", "keychain"]),
            acl("usage_merge", &["network"]),
            acl("polling_scheduler", &["timer_task"]),
            acl("session_store", &["path_resolver", "filesystem"]),
            acl("runtime_sqlite_scan", &["path_resolver", "sqlite_access"]),
            acl("running_attribution", &[]),
            acl("live_attribution", &[]),
            acl("switch_journal", &["path_resolver", "filesystem"]),
            acl("local_cost", &[]),
            acl("openai_gateway", &["socket_bind", "network"]),
            acl("openrouter_gateway", &["socket_bind", "network"]),
            acl("lease_journal", &["path_resolver", "filesystem"]),
            acl("oauth_flow", &["browser", "keychain"]),
            acl("callback_listener", &["localhost_listener"]),
            acl("account_import_export", &["file_picker", "keychain"]),
            acl("update_install_policy", &["network", "nsworkspace_open", "update_install", "notification"]),
        ],
        ownership_matrix: vec![
            owner("path_resolution", "CodexPaths", "core_store + host_contract.path_resolver", &["path_resolver"], "path parity blocker=0", "Rust path planner primary green", "Swift only resolves raw platform roots"),
            owner("config_persistence", "CodexBarConfigStore", "core_store + core_model", &["path_resolver", "filesystem", "keychain"], "config corpus blocker=0", "primary config save/load green", "Swift no longer normalizes config"),
            owner("sync_render", "CodexSyncService", "core_codec + core_store", &["path_resolver", "filesystem"], "auth/config render compare blocker=0", "sync primary green", "Swift no longer renders auth.json / config.toml"),
            owner("runtime_state", "TokenStore", "core_runtime", &[], "runtime shadow compare blocker=0", "Rust runtime primary green", "Swift only keeps UI adapter"),
            owner("refresh_state", "OpenAIOAuthRefreshService", "core_policy + core_runtime", &["network", "keychain"], "refresh parity blocker=0", "refresh primary green", "Swift no longer owns retry/backoff"),
            owner("usage_merge", "WhamService", "core_policy + core_runtime", &["network"], "usage merge parity blocker=0", "usage primary green", "Swift no longer merges state"),
            owner("polling_scheduler", "OpenAIUsagePollingService", "core_runtime", &["timer_task"], "scheduler dual-run green", "primary polling green", "Swift only drives lifecycle if still needed"),
            owner("session_store", "SessionLogStore", "core_session + core_store", &["path_resolver", "filesystem"], "session corpus blocker=0", "Rust session store primary green", "Swift no longer parses sessions"),
            owner("runtime_sqlite_scan", "CodexThreadRuntimeStore", "core_session", &["path_resolver", "sqlite_access"], "sqlite parity blocker=0", "Rust runtime scan primary green", "Swift no longer queries sqlite"),
            owner("running_attribution", "OpenAIRunningThreadAttributionService", "core_session + core_runtime", &[], "attribution parity blocker=0", "Rust attribution primary green", "Swift no longer computes ownership"),
            owner("live_attribution", "OpenAILiveSessionAttributionService", "core_session + core_runtime", &[], "live attribution parity blocker=0", "Rust live attribution primary green", "Swift no longer computes live summary"),
            owner("switch_journal", "SwitchJournalStore", "core_store", &["path_resolver", "filesystem"], "journal parity blocker=0", "Rust journal primary green", "Swift no longer owns journal semantics"),
            owner("local_cost", "LocalCostSummaryService", "core_session", &[], "cost parity blocker=0", "Rust cost primary green", "Swift only displays summary"),
            owner("openai_gateway", "OpenAIAccountGatewayService", "core_gateway", &["socket_bind", "network"], "gateway shadow blocker=0", "embedded primary green", "Swift no longer owns route/sticky/failover logic"),
            owner("openrouter_gateway", "OpenRouterGatewayService", "core_gateway", &["socket_bind", "network"], "gateway shadow blocker=0", "embedded primary green", "Swift no longer owns OpenRouter runtime policy"),
            owner("lease_journal", "OpenAIAggregateGatewayLeaseStore", "core_gateway + core_store", &["path_resolver", "filesystem"], "lease parity blocker=0", "primary green", "Swift only exposes raw file capability"),
            owner("oauth_flow", "OpenAIOAuthFlowService", "core_gateway + core_store", &["browser", "keychain"], "auth flow parity blocker=0", "primary green", "Swift no longer interprets auth flow"),
            owner("callback_listener", "LocalhostOAuthCallbackServer", "host_contract.localhost_listener + core_gateway", &["localhost_listener"], "callback flow blocker=0", "primary green", "Swift only binds and streams raw callback payload"),
            owner("account_import_export", "CodexBarOAuthAccountService", "core_codec + core_store", &["file_picker", "keychain"], "import/export parity blocker=0", "primary green", "Swift only invokes UI"),
            owner("update_install_policy", "UpdateCoordinator", "core_update + core_runtime", &["network", "nsworkspace_open", "update_install", "notification"], "update parity blocker=0", "update primary green", "Swift only launches installer/system UI and forwards progress"),
        ],
        branch_worktree_law: BranchWorktreeLaw {
            integration_worktree: "/Users/lzl/FILE/github/codexbar-rust-portable-core-first".to_string(),
            integration_branch: "rust-portable-core-first".to_string(),
            sibling_worktree: "/Users/lzl/FILE/github/codexbar".to_string(),
            sibling_branch_expected: "codex/openai-aggregate-gateway-credential-mode".to_string(),
            hot_files: vec_strings(&[
                "CodexPaths.swift",
                "TokenStore.swift",
                "CodexBarConfigStore.swift",
                "CodexSyncService.swift",
                "SessionLogStore.swift",
                "CodexThreadRuntimeStore.swift",
                "OpenAIAccountGatewayService.swift",
                "OpenRouterGatewayService.swift",
                "OpenAIAggregateGatewayLeaseStore.swift",
                "OpenAIOAuthRefreshService.swift",
                "WhamService.swift",
                "UpdateCoordinator.swift",
                "CodexBarConfig.swift",
            ]),
            rules: vec_strings(&[
                "Only /Users/lzl/FILE/github/codexbar-rust-portable-core-first may carry full-cutover integration work.",
                "The sibling worktree is a product lane, not a Rust cutover lane.",
                "No direct full-cutover development lands on main.",
                "Hot files may not evolve in both lanes without an explicit reconciliation note.",
                "Sibling lane sync happens only at phase boundaries.",
                "process_supervisor stays forbidden before p6-sidecar-eval admission.",
            ]),
        },
    }
}

fn vec_strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_string()).collect()
}

fn crate_node(name: &str, owns_subsystems: &[&str], depends_on: &[&str]) -> CrateNode {
    CrateNode {
        crate_name: name.to_string(),
        owns_subsystems: vec_strings(owns_subsystems),
        depends_on: vec_strings(depends_on),
    }
}

fn capability(
    capability: &str,
    request_response_shape: &str,
    swift_allowed: &str,
    swift_forbidden: &str,
) -> HostCapabilityRule {
    HostCapabilityRule {
        capability: capability.to_string(),
        request_response_shape: request_response_shape.to_string(),
        swift_allowed: swift_allowed.to_string(),
        swift_forbidden: swift_forbidden.to_string(),
    }
}

fn acl(subsystem: &str, capabilities: &[&str]) -> SubsystemAcl {
    SubsystemAcl {
        subsystem: subsystem.to_string(),
        capabilities: vec_strings(capabilities),
    }
}

fn owner(
    subsystem: &str,
    current_swift_owner: &str,
    target_rust_owner: &str,
    host_capabilities: &[&str],
    dual_run_gate: &str,
    primary_cutover_gate: &str,
    swift_delete_condition: &str,
) -> OwnershipMatrixEntry {
    OwnershipMatrixEntry {
        subsystem: subsystem.to_string(),
        current_swift_owner: current_swift_owner.to_string(),
        target_rust_owner: target_rust_owner.to_string(),
        host_capabilities: vec_strings(host_capabilities),
        dual_run_gate: dual_run_gate.to_string(),
        primary_cutover_gate: primary_cutover_gate.to_string(),
        swift_delete_condition: swift_delete_condition.to_string(),
        swift_owner_state: "temporary_wrapper".to_string(),
        temporary_wrapper_reason: Some("p0-contract freezes Rust ownership and keeps Swift only as an adapter until the phase gate turns primary.".to_string()),
        delete_condition_met: false,
    }
}
