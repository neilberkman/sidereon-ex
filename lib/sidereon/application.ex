defmodule Sidereon.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    warn_on_libc_mismatch()

    children = [
      {Elixir.Finch, name: :"Elixir.Sidereon.GNSS.Data.Finch"},
      {Elixir.Finch, name: :"Elixir.Sidereon.GNSS.Ntrip.Finch", pools: %{default: [size: 1]}}
    ]

    opts = [strategy: :one_for_one, name: Sidereon.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # RustlerPrecompiled selects its artifact from the *build host's* target
  # triple, not from the artifact the user is ultimately producing. A glibc
  # build host packaging a musl output - an Alpine image, a self-extracting
  # release, Nerves firmware - resolves to the gnu triple, downloads that .so,
  # and packages it with no error at build time. The failure surfaces later, on
  # the target machine, as an opaque NIF load error that reads like a broken
  # library rather than a build-host libc mismatch.
  #
  # This cannot prevent the mismatch: by the time anything runs, the wrong
  # artifact is already packaged. It names the cause and the remedy at startup,
  # which is the difference between a one-line fix and an afternoon.
  defp warn_on_libc_mismatch do
    if not Code.ensure_loaded?(Sidereon.NIF) or
         not function_exported?(Sidereon.NIF, :sp3_epoch_count, 1) do
      require Logger

      Logger.error(Sidereon.NIF.__sidereon_load_diagnosis__())
    end
  rescue
    # Diagnosis is best-effort: never let it turn a working start into a
    # failure, and never mask the real load error behind an error in the code
    # that was supposed to explain it.
    _ -> :ok
  end
end
