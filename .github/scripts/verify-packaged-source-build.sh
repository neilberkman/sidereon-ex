#!/usr/bin/env bash
set -euo pipefail

package_meta=/tmp/sidereon-package-meta
package_root=/tmp/sidereon-package
probe_root=/tmp/sidereon_source_probe

rm -rf "$package_meta" "$package_root" "$probe_root"
mkdir -p "$package_meta" "$package_root"
tar -xf /work/sidereon.tar -C "$package_meta"
tar -xzf "$package_meta/contents.tar.gz" -C "$package_root"

for dependency in sidereon-core sidereon; do
  mapfile -t pin_lines < <(
    sed -n "/^[[:space:]]*${dependency}[[:space:]]*=/p" \
      "$package_root/native/sidereon_nif/Cargo.toml"
  )

  if [[ "${#pin_lines[@]}" -ne 1 ]]; then
    echo "packaged NIF manifest must contain exactly one ${dependency} dependency" >&2
    exit 1
  fi

  pin="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"${pin_lines[0]}")"
  if [[ ! "$pin" =~ ^${dependency}[[:space:]]*=[[:space:]]*\"=[0-9]+\.[0-9]+\.[0-9]+\"$ ]]; then
    echo "packaged NIF must use an exact registry-only pin: ${dependency} = \"=X.Y.Z\"" >&2
    echo "found: $pin" >&2
    exit 1
  fi
done

if [[ ! -f "$package_root/Cargo.toml" || ! -f "$package_root/Cargo.lock" ]]; then
  echo "packaged source must include the Cargo workspace manifest and lockfile" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential ca-certificates curl git
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
  | sh -s -- -y --profile minimal
export PATH="/root/.cargo/bin:$PATH"

cargo metadata --locked --format-version 1 --manifest-path "$package_root/Cargo.toml" >/dev/null

mix local.hex --force
mix local.rebar --force
mix new "$probe_root" --sup
sed -i \
  '/defp deps do/{n;s/\[/[{:sidereon, path: "\/tmp\/sidereon-package"}, {:rustler, ">= 0.0.0", optional: true},/;}' \
  "$probe_root/mix.exs"
grep -Fq '{:sidereon, path: "/tmp/sidereon-package"}' "$probe_root/mix.exs"
grep -Fq '{:rustler, ">= 0.0.0", optional: true}' "$probe_root/mix.exs"

cd "$probe_root"
SIDEREON_BUILD=1 mix deps.get
SIDEREON_BUILD=1 mix deps.compile
