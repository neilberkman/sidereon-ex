defmodule Sidereon.GNSS.PreciseEphemeris.PreciseInterpolantArtifact do
  @moduledoc """
  Canonical precise-interpolant artifact facade.

  This module delegates to `Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact`
  and preserves the capability name used by the Rust, Python, wasm, and C
  bindings.
  """

  alias Sidereon.GNSS.PreciseEphemeris.Interpolant
  alias Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact
  alias Sidereon.GNSS.PreciseEphemeris.StateBatch
  alias Sidereon.GNSS.SP3

  @type t :: InterpolantArtifact.t()
  @type source :: InterpolantArtifact.source()

  @doc "Build canonical artifact bytes from an SP3 product, an interpolant, or an opened artifact."
  @spec artifact_bytes(SP3.t() | Interpolant.t() | t()) :: {:ok, binary()} | {:error, term()}
  defdelegate artifact_bytes(source), to: InterpolantArtifact

  @doc "Open precise-interpolant artifact bytes."
  @spec open(binary()) :: {:ok, t()} | {:error, term()}
  defdelegate open(bytes), to: InterpolantArtifact

  @doc "Alias for `open/1`."
  @spec from_bytes(binary()) :: {:ok, t()} | {:error, term()}
  defdelegate from_bytes(bytes), to: InterpolantArtifact

  @doc "Read artifact bytes from disk and open them."
  @spec from_path(String.t()) :: {:ok, t()} | {:error, term()}
  defdelegate from_path(path), to: InterpolantArtifact

  @doc "Return the artifact checksum."
  @spec checksum(source()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate checksum(source), to: InterpolantArtifact

  @doc "Alias for `checksum/1`."
  @spec checksum64(source()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate checksum64(source), to: InterpolantArtifact

  @doc "Return the artifact bytes backing an opened handle."
  @spec as_bytes(t()) :: {:ok, binary()} | {:error, term()}
  defdelegate as_bytes(artifact), to: InterpolantArtifact

  @doc "Return the artifact byte length."
  @spec byte_len(t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate byte_len(artifact), to: InterpolantArtifact

  @doc "Return the source time-scale abbreviation."
  @spec time_scale(t()) :: String.t()
  defdelegate time_scale(artifact), to: InterpolantArtifact

  @doc "Return the satellite ids available in the artifact."
  @spec satellite_ids(t()) :: [String.t()]
  defdelegate satellite_ids(artifact), to: InterpolantArtifact

  @doc "Alias for `satellite_ids/1`."
  @spec satellites(t()) :: [String.t()]
  defdelegate satellites(artifact), to: InterpolantArtifact

  @doc "Evaluate states for parallel satellite and epoch arrays."
  @spec states_at_j2000_s(t(), [String.t()], [number()]) :: {:ok, StateBatch.t()} | {:error, term()}
  defdelegate states_at_j2000_s(artifact, satellites, epochs_j2000_s), to: InterpolantArtifact

  @doc "Evaluate states for many satellites at one shared J2000-second epoch."
  @spec states_at_shared_j2000_s(t(), [String.t()], number()) :: {:ok, StateBatch.t()} | {:error, term()}
  defdelegate states_at_shared_j2000_s(artifact, satellites, epoch_j2000_s), to: InterpolantArtifact

  @doc "Return the underlying interpolant handle."
  @spec to_interpolant(t()) :: Interpolant.t()
  defdelegate to_interpolant(artifact), to: InterpolantArtifact
end
