defmodule Sidereon.NIF.SourceLock do
  @moduledoc false

  @lock_file "Cargo.lock"

  defmacro __using__(opts) do
    crate_path = Keyword.fetch!(opts, :crate_path)
    enabled = Keyword.fetch!(opts, :enabled)

    quote do
      if unquote(enabled) do
        @sidereon_source_lock_snapshot Sidereon.NIF.SourceLock.preflight!(unquote(crate_path))
        @before_compile Sidereon.NIF.SourceLock
      end
    end
  end

  def preflight!(crate_path) when is_binary(crate_path) do
    crate_path = Path.expand(crate_path)

    workspace_manifest =
      case System.cmd(
             "cargo",
             ["locate-project", "--workspace", "--message-format", "plain"],
             cd: crate_path,
             stderr_to_stdout: true
           ) do
        {manifest, 0} ->
          case String.split(String.trim(manifest), "\n", trim: true) do
            [manifest_path] ->
              Path.expand(manifest_path, crate_path)

            _ ->
              raise "Sidereon source NIF build received an invalid Cargo workspace path: " <>
                      inspect(manifest)
          end

        {output, status} ->
          raise "Sidereon source NIF build cannot locate the Cargo workspace " <>
                  "(status #{status}):\n#{output}"
      end

    lock_path = Path.join(Path.dirname(workspace_manifest), @lock_file)

    lock_before =
      case File.read(lock_path) do
        {:ok, bytes} when byte_size(bytes) > 0 ->
          bytes

        {:ok, _empty} ->
          raise "Sidereon source NIF build requires a non-empty #{lock_path}"

        {:error, :enoent} ->
          raise "Sidereon source NIF build requires the packaged #{lock_path} before compilation"

        {:error, reason} ->
          raise "Sidereon source NIF build cannot read #{lock_path}: #{inspect(reason)}"
      end

    case System.cmd(
           "cargo",
           ["metadata", "--locked", "--format-version", "1"],
           cd: crate_path,
           stderr_to_stdout: true
         ) do
      {_metadata, 0} ->
        assert_unchanged!(lock_path, lock_before, "locked metadata preflight")
        {lock_path, lock_before}

      {output, status} ->
        raise "Sidereon source NIF build requires a current Cargo.lock; " <>
                "`cargo metadata --locked` failed with status #{status}:\n#{output}"
    end
  end

  def assert_unchanged!(lock_path, expected_bytes, stage) do
    case File.read(lock_path) do
      {:ok, ^expected_bytes} ->
        :ok

      {:ok, _changed_bytes} ->
        raise "Sidereon Cargo.lock changed during #{stage}: #{lock_path}"

      {:error, reason} ->
        raise "Sidereon Cargo.lock became unavailable during #{stage}: " <>
                "#{lock_path} (#{inspect(reason)})"
    end
  end

  defmacro __before_compile__(env) do
    case Module.get_attribute(env.module, :sidereon_source_lock_snapshot) do
      {lock_path, expected_bytes} ->
        assert_unchanged!(lock_path, expected_bytes, "Rustler source compilation")

      nil ->
        :ok
    end

    quote do
    end
  end
end
