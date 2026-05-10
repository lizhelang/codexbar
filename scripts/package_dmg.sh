#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE' >&2
Usage:
  scripts/package_dmg.sh --app /path/to/codexbar.app --version 1.2.2 [--output /path/to/file.dmg]

Creates a release DMG containing:
  - codexbar.app
  - Applications -> /Applications
USAGE
}

app_path=""
version=""
output_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      app_path="${2:-}"
      shift 2
      ;;
    --version)
      version="${2:-}"
      shift 2
      ;;
    --output)
      output_path="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${app_path}" || -z "${version}" ]]; then
  usage
  exit 2
fi

if [[ ! -d "${app_path}" ]]; then
  echo "App bundle not found: ${app_path}" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -z "${output_path}" ]]; then
  output_path="${repo_root}/dist/${version}/codexbar-${version}-macOS.dmg"
fi

if [[ "${output_path}" != *.dmg ]]; then
  echo "Output path must end with .dmg: ${output_path}" >&2
  exit 2
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/codexbar-dmg.XXXXXX")"
cleanup() {
  rm -rf "${staging_dir}"
}
trap cleanup EXIT

mkdir -p "$(dirname "${output_path}")"

ditto "${app_path}" "${staging_dir}/codexbar.app"
ln -s /Applications "${staging_dir}/Applications"

hdiutil create \
  -volname "codexbar ${version}" \
  -srcfolder "${staging_dir}" \
  -ov \
  -format UDZO \
  "${output_path}"

hdiutil verify "${output_path}"
