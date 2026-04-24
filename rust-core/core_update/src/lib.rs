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

pub fn resolve_update_availability(
    request: UpdateResolutionRequest,
) -> Result<UpdateAvailabilityResult, String> {
    let current = parse_semver(&request.environment.current_version)
        .ok_or_else(|| format!("invalidCurrentVersion: {}", request.environment.current_version))?;
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
        blockers.push(blocker("guidedDownloadOnlyRelease", "release requires guided download"));
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

fn blocker(code: &str, detail: &str) -> UpdateBlockerResult {
    UpdateBlockerResult {
        code: code.to_string(),
        detail: detail.to_string(),
    }
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
