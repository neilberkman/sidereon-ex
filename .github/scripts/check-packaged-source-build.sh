#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work_root="$(mktemp -d "${RUNNER_TEMP:-/tmp}/sidereon-packaged-source.XXXXXX")"
package_tar="$work_root/sidereon.tar"
container_script="$repo_root/.github/scripts/verify-packaged-source-build.sh"
image="${SIDEREON_SOURCE_BUILD_IMAGE:-hexpm/elixir:1.19.4-erlang-28.3-debian-bookworm-20260518-slim}"

(
  cd "$repo_root"
  mix hex.build --output "$package_tar"
)

docker run --rm \
  --env SIDEREON_BUILD=1 \
  --volume "$package_tar:/work/sidereon.tar:ro" \
  --volume "$container_script:/work/verify-packaged-source-build.sh:ro" \
  "$image" \
  bash /work/verify-packaged-source-build.sh
