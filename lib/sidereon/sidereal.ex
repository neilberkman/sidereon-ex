defmodule Sidereon.Sidereal do
  @moduledoc """
  Sidereal repeat-period helpers and residual filtering.

  Durations cross the public Elixir boundary as seconds. Residual samples are
  unitless to the filter, so callers may pass metres, cycles, or another scalar
  residual unit as long as each series uses one unit consistently.
  """

  alias __MODULE__.FilterOptions
  alias __MODULE__.FilterOutput
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.NIF

  defmodule FilterOptions do
    @moduledoc """
    Options for sidereal residual filtering.
    """

    defstruct sample_interval_s: 1.0,
              prior_periods: 1,
              min_coverage: 1,
              template_method: :mean

    @type template_method :: :mean | :robust_mad | {:ewma, number()}

    @type t :: %__MODULE__{
            sample_interval_s: float(),
            prior_periods: pos_integer(),
            min_coverage: non_neg_integer(),
            template_method: template_method()
          }
  end

  defmodule FilterOutput do
    @moduledoc """
    Output from sidereal residual filtering.
    """

    @enforce_keys [:filtered, :template, :coverage, :under_covered]
    defstruct [:filtered, :template, :coverage, :under_covered]

    @type t :: %__MODULE__{
            filtered: [float()],
            template: [float() | nil],
            coverage: [non_neg_integer()],
            under_covered: [boolean()]
          }
  end

  @type constellation :: :gps | :glonass | :galileo | :beidou | :qzss | :navic | :sbas | String.t()
  @type satellite_id :: String.t() | {String.t(), pos_integer()} | {atom(), pos_integer()}
  @type error_reason :: :invalid_input | :no_broadcast_record | :unsupported_constellation | term()

  @doc """
  Return the default constellation repeat period in seconds.
  """
  @spec repeat_period(constellation()) :: float()
  def repeat_period(system) do
    NIF.sidereal_repeat_period(system_letter(system))
  end

  @doc """
  Compute a broadcast-derived per-satellite orbit repeat lag in seconds.
  """
  @spec orbit_repeat_lag(Broadcast.t(), satellite_id(), number()) :: {:ok, float()} | {:error, error_reason()}
  def orbit_repeat_lag(%Broadcast{handle: handle}, satellite_id, near_epoch_j2000_s) do
    {letter, prn} = satellite(satellite_id)
    NIF.sidereal_orbit_repeat_lag(handle, letter, prn, near_epoch_j2000_s / 1.0)
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Filter a residual series with a supplied repeat period in seconds.
  """
  @spec filter([number()], number(), keyword() | FilterOptions.t()) ::
          {:ok, FilterOutput.t()} | {:error, error_reason()}
  def filter(series, period_s, opts \\ []) do
    with {:ok, options} <- filter_options(opts) do
      case NIF.sidereal_filter_series(numbers(series), period_s / 1.0, options) do
        {:ok, output} -> {:ok, output(output)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Score repeating components at candidate periods.

  Returns `{period_s, strength}` pairs, where strength is in `[0, 1]`.
  """
  @spec periodicity_strength([number()], [number()], keyword()) ::
          {:ok, [{float(), float()}]} | {:error, error_reason()}
  def periodicity_strength(series, candidate_periods_s, opts \\ []) do
    sample_interval_s = Keyword.get(opts, :sample_interval_s, 1.0) / 1.0

    NIF.sidereal_periodicity_strength(numbers(series), numbers(candidate_periods_s), sample_interval_s)
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp filter_options(%FilterOptions{} = opts), do: filter_options(Map.from_struct(opts))

  defp filter_options(opts) when is_list(opts), do: opts |> Map.new() |> filter_options()

  defp filter_options(opts) when is_map(opts) do
    sample_interval_s = Map.get(opts, :sample_interval_s, 1.0) / 1.0
    prior_periods = Map.get(opts, :prior_periods, 1)
    min_coverage = Map.get(opts, :min_coverage, 1)

    with {:ok, method, alpha} <- template_method(Map.get(opts, :template_method, :mean)) do
      {:ok, {sample_interval_s, prior_periods, min_coverage, method, alpha || 0.0}}
    end
  end

  defp filter_options(_other), do: {:error, :invalid_options}

  defp template_method(:mean), do: {:ok, "mean", nil}
  defp template_method(:robust_mad), do: {:ok, "robust_mad", nil}
  defp template_method({:ewma, alpha}) when is_number(alpha), do: {:ok, "ewma", alpha / 1.0}
  defp template_method(_other), do: {:error, :invalid_template_method}

  defp output(value) do
    %FilterOutput{
      filtered: value.filtered,
      template: value.template,
      coverage: value.coverage,
      under_covered: value.under_covered
    }
  end

  defp satellite(<<letter::binary-size(1), prn_text::binary>>) do
    {letter, String.to_integer(prn_text)}
  end

  defp satellite({system, prn}) when is_integer(prn), do: {system_letter(system), prn}

  defp system_letter(:gps), do: "G"
  defp system_letter(:glonass), do: "R"
  defp system_letter(:galileo), do: "E"
  defp system_letter(:beidou), do: "C"
  defp system_letter(:bds), do: "C"
  defp system_letter(:qzss), do: "J"
  defp system_letter(:navic), do: "I"
  defp system_letter(:sbas), do: "S"
  defp system_letter(<<letter::binary-size(1)>>), do: letter
  defp system_letter(system) when is_binary(system), do: system
  defp system_letter(system) when is_atom(system), do: system |> Atom.to_string() |> system_letter()

  defp numbers(values), do: Enum.map(values, &(&1 / 1.0))
end
