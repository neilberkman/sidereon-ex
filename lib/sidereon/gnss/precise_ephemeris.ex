defmodule Sidereon.GNSS.PreciseEphemeris do
  @moduledoc """
  A precise-ephemeris source built directly from samples, with no SP3 text in the
  loop.

  This is the Elixir surface over `sidereon-core`'s sample-backed precise-ephemeris
  source. The canonical intermediate representation of a precise orbit/clock
  product is a set of per-satellite ECEF position (+ optional clock) samples on a
  time axis (`Sidereon.GNSS.PreciseEphemerisSample`); this module builds an
  interpolatable source from those samples directly. It drives the exact same
  interpolation substrate the SP3-parsed source uses, so
  `Sidereon.GNSS.Observables.predict_ranges/3` accepts either kind of source.

  A built source is held as a resource handle by the BEAM; evaluation operates on
  that handle.

  Structural validation errors are atoms when they have no satellite payload
  (`:empty`, `:mixed_timescale`, `:accuracy_samples_mismatch`) and
  `{reason, satellite_id}` tuples when they identify a satellite. The latter
  reasons are `:single_sample_satellite`, `:non_monotonic`, `:out_of_range`,
  `:non_finite`, and `:invalid_accuracy_value`.

  ## Round trip

      {:ok, sp3} = Sidereon.GNSS.SP3.load("igs.sp3")
      samples = Sidereon.GNSS.SP3.precise_ephemeris_samples(sp3)
      {:ok, source} = Sidereon.GNSS.PreciseEphemeris.from_samples(samples)

  For samples that are the faithful image of the interpolation fit nodes (the
  round-trip case above), the rebuilt source interpolates and predicts ranges
  byte-identically to the SP3-parsed source. Samples carrying lower precision
  interpolate at that precision.
  """

  alias Sidereon.GNSS.Core.Types
  alias Sidereon.GNSS.PreciseEphemeris.Interpolant
  alias Sidereon.GNSS.PreciseEphemeris.StateBatch
  alias Sidereon.GNSS.PreciseEphemerisAccuracySample
  alias Sidereon.GNSS.PreciseEphemerisSample
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @enforce_keys [:handle, :time_scale]
  defstruct [:handle, :time_scale]

  @type t :: %__MODULE__{
          handle: reference(),
          time_scale: String.t() | nil
        }

  @typedoc "Structural refusal returned while building a sample-backed precise source."
  @type sample_error ::
          :empty
          | {:single_sample_satellite, String.t()}
          | {:non_monotonic, String.t()}
          | :mixed_timescale
          | {:out_of_range, String.t()}
          | {:non_finite, String.t()}
          | :accuracy_samples_mismatch
          | {:invalid_accuracy_value, String.t()}

  @typedoc "Validated error detail for an invalid interpolation policy."
  @type interpolation_error :: %{
          kind: String.t(),
          field: String.t(),
          value: String.t(),
          reason: String.t()
        }

  @typedoc "A sample-construction refusal, interpolation refusal, or boundary/input conversion error."
  @type construction_error ::
          sample_error() | interpolation_error() | atom() | tuple() | String.t()

  @doc """
  Build a precise-ephemeris source from a list of
  `Sidereon.GNSS.PreciseEphemerisSample` structs.

  Samples are grouped by satellite. Each satellite's series must be strictly
  increasing in epoch and carry at least two samples, and every sample must share
  one time scale. Returns `{:ok, %Sidereon.GNSS.PreciseEphemeris{}}`, or
  `{:error, reason}` where `reason` is one of the structural validation reasons:

    * `:empty` - no samples supplied
    * `{:single_sample_satellite, satellite_id}` - a satellite has only one sample
    * `{:non_monotonic, satellite_id}` - a satellite's epochs are not strictly increasing
    * `:mixed_timescale` - samples carry more than one time scale
    * `{:non_finite, satellite_id}` - a sample position or clock value was not finite
    * `{:out_of_range, satellite_id}` - a sample epoch is not representable as J2000 seconds

  A malformed satellite token or time scale in a sample is returned verbatim as
  `{:error, reason}` without raising.
  Options:
    * `:gap_threshold_factor` - multiple of nominal node spacing above which
      consecutive records mark a coverage gap (default `1.5`, must be > 1.0).

  A numeric factor at or below `1.0` returns an
  `{:error, %{kind: "sp3_interpolation_options", field: "gap_threshold_factor", ...}}`
  detail with the supplied value and core refusal reason.
  """
  @spec from_samples([PreciseEphemerisSample.t()], keyword()) ::
          {:ok, t()} | {:error, construction_error()}
  def from_samples(samples, opts \\ []) when is_list(samples) do
    with {:ok, factor} <- normalize_gap_threshold_factor(opts),
         {:ok, tuples} <- to_nif_tuples(samples) do
      case NIF.precise_samples_from_samples(tuples, factor) do
        {:ok, handle} when is_reference(handle) ->
          {:ok, %__MODULE__{handle: handle, time_scale: time_scale_of(samples)}}

        {:error, _} = err ->
          err

        other ->
          {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :precise_samples_from_samples)
  end

  @doc """
  Build a precise source from samples and identity-aligned accuracy sidecars.

  Returns `:accuracy_samples_mismatch` if the sidecars do not match the samples,
  or `{:invalid_accuracy_value, satellite_id}` when a sidecar's known variance
  is invalid. Sample validation uses the same typed reasons as `from_samples/2`.
  A rejected numeric gap threshold returns the typed `interpolation_error()` map.
  """
  @spec from_samples_with_accuracy(
          [PreciseEphemerisSample.t()],
          [PreciseEphemerisAccuracySample.t()],
          keyword()
        ) :: {:ok, t()} | {:error, construction_error()}
  def from_samples_with_accuracy(samples, accuracy, opts \\ [])

  def from_samples_with_accuracy(samples, accuracy, opts) when is_list(samples) and is_list(accuracy) do
    with {:ok, factor} <- normalize_gap_threshold_factor(opts),
         {:ok, sample_tuples} <- to_nif_tuples(samples),
         {:ok, accuracy_tuples} <- accuracy_tuples(accuracy) do
      case NIF.precise_samples_from_samples_with_accuracy(sample_tuples, accuracy_tuples, factor) do
        {:ok, handle} when is_reference(handle) ->
          {:ok, %__MODULE__{handle: handle, time_scale: time_scale_of(samples)}}

        {:error, _} = error ->
          error

        other ->
          {:error, other}
      end
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :precise_samples_from_samples_with_accuracy)
  end

  def from_samples_with_accuracy(_samples, _accuracy, _opts), do: {:error, :invalid_accuracy_samples}

  @doc """
  Return the position-interpolation gap threshold factor carried by this sample-backed source.
  """
  @spec gap_threshold_factor(t()) :: float()
  def gap_threshold_factor(%__MODULE__{handle: handle}) do
    NIF.precise_samples_gap_threshold_factor(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError,
              [message: "could not read precise-ephemeris gap threshold factor: #{NifCall.describe(e)}"],
              __STACKTRACE__
  end

  @doc """
  Return the satellite ids available in this sample-backed precise source.
  """
  @spec satellites(t()) :: [String.t()] | {:error, term()}
  def satellites(%__MODULE__{} = source) do
    with {:ok, interpolant} <- Interpolant.from_precise_ephemeris_samples(source) do
      Interpolant.satellites(interpolant)
    end
  end

  @doc """
  Evaluate states for parallel satellite and J2000-second arrays.
  """
  @spec observable_states_at_j2000_s(t(), [String.t()], [number()]) ::
          {:ok, StateBatch.t()} | {:error, term()}
  def observable_states_at_j2000_s(%__MODULE__{} = source, satellites, epochs_j2000_s) do
    Interpolant.states_at_j2000_s(source, satellites, epochs_j2000_s)
  end

  @doc """
  Evaluate state batches while retaining structured error details for failed
  rows. Existing `observable_states_at_j2000_s/3` behavior is unchanged.
  """
  @spec observable_states_at_j2000_s_detailed(t(), [String.t()], [number()]) ::
          {:ok, StateBatch.t()} | {:error, term()}
  def observable_states_at_j2000_s_detailed(%__MODULE__{} = source, satellites, epochs_j2000_s) do
    Interpolant.states_at_j2000_s_detailed(source, satellites, epochs_j2000_s)
  end

  @doc """
  Evaluate states for many satellites at one shared J2000-second epoch.
  """
  @spec observable_states_at_shared_j2000_s(t(), [String.t()], number()) ::
          {:ok, StateBatch.t()} | {:error, term()}
  def observable_states_at_shared_j2000_s(%__MODULE__{} = source, satellites, epoch_j2000_s) do
    Interpolant.states_at_shared_j2000_s(source, satellites, epoch_j2000_s)
  end

  defp to_nif_tuples(samples) do
    samples
    |> Enum.reduce_while({:ok, []}, fn sample, {:ok, acc} ->
      case PreciseEphemerisSample.to_nif_tuple(sample) do
        {:ok, tuple} -> {:cont, {:ok, [tuple | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, tuples} -> {:ok, Enum.reverse(tuples)}
      {:error, _} = err -> err
    end
  end

  defp accuracy_tuples(accuracy) do
    accuracy
    |> Enum.reduce_while({:ok, []}, fn sidecar, {:ok, acc} ->
      case PreciseEphemerisAccuracySample.to_nif_tuple(sidecar) do
        {:ok, tuple} ->
          {:cont, {:ok, [tuple | acc]}}

        {:error, :invalid_accuracy_value} ->
          {:halt, {:error, {:invalid_accuracy_value, canonical_satellite_id(sidecar.sat)}}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, tuples} -> {:ok, Enum.reverse(tuples)}
      {:error, _} = error -> error
    end
  end

  defp canonical_satellite_id(sat) do
    case Types.parse_sat_id(sat) do
      {:ok, letter, prn} -> letter <> String.pad_leading(Integer.to_string(prn), 2, "0")
      _ -> sat
    end
  end

  defp time_scale_of([%PreciseEphemerisSample{epoch: %{time_scale: time_scale}} | _]), do: time_scale
  defp time_scale_of(_samples), do: nil

  defp normalize_gap_threshold_factor(opts) when is_list(opts) do
    case Keyword.get(opts, :gap_threshold_factor) do
      nil -> {:ok, nil}
      factor when is_number(factor) -> {:ok, factor / 1.0}
      other -> {:error, {:bad_gap_threshold_factor, other}}
    end
  end

  defp normalize_gap_threshold_factor(other), do: {:error, {:bad_gap_threshold_factor, other}}
end
