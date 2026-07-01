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

  ## Round trip

      {:ok, sp3} = Sidereon.GNSS.SP3.load("igs.sp3")
      samples = Sidereon.GNSS.SP3.precise_ephemeris_samples(sp3)
      {:ok, source} = Sidereon.GNSS.PreciseEphemeris.from_samples(samples)

  For samples that are the faithful image of the interpolation fit nodes (the
  round-trip case above), the rebuilt source interpolates and predicts ranges
  byte-identically to the SP3-parsed source. Samples carrying lower precision
  interpolate at that precision.
  """

  alias Sidereon.GNSS.PreciseEphemerisSample
  alias Sidereon.NIF

  @enforce_keys [:handle, :time_scale]
  defstruct [:handle, :time_scale]

  @type t :: %__MODULE__{
          handle: reference(),
          time_scale: String.t() | nil
        }

  @doc """
  Build a precise-ephemeris source from a list of
  `Sidereon.GNSS.PreciseEphemerisSample` structs.

  Samples are grouped by satellite. Each satellite's series must be strictly
  increasing in epoch and carry at least two samples, and every sample must share
  one time scale. Returns `{:ok, %Sidereon.GNSS.PreciseEphemeris{}}`, or
  `{:error, reason}` where `reason` is one of the structural validation atoms:

    * `:empty` - no samples supplied
    * `:single_sample_satellite` - a satellite has only one sample
    * `:non_monotonic` - a satellite's epochs are not strictly increasing
    * `:mixed_timescale` - samples carry more than one time scale
    * `:non_finite` - a sample position or clock value was not finite
    * `:out_of_range` - a sample epoch is not representable as J2000 seconds

  A malformed satellite token or time scale in a sample is returned verbatim as
  `{:error, reason}` without raising.
  """
  @spec from_samples([PreciseEphemerisSample.t()]) :: {:ok, t()} | {:error, term()}
  def from_samples(samples) when is_list(samples) do
    with {:ok, tuples} <- to_nif_tuples(samples) do
      case NIF.precise_samples_from_samples(tuples) do
        {:ok, handle} when is_reference(handle) ->
          {:ok, %__MODULE__{handle: handle, time_scale: time_scale_of(samples)}}

        {:error, _} = err ->
          err

        other ->
          {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
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

  defp time_scale_of([%PreciseEphemerisSample{epoch: %{time_scale: time_scale}} | _]), do: time_scale
  defp time_scale_of(_samples), do: nil
end
