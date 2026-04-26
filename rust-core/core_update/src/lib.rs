use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateArtifactInput {
    pub architecture: String,
    pub format: String,
    pub download_url: String,
    #[serde(default)]
    pub sha256: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateReleaseInput {
    pub version: String,
    pub delivery_mode: String,
    #[serde(default)]
    pub minimum_automatic_update_version: Option<String>,
    #[serde(default)]
    pub artifacts: Vec<UpdateArtifactInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateEnvironmentFacts {
    pub current_version: String,
    pub architecture: String,
    pub bundle_path: String,
    pub signature_usable: bool,
    pub signature_summary: String,
    pub gatekeeper_passes: bool,
    pub gatekeeper_summary: String,
    pub automatic_updater_available: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateResolutionRequest {
    pub release: UpdateReleaseInput,
    pub environment: UpdateEnvironmentFacts,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateBlockerResult {
    pub code: String,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateAvailabilityResult {
    pub update_available: bool,
    #[serde(default)]
    pub selected_artifact: Option<UpdateArtifactInput>,
    #[serde(default)]
    pub blockers: Vec<UpdateBlockerResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateArtifactSelectionRequest {
    pub architecture: String,
    #[serde(default)]
    pub artifacts: Vec<UpdateArtifactInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateArtifactSelectionResult {
    #[serde(default)]
    pub selected_artifact: Option<UpdateArtifactInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateBlockerEvaluationRequest {
    pub release: UpdateReleaseInput,
    pub environment: UpdateEnvironmentFacts,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateBlockerEvaluationResult {
    #[serde(default)]
    pub blockers: Vec<UpdateBlockerResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateSignatureInspectionParseRequest {
    pub raw_output: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateSignatureInspectionParseResult {
    pub has_usable_signature: bool,
    pub summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateGatekeeperInspectionParseRequest {
    pub raw_output: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UpdateGatekeeperInspectionParseResult {
    pub passes_assessment: bool,
    pub summary: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GitHubReleaseAssetInput {
    pub name: String,
    pub browser_download_url: String,
    #[serde(default)]
    pub digest: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GitHubReleaseIndexEntryInput {
    pub tag_name: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub body: Option<String>,
    pub html_url: String,
    pub draft: bool,
    pub prerelease: bool,
    #[serde(default)]
    pub published_at: Option<f64>,
    #[serde(default)]
    pub assets: Vec<GitHubReleaseAssetInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GitHubInstallableReleaseInput {
    pub version: String,
    #[serde(default)]
    pub published_at: Option<f64>,
    #[serde(default)]
    pub summary: Option<String>,
    pub release_notes_url: String,
    pub download_page_url: String,
    pub delivery_mode: String,
    #[serde(default)]
    pub minimum_automatic_update_version: Option<String>,
    #[serde(default)]
    pub artifacts: Vec<UpdateArtifactInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GitHubInstallableReleaseSelectionRequest {
    #[serde(default)]
    pub releases: Vec<GitHubReleaseIndexEntryInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GitHubInstallableReleaseSelectionResult {
    #[serde(default)]
    pub release: Option<GitHubInstallableReleaseInput>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GitHubInstallableReleaseSelectionFromJsonRequest {
    pub json_text: String,
}

pub fn resolve_update_availability(
    request: UpdateResolutionRequest,
) -> Result<UpdateAvailabilityResult, String> {
    let current = parse_semver(&request.environment.current_version).ok_or_else(|| {
        format!(
            "invalidCurrentVersion: {}",
            request.environment.current_version
        )
    })?;
    let release = parse_semver(&request.release.version)
        .ok_or_else(|| format!("invalidReleaseVersion: {}", request.release.version))?;
    if compare_semver(&current, &release).is_ge() {
        return Ok(UpdateAvailabilityResult {
            update_available: false,
            selected_artifact: None,
            blockers: Vec::new(),
        });
    }

    let selected_artifact = select_artifact(
        &request.environment.architecture,
        &request.release.artifacts,
    )?;
    let blockers = evaluate_blockers(&request.release, &request.environment)?;

    Ok(UpdateAvailabilityResult {
        update_available: true,
        selected_artifact: Some(selected_artifact),
        blockers,
    })
}

pub fn select_update_artifact(
    request: UpdateArtifactSelectionRequest,
) -> Result<UpdateArtifactSelectionResult, String> {
    let selected_artifact = select_artifact(&request.architecture, &request.artifacts)?;
    Ok(UpdateArtifactSelectionResult {
        selected_artifact: Some(selected_artifact),
    })
}

pub fn evaluate_update_blockers(
    request: UpdateBlockerEvaluationRequest,
) -> Result<UpdateBlockerEvaluationResult, String> {
    Ok(UpdateBlockerEvaluationResult {
        blockers: evaluate_blockers(&request.release, &request.environment)?,
    })
}

pub fn parse_update_signature_inspection(
    request: UpdateSignatureInspectionParseRequest,
) -> UpdateSignatureInspectionParseResult {
    let trimmed = request.raw_output.trim();
    if trimmed.is_empty() {
        return UpdateSignatureInspectionParseResult {
            has_usable_signature: false,
            summary: "Unknown signature".to_string(),
        };
    }

    let lines = trimmed.lines().map(str::trim).collect::<Vec<_>>();
    let signature_line = lines
        .iter()
        .find(|line| line.starts_with("Signature="))
        .copied()
        .unwrap_or("Signature=unknown");
    let team_line = lines
        .iter()
        .find(|line| line.starts_with("TeamIdentifier="))
        .copied()
        .unwrap_or("TeamIdentifier=unknown");
    let summary = format!("{signature_line}; {team_line}");
    let is_adhoc = signature_line.to_lowercase().contains("adhoc");
    let team_missing = team_line.to_lowercase().contains("not set");

    UpdateSignatureInspectionParseResult {
        has_usable_signature: !is_adhoc && !team_missing,
        summary,
    }
}

pub fn parse_update_gatekeeper_inspection(
    request: UpdateGatekeeperInspectionParseRequest,
) -> UpdateGatekeeperInspectionParseResult {
    let trimmed = request.raw_output.trim();
    if trimmed.is_empty() {
        return UpdateGatekeeperInspectionParseResult {
            passes_assessment: false,
            summary: "Unknown signature".to_string(),
        };
    }

    let summary = trimmed.lines().take(2).collect::<Vec<_>>().join(" | ");
    let normalized = trimmed.to_lowercase();
    UpdateGatekeeperInspectionParseResult {
        passes_assessment: normalized.contains("accepted")
            && !normalized.contains("no usable signature"),
        summary,
    }
}

pub fn select_installable_github_release(
    request: GitHubInstallableReleaseSelectionRequest,
) -> GitHubInstallableReleaseSelectionResult {
    GitHubInstallableReleaseSelectionResult {
        release: request
            .releases
            .into_iter()
            .find_map(installable_release_from_index_entry),
    }
}

pub fn select_installable_github_release_from_json(
    request: GitHubInstallableReleaseSelectionFromJsonRequest,
) -> GitHubInstallableReleaseSelectionResult {
    GitHubInstallableReleaseSelectionResult {
        release: github_release_index_entries_from_json(&request.json_text)
            .into_iter()
            .find_map(installable_release_from_index_entry),
    }
}

fn blocker(code: &str, detail: &str) -> UpdateBlockerResult {
    UpdateBlockerResult {
        code: code.to_string(),
        detail: detail.to_string(),
    }
}

fn github_release_index_entries_from_json(text: &str) -> Vec<GitHubReleaseIndexEntryInput> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return Vec::new();
    };
    let Some(items) = value.as_array() else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(github_release_index_entry_from_value)
        .collect()
}

fn github_release_index_entry_from_value(
    value: &serde_json::Value,
) -> Option<GitHubReleaseIndexEntryInput> {
    let object = value.as_object()?;
    Some(GitHubReleaseIndexEntryInput {
        tag_name: object.get("tag_name")?.as_str()?.to_string(),
        name: object
            .get("name")
            .and_then(|value| value.as_str())
            .map(|value| value.to_string()),
        body: object
            .get("body")
            .and_then(|value| value.as_str())
            .map(|value| value.to_string()),
        html_url: object.get("html_url")?.as_str()?.to_string(),
        draft: object.get("draft")?.as_bool()?,
        prerelease: object.get("prerelease")?.as_bool()?,
        published_at: object
            .get("published_at")
            .and_then(|value| value.as_str())
            .and_then(parse_iso8601_to_unix_seconds),
        assets: object
            .get("assets")
            .and_then(|value| value.as_array())
            .into_iter()
            .flatten()
            .filter_map(github_release_asset_from_value)
            .collect(),
    })
}

fn github_release_asset_from_value(value: &serde_json::Value) -> Option<GitHubReleaseAssetInput> {
    let object = value.as_object()?;
    Some(GitHubReleaseAssetInput {
        name: object.get("name")?.as_str()?.to_string(),
        browser_download_url: object.get("browser_download_url")?.as_str()?.to_string(),
        digest: object
            .get("digest")
            .and_then(|value| value.as_str())
            .map(|value| value.to_string()),
    })
}

fn evaluate_blockers(
    release: &UpdateReleaseInput,
    environment: &UpdateEnvironmentFacts,
) -> Result<Vec<UpdateBlockerResult>, String> {
    let mut blockers = Vec::new();
    if release.delivery_mode == "guidedDownload" {
        blockers.push(blocker(
            "guidedDownloadOnlyRelease",
            "release requires guided download",
        ));
    }
    if let Some(minimum_version) = release.minimum_automatic_update_version.as_ref() {
        let current = parse_semver(&environment.current_version)
            .ok_or_else(|| format!("invalidCurrentVersion: {}", environment.current_version))?;
        let minimum = parse_semver(minimum_version)
            .ok_or_else(|| format!("invalidMinimumAutomaticVersion: {}", minimum_version))?;
        if current < minimum {
            blockers.push(blocker(
                "bootstrapRequired",
                &format!(
                    "current {} is below automatic minimum {}",
                    environment.current_version, minimum_version
                ),
            ));
        }
    }
    if environment.automatic_updater_available == false {
        blockers.push(blocker(
            "automaticUpdaterUnavailable",
            "automatic updater is not available",
        ));
    }
    if environment.signature_usable == false {
        blockers.push(blocker(
            "missingTrustedSignature",
            &environment.signature_summary,
        ));
    }
    if environment.gatekeeper_passes == false {
        blockers.push(blocker(
            "failingGatekeeperAssessment",
            &environment.gatekeeper_summary,
        ));
    }
    let install_location = classify_install_location(&environment.bundle_path);
    if install_location == "other" {
        blockers.push(blocker(
            "unsupportedInstallLocation",
            install_location,
        ));
    }
    Ok(blockers)
}

fn classify_install_location(bundle_path: &str) -> &'static str {
    let path = bundle_path.trim();
    if path == "/Applications" || path.starts_with("/Applications/") {
        return "applications";
    }
    if let Some(home) = std::env::var_os("HOME") {
        let user_apps = std::path::PathBuf::from(home).join("Applications");
        let user_apps = user_apps.to_string_lossy();
        let user_apps = user_apps.as_ref();
        if path == user_apps || path.starts_with(&format!("{user_apps}/")) {
            return "userApplications";
        }
    }
    "other"
}

fn installable_release_from_index_entry(
    release: GitHubReleaseIndexEntryInput,
) -> Option<GitHubInstallableReleaseInput> {
    if release.draft || release.prerelease {
        return None;
    }

    let artifacts = release
        .assets
        .into_iter()
        .filter_map(installable_artifact_from_github_asset)
        .collect::<Vec<_>>();
    if artifacts.is_empty() {
        return None;
    }

    Some(GitHubInstallableReleaseInput {
        version: normalize_release_version(&release.tag_name),
        published_at: release.published_at,
        summary: first_nonempty(release.body.as_deref(), release.name.as_deref()),
        release_notes_url: release.html_url.clone(),
        download_page_url: release.html_url,
        delivery_mode: "guidedDownload".to_string(),
        minimum_automatic_update_version: None,
        artifacts,
    })
}

fn installable_artifact_from_github_asset(
    asset: GitHubReleaseAssetInput,
) -> Option<UpdateArtifactInput> {
    let format = infer_update_artifact_format(&asset.name)?;
    Some(UpdateArtifactInput {
        architecture: infer_update_artifact_architecture(&asset.name).to_string(),
        format: format.to_string(),
        download_url: asset.browser_download_url,
        sha256: normalize_digest(asset.digest.as_deref()),
    })
}

fn normalize_release_version(value: &str) -> String {
    let trimmed = value.trim();
    trimmed.strip_prefix('v').unwrap_or(trimmed).to_string()
}

fn first_nonempty(primary: Option<&str>, fallback: Option<&str>) -> Option<String> {
    let primary = primary.map(str::trim).filter(|value| !value.is_empty());
    if let Some(primary) = primary {
        return Some(primary.to_string());
    }
    fallback
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_string())
}

fn infer_update_artifact_format(filename: &str) -> Option<&'static str> {
    let normalized = filename.to_lowercase();
    if normalized.ends_with(".dmg") {
        return Some("dmg");
    }
    if normalized.ends_with(".zip") {
        return Some("zip");
    }
    None
}

fn infer_update_artifact_architecture(filename: &str) -> &'static str {
    let normalized = filename.to_lowercase();
    if normalized.contains("intel") || normalized.contains("x86_64") || normalized.contains("x64") {
        return "x86_64";
    }
    if normalized.contains("arm64")
        || normalized.contains("apple-silicon")
        || normalized.contains("aarch64")
    {
        return "arm64";
    }
    "universal"
}

fn normalize_digest(digest: Option<&str>) -> Option<String> {
    let digest = digest?.trim();
    if digest.is_empty() || digest.starts_with("sha256:") == false {
        return None;
    }
    Some(digest.trim_start_matches("sha256:").to_string())
}

fn parse_iso8601_to_unix_seconds(value: &str) -> Option<f64> {
    let value = value.trim();
    if value.len() < 19 {
        return None;
    }
    let year = value.get(0..4)?.parse::<i32>().ok()?;
    let month = value.get(5..7)?.parse::<u32>().ok()?;
    let day = value.get(8..10)?.parse::<u32>().ok()?;
    let hour = value.get(11..13)?.parse::<u32>().ok()?;
    let minute = value.get(14..16)?.parse::<u32>().ok()?;
    let second = value.get(17..19)?.parse::<u32>().ok()?;
    if value.get(4..5)? != "-"
        || value.get(7..8)? != "-"
        || !matches!(value.get(10..11)?, "T" | "t" | " ")
        || value.get(13..14)? != ":"
        || value.get(16..17)? != ":"
        || !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }

    let mut index = 19;
    let mut fractional = 0.0;
    if value.get(index..index + 1) == Some(".") {
        index += 1;
        let start = index;
        while value
            .as_bytes()
            .get(index)
            .map(|byte| byte.is_ascii_digit())
            .unwrap_or(false)
        {
            index += 1;
        }
        if index > start {
            let divisor = 10_f64.powi((index - start) as i32);
            fractional = value.get(start..index)?.parse::<f64>().ok()? / divisor;
        }
    }

    let offset_seconds = match value.get(index..index + 1)? {
        "Z" | "z" => 0,
        "+" | "-" => {
            let sign = if value.get(index..index + 1)? == "+" {
                1
            } else {
                -1
            };
            let hours = value.get(index + 1..index + 3)?.parse::<i64>().ok()?;
            let minutes = value.get(index + 4..index + 6)?.parse::<i64>().ok()?;
            if value.get(index + 3..index + 4)? != ":" || hours > 23 || minutes > 59 {
                return None;
            }
            sign * (hours * 3600 + minutes * 60)
        }
        _ => return None,
    };

    Some(
        (days_from_civil(year, month, day) * 86_400
            + i64::from(hour) * 3_600
            + i64::from(minute) * 60
            + i64::from(second)
            - offset_seconds) as f64
            + fractional,
    )
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

fn parse_semver(value: &str) -> Option<Vec<i64>> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    let normalized = trimmed.strip_prefix('v').unwrap_or(trimmed);
    let numeric = normalized.split('-').next().unwrap_or(normalized);
    let components = numeric
        .split('.')
        .filter_map(|component| component.parse::<i64>().ok())
        .collect::<Vec<_>>();
    if components.is_empty() {
        None
    } else {
        Some(components)
    }
}

fn compare_semver(lhs: &[i64], rhs: &[i64]) -> std::cmp::Ordering {
    let max_len = lhs.len().max(rhs.len());
    for index in 0..max_len {
        let left = *lhs.get(index).unwrap_or(&0);
        let right = *rhs.get(index).unwrap_or(&0);
        match left.cmp(&right) {
            std::cmp::Ordering::Equal => continue,
            ordering => return ordering,
        }
    }
    std::cmp::Ordering::Equal
}

fn select_artifact(
    architecture: &str,
    artifacts: &[UpdateArtifactInput],
) -> Result<UpdateArtifactInput, String> {
    let architecture_preference: &[&str] = match architecture {
        "arm64" => &["arm64", "universal"],
        "x86_64" => &["x86_64", "universal"],
        _ => &["universal", "arm64", "x86_64"],
    };
    let format_preference = ["dmg", "zip"];

    for format in format_preference {
        for preferred_architecture in architecture_preference {
            if let Some(artifact) = artifacts.iter().find(|artifact| {
                artifact.architecture == *preferred_architecture && artifact.format == format
            }) {
                return Ok(artifact.clone());
            }
        }
    }

    Err(format!("noCompatibleArtifact: {}", architecture))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn select_installable_github_release_skips_prerelease_and_missing_artifacts() {
        let result = select_installable_github_release(GitHubInstallableReleaseSelectionRequest {
            releases: vec![
                GitHubReleaseIndexEntryInput {
                    tag_name: "v1.2.1-beta.1".to_string(),
                    name: Some("v1.2.1 beta 1".to_string()),
                    body: Some("pre".to_string()),
                    html_url: "https://example.com/pre".to_string(),
                    draft: false,
                    prerelease: true,
                    published_at: Some(1_776_217_742.0),
                    assets: vec![GitHubReleaseAssetInput {
                        name: "codexbar-1.2.1-beta.1-macOS.dmg".to_string(),
                        browser_download_url: "https://example.com/pre.dmg".to_string(),
                        digest: None,
                    }],
                },
                GitHubReleaseIndexEntryInput {
                    tag_name: "v1.2.0".to_string(),
                    name: Some("v1.2.0".to_string()),
                    body: Some("stable but not installable".to_string()),
                    html_url: "https://example.com/stable".to_string(),
                    draft: false,
                    prerelease: false,
                    published_at: Some(1_776_217_682.0),
                    assets: vec![GitHubReleaseAssetInput {
                        name: "codexbar-1.2.0.pkg".to_string(),
                        browser_download_url: "https://example.com/ignored.pkg".to_string(),
                        digest: None,
                    }],
                },
                GitHubReleaseIndexEntryInput {
                    tag_name: "v1.1.9".to_string(),
                    name: Some("v1.1.9".to_string()),
                    body: Some("reissued stable".to_string()),
                    html_url: "https://example.com/v1.1.9".to_string(),
                    draft: false,
                    prerelease: false,
                    published_at: Some(1_776_217_622.0),
                    assets: vec![
                        GitHubReleaseAssetInput {
                            name: "codexbar-1.1.9-macOS.dmg".to_string(),
                            browser_download_url: "https://example.com/universal.dmg".to_string(),
                            digest: Some("sha256:abc123".to_string()),
                        },
                        GitHubReleaseAssetInput {
                            name: "codexbar-1.1.9-macOS-intel.zip".to_string(),
                            browser_download_url: "https://example.com/intel.zip".to_string(),
                            digest: Some("sha256:def456".to_string()),
                        },
                    ],
                },
            ],
        });

        let release = result.release.expect("release");
        assert_eq!(release.version, "1.1.9");
        assert_eq!(release.delivery_mode, "guidedDownload");
        assert_eq!(release.summary.as_deref(), Some("reissued stable"));
        assert_eq!(release.artifacts.len(), 2);
        assert_eq!(release.artifacts[0].architecture, "universal");
        assert_eq!(release.artifacts[0].format, "dmg");
        assert_eq!(release.artifacts[0].sha256.as_deref(), Some("abc123"));
        assert_eq!(release.artifacts[1].architecture, "x86_64");
        assert_eq!(release.artifacts[1].format, "zip");
        assert_eq!(release.artifacts[1].sha256.as_deref(), Some("def456"));
    }

    #[test]
    fn select_installable_github_release_returns_none_when_no_installable_stable_release_exists() {
        let result = select_installable_github_release(GitHubInstallableReleaseSelectionRequest {
            releases: vec![GitHubReleaseIndexEntryInput {
                tag_name: "v1.2.0".to_string(),
                name: Some("v1.2.0".to_string()),
                body: None,
                html_url: "https://example.com/v1.2.0".to_string(),
                draft: false,
                prerelease: false,
                published_at: None,
                assets: vec![GitHubReleaseAssetInput {
                    name: "codexbar-1.2.0.pkg".to_string(),
                    browser_download_url: "https://example.com/ignored.pkg".to_string(),
                    digest: None,
                }],
            }],
        });

        assert!(result.release.is_none());
    }

    #[test]
    fn select_installable_github_release_from_json_parses_release_index() {
        let result = select_installable_github_release_from_json(
            GitHubInstallableReleaseSelectionFromJsonRequest {
                json_text: r#"
                [
                  {
                    "tag_name": "v1.2.1-beta.1",
                    "name": "v1.2.1 beta 1",
                    "body": "pre",
                    "html_url": "https://example.com/pre",
                    "draft": false,
                    "prerelease": true,
                    "published_at": "2026-04-15T11:49:02Z",
                    "assets": [
                      {
                        "name": "codexbar-1.2.1-beta.1-macOS.dmg",
                        "browser_download_url": "https://example.com/pre.dmg"
                      }
                    ]
                  },
                  {
                    "tag_name": "v1.1.9",
                    "name": "v1.1.9",
                    "body": "reissued stable",
                    "html_url": "https://example.com/v1.1.9",
                    "draft": false,
                    "prerelease": false,
                    "published_at": "2026-04-15T11:47:02Z",
                    "assets": [
                      {
                        "name": "codexbar-1.1.9-macOS.dmg",
                        "browser_download_url": "https://example.com/universal.dmg",
                        "digest": "sha256:abc123"
                      }
                    ]
                  }
                ]
                "#
                .to_string(),
            },
        );

        let release = result.release.expect("release");
        assert_eq!(release.version, "1.1.9");
        assert_eq!(release.delivery_mode, "guidedDownload");
        assert_eq!(release.published_at, Some(1_776_253_622.0));
        assert_eq!(release.artifacts.len(), 1);
        assert_eq!(release.artifacts[0].sha256.as_deref(), Some("abc123"));
    }

    #[test]
    fn select_update_artifact_prefers_dmg_and_architecture_order() {
        let result = select_update_artifact(UpdateArtifactSelectionRequest {
            architecture: "arm64".to_string(),
            artifacts: vec![
                UpdateArtifactInput {
                    architecture: "universal".to_string(),
                    format: "dmg".to_string(),
                    download_url: "https://example.com/universal.dmg".to_string(),
                    sha256: None,
                },
                UpdateArtifactInput {
                    architecture: "arm64".to_string(),
                    format: "zip".to_string(),
                    download_url: "https://example.com/arm.zip".to_string(),
                    sha256: None,
                },
            ],
        })
        .expect("selection");

        assert_eq!(
            result.selected_artifact,
            Some(UpdateArtifactInput {
                architecture: "universal".to_string(),
                format: "dmg".to_string(),
                download_url: "https://example.com/universal.dmg".to_string(),
                sha256: None,
            })
        );
    }

    #[test]
    fn evaluate_update_blockers_matches_phase0_rules() {
        let result = evaluate_update_blockers(UpdateBlockerEvaluationRequest {
            release: UpdateReleaseInput {
                version: "1.1.7".to_string(),
                delivery_mode: "automatic".to_string(),
                minimum_automatic_update_version: Some("1.1.6".to_string()),
                artifacts: vec![],
            },
            environment: UpdateEnvironmentFacts {
                current_version: "1.1.5".to_string(),
                architecture: "arm64".to_string(),
                bundle_path: "/Applications/codexbar.app".to_string(),
                signature_usable: true,
                signature_summary: "Signature=Developer ID; TeamIdentifier=TEAMID".to_string(),
                gatekeeper_passes: false,
                gatekeeper_summary: "accepted | source=no usable signature".to_string(),
                automatic_updater_available: true,
            },
        })
        .expect("blockers");

        assert_eq!(
            result.blockers,
            vec![
                blocker(
                    "bootstrapRequired",
                    "current 1.1.5 is below automatic minimum 1.1.6"
                ),
                blocker(
                    "failingGatekeeperAssessment",
                    "accepted | source=no usable signature"
                ),
            ]
        );
    }

    #[test]
    fn select_update_artifact_prefers_dmg_then_zip_and_architecture_order() {
        let result = select_update_artifact(UpdateArtifactSelectionRequest {
            architecture: "arm64".to_string(),
            artifacts: vec![
                UpdateArtifactInput {
                    architecture: "universal".to_string(),
                    format: "dmg".to_string(),
                    download_url: "https://example.com/universal.dmg".to_string(),
                    sha256: None,
                },
                UpdateArtifactInput {
                    architecture: "arm64".to_string(),
                    format: "zip".to_string(),
                    download_url: "https://example.com/arm.zip".to_string(),
                    sha256: None,
                },
            ],
        })
        .expect("selection");

        assert_eq!(
            result.selected_artifact,
            Some(UpdateArtifactInput {
                architecture: "universal".to_string(),
                format: "dmg".to_string(),
                download_url: "https://example.com/universal.dmg".to_string(),
                sha256: None,
            })
        );
    }

    #[test]
    fn evaluate_update_blockers_reports_guided_download_and_signature_blockers() {
        let result = evaluate_update_blockers(UpdateBlockerEvaluationRequest {
            release: UpdateReleaseInput {
                version: "1.1.7".to_string(),
                delivery_mode: "guidedDownload".to_string(),
                minimum_automatic_update_version: Some("1.1.5".to_string()),
                artifacts: vec![],
            },
            environment: UpdateEnvironmentFacts {
                current_version: "1.1.5".to_string(),
                architecture: "arm64".to_string(),
                bundle_path: "/tmp/codexbar.app".to_string(),
                signature_usable: false,
                signature_summary: "Signature=adhoc".to_string(),
                gatekeeper_passes: true,
                gatekeeper_summary: "accepted".to_string(),
                automatic_updater_available: false,
            },
        })
        .expect("blockers");

        assert_eq!(
            result.blockers,
            vec![
                blocker(
                    "guidedDownloadOnlyRelease",
                    "release requires guided download"
                ),
                blocker(
                    "automaticUpdaterUnavailable",
                    "automatic updater is not available"
                ),
                blocker("missingTrustedSignature", "Signature=adhoc"),
                blocker("unsupportedInstallLocation", "other"),
            ]
        );
    }
}
