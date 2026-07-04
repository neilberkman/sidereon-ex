defmodule Sidereon.SourceLocalization.Sensor do
  @moduledoc """
  Sensor with a known Cartesian position.

  `position_m` is a 2D or 3D Cartesian coordinate in metres. All sensors in one
  solve must use the same dimension. `propagation_speed_m_s` optionally
  overrides the call-level speed for this sensor.
  """

  @enforce_keys [:position_m]
  defstruct [:position_m, :propagation_speed_m_s]

  @type t :: %__MODULE__{
          position_m: [float()],
          propagation_speed_m_s: float() | nil
        }

  @doc """
  Build a sensor from a 2D or 3D position in metres.
  """
  @spec new([number()] | tuple(), number() | nil) :: t()
  def new(position_m, propagation_speed_m_s \\ nil) do
    %__MODULE__{
      position_m: Sidereon.SourceLocalization.position_to_list!(position_m),
      propagation_speed_m_s: maybe_float(propagation_speed_m_s)
    }
  end

  defp maybe_float(nil), do: nil
  defp maybe_float(value), do: value / 1.0
end

defmodule Sidereon.SourceLocalization.Options do
  @moduledoc """
  Options for ToA or TDOA source localization.

  `mode` is `:toa` or `{:tdoa, reference_sensor_index}`. Timing sigma is seconds
  and controls covariance, CRLB, and influence-score scaling. `loss` is one of
  `:linear`, `:huber`, `:soft_l1`, `:cauchy`, or `:arctan`; `f_scale_s` is the
  residual scale in seconds for non-linear losses. Tolerances and `max_nfev`
  are passed through to the trust-region solver when set.
  """

  defstruct mode: :toa,
            timing_sigma_s: 1.0,
            loss: :linear,
            f_scale_s: 1.0,
            ftol: nil,
            xtol: nil,
            gtol: nil,
            max_nfev: nil

  @type solve_mode :: :toa | {:tdoa, non_neg_integer()}
  @type loss :: :linear | :huber | :soft_l1 | :cauchy | :arctan

  @type t :: %__MODULE__{
          mode: solve_mode(),
          timing_sigma_s: float(),
          loss: loss(),
          f_scale_s: float(),
          ftol: float() | nil,
          xtol: float() | nil,
          gtol: float() | nil,
          max_nfev: pos_integer() | nil
        }
end

defmodule Sidereon.SourceLocalization.InitialGuess do
  @moduledoc """
  Closed-form seed used to start a source-localization solve.

  Position is metres. Origin time and residual RMS are seconds.
  """

  @enforce_keys [:position_m, :origin_time_s, :residual_rms_s]
  defstruct [:position_m, :origin_time_s, :residual_rms_s]

  @type t :: %__MODULE__{
          position_m: [float()],
          origin_time_s: float() | nil,
          residual_rms_s: float()
        }
end

defmodule Sidereon.SourceLocalization.Covariance do
  @moduledoc """
  State covariance or CRLB from a source-localization solve.

  `state` is in solver state order. `position_m2` is the position block in square
  metres. `origin_time_s2` is square seconds when the origin time is part of the
  state. `timing_sigma_s` is the timing standard deviation used for scaling.
  """

  @enforce_keys [:state, :position_m2, :origin_time_s2, :timing_sigma_s]
  defstruct [:state, :position_m2, :origin_time_s2, :timing_sigma_s]

  @type matrix :: [[float()]]
  @type t :: %__MODULE__{
          state: matrix(),
          position_m2: matrix(),
          origin_time_s2: float() | nil,
          timing_sigma_s: float()
        }
end

defmodule Sidereon.SourceLocalization.Residual do
  @moduledoc """
  Solver residual associated with a sensor row.

  `reference_sensor_index` is `nil` for ToA and set for TDOA residuals.
  Residuals are seconds.
  """

  @enforce_keys [:sensor_index, :reference_sensor_index, :residual_s]
  defstruct [:sensor_index, :reference_sensor_index, :residual_s]

  @type t :: %__MODULE__{
          sensor_index: non_neg_integer(),
          reference_sensor_index: non_neg_integer() | nil,
          residual_s: float()
        }
end

defmodule Sidereon.SourceLocalization.SensorInfluence do
  @moduledoc """
  Per-sensor leave-one-out diagnostic.

  Residual and origin-time fields are seconds. Position delta is metres. Larger
  score means a poorer fit under the selected timing sigma and loss.
  """

  @enforce_keys [
    :sensor_index,
    :residual_s,
    :leave_one_out_residual_s,
    :position_delta_m,
    :origin_time_delta_s,
    :loss_weight,
    :score
  ]
  defstruct [
    :sensor_index,
    :residual_s,
    :leave_one_out_residual_s,
    :position_delta_m,
    :origin_time_delta_s,
    :loss_weight,
    :score
  ]

  @type t :: %__MODULE__{
          sensor_index: non_neg_integer(),
          residual_s: float(),
          leave_one_out_residual_s: float() | nil,
          position_delta_m: float() | nil,
          origin_time_delta_s: float() | nil,
          loss_weight: float(),
          score: float()
        }
end

defmodule Sidereon.SourceLocalization.GeometryQuality do
  @moduledoc """
  Rank and redundancy summary for a source-localization solve.

  Counts are row and parameter counts from the timing design. `rank_deficient`
  is true when covariance was not available from the normal matrix.
  """

  @enforce_keys [
    :residual_count,
    :parameter_count,
    :redundancy,
    :covariance_available,
    :rank_deficient
  ]
  defstruct [
    :residual_count,
    :parameter_count,
    :redundancy,
    :covariance_available,
    :rank_deficient
  ]

  @type t :: %__MODULE__{
          residual_count: non_neg_integer(),
          parameter_count: non_neg_integer(),
          redundancy: non_neg_integer(),
          covariance_available: boolean(),
          rank_deficient: boolean()
        }
end

defmodule Sidereon.SourceLocalization.Solution do
  @moduledoc """
  Source-localization solution.

  Position is a 2D or 3D Cartesian coordinate in metres. Origin time and
  residuals are seconds. The covariance, when present, is scaled by the timing
  sigma in the options.
  """

  alias Sidereon.SourceLocalization.Covariance
  alias Sidereon.SourceLocalization.GeometryQuality
  alias Sidereon.SourceLocalization.InitialGuess
  alias Sidereon.SourceLocalization.Residual
  alias Sidereon.SourceLocalization.SensorInfluence

  @enforce_keys [
    :position_m,
    :origin_time_s,
    :covariance,
    :residuals,
    :per_sensor_influence,
    :geometry_quality,
    :initial_guess,
    :status,
    :nfev,
    :njev,
    :cost,
    :optimality
  ]
  defstruct [
    :position_m,
    :origin_time_s,
    :covariance,
    :residuals,
    :per_sensor_influence,
    :geometry_quality,
    :initial_guess,
    :status,
    :nfev,
    :njev,
    :cost,
    :optimality
  ]

  @type t :: %__MODULE__{
          position_m: [float()],
          origin_time_s: float() | nil,
          covariance: Covariance.t() | nil,
          residuals: [Residual.t()],
          per_sensor_influence: [SensorInfluence.t()],
          geometry_quality: GeometryQuality.t(),
          initial_guess: InitialGuess.t(),
          status: integer(),
          nfev: non_neg_integer(),
          njev: non_neg_integer(),
          cost: float(),
          optimality: float()
        }
end

defmodule Sidereon.SourceLocalization.Crlb do
  @moduledoc """
  Timing CRLB and DOP for a proposed source and sensor geometry.

  DOP values multiply timing sigma in seconds to produce metres for position
  terms. Covariance is scaled by the requested timing sigma.
  """

  alias Sidereon.SourceLocalization.Covariance

  @enforce_keys [:dop, :covariance]
  defstruct [:dop, :covariance]

  @type dop :: %{gdop: float(), pdop: float(), hdop: float(), vdop: float(), tdop: float()}
  @type t :: %__MODULE__{dop: dop(), covariance: Covariance.t()}
end

defmodule Sidereon.SourceLocalization do
  @moduledoc """
  Source localization from time of arrival or time difference of arrival.

  Sensors are fixed 2D or 3D Cartesian positions in metres. Arrival times and
  origin times are seconds. The propagation speed is metres per second, with an
  optional per-sensor override for simple per-path timing differences.
  """

  alias Sidereon.NIF
  alias Sidereon.SourceLocalization.Covariance
  alias Sidereon.SourceLocalization.Crlb
  alias Sidereon.SourceLocalization.GeometryQuality
  alias Sidereon.SourceLocalization.InitialGuess
  alias Sidereon.SourceLocalization.Options
  alias Sidereon.SourceLocalization.Residual
  alias Sidereon.SourceLocalization.Sensor
  alias Sidereon.SourceLocalization.SensorInfluence
  alias Sidereon.SourceLocalization.Solution

  @type source_error ::
          {:invalid_input, String.t(), String.t()}
          | {:too_few_sensors, non_neg_integer(), pos_integer()}
          | :initializer_singular
          | {:geometry, term()}
          | {:solver, String.t()}
          | {:did_not_converge, integer()}

  @doc """
  Convenience constructor for `Sidereon.SourceLocalization.Sensor`.
  """
  @spec sensor([number()] | tuple(), number() | nil) :: Sensor.t()
  def sensor(position_m, propagation_speed_m_s \\ nil), do: Sensor.new(position_m, propagation_speed_m_s)

  @doc """
  Locate a source from sensor arrival times.

  `sensors` is a list of `Sensor` structs. `arrival_times_s` must have matching
  length. `propagation_speed_m_s` is the default propagation speed in metres per
  second. Options are a keyword list or `Sidereon.SourceLocalization.Options`.
  """
  @spec locate_source([Sensor.t()], [number()], number(), keyword() | Options.t()) ::
          {:ok, Solution.t()} | {:error, source_error() | :invalid_sensor | :invalid_position | :invalid_options}
  def locate_source(sensors, arrival_times_s, propagation_speed_m_s, opts \\ [])
      when is_list(sensors) and is_list(arrival_times_s) do
    with {:ok, sensor_terms} <- sensor_terms(sensors),
         {:ok, options_term} <- options_term(opts) do
      case NIF.source_localization_locate(
             sensor_terms,
             Enum.map(arrival_times_s, &(&1 / 1.0)),
             propagation_speed_m_s / 1.0,
             options_term
           ) do
        {:ok, tuple} -> {:ok, solution_from_tuple(tuple)}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Compute the closed-form Chan-Ho seed used by `locate_source/4`.

  `mode` is `:toa` or `{:tdoa, reference_sensor_index}`.
  """
  @spec chan_ho_initial_guess([Sensor.t()], [number()], number(), Options.solve_mode()) ::
          {:ok, InitialGuess.t()} | {:error, source_error() | :invalid_sensor | :invalid_mode}
  def chan_ho_initial_guess(sensors, arrival_times_s, propagation_speed_m_s, mode \\ :toa)
      when is_list(sensors) and is_list(arrival_times_s) do
    with {:ok, sensor_terms} <- sensor_terms(sensors),
         {:ok, mode_term} <- mode_term(mode) do
      case NIF.source_localization_chan_ho_initial_guess(
             sensor_terms,
             Enum.map(arrival_times_s, &(&1 / 1.0)),
             propagation_speed_m_s / 1.0,
             mode_term
           ) do
        {:ok, tuple} -> {:ok, initial_guess_from_tuple(tuple)}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Compute timing DOP for a proposed source location.

  The returned DOP values use the local Cartesian axes for horizontal and
  vertical split. Position DOP values multiply timing sigma in seconds to
  produce metres.
  """
  @spec source_dop([Sensor.t()], [number()] | tuple(), number()) ::
          {:ok, Crlb.dop()} | {:error, source_error() | :invalid_sensor | :invalid_position}
  def source_dop(sensors, source_position_m, propagation_speed_m_s) when is_list(sensors) do
    with {:ok, sensor_terms} <- sensor_terms(sensors),
         {:ok, position} <- position_to_list(source_position_m) do
      case NIF.source_localization_dop(sensor_terms, position, propagation_speed_m_s / 1.0) do
        {:ok, tuple} -> {:ok, dop_from_tuple(tuple)}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Compute a timing Cramer-Rao lower bound for a proposed source location.

  `timing_sigma_s` is the timing standard deviation in seconds used to scale the
  covariance.
  """
  @spec source_crlb([Sensor.t()], [number()] | tuple(), number(), number()) ::
          {:ok, Crlb.t()} | {:error, source_error() | :invalid_sensor | :invalid_position}
  def source_crlb(sensors, source_position_m, propagation_speed_m_s, timing_sigma_s) when is_list(sensors) do
    with {:ok, sensor_terms} <- sensor_terms(sensors),
         {:ok, position} <- position_to_list(source_position_m) do
      case NIF.source_localization_crlb(
             sensor_terms,
             position,
             propagation_speed_m_s / 1.0,
             timing_sigma_s / 1.0
           ) do
        {:ok, tuple} -> {:ok, crlb_from_tuple(tuple)}
        {:error, _} = err -> err
      end
    end
  end

  @doc false
  @spec position_to_list!([number()] | tuple()) :: [float()]
  def position_to_list!(position) do
    case position_to_list(position) do
      {:ok, list} -> list
      {:error, reason} -> raise ArgumentError, "invalid source-localization position: #{inspect(reason)}"
    end
  end

  defp sensor_terms(sensors) do
    sensors
    |> Enum.reduce_while({:ok, []}, fn sensor, {:ok, acc} ->
      case sensor_term(sensor) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _} = err -> err
    end
  end

  defp sensor_term(%Sensor{position_m: position_m, propagation_speed_m_s: speed}) do
    with {:ok, position} <- position_to_list(position_m) do
      {:ok, {position, maybe_float(speed)}}
    end
  end

  defp sensor_term(_sensor), do: {:error, :invalid_sensor}

  defp options_term(%Options{} = options) do
    with {:ok, mode} <- mode_term(options.mode),
         {:ok, loss} <- loss_string(options.loss) do
      {:ok,
       {{mode, options.timing_sigma_s / 1.0, loss, options.f_scale_s / 1.0},
        {maybe_float(options.ftol), maybe_float(options.xtol), maybe_float(options.gtol), options.max_nfev}}}
    end
  end

  defp options_term(opts) when is_list(opts) do
    options_term(%Options{
      mode: Keyword.get(opts, :mode, :toa),
      timing_sigma_s: Keyword.get(opts, :timing_sigma_s, 1.0),
      loss: Keyword.get(opts, :loss, :linear),
      f_scale_s: Keyword.get(opts, :f_scale_s, 1.0),
      ftol: Keyword.get(opts, :ftol),
      xtol: Keyword.get(opts, :xtol),
      gtol: Keyword.get(opts, :gtol),
      max_nfev: Keyword.get(opts, :max_nfev)
    })
  end

  defp options_term(_opts), do: {:error, :invalid_options}

  defp mode_term(:toa), do: {:ok, {"toa", 0}}
  defp mode_term({:tdoa, reference}) when is_integer(reference) and reference >= 0, do: {:ok, {"tdoa", reference}}
  defp mode_term(_mode), do: {:error, :invalid_mode}

  defp loss_string(loss) when loss in [:linear, :huber, :soft_l1, :cauchy, :arctan], do: {:ok, Atom.to_string(loss)}

  defp loss_string(_loss), do: {:error, :invalid_options}

  defp position_to_list({x, y}), do: position_to_list([x, y])
  defp position_to_list({x, y, z}), do: position_to_list([x, y, z])

  defp position_to_list(values) when is_list(values) and length(values) in 2..3 do
    if Enum.all?(values, &is_number/1) do
      {:ok, Enum.map(values, &(&1 / 1.0))}
    else
      {:error, :invalid_position}
    end
  end

  defp position_to_list(_position), do: {:error, :invalid_position}

  defp maybe_float(nil), do: nil
  defp maybe_float(value) when is_number(value), do: value / 1.0

  defp solution_from_tuple(
         {{position_m, origin_time_s, covariance, residuals, influences, geometry_quality, initial_guess},
          {status, nfev, njev, cost, optimality}}
       ) do
    %Solution{
      position_m: position_m,
      origin_time_s: origin_time_s,
      covariance: covariance_from_tuple(covariance),
      residuals: Enum.map(residuals, &residual_from_tuple/1),
      per_sensor_influence: Enum.map(influences, &influence_from_tuple/1),
      geometry_quality: geometry_quality_from_tuple(geometry_quality),
      initial_guess: initial_guess_from_tuple(initial_guess),
      status: status,
      nfev: nfev,
      njev: njev,
      cost: cost,
      optimality: optimality
    }
  end

  defp covariance_from_tuple(nil), do: nil

  defp covariance_from_tuple({state, position_m2, origin_time_s2, timing_sigma_s}) do
    %Covariance{
      state: state,
      position_m2: position_m2,
      origin_time_s2: origin_time_s2,
      timing_sigma_s: timing_sigma_s
    }
  end

  defp residual_from_tuple({sensor_index, reference_sensor_index, residual_s}) do
    %Residual{
      sensor_index: sensor_index,
      reference_sensor_index: reference_sensor_index,
      residual_s: residual_s
    }
  end

  defp influence_from_tuple(
         {sensor_index, residual_s, leave_one_out_residual_s, position_delta_m, origin_time_delta_s, loss_weight, score}
       ) do
    %SensorInfluence{
      sensor_index: sensor_index,
      residual_s: residual_s,
      leave_one_out_residual_s: leave_one_out_residual_s,
      position_delta_m: position_delta_m,
      origin_time_delta_s: origin_time_delta_s,
      loss_weight: loss_weight,
      score: score
    }
  end

  defp geometry_quality_from_tuple({residual_count, parameter_count, redundancy, covariance_available, rank_deficient}) do
    %GeometryQuality{
      residual_count: residual_count,
      parameter_count: parameter_count,
      redundancy: redundancy,
      covariance_available: covariance_available,
      rank_deficient: rank_deficient
    }
  end

  defp initial_guess_from_tuple({position_m, origin_time_s, residual_rms_s}) do
    %InitialGuess{
      position_m: position_m,
      origin_time_s: origin_time_s,
      residual_rms_s: residual_rms_s
    }
  end

  defp crlb_from_tuple({dop, covariance}) do
    %Crlb{
      dop: dop_from_tuple(dop),
      covariance: covariance_from_tuple(covariance)
    }
  end

  defp dop_from_tuple({gdop, pdop, hdop, vdop, tdop}) do
    %{gdop: gdop, pdop: pdop, hdop: hdop, vdop: vdop, tdop: tdop}
  end
end
