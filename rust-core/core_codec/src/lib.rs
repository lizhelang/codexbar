use core_model::{
    CanonicalConfigSnapshot, CanonicalProviderAccountSnapshot, CanonicalProviderSnapshot,
    CodecMessage, RenderCodecOutput, RenderCodecRequest,
};
use serde::Serialize;
use serde_json::Value;
use time::{format_description::well_known::Rfc3339, OffsetDateTime};

const OPENAI_GATEWAY_BASE_URL: &str = "http://localhost:1456/v1";
const OPENROUTER_GATEWAY_BASE_URL: &str = "http://localhost:1457/v1";
const OPENROUTER_GATEWAY_API_KEY: &str = "codexbar-openrouter-gateway";

pub fn render_codec_bundle(request: RenderCodecRequest) -> Result<RenderCodecOutput, String> {
    let provider = request
        .config
        .providers
        .iter()
        .find(|provider| provider.id == request.active_provider_id)
        .ok_or_else(|| "missingActiveProvider".to_string())?;
    let account = provider
        .accounts
        .iter()
        .find(|account| account.id == request.active_account_id)
        .or_else(|| {
            provider
                .active_account_id
                .as_ref()
                .and_then(|active_account_id| {
                    provider
                        .accounts
                        .iter()
                        .find(|account| &account.id == active_account_id)
                })
        })
        .ok_or_else(|| "missingActiveAccount".to_string())?;

    let effective_model = match provider.kind.as_str() {
        "openrouter" => provider
            .selected_model_id
            .clone()
            .ok_or_else(|| "missingOpenRouterModel".to_string())?,
        _ => request.config.global.default_model.clone(),
    };

    let auth_json = render_auth_json(provider, account)?;
    let config_toml = render_config_toml(
        &request.config,
        provider,
        &effective_model,
        &request.existing_toml_text,
    );

    Ok(RenderCodecOutput {
        auth_json,
        config_toml,
        codec_warnings: Vec::<CodecMessage>::new(),
        migration_notes: Vec::<CodecMessage>::new(),
    })
}

fn render_auth_json(
    provider: &CanonicalProviderSnapshot,
    account: &CanonicalProviderAccountSnapshot,
) -> Result<String, String> {
    match provider.kind.as_str() {
        "openai_oauth" => {
            let access_token = account
                .access_token
                .clone()
                .ok_or_else(|| "missingOAuthTokens".to_string())?;
            let refresh_token = account
                .refresh_token
                .clone()
                .ok_or_else(|| "missingOAuthTokens".to_string())?;
            let id_token = account
                .id_token
                .clone()
                .ok_or_else(|| "missingOAuthTokens".to_string())?;
            let account_id = account
                .openai_account_id
                .clone()
                .ok_or_else(|| "missingOAuthTokens".to_string())?;
            let auth = OAuthAuthJson {
                openai_api_key: Value::Null,
                auth_mode: "chatgpt".to_string(),
                client_id: account.oauth_client_id.clone(),
                last_refresh: format_unix_timestamp(
                    account
                        .token_last_refresh_at
                        .unwrap_or(0.0),
                ),
                tokens: OAuthAuthTokens {
                    access_token,
                    account_id,
                    id_token,
                    refresh_token,
                },
            };
            serde_json::to_string_pretty(&auth)
                .map(legacy_json_spacing)
                .map_err(|error| error.to_string())
        }
        "openrouter" => {
            if account.api_key.is_none() {
                return Err("missingAPIKey".to_string());
            }
            serde_json::to_string_pretty(&ApiKeyAuthJson {
                openai_api_key: OPENROUTER_GATEWAY_API_KEY.to_string(),
            })
            .map(legacy_json_spacing)
            .map_err(|error| error.to_string())
        }
        _ => {
            let api_key = account
                .api_key
                .clone()
                .ok_or_else(|| "missingAPIKey".to_string())?;
            serde_json::to_string_pretty(&ApiKeyAuthJson {
                openai_api_key: api_key,
            })
            .map(legacy_json_spacing)
            .map_err(|error| error.to_string())
        }
    }
}

fn legacy_json_spacing(json: String) -> String {
    json.replace("\": ", "\" : ")
}

fn format_unix_timestamp(timestamp: f64) -> String {
    let nanoseconds = (timestamp * 1_000_000_000.0).round() as i128;
    OffsetDateTime::from_unix_timestamp_nanos(nanoseconds)
        .ok()
        .and_then(|value| value.format(&Rfc3339).ok())
        .unwrap_or_else(|| "1970-01-01T00:00:00Z".to_string())
}

fn render_config_toml(
    config: &CanonicalConfigSnapshot,
    provider: &CanonicalProviderSnapshot,
    effective_model: &str,
    existing_toml_text: &str,
) -> String {
    let mut text = existing_toml_text.to_string();

    text = upsert_setting(&text, "model_provider", "\"openai\"");
    text = upsert_setting(&text, "model", &quote(effective_model));
    text = upsert_setting(
        &text,
        "review_model",
        &quote(if provider.kind == "openrouter" {
            effective_model
        } else {
            &config.global.review_model
        }),
    );
    text = upsert_setting(
        &text,
        "model_reasoning_effort",
        &quote(&config.global.reasoning_effort),
    );

    if provider.kind != "openai_oauth" {
        text = remove_setting(&text, "service_tier");
    }
    text = remove_setting(&text, "oss_provider");
    text = remove_setting(&text, "openai_base_url");
    text = remove_setting(&text, "model_catalog_json");
    text = remove_setting(&text, "preferred_auth_method");
    text = remove_block(&text, "OpenAI");
    text = remove_block(&text, "openai");

    if provider.kind == "openai_oauth" && config.openai.account_usage_mode == "aggregate_gateway" {
        text = upsert_setting(
            &text,
            "openai_base_url",
            &quote(OPENAI_GATEWAY_BASE_URL),
        );
    } else if provider.kind == "openrouter" {
        text = upsert_setting(
            &text,
            "openai_base_url",
            &quote(OPENROUTER_GATEWAY_BASE_URL),
        );
    } else if let Some(base_url) = provider.base_url.as_deref() {
        text = upsert_setting(&text, "openai_base_url", &quote(base_url));
    }

    collapse_blank_lines(text)
}

fn quote(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

fn upsert_setting(text: &str, key: &str, value: &str) -> String {
    let replacement = format!("{key} = {value}");
    let mut lines = text.lines().map(str::to_string).collect::<Vec<_>>();
    if let Some(index) = lines
        .iter()
        .position(|line| line.trim_start().starts_with(&format!("{key} =")))
    {
        lines[index] = replacement;
        return join_lines(lines);
    }
    lines.insert(0, replacement);
    join_lines(lines)
}

fn remove_setting(text: &str, key: &str) -> String {
    join_lines(
        text.lines()
            .filter(|line| line.trim_start().starts_with(&format!("{key} =")) == false)
            .map(str::to_string)
            .collect::<Vec<_>>(),
    )
}

fn remove_block(text: &str, key: &str) -> String {
    let block_header = format!("[model_providers.{key}]");
    let mut kept = Vec::new();
    let mut skipping = false;
    for line in text.lines() {
        if line.trim() == block_header {
            skipping = true;
            continue;
        }
        if skipping && line.trim_start().starts_with('[') {
            skipping = false;
        }
        if skipping == false {
            kept.push(line.to_string());
        }
    }
    join_lines(kept)
}

fn join_lines(lines: Vec<String>) -> String {
    if lines.is_empty() {
        return String::new();
    }
    lines.join("\n")
}

fn collapse_blank_lines(text: String) -> String {
    let mut output = String::new();
    let mut previous_blank = false;
    for line in text.lines() {
        let is_blank = line.trim().is_empty();
        if is_blank && previous_blank {
            continue;
        }
        if output.is_empty() == false {
            output.push('\n');
        }
        output.push_str(line);
        previous_blank = is_blank;
    }
    output.trim().to_string() + "\n"
}

#[derive(Serialize)]
struct OAuthAuthJson {
    #[serde(rename = "OPENAI_API_KEY")]
    openai_api_key: Value,
    auth_mode: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    client_id: Option<String>,
    last_refresh: String,
    tokens: OAuthAuthTokens,
}

#[derive(Serialize)]
struct OAuthAuthTokens {
    access_token: String,
    account_id: String,
    id_token: String,
    refresh_token: String,
}

#[derive(Serialize)]
struct ApiKeyAuthJson {
    #[serde(rename = "OPENAI_API_KEY")]
    openai_api_key: String,
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use core_model::{
        CanonicalActiveSelection, CanonicalConfigSnapshot, CanonicalGlobalSettings,
        CanonicalOpenAISettings, CanonicalProviderAccountSnapshot, CanonicalProviderSnapshot,
        CanonicalQuotaSortSettings, RenderCodecRequest,
    };

    use super::*;

    fn sample_config(kind: &str) -> CanonicalConfigSnapshot {
        CanonicalConfigSnapshot {
            version: 1,
            global: CanonicalGlobalSettings {
                default_model: "gpt-5.4".into(),
                review_model: "gpt-5.4".into(),
                reasoning_effort: "xhigh".into(),
            },
            active: CanonicalActiveSelection {
                provider_id: Some("provider-1".into()),
                account_id: Some("account-1".into()),
            },
            model_pricing: BTreeMap::new(),
            openai: CanonicalOpenAISettings {
                account_order: vec![],
                account_usage_mode: "aggregate_gateway".into(),
                switch_mode_selection: None,
                account_ordering_mode: "quotaSort".into(),
                manual_activation_behavior: "updateConfigOnly".into(),
                usage_display_mode: "used".into(),
                quota_sort: CanonicalQuotaSortSettings {
                    plus_relative_weight: 10.0,
                    pro_relative_to_plus_multiplier: 10.0,
                    team_relative_to_plus_multiplier: 1.5,
                    pro_absolute_weight: 100.0,
                    team_absolute_weight: 15.0,
                },
                interop_proxies_json: None,
                extensions: BTreeMap::new(),
            },
            providers: vec![CanonicalProviderSnapshot {
                id: "provider-1".into(),
                kind: kind.into(),
                label: "Provider".into(),
                enabled: true,
                base_url: Some("https://example.com/v1".into()),
                default_model: Some("gpt-5.4".into()),
                selected_model_id: Some("anthropic/claude-3.7-sonnet".into()),
                pinned_model_ids: vec![],
                active_account_id: Some("account-1".into()),
                accounts: vec![CanonicalProviderAccountSnapshot {
                    id: "account-1".into(),
                    kind: if kind == "openai_oauth" {
                        "oauth_tokens".into()
                    } else {
                        "api_key".into()
                    },
                    label: "Provider Account".into(),
                    email: Some("acct@example.com".into()),
                    openai_account_id: Some("remote-1".into()),
                    access_token: Some("access".into()),
                    refresh_token: Some("refresh".into()),
                    id_token: Some("id".into()),
                    expires_at: Some(10.0),
                    oauth_client_id: Some("client".into()),
                    token_last_refresh_at: Some(5.0),
                    api_key: Some("sk-live".into()),
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
                }],
            }],
        }
    }

    #[test]
    fn renders_oauth_auth_json() {
        let output = render_codec_bundle(RenderCodecRequest {
            config: sample_config("openai_oauth"),
            active_provider_id: "provider-1".into(),
            active_account_id: "account-1".into(),
            existing_toml_text: String::new(),
        })
        .unwrap();

        assert!(output.auth_json.contains("\"auth_mode\": \"chatgpt\""));
        assert!(output.config_toml.contains("openai_base_url = \"http://localhost:1456/v1\""));
    }
}
