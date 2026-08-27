#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

if (($# != 2)); then
  printf 'usage: build-package.sh <package-directory> <artifact-directory>\n' >&2
  exit 2
fi

package_path="$1"
artifact_path="$2"
repo_root="$(git rev-parse --show-toplevel)"

[[ "$package_path" =~ ^[A-Za-z0-9@._+-]+$ ]] || die "unsafe package directory: $package_path"
[[ -f "$repo_root/$package_path/PKGBUILD" ]] || die "missing PKGBUILD: $package_path"

package_dir="$(realpath "$repo_root/$package_path")"
artifact_dir="$(realpath -m "$artifact_path")"
[[ "$package_dir" == "$repo_root/"* ]] || die 'package directory escaped the repository'

install -d "$artifact_dir"
find "$artifact_dir" -maxdepth 1 -type f \
  \( -name '*.pkg.tar.*' -o -name 'manifest-*.json' \) -delete

cd "$package_dir"

export PKGDEST="$artifact_dir"
makepkg --syncdeps --noconfirm --cleanbuild

mapfile -t expected_files < <(
  while IFS= read -r package_file; do
    basename "$package_file"
  done < <(makepkg --packagelist) | LC_ALL=C sort -u
)
((${#expected_files[@]} > 0)) || die 'makepkg did not declare any package outputs'

mapfile -t actual_files < <(
  find "$artifact_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' -printf '%f\n' |
    LC_ALL=C sort -u
)

((${#actual_files[@]} > 0)) || die 'makepkg produced no package archives'

if [[ "$(printf '%s\n' "${expected_files[@]}")" != "$(printf '%s\n' "${actual_files[@]}")" ]]; then
  {
    printf 'error: package outputs did not match makepkg --packagelist\n'
    printf 'expected:\n'
    printf '  %s\n' "${expected_files[@]}"
    printf 'actual:\n'
    printf '  %s\n' "${actual_files[@]}"
  } >&2
  exit 1
fi

packages_jsonl="$(mktemp)"
sources_jsonl="$(mktemp)"
trap 'rm -f "$packages_jsonl" "$sources_jsonl"' EXIT

for filename in "${actual_files[@]}"; do
  package_file="$artifact_dir/$filename"
  pkginfo="$(bsdtar -xOf "$package_file" .PKGINFO)"
  pkgname="$(awk -F ' = ' '$1 == "pkgname" {print $2; exit}' <<<"$pkginfo")"
  pkgver="$(awk -F ' = ' '$1 == "pkgver" {print $2; exit}' <<<"$pkginfo")"
  arch="$(awk -F ' = ' '$1 == "arch" {print $2; exit}' <<<"$pkginfo")"

  [[ -n "$pkgname" && -n "$pkgver" && -n "$arch" ]] || die "incomplete .PKGINFO in $filename"
  [[ "$arch" == "any" || "$arch" == "x86_64" ]] || die "unsupported architecture $arch in $filename"

  jq -cn \
    --arg filename "$filename" \
    --arg pkgname "$pkgname" \
    --arg pkgver "$pkgver" \
    --arg arch "$arch" \
    --arg sha256 "$(sha256sum "$package_file" | cut -d' ' -f1)" \
    --argjson size "$(stat -c %s "$package_file")" \
    '{
      filename: $filename,
      pkgname: $pkgname,
      pkgver: $pkgver,
      arch: $arch,
      size: $size,
      sha256: $sha256
    }' >>"$packages_jsonl"
done

if [[ -d "$package_dir/src" ]]; then
  while IFS= read -r -d '' git_dir; do
    source_dir="${git_dir%/.git}"
    jq -cn \
      --arg path "${source_dir#"$package_dir/"}" \
      --arg commit "$(git -C "$source_dir" rev-parse HEAD)" \
      '{path: $path, commit: $commit}' >>"$sources_jsonl"
  done < <(find "$package_dir/src" -type d -name .git -print0)
fi

manifest="$artifact_dir/manifest-$package_path.json"
jq -n \
  --arg package_base "$package_path" \
  --arg source_repository "${POND_SOURCE_REPOSITORY:-}" \
  --arg source_sha "${POND_SOURCE_SHA:-}" \
  --arg upstream_repository "${POND_UPSTREAM_REPOSITORY:-}" \
  --arg upstream_sha "${POND_UPSTREAM_SHA:-}" \
  --arg workflow "${GITHUB_WORKFLOW_REF:-}" \
  --arg run_id "${GITHUB_RUN_ID:-}" \
  --arg event "${GITHUB_EVENT_NAME:-}" \
  --slurpfile packages "$packages_jsonl" \
  --slurpfile resolved_git_sources "$sources_jsonl" \
  '{
    schema: 1,
    package_base: $package_base,
    source: {
      repository: $source_repository,
      sha: $source_sha,
      upstream_repository: $upstream_repository,
      upstream_sha: $upstream_sha
    },
    workflow: {
      identity: $workflow,
      run_id: $run_id,
      event: $event
    },
    packages: $packages,
    resolved_git_sources: $resolved_git_sources
  }' >"$manifest"

jq -e '.packages | length > 0' "$manifest" >/dev/null
printf 'Built and validated %s (%s output file(s)).\n' "$package_path" "${#actual_files[@]}"
