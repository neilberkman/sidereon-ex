#!/usr/bin/env bash
set -euo pipefail

package_meta=/tmp/sidereon-package-meta
package_root=/tmp/sidereon-package
probe_root=/tmp/sidereon_source_probe
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

  if [[ "$candidate_mode" == "true" ]]; then
    if [[ "$pin" =~ path[[:space:]]*= || "$pin" =~ branch[[:space:]]*= || "$pin" =~ tag[[:space:]]*= ]]; then
      echo "candidate NIF dependency must not use a path, branch, or tag: $pin" >&2
      exit 1
    fi
    if [[ "$pin" =~ git[[:space:]]*= ]]; then
      if [[ ! "$pin" =~ git[[:space:]]*=[[:space:]]*\"https://github\.com/neilberkman/sidereon\" ]] || \
        [[ ! "$pin" =~ rev[[:space:]]*=[[:space:]]*\"[0-9a-f]{40}\" ]]; then
        echo "candidate NIF dependencies must use the canonical Git URL and a full revision: $pin" >&2
        exit 1
      fi
    elif [[ ! "$pin" =~ \"=[0-9]+\.[0-9]+\.[0-9]+\" ]]; then
      echo "candidate dependencies must use exact registry versions or the canonical full-revision Git source: $pin" >&2
      exit 1
    fi
  else
    if [[ "$pin" =~ path[[:space:]]*= || "$pin" =~ git[[:space:]]*= ]]; then
      echo "packaged NIF must not depend on ${dependency} by path or git: $pin" >&2
      exit 1
    fi

    if [[ ! "$pin" =~ \"=[0-9]+\.[0-9]+\.[0-9]+\" ]]; then
      echo "packaged NIF must use an exact registry pin: ${dependency} = \"=X.Y.Z\"" >&2
      echo "found: $pin" >&2
      exit 1
    fi
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
  third_party_source/sidereon-core-3.0.0/tides/mod.rs \
  third_party_source/sidereon-core-3.0.0/tides/ocean.rs \
  third_party_source/sidereon-core-3.0.0/tides/pole.rs; do
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

# Exact public sidereon-core v3.0.0 sources.
check_sha256 0703d1b3470f59528880ae34990f064897d34876d5ff30b4fc860afdcadf7433 \
  "$package_root/third_party_source/sidereon-core-3.0.0/tides/mod.rs"
check_sha256 25946677944425671a92717860ac2d70f255de5403eeb1fbf98b361716821d5c \
  "$package_root/third_party_source/sidereon-core-3.0.0/tides/ocean.rs"
check_sha256 b4cc4c16bdd8ce1d8f04073602ab47dfb85a002b946ab192e8d4d2d600f0a1f8 \
  "$package_root/third_party_source/sidereon-core-3.0.0/tides/pole.rs"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends build-essential ca-certificates curl git python3
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
"$rustup_init" -y --profile minimal --default-toolchain 1.98.1
export PATH="/root/.cargo/bin:$PATH"
rustc --version | grep -Fq 'rustc 1.98.1 '

cargo metadata --locked --format-version 1 --manifest-path "$package_root/Cargo.toml" \
  > /tmp/sidereon-cargo-metadata.json

mapfile -t project_versions < <(
  sed -nE 's/^[[:space:]]*@version[[:space:]]+"([0-9]+\.[0-9]+\.[0-9]+)"[[:space:]]*$/\1/p' \
    "$package_root/mix.exs"
)
if [[ "${#project_versions[@]}" -ne 1 ]]; then
  echo "packaged tarball must state exactly one semantic project version" >&2
  exit 1
fi
SIDEREON_PROJECT_VERSION="${project_versions[0]}" \
SIDEREON_CANDIDATE_MODE="$candidate_mode" python3 - \
  /tmp/sidereon-cargo-metadata.json "$package_root/native/sidereon_nif/Cargo.toml" <<'PY'
import json
import os
import re
import sys

metadata_path, manifest_path = sys.argv[1:]
project_version = os.environ["SIDEREON_PROJECT_VERSION"]
candidate_mode = os.environ["SIDEREON_CANDIDATE_MODE"] == "true"
with open(metadata_path, encoding="utf-8") as metadata_file:
    metadata = json.load(metadata_file)

packages_by_id = {package["id"]: package for package in metadata["packages"]}
root_packages = [
    package
    for package in metadata["packages"]
    if package["name"] == "sidereon_nif" and package["manifest_path"] == manifest_path
]
if len(root_packages) != 1:
    raise SystemExit("metadata must contain exactly one packaged NIF root")
root_package = root_packages[0]
root_node = next(
    (node for node in metadata["resolve"]["nodes"] if node["id"] == root_package["id"]),
    None,
)
if root_node is None:
    raise SystemExit("metadata omitted the packaged NIF dependency node")

direct_packages = {"sidereon": [], "sidereon-core": []}
for dependency in root_node["deps"]:
    package = packages_by_id[dependency["pkg"]]
    package_name = package["name"]
    if package_name not in direct_packages:
        continue
    expected_alias = package_name.replace("-", "_")
    if dependency["name"] != expected_alias:
        raise SystemExit(f"unexpected dependency alias for {package_name}")
    direct_packages[package_name].append(package)

if any(len(packages) != 1 for packages in direct_packages.values()):
    raise SystemExit("package must resolve exactly one facade and core dependency")

resolved_packages = [packages[0] for packages in direct_packages.values()]
for package_name, packages in direct_packages.items():
    package = packages[0]
    if package["version"] != project_version:
        raise SystemExit(
            f"{package_name} version {package['version']} does not match "
            f"project version {project_version}"
        )

registry_source = "registry+https://github.com/rust-lang/crates.io-index"
if not all(package["source"] == registry_source for package in resolved_packages):
    if not candidate_mode:
        raise SystemExit("strict packaged-source validation requires registry dependencies")

    canonical_source = re.compile(
        r"^git\+https://github\.com/neilberkman/sidereon"
        r"\?rev=([0-9a-f]{40})#([0-9a-f]{40})$"
    )
    resolved_sources = []
    for package_name in ("sidereon", "sidereon-core"):
        package = direct_packages[package_name][0]
        match = canonical_source.fullmatch(package["source"] or "")
        if match is None or match.group(1) != match.group(2):
            raise SystemExit(
                f"{package_name} must resolve from the canonical URL "
                "at its full 40-character revision"
            )
        resolved_sources.append((package["source"], match.group(2)))

    if resolved_sources[0] != resolved_sources[1]:
        raise SystemExit("facade and core must resolve from the same Git revision")
PY

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
