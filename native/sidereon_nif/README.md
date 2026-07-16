# Sidereon native NIF

`Sidereon.NIF` loads this crate through `RustlerPrecompiled`. Packages that include
`checksum-Elixir.Sidereon.NIF.exs` use precompiled archives from GitHub Releases for
the supported targets, and those archives are verified against the checksum file.
If the checksum file is absent, Sidereon builds from source instead of attempting a
download. That keeps development and half-prepared releases source-buildable.

To force a local source build, the consuming application must activate
Sidereon's optional Rustler dependency:

```elixir
def deps do
  [
    {:sidereon, "~> 0.31"},
    {:rustler, ">= 0.0.0", optional: true}
  ]
end
```

Then compile with a Rust toolchain installed:

```bash
SIDEREON_BUILD=1 mix compile
```

The precompiled archive workflow is `.github/workflows/precompiled-nifs.yml`.
The release order is strict:

1. Commit the version and registry dependency updates, then create and push the
   version tag. The tag must exist before the workflow can build its archives.
2. Wait for all release archives to attach to the GitHub Release.
3. Generate and inspect the checksum-backed Hex package, then commit the
   regenerated checksum file.
4. Push the checksum commit, force-move the version tag to that commit, and
   wait for the tag workflow's asset check to confirm that the existing
   archives are retained.
5. Publish Hex only after the packaged checksum file and the final tag agree.

```bash
git tag vX.Y.Z
git push origin vX.Y.Z

# Wait for the tagged precompiled-NIF workflow to attach every archive.
mix rustler_precompiled.download Sidereon.NIF --all --print
mix hex.build --unpack
git add checksum-Elixir.Sidereon.NIF.exs
git commit -m "release: regenerate NIF checksums for X.Y.Z precompiled artifacts"
git push origin HEAD:main

git tag -f vX.Y.Z
git push --force origin vX.Y.Z

# Wait for the tag workflow's asset check, then publish.
mix hex.publish
```

The unpack check should include `checksum-Elixir.Sidereon.NIF.exs` and should not
include `native/sidereon_nif/target`.

Pushing a tag that already has release archives only runs the asset check and
skips the rebuild. To intentionally rebuild and replace archives, run the
workflow manually with `rebuild_existing_assets` enabled.
