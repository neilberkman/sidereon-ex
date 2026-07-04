defmodule Sidereon.GeodeticTimeSeries do
  @moduledoc """
  Geodetic position time-series velocity, trajectory, step, and network tools.

  Epochs are decimal years. Positions are metres in the selected frame.
  """

  alias Sidereon.NIF

  defmodule PositionSample do
    @moduledoc """
    One position sample in a geodetic time series.
    """

    @enforce_keys [:epoch_year, :position_m]
    defstruct [:epoch_year, :position_m, :covariance_m2]

    @type t :: %__MODULE__{
            epoch_year: float(),
            position_m: {float(), float(), float()},
            covariance_m2: [[float()]] | nil
          }
  end

  defmodule MidasOptions do
    @moduledoc """
    Options for the MIDAS velocity estimator.
    """

    defstruct dominant_period_years: 1.0,
              period_tolerance_years: 0.001,
              min_pairs: 3

    @type t :: %__MODULE__{
            dominant_period_years: float(),
            period_tolerance_years: float(),
            min_pairs: pos_integer()
          }
  end

  defmodule MidasComponentStats do
    @moduledoc """
    MIDAS pair-selection diagnostics for one ENU component.
    """

    @enforce_keys [:pair_count, :retained_pair_count, :slope_sigma_m_per_yr, :effective_pair_count]
    defstruct [:pair_count, :retained_pair_count, :slope_sigma_m_per_yr, :effective_pair_count]

    @type t :: %__MODULE__{
            pair_count: non_neg_integer(),
            retained_pair_count: non_neg_integer(),
            slope_sigma_m_per_yr: float(),
            effective_pair_count: float()
          }
  end

  defmodule Velocity do
    @moduledoc """
    Robust ENU velocity estimate.
    """

    @enforce_keys [
      :rate_enu_m_per_yr,
      :sigma_enu_m_per_yr,
      :covariance_enu_m2_per_yr2,
      :component_stats,
      :sample_count,
      :span_years,
      :quality
    ]
    defstruct [
      :rate_enu_m_per_yr,
      :sigma_enu_m_per_yr,
      :covariance_enu_m2_per_yr2,
      :component_stats,
      :sample_count,
      :span_years,
      :quality
    ]

    @type t :: %__MODULE__{
            rate_enu_m_per_yr: {float(), float(), float()},
            sigma_enu_m_per_yr: {float(), float(), float()},
            covariance_enu_m2_per_yr2: [[float()]],
            component_stats: [MidasComponentStats.t()],
            sample_count: non_neg_integer(),
            span_years: float(),
            quality: :nominal | :short_span
          }
  end

  defmodule TrajectoryModel do
    @moduledoc """
    Linear trajectory model shape.
    """

    defstruct reference_epoch_year: nil,
              include_annual: true,
              include_semiannual: true,
              offset_epochs_year: []

    @type t :: %__MODULE__{
            reference_epoch_year: float() | nil,
            include_annual: boolean(),
            include_semiannual: boolean(),
            offset_epochs_year: [float()]
          }
  end

  defmodule TrajectoryFitOptions do
    @moduledoc """
    Least-squares controls for trajectory fitting.
    """

    defstruct loss: :linear, f_scale_m: 1.0, max_nfev: nil

    @type t :: %__MODULE__{
            loss: :linear | :soft_l1 | :huber | :cauchy | :arctan,
            f_scale_m: float(),
            max_nfev: pos_integer() | nil
          }
  end

  defmodule Trajectory do
    @moduledoc """
    Fitted trajectory coefficients and solver diagnostics.
    """

    defstruct [
      :reference_epoch_year,
      :terms,
      :components,
      :parameter_covariance,
      :residual_rms_enu_m,
      :geometry_quality,
      :status,
      :nfev,
      :njev,
      :cost,
      :optimality
    ]

    @type t :: %__MODULE__{reference_epoch_year: float(), terms: list(), components: list()}
  end

  defmodule StepDetectionOptions do
    @moduledoc """
    Options for displacement step detection.
    """

    defstruct window_years: 0.75,
              score_threshold: 8.0,
              min_offset_m: 1.0e-4,
              min_samples_each_side: 4,
              min_separation_years: 0.25,
              midas: %MidasOptions{}

    @type t :: %__MODULE__{
            window_years: float(),
            score_threshold: float(),
            min_offset_m: float(),
            min_samples_each_side: pos_integer(),
            min_separation_years: float(),
            midas: MidasOptions.t()
          }
  end

  defmodule StepCandidate do
    @moduledoc """
    Candidate displacement step from the labelled detector heuristic.
    """

    @enforce_keys [:epoch_year, :offset_enu_m, :score, :before_count, :after_count, :heuristic]
    defstruct [:epoch_year, :offset_enu_m, :score, :before_count, :after_count, :heuristic]

    @type t :: %__MODULE__{
            epoch_year: float(),
            offset_enu_m: {float(), float(), float()},
            score: float(),
            before_count: non_neg_integer(),
            after_count: non_neg_integer(),
            heuristic: atom()
          }
  end

  defmodule NetworkStation do
    @moduledoc """
    One station input for network motion-field estimation.
    """

    @enforce_keys [:id, :reference, :samples]
    defstruct [:id, :reference, :samples, frame: :enu]

    @type t :: %__MODULE__{
            id: String.t(),
            reference: {float(), float(), float()},
            samples: [PositionSample.t()],
            frame: Sidereon.GeodeticTimeSeries.frame()
          }
  end

  defmodule MotionField do
    @moduledoc """
    Network motion field in one output ENU frame.
    """

    @enforce_keys [:origin, :remove_common_mode, :stations, :common_mode_enu_m_per_yr]
    defstruct [:origin, :remove_common_mode, :stations, :common_mode_enu_m_per_yr]

    @type t :: %__MODULE__{
            origin: {float(), float(), float()},
            remove_common_mode: boolean(),
            stations: [map()],
            common_mode_enu_m_per_yr: {float(), float(), float()}
          }
  end

  @type frame :: :enu | {:ecef, {number(), number(), number()}}
  @type sample :: PositionSample.t() | {number(), {number(), number(), number()}}
  @type error_reason ::
          :invalid_input
          | :too_few_samples
          | :insufficient_pairs
          | :singular_trajectory
          | :did_not_converge
          | :solver
          | term()

  @doc """
  Estimate station velocity with MIDAS.

  Options accept the `MidasOptions` fields plus `:frame`, which defaults to
  `:enu`.
  """
  @spec velocity_midas([sample()], keyword() | MidasOptions.t()) :: {:ok, Velocity.t()} | {:error, error_reason()}
  def velocity_midas(samples, opts \\ []) do
    opts = options_map(opts)

    case NIF.geodetic_velocity_midas(
           frame_term(Map.get(opts, :frame, :enu)),
           sample_terms(samples),
           midas_options(opts)
         ) do
      {:ok, velocity} -> {:ok, velocity(velocity)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Fit a linear geodetic trajectory model.

  Pass a `TrajectoryModel` as the second argument and fit options as the third.
  The `:frame` option selects `:enu` or `{:ecef, reference}` input positions.
  """
  @spec fit_trajectory([sample()], TrajectoryModel.t(), keyword() | TrajectoryFitOptions.t()) ::
          {:ok, Trajectory.t()} | {:error, error_reason()}
  def fit_trajectory(samples, model \\ %TrajectoryModel{}, opts \\ []) do
    opts = options_map(opts)

    case NIF.geodetic_fit_trajectory(
           frame_term(Map.get(opts, :frame, :enu)),
           sample_terms(samples),
           trajectory_model(model),
           trajectory_fit_options(opts)
         ) do
      {:ok, trajectory} -> {:ok, trajectory(trajectory)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Detect displacement step candidates.
  """
  @spec detect_steps([sample()], keyword() | StepDetectionOptions.t()) ::
          {:ok, [StepCandidate.t()]} | {:error, error_reason()}
  def detect_steps(samples, opts \\ []) do
    opts = options_map(opts)

    case NIF.geodetic_detect_steps(
           frame_term(Map.get(opts, :frame, :enu)),
           sample_terms(samples),
           step_options(opts)
         ) do
      {:ok, candidates} -> {:ok, Enum.map(candidates, &step_candidate/1)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Estimate a network motion field in one output frame.

  `origin` is `{lat_rad, lon_rad, height_m}` for the output local ENU frame.
  """
  @spec network_field([NetworkStation.t()], {number(), number(), number()}, keyword()) ::
          {:ok, MotionField.t()} | {:error, error_reason()}
  def network_field(stations, origin, opts \\ []) do
    frame = {geodetic(origin), Keyword.get(opts, :remove_common_mode, false)}

    case NIF.geodetic_network_field(Enum.map(stations, &network_station/1), frame) do
      {:ok, field} -> {:ok, motion_field(field)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp options_map(%MidasOptions{} = opts), do: Map.from_struct(opts)
  defp options_map(%TrajectoryFitOptions{} = opts), do: Map.from_struct(opts)
  defp options_map(%StepDetectionOptions{} = opts), do: Map.from_struct(opts)
  defp options_map(opts) when is_list(opts), do: Map.new(opts)
  defp options_map(opts) when is_map(opts), do: opts

  defp sample_terms(samples), do: Enum.map(samples, &sample_term/1)

  defp sample_term(%PositionSample{} = sample) do
    {sample.epoch_year / 1.0, vec3(sample.position_m), matrix_or_nil(sample.covariance_m2)}
  end

  defp sample_term({epoch_year, position_m}) do
    {epoch_year / 1.0, vec3(position_m), nil}
  end

  defp frame_term(:enu), do: {"enu", nil}
  defp frame_term({:ecef, reference}), do: {"ecef", geodetic(reference)}

  defp midas_options(opts) do
    {
      Map.get(opts, :dominant_period_years, 1.0) / 1.0,
      Map.get(opts, :period_tolerance_years, 0.001) / 1.0,
      Map.get(opts, :min_pairs, 3)
    }
  end

  defp trajectory_model(%TrajectoryModel{} = model) do
    {
      model.reference_epoch_year,
      model.include_annual,
      model.include_semiannual,
      Enum.map(model.offset_epochs_year, &(&1 / 1.0))
    }
  end

  defp trajectory_fit_options(opts) do
    {
      Map.get(opts, :loss, :linear) |> to_string(),
      Map.get(opts, :f_scale_m, 1.0) / 1.0,
      Map.get(opts, :max_nfev)
    }
  end

  defp step_options(%{midas: %MidasOptions{} = midas} = opts) do
    step_options(%{opts | midas: Map.from_struct(midas)})
  end

  defp step_options(opts) do
    {
      Map.get(opts, :window_years, 0.75) / 1.0,
      Map.get(opts, :score_threshold, 8.0) / 1.0,
      Map.get(opts, :min_offset_m, 1.0e-4) / 1.0,
      Map.get(opts, :min_samples_each_side, 4),
      Map.get(opts, :min_separation_years, 0.25) / 1.0,
      midas_options(Map.get(opts, :midas, %{}))
    }
  end

  defp network_station(%NetworkStation{} = station) do
    {
      station.id,
      geodetic(station.reference),
      frame_term(station.frame),
      sample_terms(station.samples)
    }
  end

  defp velocity(value) do
    %Velocity{
      rate_enu_m_per_yr: value.rate_enu_m_per_yr,
      sigma_enu_m_per_yr: value.sigma_enu_m_per_yr,
      covariance_enu_m2_per_yr2: value.covariance_enu_m2_per_yr2,
      component_stats: Enum.map(value.component_stats, &component_stats/1),
      sample_count: value.sample_count,
      span_years: value.span_years,
      quality: String.to_atom(value.quality)
    }
  end

  defp component_stats(value) do
    %MidasComponentStats{
      pair_count: value.pair_count,
      retained_pair_count: value.retained_pair_count,
      slope_sigma_m_per_yr: value.slope_sigma_m_per_yr,
      effective_pair_count: value.effective_pair_count
    }
  end

  defp trajectory(value) do
    %Trajectory{
      reference_epoch_year: value.reference_epoch_year,
      terms: value.terms,
      components: value.components,
      parameter_covariance: value.parameter_covariance,
      residual_rms_enu_m: value.residual_rms_enu_m,
      geometry_quality: value.geometry_quality,
      status: value.status,
      nfev: value.nfev,
      njev: value.njev,
      cost: value.cost,
      optimality: value.optimality
    }
  end

  defp step_candidate(value) do
    %StepCandidate{
      epoch_year: value.epoch_year,
      offset_enu_m: value.offset_enu_m,
      score: value.score,
      before_count: value.before_count,
      after_count: value.after_count,
      heuristic: String.to_atom(value.heuristic)
    }
  end

  defp motion_field(value) do
    %MotionField{
      origin: value.origin,
      remove_common_mode: value.remove_common_mode,
      stations: value.stations,
      common_mode_enu_m_per_yr: value.common_mode_enu_m_per_yr
    }
  end

  defp geodetic({lat_rad, lon_rad, height_m}), do: {lat_rad / 1.0, lon_rad / 1.0, height_m / 1.0}
  defp vec3({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}
  defp vec3([x, y, z]), do: {x / 1.0, y / 1.0, z / 1.0}
  defp matrix_or_nil(nil), do: nil
  defp matrix_or_nil(matrix), do: Enum.map(matrix, fn row -> Enum.map(row, &(&1 / 1.0)) end)
end
