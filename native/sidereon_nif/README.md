# Sidereon native NIF

`Sidereon.NIF` loads this crate through `RustlerPrecompiled`. Packages that include
`checksum-Elixir.Sidereon.NIF.exs` use precompiled archives from GitHub Releases for
the supported targets, and those archives are verified against the checksum file.
If the checksum file is absent, Sidereon builds from source instead of attempting a
download. That keeps development and half-prepared releases source-buildable.

Set `SIDEREON_BUILD=1` to force a local source build with Rustler instead:

```bash
SIDEREON_BUILD=1 mix compile
```

The precompiled archive workflow is `.github/workflows/precompiled-nifs.yml`.
After tagging a release and waiting for the archives to attach to the GitHub
Release, generate the checksum file, commit it, and move the tag to the final
publish commit before publishing or replacing Hex:

```bash
mix rustler_precompiled.download Sidereon.NIF --all --print
mix hex.build --unpack
git tag -f vX.Y.Z
git push --force origin vX.Y.Z
```

The unpack check should include `checksum-Elixir.Sidereon.NIF.exs` and should not
include `native/sidereon_nif/target`.

Pushing a tag that already has release archives only runs the asset check and
skips the rebuild. To intentionally rebuild and replace archives, run the
workflow manually with `rebuild_existing_assets` enabled.
