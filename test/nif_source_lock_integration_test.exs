defmodule Sidereon.NIFSourceLockIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :local_data
  @moduletag timeout: 900_000

  test "a packaged source build accepts its current lock and leaves it unchanged" do
    {package_root, build_root} = packaged_project()
    original_lock = File.read!(Path.join(package_root, "Cargo.lock"))

    {output, status} =
      compile_package(package_root, build_root, [
        {"SIDEREON_BUILD", "1"},
        {"RUSTLER_PRECOMPILED_FORCE_BUILD_ALL", "0"}
      ])

    assert status == 0, output
    assert File.read!(Path.join(package_root, "Cargo.lock")) == original_lock
  end

  test "force_build_all applies the locked preflight to a stale packaged lock" do
    {package_root, build_root} = packaged_project()
    lock_path = Path.join(package_root, "Cargo.lock")
    original_lock = File.read!(lock_path)

    override_path = Path.join(package_root, "native/sidereon_override")
    File.mkdir_p!(Path.dirname(override_path))
    {:ok, _copied} = File.cp_r(Path.join(package_root, "native/sidereon_nif"), override_path)

    override_lock_path = Path.join(override_path, "Cargo.lock")
    File.write!(override_lock_path, original_lock)
    original_override_lock = File.read!(override_lock_path)

    manifest_path = Path.join(override_path, "Cargo.toml")
    manifest = File.read!(manifest_path)
    assert manifest =~ ~s(nalgebra = "0.33")

    File.write!(
      manifest_path,
      String.replace(manifest, ~s(nalgebra = "0.33"), ~s(nalgebra = "0.34"), global: false) <>
        "\n[workspace]\n"
    )

    config_dir = Path.join(package_root, "config")
    File.mkdir_p!(config_dir)

    File.write!(
      Path.join(config_dir, "config.exs"),
      "import Config\nconfig :sidereon, Sidereon.NIF, path: \"native/sidereon_override\"\n"
    )

    # A matching-version marker keeps the package's ordinary local selector
    # false; the RustlerPrecompiled global override is the sole source-build
    # selector for this control.
    File.write!(
      Path.join(package_root, "checksum-Elixir.Sidereon.NIF.exs"),
      ~s(%{"fixture-v3.0.0-marker" => "sha256:00"}\n)
    )

    {output, status} =
      compile_package(package_root, build_root, [
        {"SIDEREON_BUILD", "0"},
        {"RUSTLER_PRECOMPILED_FORCE_BUILD_ALL", "1"}
      ])

    assert status != 0
    assert output =~ "Sidereon source NIF build requires a current Cargo.lock"
    assert output =~ "cargo metadata --locked"
    assert File.read!(lock_path) == original_lock
    assert File.read!(override_lock_path) == original_override_lock
  end

  test "a configured alternate path compiles its current lock graph" do
    {package_root, build_root} = packaged_project()
    lock_path = Path.join(package_root, "Cargo.lock")
    original_lock = File.read!(lock_path)

    override_path = Path.join(package_root, "native/sidereon_override")
    File.mkdir_p!(Path.dirname(override_path))
    {:ok, _copied} = File.cp_r(Path.join(package_root, "native/sidereon_nif"), override_path)

    override_lock_path = Path.join(override_path, "Cargo.lock")
    File.write!(override_lock_path, original_lock)
    original_override_lock = File.read!(override_lock_path)

    manifest_path = Path.join(override_path, "Cargo.toml")
    File.write!(manifest_path, File.read!(manifest_path) <> "\n[workspace]\n")

    config_dir = Path.join(package_root, "config")
    File.mkdir_p!(config_dir)

    File.write!(
      Path.join(config_dir, "config.exs"),
      "import Config\nconfig :sidereon, Sidereon.NIF, path: \"native/sidereon_override\"\n"
    )

    # Keep the package's ordinary selector false so the global Rustler override
    # is the only source-build selector for this alternate-graph control.
    File.write!(
      Path.join(package_root, "checksum-Elixir.Sidereon.NIF.exs"),
      ~s(%{"fixture-v3.0.0-marker" => "sha256:00"}\n)
    )

    {output, status} =
      compile_package(package_root, build_root, [
        {"SIDEREON_BUILD", "0"},
        {"RUSTLER_PRECOMPILED_FORCE_BUILD_ALL", "1"}
      ])

    assert status == 0, output

    assert output =~ "Compiling crate sidereon_nif in release mode (native/sidereon_override)",
           output

    refute output =~ "Compiling crate sidereon_nif in release mode (native/sidereon_nif)",
           output

    assert File.read!(lock_path) == original_lock
    assert File.read!(override_lock_path) == original_override_lock
  end

  test "source compilation without Cargo.lock fails before metadata can mutate it" do
    {package_root, build_root} = packaged_project()
    lock_path = Path.join(package_root, "Cargo.lock")
    File.rm!(lock_path)

    {output, status} =
      compile_package(package_root, build_root, [
        {"SIDEREON_BUILD", "1"},
        {"RUSTLER_PRECOMPILED_FORCE_BUILD_ALL", "0"}
      ])

    assert status != 0
    assert output =~ "Sidereon source NIF build requires the packaged"
    refute File.exists?(lock_path)
  end

  test "a current packaged checksum uses the actual precompiled macro without Cargo" do
    archive =
      System.get_env("SIDEREON_SOURCE_LOCK_PRECOMPILED_ARCHIVE") ||
        flunk("set SIDEREON_SOURCE_LOCK_PRECOMPILED_ARCHIVE to the reviewed local NIF archive")

    assert File.regular?(archive)
    {package_root, build_root} = packaged_project()
    cache_root = Path.join(package_root, ".precompiled-cache")
    File.mkdir_p!(cache_root)

    {:ok, target} = RustlerPrecompiled.target()
    [_nif_prefix, _nif_version, target_triple] = String.split(target, "-", parts: 3)
    extension = if String.contains?(target_triple, "windows"), do: "dll", else: "so"
    library_prefix = if extension == "dll", do: "", else: "lib"

    expected_name =
      "#{library_prefix}sidereon_nif-v3.0.0-nif-2.15-#{target_triple}.#{extension}.tar.gz"

    assert Path.basename(archive) == expected_name

    cached_archive = Path.join(cache_root, expected_name)
    File.cp!(archive, cached_archive)
    checksum = :crypto.hash(:sha256, File.read!(cached_archive)) |> Base.encode16(case: :lower)

    File.write!(
      Path.join(package_root, "checksum-Elixir.Sidereon.NIF.exs"),
      "%{#{inspect(expected_name)} => #{inspect("sha256:" <> checksum)}}\n"
    )

    trap_dir = Path.join(package_root, ".cargo-trap")
    File.mkdir_p!(trap_dir)
    marker = Path.join(package_root, ".cargo-was-called")
    trap = Path.join(trap_dir, "cargo")
    File.write!(trap, "#!/bin/sh\nprintf called > #{shell_quote(marker)}\nexit 97\n")
    File.chmod!(trap, 0o755)

    {output, status} =
      run_package(
        package_root,
        build_root,
        ["run", "--no-start", "-e", "Sidereon.NIF.__sidereon_system_libc__()"],
        [
          {"SIDEREON_BUILD", "0"},
          {"RUSTLER_PRECOMPILED_FORCE_BUILD_ALL", "0"},
          {"RUSTLER_PRECOMPILED_GLOBAL_CACHE_PATH", cache_root},
          {"PATH", trap_dir <> ":" <> System.get_env("PATH", "")}
        ]
      )

    assert status == 0, output
    refute File.exists?(marker), "the precompiled path invoked Cargo"
  end

  defp packaged_project do
    project_root = Path.expand("..", __DIR__)

    fixture_root =
      Path.join(System.tmp_dir!(), "sidereon-source-lock-#{System.unique_integer([:positive])}")

    File.mkdir_p!(fixture_root)

    # macOS exposes the temporary directory through /var, which resolves to
    # /private/var. Mix creates dependency priv links from its build path, so
    # keep the child cwd and absolute MIX_BUILD_PATH on the same physical path.
    {physical_fixture_root, 0} = System.cmd("/bin/pwd", ["-P"], cd: fixture_root)
    fixture_root = String.trim_trailing(physical_fixture_root, "\n")

    package_root = Path.join(fixture_root, "package")
    # Keep Mix's environment-specific build layout inside the packaged child
    # project so dependency priv links stay within this fixture root.
    build_root = Path.join(package_root, "_build/test")
    File.mkdir_p!(package_root)

    package_files = Mix.Project.config() |> Keyword.fetch!(:package) |> Keyword.fetch!(:files)

    package_files
    |> Enum.flat_map(fn pattern -> Path.wildcard(Path.join(project_root, pattern), match_dot: true) end)
    |> Enum.uniq()
    |> Enum.each(fn source ->
      relative = Path.relative_to(source, project_root)
      destination = Path.join(package_root, relative)
      File.mkdir_p!(Path.dirname(destination))
      {:ok, _copied} = File.cp_r(source, destination)
    end)

    # Mix consumers have their own lockfile. The project lock is test harness
    # input only; it is not part of the published package. Copy the fetched
    # source dependencies into the child so Mix creates dependency priv links
    # within the same temporary root instead of crossing a symlinked deps path.
    File.cp!(Path.join(project_root, "mix.lock"), Path.join(package_root, "mix.lock"))
    deps_root = Path.join(package_root, "deps")
    {:ok, _copied} = File.cp_r(Path.join(project_root, "deps"), deps_root)
    assert File.lstat!(deps_root).type == :directory
    assert File.lstat!(Path.join(deps_root, "rustler")).type == :directory
    assert File.regular?(Path.join(deps_root, "rustler/priv/templates/basic/README.md"))

    on_exit(fn -> File.rm_rf!(fixture_root) end)
    {package_root, build_root}
  end

  defp compile_package(package_root, build_root, overrides) do
    run_package(package_root, build_root, ["compile"], overrides)
  end

  defp run_package(package_root, build_root, args, overrides) do
    File.mkdir_p!(build_root)
    mix = System.find_executable("mix") || flunk("Mix executable is unavailable")

    env =
      [
        {"MIX_ENV", "test"},
        {"MIX_BUILD_PATH", build_root},
        {"SIDEREON_PORTABLE_NIF", "0"}
      ] ++ Enum.to_list(overrides)

    System.cmd(mix, args, cd: package_root, env: env, stderr_to_stdout: true)
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end
end
