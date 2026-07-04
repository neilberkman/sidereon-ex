defmodule Sidereon.ClockStability do
  @moduledoc """
  Allan-family clock-stability estimators.

  The functions in this module delegate to `sidereon-core`'s IEEE-1139 Allan,
  modified Allan, Hadamard, and time-deviation estimators. Phase deviations are
  in seconds, fractional-frequency samples are dimensionless, and averaging
  times are seconds.
  """

  alias __MODULE__.Curve
  alias __MODULE__.Curves
  alias __MODULE__.PowerLawNoiseFit
  alias __MODULE__.PowerLawNoiseOptions
  alias __MODULE__.PowerLawNoiseRegion
  alias __MODULE__.PowerLawOctave
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.NIF

  defmodule Curve do
    @moduledoc """
    One clock-stability estimator curve.

    `:tau_s` is the averaging time in seconds, `:deviation` is the estimator
    value, and `:n` is the number of estimator terms used at each point.
    """

    @enforce_keys [:tau_s, :deviation, :n]
    defstruct [:tau_s, :deviation, :n]

    @type t :: %__MODULE__{
            tau_s: [float()],
            deviation: [float()],
            n: [non_neg_integer()]
          }
  end

  defmodule Curves do
    @moduledoc """
    Combined Allan-family output.

    Each field is either a `Sidereon.ClockStability.Curve` or `nil` when that
    estimator was not requested. Deviations are dimensionless except `:tdev`,
    whose deviation values are seconds.
    """

    alias Sidereon.ClockStability.Curve

    defstruct [:adev, :overlapping_adev, :mdev, :hdev, :tdev]

    @type t :: %__MODULE__{
            adev: Curve.t() | nil,
            overlapping_adev: Curve.t() | nil,
            mdev: Curve.t() | nil,
            hdev: Curve.t() | nil,
            tdev: Curve.t() | nil
          }
  end

  defmodule PowerLawNoiseOptions do
    @moduledoc """
    Options for power-law clock-noise identification.
    """

    defstruct min_points_per_octave: 2,
              slope_tolerance: 0.125,
              scatter_tolerance: 0.125,
              basic_tau_s: 1.0,
              measurement_bandwidth_hz: 0.5

    @type t :: %__MODULE__{
            min_points_per_octave: pos_integer(),
            slope_tolerance: float(),
            scatter_tolerance: float(),
            basic_tau_s: float(),
            measurement_bandwidth_hz: float()
          }
  end

  defmodule PowerLawOctave do
    @moduledoc """
    Per-octave power-law classification.
    """

    @enforce_keys [:tau_start_s, :tau_end_s, :point_count, :dominance]
    defstruct [
      :tau_start_s,
      :tau_end_s,
      :point_count,
      :adev_slope,
      :mdev_slope,
      :slope_scatter,
      :dominance,
      :noise_type,
      :flag
    ]

    @type dominance :: :dominant | :ambiguous | :flagged

    @type t :: %__MODULE__{
            tau_start_s: float(),
            tau_end_s: float(),
            point_count: non_neg_integer(),
            adev_slope: float() | nil,
            mdev_slope: float() | nil,
            slope_scatter: float() | nil,
            dominance: dominance(),
            noise_type: atom() | nil,
            flag: atom() | nil
          }
  end

  defmodule PowerLawNoiseRegion do
    @moduledoc """
    Consecutive tau span used for one fitted power-law coefficient.
    """

    @enforce_keys [
      :noise_type,
      :tau_start_s,
      :tau_end_s,
      :octave_count,
      :point_count,
      :mean_slope,
      :coefficient
    ]
    defstruct [
      :noise_type,
      :tau_start_s,
      :tau_end_s,
      :octave_count,
      :point_count,
      :mean_slope,
      :coefficient
    ]

    @type t :: %__MODULE__{
            noise_type: atom(),
            tau_start_s: float(),
            tau_end_s: float(),
            octave_count: pos_integer(),
            point_count: pos_integer(),
            mean_slope: float(),
            coefficient: float()
          }
  end

  defmodule PowerLawNoiseFit do
    @moduledoc """
    Power-law clock-noise identification result.
    """

    @enforce_keys [:dominant_per_octave, :coefficients, :regions]
    defstruct [:dominant_per_octave, :coefficients, :regions]

    @type t :: %__MODULE__{
            dominant_per_octave: [PowerLawOctave.t()],
            coefficients: [float()],
            regions: [PowerLawNoiseRegion.t()]
          }
  end

  @type series ::
          [number()]
          | {:phase_seconds, [number()]}
          | {:fractional_frequency, [number()]}
          | {:phase_seconds_with_gaps, [number() | nil]}
          | {:fractional_frequency_with_gaps, [number() | nil]}

  @type tau_grid :: :octave | :all | {:explicit, [pos_integer()]}
  @type gap_policy :: :reject | :omit_terms
  @type estimator :: :adev | :overlapping_adev | :mdev | :hdev | :tdev
  @type power_law_noise_type ::
          :random_walk_fm | :flicker_fm | :white_fm | :flicker_pm | :white_pm
  @type allan_error ::
          :empty_series
          | :invalid_tau0
          | :no_estimators
          | :empty_tau_grid
          | :invalid_averaging_factor
          | :too_few_samples
          | :non_finite_sample
          | :gap
          | :non_finite_tau
          | :non_finite_deviation
          | :invalid_options
          | :invalid_curve
          | term()

  @doc """
  Plain non-overlapping Allan deviation for explicit averaging factors.

  `tau0_s` is the base sample interval in seconds. `averaging_factors` are the
  integer `m` values, so each output `tau_s` is `m * tau0_s`.
  """
  @spec allan_deviation(series(), number(), [pos_integer()]) :: {:ok, Curve.t()} | {:error, allan_error()}
  def allan_deviation(series, tau0_s, averaging_factors) do
    estimator(:adev, series, tau0_s, averaging_factors)
  end

  @doc """
  Fully overlapping Allan deviation for explicit averaging factors.

  `tau0_s` and returned `tau_s` values are seconds.
  """
  @spec overlapping_adev(series(), number(), [pos_integer()]) :: {:ok, Curve.t()} | {:error, allan_error()}
  def overlapping_adev(series, tau0_s, averaging_factors) do
    estimator(:overlapping_adev, series, tau0_s, averaging_factors)
  end

  @doc """
  Modified Allan deviation for explicit averaging factors.

  `tau0_s` and returned `tau_s` values are seconds.
  """
  @spec modified_adev(series(), number(), [pos_integer()]) :: {:ok, Curve.t()} | {:error, allan_error()}
  def modified_adev(series, tau0_s, averaging_factors) do
    estimator(:mdev, series, tau0_s, averaging_factors)
  end

  @doc """
  Overlapping Hadamard deviation for explicit averaging factors.

  `tau0_s` and returned `tau_s` values are seconds.
  """
  @spec hadamard_deviation(series(), number(), [pos_integer()]) :: {:ok, Curve.t()} | {:error, allan_error()}
  def hadamard_deviation(series, tau0_s, averaging_factors) do
    estimator(:hdev, series, tau0_s, averaging_factors)
  end

  @doc """
  Time deviation for explicit averaging factors.

  Returned deviation values are seconds.
  """
  @spec time_deviation(series(), number(), [pos_integer()]) :: {:ok, Curve.t()} | {:error, allan_error()}
  def time_deviation(series, tau0_s, averaging_factors) do
    estimator(:tdev, series, tau0_s, averaging_factors)
  end

  @doc """
  Compute a configured set of Allan-family curves.

  Options:

    * `:estimators` - `:standard` for OADEV, MDEV, HDEV, and TDEV, `:all`,
      `:none`, a list of estimator atoms, or a map of estimator booleans.
    * `:tau_grid` - `:octave`, `:all`, or `{:explicit, factors}`. Averaging
      times are seconds.
    * `:gap_policy` - `:reject` or `:omit_terms` for gapped series.
  """
  @spec compute_allan_deviations(series(), number(), keyword()) :: {:ok, Curves.t()} | {:error, allan_error()}
  def compute_allan_deviations(series, tau0_s, opts \\ []) do
    with {:ok, kind, samples} <- normalize_series(series),
         {:ok, estimator_flags} <- estimator_flags(Keyword.get(opts, :estimators, :standard)),
         {:ok, tau_kind, tau_factors} <- tau_grid(Keyword.get(opts, :tau_grid, :octave)),
         {:ok, gap_policy} <- gap_policy(Keyword.get(opts, :gap_policy, :reject)) do
      case NIF.clock_compute_allan_deviations(
             kind,
             samples,
             tau0_s / 1.0,
             estimator_flags,
             tau_kind,
             tau_factors,
             gap_policy
           ) do
        {:ok, curves} -> {:ok, curves(curves)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Extract RINEX receiver-clock phase deviations in seconds.

  Event epochs are returned as `nil` gaps. The result can be passed as
  `{:phase_seconds_with_gaps, values}` to `compute_allan_deviations/3`.
  """
  @spec receiver_clock_phase_deviations(Observations.t()) :: [float() | nil]
  def receiver_clock_phase_deviations(%Observations{handle: handle}) do
    NIF.clock_receiver_phase_deviations(handle)
  end

  @doc """
  Return the exact Allan-family log-log slope for a power-law noise type.
  """
  @spec power_law_slope(power_law_noise_type(), :adev | :overlapping_adev | :mdev) :: float()
  def power_law_slope(noise_type, estimator \\ :adev) do
    NIF.clock_power_law_slope(to_string(noise_type), to_string(estimator))
  end

  @doc """
  Identify power-law clock noise from supplied ADEV and MDEV curves.
  """
  @spec fit_power_law_noise(Curve.t(), Curve.t(), keyword() | PowerLawNoiseOptions.t()) ::
          {:ok, PowerLawNoiseFit.t()} | {:error, allan_error()}
  def fit_power_law_noise(%Curve{} = adev, %Curve{} = mdev, opts \\ []) do
    case NIF.clock_fit_power_law_noise(curve_to_nif(adev), curve_to_nif(mdev), power_law_options(opts)) do
      {:ok, fit} -> {:ok, power_law_fit(fit)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp estimator(kind, series, tau0_s, averaging_factors) do
    with {:ok, series_kind, samples} <- normalize_series(series),
         {:ok, factors} <- averaging_factors(averaging_factors) do
      case NIF.clock_allan_estimator(Atom.to_string(kind), series_kind, samples, tau0_s / 1.0, factors) do
        {:ok, curve} -> {:ok, curve(curve)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp normalize_series(values) when is_list(values), do: normalize_series({:phase_seconds, values})

  defp normalize_series({kind, values}) when kind in [:phase_seconds, :fractional_frequency] and is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_number(value) -> {:cont, {:ok, [value / 1.0 | acc]}}
      _value, _acc -> {:halt, {:error, :invalid_sample}}
    end)
    |> reverse_samples(kind)
  end

  defp normalize_series({kind, values})
       when kind in [:phase_seconds_with_gaps, :fractional_frequency_with_gaps] and is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      nil, {:ok, acc} -> {:cont, {:ok, [nil | acc]}}
      value, {:ok, acc} when is_number(value) -> {:cont, {:ok, [value / 1.0 | acc]}}
      _value, _acc -> {:halt, {:error, :invalid_sample}}
    end)
    |> reverse_samples(kind)
  end

  defp normalize_series(_other), do: {:error, :invalid_series}

  defp reverse_samples({:ok, samples}, kind), do: {:ok, Atom.to_string(kind), Enum.reverse(samples)}
  defp reverse_samples({:error, _} = err, _kind), do: err

  defp averaging_factors(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_integer(value) and value > 0 -> {:cont, {:ok, [value | acc]}}
      _value, _acc -> {:halt, {:error, :invalid_averaging_factor}}
    end)
    |> case do
      {:ok, factors} -> {:ok, Enum.reverse(factors)}
      {:error, _} = err -> err
    end
  end

  defp averaging_factors(_other), do: {:error, :invalid_averaging_factor}

  defp estimator_flags(:standard), do: {:ok, {false, true, true, true, true}}
  defp estimator_flags(:all), do: {:ok, {true, true, true, true, true}}
  defp estimator_flags(:none), do: {:ok, {false, false, false, false, false}}

  defp estimator_flags(values) when is_list(values) do
    valid = [:adev, :overlapping_adev, :mdev, :hdev, :tdev]

    if Enum.all?(values, &(&1 in valid)) do
      {:ok,
       {
         :adev in values,
         :overlapping_adev in values,
         :mdev in values,
         :hdev in values,
         :tdev in values
       }}
    else
      {:error, :invalid_estimators}
    end
  end

  defp estimator_flags(values) when is_map(values) do
    {:ok,
     {
       Map.get(values, :adev, false),
       Map.get(values, :overlapping_adev, false),
       Map.get(values, :mdev, false),
       Map.get(values, :hdev, false),
       Map.get(values, :tdev, false)
     }}
  end

  defp estimator_flags(_other), do: {:error, :invalid_estimators}

  defp tau_grid(:octave), do: {:ok, "octave", []}
  defp tau_grid(:all), do: {:ok, "all", []}

  defp tau_grid({:explicit, factors}) do
    with {:ok, factors} <- averaging_factors(factors) do
      {:ok, "explicit", factors}
    end
  end

  defp tau_grid(_other), do: {:error, :invalid_tau_grid}

  defp gap_policy(:reject), do: {:ok, "reject"}
  defp gap_policy(:omit_terms), do: {:ok, "omit_terms"}
  defp gap_policy(_other), do: {:error, :invalid_gap_policy}

  defp curve(%{tau_s: tau_s, deviation: deviation, n: n}) do
    %Curve{tau_s: tau_s, deviation: deviation, n: n}
  end

  defp curves(raw) do
    %Curves{
      adev: maybe_curve(raw.adev),
      overlapping_adev: maybe_curve(raw.overlapping_adev),
      mdev: maybe_curve(raw.mdev),
      hdev: maybe_curve(raw.hdev),
      tdev: maybe_curve(raw.tdev)
    }
  end

  defp maybe_curve(nil), do: nil
  defp maybe_curve(raw), do: curve(raw)

  defp power_law_options(%PowerLawNoiseOptions{} = opts), do: power_law_options(Map.from_struct(opts))

  defp power_law_options(opts) when is_list(opts), do: opts |> Map.new() |> power_law_options()

  defp power_law_options(opts) when is_map(opts) do
    basic_tau_s = Map.get(opts, :basic_tau_s, 1.0) / 1.0

    {
      Map.get(opts, :min_points_per_octave, 2),
      Map.get(opts, :slope_tolerance, 0.125) / 1.0,
      Map.get(opts, :scatter_tolerance, 0.125) / 1.0,
      basic_tau_s,
      Map.get(opts, :measurement_bandwidth_hz, 0.5 / basic_tau_s) / 1.0
    }
  end

  defp curve_to_nif(%Curve{} = curve) do
    %{
      tau_s: Enum.map(curve.tau_s, &(&1 / 1.0)),
      deviation: Enum.map(curve.deviation, &(&1 / 1.0)),
      n: curve.n
    }
  end

  defp power_law_fit(value) do
    %PowerLawNoiseFit{
      dominant_per_octave: Enum.map(value.dominant_per_octave, &power_law_octave/1),
      coefficients: value.coefficients,
      regions: Enum.map(value.regions, &power_law_region/1)
    }
  end

  defp power_law_octave(value) do
    %PowerLawOctave{
      tau_start_s: value.tau_start_s,
      tau_end_s: value.tau_end_s,
      point_count: value.point_count,
      adev_slope: value.adev_slope,
      mdev_slope: value.mdev_slope,
      slope_scatter: value.slope_scatter,
      dominance: String.to_atom(value.dominance),
      noise_type: atom_or_nil(value.noise_type),
      flag: atom_or_nil(value.flag)
    }
  end

  defp power_law_region(value) do
    %PowerLawNoiseRegion{
      noise_type: String.to_atom(value.noise_type),
      tau_start_s: value.tau_start_s,
      tau_end_s: value.tau_end_s,
      octave_count: value.octave_count,
      point_count: value.point_count,
      mean_slope: value.mean_slope,
      coefficient: value.coefficient
    }
  end

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(value), do: String.to_atom(value)
end
