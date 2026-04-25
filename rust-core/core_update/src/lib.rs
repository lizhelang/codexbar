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
    pub install_location: String,
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

    let mut blockers = Vec::new();
    if request.release.delivery_mode == "guidedDownload" {
        blockers.push(blocker(
            "guidedDownloadOnlyRelease",
            "release requires guided download",
        ));
    }
    if let Some(minimum_version) = request.release.minimum_automatic_update_version.as_ref() {
        let minimum = parse_semver(minimum_version)
            .ok_or_else(|| format!("invalidMinimumAutomaticVersion: {}", minimum_version))?;
        if current < minimum {
            blockers.push(blocker(
                "bootstrapRequired",
                &format!(
                    "current {} is below automatic minimum {}",
                    request.environment.current_version, minimum_version
                ),
            ));
        }
    }
    if request.environment.automatic_updater_available == false {
        blockers.push(blocker(
            "automaticUpdaterUnavailable",
            "automatic updater is not available",
        ));
    }
    if request.environment.signature_usable == false {
        blockers.push(blocker(
            "missingTrustedSignature",
            &request.environment.signature_summary,
        ));
    }
    if request.environment.gatekeeper_passes == false {
        blockers.push(blocker(
            "failingGatekeeperAssessment",
            &request.environment.gatekeeper_summary,
        ));
    }
    if request.environment.install_location == "other" {
        blockers.push(blocker(
            "unsupportedInstallLocation",
            &request.environment.install_location,
        ));
    }

    Ok(UpdateAvailabilityResult {
        update_available: true,
        selected_artifact: Some(selected_artifact),
        blockers,
    })
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

fn blocker(code: &str, detail: &str) -> UpdateBlockerResult {
    UpdateBlockerResult {
        code: code.to_string(),
        detail: detail.to_string(),
    }
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
}
