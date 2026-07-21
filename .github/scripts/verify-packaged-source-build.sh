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

for notice in \
  LICENSE \
  LICENSES/Apache-2.0.txt \
  LICENSES/ERFA-BSD-3-Clause.txt \
  LICENSES/IERS-Conventions-Software-License.txt \
  LICENSES/ISC-libloading.txt \
  LICENSES/SciPy-BSD-3-Clause.txt \
  THIRD-PARTY-NOTICES.md \
  third_party_source/sidereon-core-0.33.1/tides/mod.rs \
  third_party_source/sidereon-core-0.33.1/tides/ocean.rs \
  third_party_source/sidereon-core-0.33.1/tides/pole.rs; do
  if [[ ! -s "$package_root/$notice" ]]; then
    echo "packaged source is missing required license material: $notice" >&2
    exit 1
  fi
done

grep -Fq 'approx 0.5.1' "$package_root/THIRD-PARTY-NOTICES.md"
grep -Fq 'nalgebra 0.33.3' "$package_root/THIRD-PARTY-NOTICES.md"
grep -Fq 'nalgebra-macros 0.2.2' "$package_root/THIRD-PARTY-NOTICES.md"
grep -Fq 'simba 0.9.1' "$package_root/THIRD-PARTY-NOTICES.md"
grep -Fq 'libloading 0.8.9 and 0.9.0' "$package_root/THIRD-PARTY-NOTICES.md"
grep -Fq 'Copyright (C) 2013-2021, NumFOCUS Foundation.' \
  "$package_root/LICENSES/ERFA-BSD-3-Clause.txt"
grep -Fq 'IERS Conventions Software License' "$package_root/LICENSES/IERS-Conventions-Software-License.txt"
grep -Fq 'Copyright (c) 2001-2002 Enthought, Inc. 2003, SciPy Developers.' \
  "$package_root/LICENSES/SciPy-BSD-3-Clause.txt"

check_sha256() {
  local expected="$1"
  local path="$2"
  local actual
  actual="$(sha256sum "$path" | cut -d ' ' -f 1)"
  if [[ "$actual" != "$expected" ]]; then
    echo "packaged third-party source digest mismatch: $path" >&2
    exit 1
  fi
}

check_sha256 b1858f9a263f22c438a455a32945da51a31a0ae25a21055da13bb7ed57cc3b51 \
  "$package_root/LICENSES/ERFA-BSD-3-Clause.txt"
check_sha256 a441d8ffe8151ddd5f1e0a9f82ce88ed54bd2f55e83fee6a519e50b006a8cba2 \
  "$package_root/LICENSES/IERS-Conventions-Software-License.txt"
check_sha256 221e59f5e910fd7f94e44f0dac77436a11338c285c6346232e4a850a50da0e94 \
  "$package_root/LICENSES/SciPy-BSD-3-Clause.txt"

# Exact public sidereon-core v0.33.1 sources.
check_sha256 7c71cb8facbd81af8473d3634e4c63d97dda8cb37a2f59888d3397cfdde4d39b \
  "$package_root/third_party_source/sidereon-core-0.33.1/tides/mod.rs"
check_sha256 6bd72d6647b634f979b670040d8c0b659e1f581fa41fdeec41b74b85d8c26c01 \
  "$package_root/third_party_source/sidereon-core-0.33.1/tides/ocean.rs"
check_sha256 b4cc4c16bdd8ce1d8f04073602ab47dfb85a002b946ab192e8d4d2d600f0a1f8 \
  "$package_root/third_party_source/sidereon-core-0.33.1/tides/pole.rs"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential ca-certificates curl git
rustup_init=/tmp/rustup-init
case "$(uname -m)" in
  x86_64 | amd64)
    rustup_target=x86_64-unknown-linux-gnu
    rustup_sha256=4acc9acc76d5079515b46346a485974457b5a79893cfb01112423c89aeb5aa10
    ;;
  aarch64 | arm64)
    rustup_target=aarch64-unknown-linux-gnu
    rustup_sha256=9732d6c5e2a098d3521fca8145d826ae0aaa067ef2385ead08e6feac88fa5792
    ;;
  *)
    echo "unsupported source-build architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
curl --proto '=https' --tlsv1.2 -sSf \
  "https://static.rust-lang.org/rustup/archive/1.29.0/${rustup_target}/rustup-init" \
  -o "$rustup_init"
echo "${rustup_sha256}  ${rustup_init}" | sha256sum -c -
chmod +x "$rustup_init"
"$rustup_init" -y --profile minimal --default-toolchain 1.92.0
export PATH="/root/.cargo/bin:$PATH"
rustc --version | grep -Fq 'rustc 1.92.0 '

cargo metadata --locked --format-version 1 --manifest-path "$package_root/Cargo.toml" >/dev/null

mix local.hex 2.5.1 --force
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
