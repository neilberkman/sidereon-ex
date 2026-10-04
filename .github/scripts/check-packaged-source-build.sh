#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
candidate_mode="${SIDEREON_CANDIDATE_MODE:-false}"
case "$candidate_mode" in
  true)
    if [[ "${GITHUB_REF:-}" == refs/tags/* ]]; then
      echo "candidate validation is disabled for tag refs" >&2
      exit 1
    fi
    ;;
  false) ;;
  *)
    echo "SIDEREON_CANDIDATE_MODE must be true or false" >&2
    exit 1
    ;;
esac
work_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/sidereon-packaged-source.XXXXXX")"
package_tar="$work_root/sidereon.tar"
container_script="$repo_root/.github/scripts/verify-packaged-source-build.sh"
image="${SIDEREON_SOURCE_BUILD_IMAGE:-hexpm/elixir:1.19.4-erlang-28.3-debian-bookworm-20260518-slim@sha256:c5dbd63aca7a1c0e32be9466f145ecfe461815ee880b36905c7f9ac862d2a7c0}"

(
  cd "$repo_root"
  mix hex.build --output "$package_tar"
)

docker run --rm \
  --env SIDEREON_BUILD=1 \
  --env SIDEREON_CANDIDATE_MODE="$candidate_mode" \
  --env GITHUB_REF="${GITHUB_REF:-}" \
  --volume "$package_tar:/work/sidereon.tar:ro" \
  --volume "$container_script:/work/verify-packaged-source-build.sh:ro" \
  "$image" \
  bash /work/verify-packaged-source-build.sh
