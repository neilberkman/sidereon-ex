defmodule Sidereon.GNSS.Signal.Analysis do
  @moduledoc """
  Closed-form GNSS signal spectrum and tracking metrics.

  This module is a thin Elixir boundary over the core signal-analysis formulas.
  Modulations are plain maps built by `bpsk/1` and `boc_sine/2`; metric calls
  return `{:ok, value}` or `{:error, reason}`.
  """

  alias Sidereon.NIF

  @typedoc "Navigation-signal modulation descriptor."
  @type modulation ::
          %{kind: :bpsk, order: number()}
          | %{kind: :boc_sine, m: number(), n: number()}

  @typedoc "DLL thermal-noise options."
  @type dll_options :: %{
          cn0_db_hz: number(),
          loop_bandwidth_hz: number(),
          integration_time_s: number(),
          correlator_spacing_chips: number(),
          receiver_bandwidth_hz: number()
        }

  @typedoc "Multipath-envelope options."
  @type multipath_options :: %{
          multipath_to_direct_ratio: number(),
          correlator_spacing_chips: number(),
          receiver_bandwidth_hz: number()
        }

  @typedoc "DLL jitter result."
  @type jitter :: %{
          seconds: float(),
          chips: float(),
          meters: float(),
          squaring_loss: float()
        }

  @typedoc "One multipath-envelope point."
  @type multipath_point :: %{
          delay_chips: float(),
          delay_s: float(),
          in_phase_chips: float(),
          in_phase_s: float(),
          in_phase_m: float(),
          anti_phase_chips: float(),
          anti_phase_s: float(),
          anti_phase_m: float(),
          running_average_chips: float(),
          running_average_s: float(),
          running_average_m: float()
        }

  @doc """
  Build a BPSK(n) modulation descriptor.
  """
  @spec bpsk(number()) :: modulation()
  def bpsk(order), do: %{kind: :bpsk, order: order / 1.0}

  @doc """
  Build a sine-phased BOC(m,n) modulation descriptor.
  """
  @spec boc_sine(number(), number()) :: modulation()
  def boc_sine(m, n), do: %{kind: :boc_sine, m: m / 1.0, n: n / 1.0}

  @doc """
  Return normalized PSD values in `1/Hz` at one offset or a list of offsets.
  """
  @spec psd_hz(modulation(), number() | [number()]) :: {:ok, float() | [float()]} | {:error, term()}
  def psd_hz(modulation, offset_hz) when is_number(offset_hz) do
    case psd_hz(modulation, [offset_hz]) do
      {:ok, [value]} -> {:ok, value}
      other -> other
    end
  end

  def psd_hz(modulation, offsets_hz) when is_list(offsets_hz) do
    NIF.signal_analysis_psd_hz(modulation_term(modulation), Enum.map(offsets_hz, &(&1 / 1.0)))
  end

  @doc """
  Return the fraction of total signal power inside a two-sided receiver bandwidth.
  """
  @spec fraction_power(modulation(), number()) :: {:ok, float()} | {:error, term()}
  def fraction_power(modulation, receiver_bandwidth_hz) do
    NIF.signal_analysis_fraction_power(modulation_term(modulation), receiver_bandwidth_hz / 1.0)
  end

  @doc """
  Return RMS bandwidth over a two-sided receiver bandwidth, in hertz.
  """
  @spec rms_bandwidth_hz(modulation(), number()) :: {:ok, float()} | {:error, term()}
  def rms_bandwidth_hz(modulation, receiver_bandwidth_hz) do
    NIF.signal_analysis_rms_bandwidth_hz(modulation_term(modulation), receiver_bandwidth_hz / 1.0)
  end

  @doc """
  Return spectral separation coefficient in hertz.
  """
  @spec ssc_hz(modulation(), modulation(), number()) :: {:ok, float()} | {:error, term()}
  def ssc_hz(desired, interference, receiver_bandwidth_hz) do
    NIF.signal_analysis_ssc_hz(
      modulation_term(desired),
      modulation_term(interference),
      receiver_bandwidth_hz / 1.0
    )
  end

  @doc """
  Return spectral separation coefficient in decibel-hertz.
  """
  @spec ssc_db_hz(modulation(), modulation(), number()) :: {:ok, float()} | {:error, term()}
  def ssc_db_hz(desired, interference, receiver_bandwidth_hz) do
    NIF.signal_analysis_ssc_db_hz(
      modulation_term(desired),
      modulation_term(interference),
      receiver_bandwidth_hz / 1.0
    )
  end

  @doc """
  Return effective C/N0 after finite-band interference terms.

  Each interference is a map with `:modulation` and
  `:power_ratio_to_carrier`.
  """
  @spec effective_cn0_degradation(modulation(), number(), number(), [map()]) ::
          {:ok, %{effective_cn0_hz: float(), effective_cn0_db_hz: float(), degradation_db: float()}}
          | {:error, term()}
  def effective_cn0_degradation(desired, cn0_db_hz, receiver_bandwidth_hz, interferences) do
    case NIF.signal_analysis_effective_cn0_degradation(
           modulation_term(desired),
           cn0_db_hz / 1.0,
           receiver_bandwidth_hz / 1.0,
           Enum.map(interferences, &interference_term/1)
         ) do
      {:ok, {effective_cn0_hz, effective_cn0_db_hz, degradation_db}} ->
        {:ok,
         %{
           effective_cn0_hz: effective_cn0_hz,
           effective_cn0_db_hz: effective_cn0_db_hz,
           degradation_db: degradation_db
         }}

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Return early-late DLL thermal-noise jitter.

  `processing` is `:coherent` or `:non_coherent`.
  """
  @spec dll_jitter(modulation(), dll_options(), :coherent | :non_coherent) :: {:ok, jitter()} | {:error, term()}
  def dll_jitter(modulation, options, processing \\ :coherent) do
    case NIF.signal_analysis_dll_jitter(
           modulation_term(modulation),
           dll_options_term(options),
           Atom.to_string(processing)
         ) do
      {:ok, tuple} -> {:ok, jitter_map(tuple)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Return the DLL lower bound for code-delay tracking jitter.
  """
  @spec dll_lower_bound(modulation(), dll_options()) :: {:ok, jitter()} | {:error, term()}
  def dll_lower_bound(modulation, options) do
    case NIF.signal_analysis_dll_lower_bound(modulation_term(modulation), dll_options_term(options)) do
      {:ok, tuple} -> {:ok, jitter_map(tuple)}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Return a one-path early-late multipath envelope on the supplied delay grid.
  """
  @spec multipath_envelope(modulation(), multipath_options(), [number()]) ::
          {:ok, [multipath_point()]} | {:error, term()}
  def multipath_envelope(modulation, options, delay_chips) when is_list(delay_chips) do
    case NIF.signal_analysis_multipath_envelope(
           modulation_term(modulation),
           multipath_options_term(options),
           Enum.map(delay_chips, &(&1 / 1.0))
         ) do
      {:ok, points} -> {:ok, Enum.map(points, &multipath_point_map/1)}
      {:error, _reason} = err -> err
    end
  end

  defp modulation_term(%{kind: :bpsk, order: order}) do
    %{kind: "bpsk", order: order / 1.0, m: nil, n: nil}
  end

  defp modulation_term(%{kind: :boc_sine, m: m, n: n}) do
    %{kind: "boc_sine", order: nil, m: m / 1.0, n: n / 1.0}
  end

  defp modulation_term({:bpsk, order}), do: modulation_term(bpsk(order))
  defp modulation_term({:boc_sine, m, n}), do: modulation_term(boc_sine(m, n))

  defp interference_term(%{modulation: modulation, power_ratio_to_carrier: ratio}) do
    %{modulation: modulation_term(modulation), power_ratio_to_carrier: ratio / 1.0}
  end

  defp dll_options_term(options) do
    %{
      cn0_db_hz: field!(options, :cn0_db_hz) / 1.0,
      loop_bandwidth_hz: field!(options, :loop_bandwidth_hz) / 1.0,
      integration_time_s: field!(options, :integration_time_s) / 1.0,
      correlator_spacing_chips: field!(options, :correlator_spacing_chips) / 1.0,
      receiver_bandwidth_hz: field!(options, :receiver_bandwidth_hz) / 1.0
    }
  end

  defp multipath_options_term(options) do
    %{
      multipath_to_direct_ratio: field!(options, :multipath_to_direct_ratio) / 1.0,
      correlator_spacing_chips: field!(options, :correlator_spacing_chips) / 1.0,
      receiver_bandwidth_hz: field!(options, :receiver_bandwidth_hz) / 1.0
    }
  end

  defp jitter_map({seconds, chips, meters, squaring_loss}) do
    %{seconds: seconds, chips: chips, meters: meters, squaring_loss: squaring_loss}
  end

  defp multipath_point_map(point), do: point

  defp field!(map, key) when is_map(map), do: Map.fetch!(map, key)
  defp field!(keyword, key) when is_list(keyword), do: Keyword.fetch!(keyword, key)
end
