defmodule Sidereon.GNSS.StaticPositioning do
  @moduledoc """
  Multi-epoch static GNSS single-point positioning.

  A static solve estimates one shared receiver ECEF position from several
  pseudorange epochs while fitting epoch-local receiver clocks. It is useful
  when a receiver is known to be stationary and the caller wants the stacked
  solution covariance, residuals, and leave-one-out influence diagnostics from
  the core solver.
  """

  alias Sidereon.Constants
  alias Sidereon.GeometryQuality
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  defmodule Solution do
    @moduledoc """
    Multi-epoch static receiver solution.

    `position` is the shared ITRF/IGS ECEF receiver position in metres.
    `per_epoch_clock` contains the fitted receiver clock for each epoch and
    constellation. `covariance` contains the full stacked state covariance plus
    ECEF and ENU position covariance blocks. Influence and residual fields are
    index-aligned to the input epochs and used measurements.
    """

    @enforce_keys [
      :position,
      :geodetic,
      :per_epoch_clock,
      :covariance,
      :per_epoch_influence,
      :per_satellite_influence,
      :per_satellite_batch_influence,
      :geometry_quality,
      :residuals_m,
      :used_sats,
      :rejected_sats,
      :metadata,
      :residual_rms_m
    ]
    defstruct [
      :position,
      :geodetic,
      :per_epoch_clock,
      :covariance,
      :per_epoch_influence,
      :per_satellite_influence,
      :per_satellite_batch_influence,
      :geometry_quality,
      :residuals_m,
      :used_sats,
      :rejected_sats,
      :metadata,
      :residual_rms_m
    ]

    @typedoc "ECEF receiver position in metres."
    @type position :: %{x_m: float(), y_m: float(), z_m: float()}

    @typedoc "Geodetic receiver position in radians and metres."
    @type geodetic :: %{lat_rad: float(), lon_rad: float(), height_m: float()}

    @typedoc "Epoch-local receiver clock estimate for one GNSS system."
    @type clock_bias :: %{epoch_index: non_neg_integer(), system: String.t(), clock_s: float()}

    @typedoc "Static solve covariance blocks."
    @type covariance :: %{
            state_m2: [[float()]],
            position_ecef_m2: [[float()]],
            position_enu_m2: [[float()]]
          }

    @typedoc "Core static solve iteration and model metadata."
    @type metadata :: %{
            iterations: non_neg_integer(),
            converged: boolean(),
            status: atom(),
            outer_iterations: non_neg_integer(),
            final_robust_scale_m: float() | nil,
            used_measurements: non_neg_integer(),
            n_parameters: non_neg_integer(),
            redundancy: integer()
          }

    @typedoc "Decoded multi-epoch static positioning solution."
    @type t :: %__MODULE__{
            position: position(),
            geodetic: geodetic() | nil,
            per_epoch_clock: [clock_bias()],
            covariance: covariance(),
            per_epoch_influence: [map()],
            per_satellite_influence: [map()],
            per_satellite_batch_influence: [map()],
            geometry_quality: GeometryQuality.t(),
            residuals_m: [map()],
            used_sats: [[String.t()]],
            rejected_sats: [[{String.t(), atom()}]],
            metadata: metadata(),
            residual_rms_m: float()
          }
  end

  @typedoc "One static epoch request."
  @type epoch_request ::
          %{
            required(:observations) => [Positioning.observation()],
            required(:epoch) => Positioning.epoch(),
            optional(:weights) => [number()],
            optional(:clock_initial_m) => number()
          }
          | {[Positioning.observation()], Positioning.epoch()}
          | {[Positioning.observation()], Positioning.epoch(), keyword()}

  @default_initial_position {0.0, 0.0, 0.0}
  @default_alpha {0.0, 0.0, 0.0, 0.0}
  @default_beta {0.0, 0.0, 0.0, 0.0}
  @default_pressure_hpa Constants.surface_met_pressure_hpa()
  @default_temperature_k Constants.surface_met_temperature_k()
  @default_relative_humidity Constants.surface_met_relative_humidity()
  @default_huber_k 1.345
  @default_huber_sigma 1.0
  @default_huber_max_iter 5

  @doc """
  Solve one static receiver position from multiple pseudorange epochs.

  `source` is a parsed SP3 precise product or broadcast navigation product.
  Each epoch supplies pseudorange observations and a receive epoch. Epoch options
  may override the solve-wide atmosphere, weights, clock seed, and GLONASS
  channel options for that epoch.

  Options:

    * `:initial_position` - shared `{x_m, y_m, z_m}` position seed, default
      `{0.0, 0.0, 0.0}`.
    * `:with_geodetic` - include geodetic output, default `true`.
    * `:ionosphere`, `:troposphere`, `:klobuchar_alpha`, `:klobuchar_beta`,
      `:pressure_hpa`, `:temperature_k`, `:relative_humidity`, and
      `:glonass_channels` match `Sidereon.GNSS.Positioning.solve/4`.
    * `:huber` plus `:huber_k`, `:huber_sigma`, and `:huber_max_iter` enables
      the core static Huber reweighting.

  Returns `{:ok, %Solution{}}` or `{:error, reason}` with typed static solve
  errors from the core.
  """
  @spec solve(SP3.t() | Broadcast.t(), [epoch_request()], keyword()) ::
          {:ok, Solution.t()} | {:error, term()}
  def solve(source, epochs, opts \\ [])

  def solve(%SP3{handle: handle}, epochs, opts) when is_list(epochs) do
    run_solve(:sp3, handle, epochs, opts)
  end

  def solve(%Broadcast{handle: handle}, epochs, opts) when is_list(epochs) do
    run_solve(:broadcast, handle, epochs, opts)
  end

  defp run_solve(source, handle, epochs, opts) do
    with {:ok, normalized_epochs} <- build_epochs(epochs, opts),
         {:ok, initial_position} <- initial_position(Keyword.get(opts, :initial_position, @default_initial_position)),
         {:ok, robust} <- robust_arg(opts) do
      nif =
        case source do
          :sp3 -> :static_positioning_solve_sp3
          :broadcast -> :static_positioning_solve_broadcast
        end

      NIF
      |> apply(nif, [handle, normalized_epochs, initial_position, Keyword.get(opts, :with_geodetic, true), robust])
      |> decode()
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp build_epochs(epochs, base_opts) do
    epochs
    |> Enum.reduce_while({:ok, []}, fn epoch, {:ok, acc} ->
      case build_epoch(epoch, base_opts) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _} = err -> err
    end
  end

  defp build_epoch({observations, epoch}, base_opts), do: build_epoch({observations, epoch, []}, base_opts)

  defp build_epoch({observations, epoch, epoch_opts}, base_opts) when is_list(epoch_opts) do
    build_epoch(%{observations: observations, epoch: epoch, opts: epoch_opts}, base_opts)
  end

  defp build_epoch(%{observations: observations, epoch: epoch} = request, base_opts) when is_list(observations) do
    opts = Keyword.merge(base_opts, Map.get(request, :opts, []))
    weights = Map.get(request, :weights, Keyword.get(opts, :weights))

    with {:ok, glonass_channels} <- validate_glonass_channels(Keyword.get(opts, :glonass_channels, %{})),
         {:ok, t_rx_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch),
         {:ok, weights} <- normalize_weights(weights),
         {:ok, alpha} <- tuple4(Keyword.get(opts, :klobuchar_alpha, @default_alpha), :klobuchar_alpha),
         {:ok, beta} <- tuple4(Keyword.get(opts, :klobuchar_beta, @default_beta), :klobuchar_beta),
         {:ok, pressure_hpa} <- number_option(Keyword.get(opts, :pressure_hpa, @default_pressure_hpa), :pressure_hpa),
         {:ok, temperature_k} <-
           number_option(Keyword.get(opts, :temperature_k, @default_temperature_k), :temperature_k),
         {:ok, relative_humidity} <-
           number_option(Keyword.get(opts, :relative_humidity, @default_relative_humidity), :relative_humidity),
         {:ok, clock_initial_m} <-
           number_option(Map.get(request, :clock_initial_m, Keyword.get(opts, :clock_initial_m, 0.0)), :clock_initial_m) do
      {:ok,
       %{
         observations: Enum.map(observations, fn {sat, pr} -> {sat, pr / 1.0} end),
         weights: weights,
         t_rx_j2000_s: t_rx_j2000_s,
         t_rx_second_of_day_s: Time.second_of_day(epoch),
         day_of_year: Time.day_of_year(epoch),
         clock_initial_m: clock_initial_m,
         apply_iono: Keyword.get(opts, :ionosphere, false),
         apply_tropo: Keyword.get(opts, :troposphere, false),
         alpha: alpha,
         beta: beta,
         pressure_hpa: pressure_hpa,
         temperature_k: temperature_k,
         relative_humidity: relative_humidity,
         glonass_channels: glonass_channels
       }}
    end
  end

  defp build_epoch(_epoch, _base_opts), do: {:error, :invalid_epoch}

  defp normalize_weights(nil), do: {:ok, nil}

  defp normalize_weights(weights) when is_list(weights) do
    if Enum.all?(weights, &is_number/1) do
      {:ok, Enum.map(weights, &(&1 / 1.0))}
    else
      {:error, {:invalid_option, :weights}}
    end
  end

  defp normalize_weights(_weights), do: {:error, {:invalid_option, :weights}}

  defp initial_position({x, y, z}) when is_number(x) and is_number(y) and is_number(z),
    do: {:ok, {x / 1.0, y / 1.0, z / 1.0}}

  defp initial_position([x, y, z]) when is_number(x) and is_number(y) and is_number(z),
    do: {:ok, {x / 1.0, y / 1.0, z / 1.0}}

  defp initial_position(_other), do: {:error, {:invalid_option, :initial_position}}

  defp robust_arg(opts) do
    case Keyword.get(opts, :huber, false) do
      false ->
        {:ok, nil}

      true ->
        with {:ok, k} <- number_option(Keyword.get(opts, :huber_k, @default_huber_k), :huber_k),
             {:ok, sigma} <- number_option(Keyword.get(opts, :huber_sigma, @default_huber_sigma), :huber_sigma),
             {:ok, max_iter} <-
               positive_integer_option(Keyword.get(opts, :huber_max_iter, @default_huber_max_iter), :huber_max_iter) do
          {:ok, {k, sigma, max_iter}}
        end

      _other ->
        {:error, {:invalid_option, :huber}}
    end
  end

  defp validate_glonass_channels(channels) when is_map(channels) do
    if Enum.all?(channels, fn
         {slot, ch}
         when is_integer(slot) and slot >= 0 and slot <= 255 and is_integer(ch) and ch >= -128 and
                ch <= 127 ->
           true

         _ ->
           false
       end) do
      {:ok, Enum.sort(Map.to_list(channels))}
    else
      {:error, {:invalid_option, :glonass_channels}}
    end
  end

  defp validate_glonass_channels(_other), do: {:error, {:invalid_option, :glonass_channels}}

  defp decode({:ok, body}), do: {:ok, decode_solution(body)}
  defp decode({:error, reason}), do: {:error, reason}
  defp decode(other), do: {:error, other}

  defp decode_solution(
         {position, geodetic, per_epoch_clock, covariance, per_epoch_influence, per_satellite_influence,
          per_satellite_batch_influence, geometry_quality, residuals, used_sats, rejected_sats, metadata,
          residual_rms_m}
       ) do
    %Solution{
      position: position_map(position),
      geodetic: geodetic_map(geodetic),
      per_epoch_clock: Enum.map(per_epoch_clock, &clock_map/1),
      covariance: covariance_map(covariance),
      per_epoch_influence: Enum.map(per_epoch_influence, &epoch_influence_map/1),
      per_satellite_influence: Enum.map(per_satellite_influence, &satellite_influence_map/1),
      per_satellite_batch_influence: Enum.map(per_satellite_batch_influence, &satellite_batch_influence_map/1),
      geometry_quality: GeometryQuality.from_nif(geometry_quality),
      residuals_m: Enum.map(residuals, &residual_map/1),
      used_sats: used_sats,
      rejected_sats: rejected_sats,
      metadata: metadata_map(metadata),
      residual_rms_m: residual_rms_m
    }
  end

  defp position_map({x, y, z}), do: %{x_m: x, y_m: y, z_m: z}
  defp geodetic_map(nil), do: nil
  defp geodetic_map({lat, lon, h}), do: %{lat_rad: lat, lon_rad: lon, height_m: h}
  defp clock_map({epoch_index, system, clock_s}), do: %{epoch_index: epoch_index, system: system, clock_s: clock_s}

  defp covariance_map({state_m2, ecef_m2, enu_m2}),
    do: %{state_m2: state_m2, position_ecef_m2: ecef_m2, position_enu_m2: enu_m2}

  defp epoch_influence_map(
         {epoch_index, omitted_measurements, status, delta, delta_norm_m, residual_rms_m, min_robust_weight_ratio}
       ) do
    %{
      epoch_index: epoch_index,
      omitted_measurements: omitted_measurements,
      status: status,
      position_delta_m: delta,
      position_delta_norm_m: delta_norm_m,
      residual_rms_m: residual_rms_m,
      min_robust_weight_ratio: min_robust_weight_ratio
    }
  end

  defp satellite_influence_map(
         {epoch_index, satellite_id, status, delta, delta_norm_m, residual_rms_m, residual_m, base_weight,
          effective_weight, robust_weight_ratio}
       ) do
    %{
      epoch_index: epoch_index,
      satellite_id: satellite_id,
      status: status,
      position_delta_m: delta,
      position_delta_norm_m: delta_norm_m,
      residual_rms_m: residual_rms_m,
      residual_m: residual_m,
      base_weight: base_weight,
      effective_weight: effective_weight,
      robust_weight_ratio: robust_weight_ratio
    }
  end

  defp satellite_batch_influence_map(
         {satellite_id, omitted_measurements, status, delta, delta_norm_m, residual_rms_m, min_robust_weight_ratio}
       ) do
    %{
      satellite_id: satellite_id,
      omitted_measurements: omitted_measurements,
      status: status,
      position_delta_m: delta,
      position_delta_norm_m: delta_norm_m,
      residual_rms_m: residual_rms_m,
      min_robust_weight_ratio: min_robust_weight_ratio
    }
  end

  defp residual_map({epoch_index, satellite_id, residual_m, base_weight, effective_weight, robust_weight_ratio}) do
    %{
      epoch_index: epoch_index,
      satellite_id: satellite_id,
      residual_m: residual_m,
      base_weight: base_weight,
      effective_weight: effective_weight,
      robust_weight_ratio: robust_weight_ratio
    }
  end

  defp metadata_map(
         {iterations, converged, status, outer_iterations, final_robust_scale_m, used_measurements, n_parameters,
          redundancy}
       ) do
    %{
      iterations: iterations,
      converged: converged,
      status: status,
      outer_iterations: outer_iterations,
      final_robust_scale_m: final_robust_scale_m,
      used_measurements: used_measurements,
      n_parameters: n_parameters,
      redundancy: redundancy
    }
  end

  defp number_option(value, _option) when is_number(value), do: {:ok, value / 1.0}
  defp number_option(_value, option), do: {:error, {:invalid_option, option}}

  defp positive_integer_option(value, _option) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer_option(_value, option), do: {:error, {:invalid_option, option}}

  defp tuple4({a, b, c, d}, option), do: tuple4([a, b, c, d], option)

  defp tuple4([a, b, c, d], _option) when is_number(a) and is_number(b) and is_number(c) and is_number(d),
    do: {:ok, {a / 1.0, b / 1.0, c / 1.0, d / 1.0}}

  defp tuple4(_value, option), do: {:error, {:invalid_option, option}}
end
