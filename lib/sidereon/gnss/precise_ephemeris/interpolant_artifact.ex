defmodule Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact do
  @moduledoc """
  Opened precise-ephemeris interpolant artifact.

  Artifact bytes are produced by the core precise-interpolant store writer and
  can be reopened without reparsing the original SP3 product. This module gives
  that artifact path a named public struct while delegating all native work to
  `Sidereon.GNSS.PreciseEphemeris.Interpolant`.
  """

  alias Sidereon.GNSS.PreciseEphemeris.Interpolant
  alias Sidereon.GNSS.PreciseEphemeris.StateBatch
  alias Sidereon.GNSS.SP3

  @enforce_keys [:interpolant]
  defstruct [:interpolant]

  @type source :: SP3.t() | Interpolant.t() | t() | binary()

  @type digest_provenance :: Interpolant.digest_provenance()

  @typedoc "Opened precise-interpolant artifact handle."
  @type t :: %__MODULE__{interpolant: Interpolant.t()}

  @doc """
  Build canonical artifact bytes from an SP3 product, an interpolant, or an opened artifact.
  """
  @spec artifact_bytes(SP3.t() | Interpolant.t() | t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def artifact_bytes(source, opts \\ [])
  def artifact_bytes(%__MODULE__{interpolant: interpolant}, []), do: Interpolant.as_bytes(interpolant)
  def artifact_bytes(%__MODULE__{interpolant: interpolant}, opts), do: Interpolant.artifact_bytes(interpolant, opts)
  def artifact_bytes(source, opts), do: Interpolant.artifact_bytes(source, opts)

  @doc """
  Open precise-interpolant artifact bytes into a named artifact handle.
  """
  @spec open(binary()) :: {:ok, t()} | {:error, term()}
  def open(bytes) when is_binary(bytes) do
    with {:ok, interpolant} <- Interpolant.open(bytes) do
      {:ok, %__MODULE__{interpolant: interpolant}}
    end
  end

  @doc """
  Alias for `open/1`.
  """
  @spec from_bytes(binary()) :: {:ok, t()} | {:error, term()}
  def from_bytes(bytes), do: open(bytes)

  @doc """
  Read artifact bytes from disk and open them.
  """
  @spec from_path(String.t()) :: {:ok, t()} | {:error, term()}
  def from_path(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path) do
      open(bytes)
    end
  end

  @doc """
  Open an artifact using a caller-attested checksum.

  The claim must equal the checksum declared by the header. Payload hashes are
  deferred until `verify/1` is called.
  """
  @spec from_path_attested(String.t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def from_path_attested(path, claimed_checksum64) when is_binary(path) do
    with {:ok, interpolant} <- Interpolant.from_path_attested(path, claimed_checksum64) do
      {:ok, %__MODULE__{interpolant: interpolant}}
    end
  end

  @doc """
  Return the artifact checksum for bytes, an interpolant, or an opened artifact.
  """
  @spec checksum(source()) :: {:ok, non_neg_integer()} | {:error, term()}
  def checksum(%__MODULE__{interpolant: interpolant}), do: Interpolant.checksum(interpolant)
  def checksum(source), do: Interpolant.checksum(source)

  @doc """
  Alias for `checksum/1`.
  """
  @spec checksum64(source()) :: {:ok, non_neg_integer()} | {:error, term()}
  def checksum64(source), do: checksum(source)

  @doc """
  Return who computed the checksum carried by this artifact handle.
  """
  @spec digest_provenance(t()) :: digest_provenance()
  def digest_provenance(%__MODULE__{interpolant: interpolant}) do
    Interpolant.digest_provenance(interpolant)
  end

  @doc """
  Verify the file-level and per-satellite payload checksums.
  """
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{interpolant: interpolant}), do: Interpolant.verify(interpolant)

  @doc """
  Return the artifact bytes backing this opened handle.
  """
  @spec as_bytes(t()) :: {:ok, binary()} | {:error, term()}
  def as_bytes(%__MODULE__{interpolant: interpolant}), do: Interpolant.as_bytes(interpolant)

  @doc """
  Return the artifact byte length.
  """
  @spec byte_len(t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def byte_len(%__MODULE__{interpolant: interpolant}), do: Interpolant.byte_len(interpolant)

  @doc """
  Return the source time-scale abbreviation, such as `"GPST"`.
  """
  @spec time_scale(t()) :: String.t()
  def time_scale(%__MODULE__{interpolant: interpolant}), do: Interpolant.time_scale(interpolant)

  @doc """
  Return the position-interpolation gap threshold factor carried by this artifact.
  """
  @spec gap_threshold_factor(t()) :: float()
  def gap_threshold_factor(%__MODULE__{interpolant: interpolant}) do
    Interpolant.gap_threshold_factor(interpolant)
  end

  @doc """
  Return the satellite ids available in the artifact.
  """
  @spec satellite_ids(t()) :: [String.t()]
  def satellite_ids(%__MODULE__{interpolant: interpolant}), do: Interpolant.satellite_ids(interpolant)

  @doc """
  Alias for `satellite_ids/1`.
  """
  @spec satellites(t()) :: [String.t()]
  def satellites(%__MODULE__{} = artifact), do: satellite_ids(artifact)

  @doc """
  Evaluate states for parallel satellite and epoch arrays.
  """
  @spec states_at_j2000_s(t(), [String.t()], [number()]) :: {:ok, StateBatch.t()} | {:error, term()}
  def states_at_j2000_s(%__MODULE__{interpolant: interpolant}, satellites, epochs_j2000_s) do
    Interpolant.states_at_j2000_s(interpolant, satellites, epochs_j2000_s)
  end

  @doc """
  Evaluate states for many satellites at one shared J2000-second epoch.
  """
  @spec states_at_shared_j2000_s(t(), [String.t()], number()) :: {:ok, StateBatch.t()} | {:error, term()}
  def states_at_shared_j2000_s(%__MODULE__{interpolant: interpolant}, satellites, epoch_j2000_s) do
    Interpolant.states_at_shared_j2000_s(interpolant, satellites, epoch_j2000_s)
  end

  @doc """
  Return the underlying interpolant handle for APIs that accept interpolant sources.
  """
  @spec to_interpolant(t()) :: Interpolant.t()
  def to_interpolant(%__MODULE__{interpolant: interpolant}), do: interpolant
end
