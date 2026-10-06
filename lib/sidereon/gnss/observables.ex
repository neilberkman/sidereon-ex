defmodule Sidereon.GNSS.Observables do
  @moduledoc """
  Predict the GNSS observables a receiver at a known ECEF position would see for
  a satellite, from a precise (SP3) or broadcast ephemeris source.

  This is the forward model behind the question "is this measurement physically
  plausible?": given a receiver position, a satellite, and a receive epoch, it
  computes the geometric range, the line-of-sight range rate, the L1 Doppler,
  the topocentric azimuth/elevation, the satellite clock offset, and the signal
  transmit time. The Rust core evaluates the loaded SP3 or broadcast ephemeris
  handle and applies standard textbook GNSS geometry; this module keeps only the
  Elixir API shape and result mapping. It never solves the inverse
  (positioning) problem.

  ## Algorithm (standard GNSS geometry)

  * **Light-time / transmit-time correction.** The signal seen at the receive
    epoch `t_rx` left the satellite earlier, at
    `t_tx = t_rx - |r_sat(t_tx) - r_rx| / c`. This is solved by fixed-point
    iteration starting from `t_tx = t_rx`; a couple of iterations converge to
    sub-millimetre level for a coarse receiver position. The satellite state is
    evaluated at the fractional epoch `t_tx` (the SP3 spline is sampled at
    sub-second precision).

  * **Sagnac / Earth-rotation correction.** During the travel time `tau` the
    Earth-fixed (ECEF) frame rotates by `omega_e * tau`. The satellite position
    computed in the ECEF frame at `t_tx` is rotated about the Z axis by
    `Rz(omega_e * tau)` into the receive-epoch ECEF frame before differencing,
    with `omega_e = 7.2921151467e-5 rad/s`. This is the Sagnac (Earth-rotation)
    correction.

  * **Geometric range** is `|r_sat_rot - r_rx|` in metres, and the
    line-of-sight unit vector points from the receiver to the satellite.

  * **Range rate.** The satellite velocity at `t_tx` is the source's own where it
    defines one: for a broadcast source, the difference of the selected
    record's positions at `t_tx` and 1 ms later over 1 ms, as RTKLIB `ephpos`
    forms it. For an SP3 source it is the central finite difference of
    `Sidereon.GNSS.SP3.position/3` (+/- 0.5 s). For a static
    receiver (`v_rx = 0`) the range rate is the LOS projection
    `los . (v_sat - v_rx)`, which equals `d(range)/dt`.

  * **Doppler (IS-GPS-200 L1 carrier).** `doppler_hz = -range_rate * f / c`
    with the L1 carrier `f = 1575.42 MHz` and `c = 299792458 m/s`.

  ## Sign conventions

  ## Satellite clock terms

  `sat_clock_s` is the clock the source states at `t_tx`. A broadcast clock is
  the one RTKLIB `satposs` returns: the clock polynomial and the relativistic
  term, without the broadcast group delay. Two further terms describe what a
  single-frequency positioning model does with that clock, as
  `Sidereon.GNSS.Positioning.solve/4` applies them:

    * `sat_clock_relativity_s` - the relativistic term `-2 r·v / c²` a model
      adds to a product clock (SP3), as RTKLIB `peph2pos` forms it for
      positioning; `:not_applicable` for a clock that carries its own term
      (broadcast), and `:unavailable` where the term cannot be formed, within
      1 ms of the end of the product's coverage.
    * `single_frequency_group_delay_s` - the broadcast group delay (GPS and
      QZSS TGD, Galileo BGD, BeiDou TGD1) a model subtracts from the clock for
      a single-frequency pseudorange, as RTKLIB `prange` does; `nil` for a
      precise clock.

  `range_rate_m_s` is the time derivative of the geometric range: it is
  **negative when the satellite is approaching** (range decreasing) and positive
  when receding. The Doppler shift is the negative of the (scaled) range rate, so
  an **approaching satellite gives a positive Doppler** and a receding satellite
  a negative one.

  ## Result map

      %{
        geometric_range_m: float(),    # metres
        range_rate_m_s:    float(),    # d(range)/dt; negative = approaching
        doppler_hz:        float(),    # = -range_rate * carrier / c; + = approaching
        sat_clock_s:       float() | nil,  # source clock offset at transmit time
        sat_clock_relativity_s: float() | :not_applicable | :unavailable,
        single_frequency_group_delay_s: float() | nil,
        elevation_deg:     float(),    # topocentric elevation
        azimuth_deg:       float(),    # topocentric azimuth, [0, 360)
        transmit_time:     NaiveDateTime.t(),  # t_tx
        los_unit:          {float(), float(), float()},  # receiver -> satellite, ECEF unit
        sat_pos_ecef_m:    {float(), float(), float()},  # Sagnac-rotated sat position
        sat_velocity_m_s:  {float(), float(), float()}   # Sagnac-rotated sat velocity
      }
  """

  alias Sidereon.Constants, as: SidereonConstants
  alias Sidereon.GNSS.{Broadcast, PreciseEphemeris, SP3, Time}
  alias Sidereon.GNSS.Core.Constants
  alias Sidereon.GNSS.Core.Types
  alias Sidereon.GNSS.PreciseEphemeris.Interpolant
  alias Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @type vec3 :: {float(), float(), float()}

  @type observables :: %{
          geometric_range_m: float(),
          range_rate_m_s: float(),
          doppler_hz: float(),
          sat_clock_s: float() | nil,
          sat_clock_relativity_s: float() | :not_applicable | :unavailable,
          single_frequency_group_delay_s: float() | nil,
          elevation_deg: float(),
          azimuth_deg: float(),
          transmit_time: NaiveDateTime.t(),
          los_unit: vec3(),
          sat_pos_ecef_m: vec3(),
          sat_velocity_m_s: vec3()
        }

  @typedoc "Structured error detail returned by the additive detailed prediction API."
  @type ionex_missing_nodes_detail :: %{
          map_number: non_neg_integer(),
          lat_index: non_neg_integer(),
          lon_index: non_neg_integer(),
          lon_index_next: non_neg_integer(),
          missing: [boolean()]
        }

  @typedoc """
  Structured core causes. `mapping_function_declaration` is `Absent` or
  `Declared`; `mapping_function_kind` is `NoMapping`, `CosZ`, `QFactor`, or
  `Other` when declared, and `nil` when absent.
  """
  @type core_cause_detail :: %{
          family: String.t(),
          kind: String.t(),
          message: String.t(),
          satellite: String.t() | nil,
          nodes: non_neg_integer() | nil,
          required: non_neg_integer() | nil,
          input_message: String.t() | nil,
          coverage_reason: String.t() | nil,
          earlier_missing_nodes: ionex_missing_nodes_detail() | nil,
          later_missing_nodes: ionex_missing_nodes_detail() | nil,
          refusal_kind: String.t() | nil,
          map_number: non_neg_integer() | nil,
          latitude_index: non_neg_integer() | nil,
          longitude_index: non_neg_integer() | nil,
          mapping_function_declaration: String.t() | nil,
          mapping_function_kind: String.t() | nil,
          mapping_function_code: String.t() | nil
        }

  @type elixir_input_cause_detail :: %{
          family: String.t(),
          kind: String.t(),
          message: String.t(),
          raw: term()
        }

  @type prediction_error :: %{
          family: String.t(),
          kind: String.t(),
          message: String.t(),
          field: String.t() | nil,
          reason: term() | nil,
          input_kind: String.t() | nil,
          cause: core_cause_detail() | elixir_input_cause_detail() | nil
        }

  @doc """
  Predict the observables for `satellite_id` seen from `receiver_ecef` at `epoch`.

  `receiver_ecef` is the static receiver position in ITRF/ECEF metres, given as
  `{x_m, y_m, z_m}` or `%{x_m: _, y_m: _, z_m: _}`. `epoch` is the receive epoch,
  a `NaiveDateTime` (interpreted in the ephemeris source's own time scale).

  ## Options

    * `:carrier_hz` - carrier frequency for the Doppler, default the L1 carrier
      `1575.42 MHz`.
    * `:light_time` - apply the light-time / transmit-time correction, default
      `true`. When `false`, the satellite is evaluated at `epoch`.
    * `:sagnac` - apply the Sagnac / Earth-rotation correction, default `true`.
    * `:extrapolate` - for SP3 sources, allow evaluation outside the parsed
      product coverage. Default `false`.

  Returns `{:ok, observables}`, `{:error, :invalid_receiver}` for a malformed
  receiver position, or propagates any ephemeris position error (e.g. an unknown
  satellite or a malformed satellite token) verbatim as
  `{:error, reason}`. Never raises.
  """
  @spec predict(SP3.t() | Broadcast.t(), String.t(), vec3() | map(), NaiveDateTime.t(), keyword()) ::
          {:ok, observables()} | {:error, term()}
  def predict(source, satellite_id, receiver_ecef, epoch, opts \\ [])

  def predict(%SP3{} = source, satellite_id, receiver_ecef, %NaiveDateTime{} = epoch, opts)
      when is_binary(satellite_id) do
    do_predict(source, satellite_id, receiver_ecef, epoch, opts)
  end

  def predict(%Broadcast{} = source, satellite_id, receiver_ecef, %NaiveDateTime{} = epoch, opts)
      when is_binary(satellite_id) do
    do_predict(source, satellite_id, receiver_ecef, epoch, opts)
  end

  @doc """
  Predict observables and retain the structured cause of native prediction errors.

  The result uses the same success map as `predict/5`; failures from the core
  include the observable field and validation category or a nested core error
  detail map. The existing `predict/5` return values are unchanged.
  """
  @spec predict_detailed(
          SP3.t() | Broadcast.t(),
          String.t(),
          vec3() | map(),
          NaiveDateTime.t(),
          keyword()
        ) :: {:ok, observables()} | {:error, prediction_error()}
  def predict_detailed(source, satellite_id, receiver_ecef, epoch, opts \\ [])

  def predict_detailed(%SP3{} = source, satellite_id, receiver_ecef, %NaiveDateTime{} = epoch, opts)
      when is_binary(satellite_id), do: do_predict_detailed(source, satellite_id, receiver_ecef, epoch, opts)

  def predict_detailed(%Broadcast{} = source, satellite_id, receiver_ecef, %NaiveDateTime{} = epoch, opts)
      when is_binary(satellite_id), do: do_predict_detailed(source, satellite_id, receiver_ecef, epoch, opts)

  defp do_predict_detailed(source, satellite_id, receiver_ecef, epoch, opts) do
    carrier_hz = Keyword.get(opts, :carrier_hz, Constants.gps_l1_hz())
    light_time? = Keyword.get(opts, :light_time, true)
    sagnac? = Keyword.get(opts, :sagnac, true)

    result =
      with {:ok, receiver} <- Types.normalize_ecef(receiver_ecef),
           {:ok, system_letter, prn} <- Types.parse_sat_id(satellite_id),
           :ok <- validate_source_coverage(source, epoch, opts),
           {:ok, raw} <-
             core_predict_detailed(
               source,
               system_letter,
               prn,
               receiver,
               epoch,
               carrier_hz,
               light_time?,
               sagnac?
             ) do
        {:ok, to_observables_map(raw, epoch)}
      end

    case result do
      {:error, %{family: _family, kind: _kind} = detail} -> {:error, detail}
      {:error, reason} -> {:error, detailed_input_error(reason)}
      other -> other
    end
  end

  defp do_predict(source, satellite_id, receiver_ecef, epoch, opts) do
    carrier_hz = Keyword.get(opts, :carrier_hz, Constants.gps_l1_hz())
    light_time? = Keyword.get(opts, :light_time, true)
    sagnac? = Keyword.get(opts, :sagnac, true)

    with {:ok, receiver} <- Types.normalize_ecef(receiver_ecef),
         {:ok, system_letter, prn} <- Types.parse_sat_id(satellite_id),
         :ok <- validate_source_coverage(source, epoch, opts),
         {:ok, result} <-
           core_predict(
             source,
             system_letter,
             prn,
             receiver,
             epoch,
             carrier_hz,
             light_time?,
             sagnac?
           ) do
      {:ok, to_observables_map(result, epoch)}
    end
  end

  @doc """
  Predict observables for every satellite in the product, seen from `receiver_ecef`.

  Returns a map `satellite_id => {:ok, observables} | {:error, reason}`, so one
  satellite failing (e.g. no estimate at this epoch) does not sink the batch.
  Options are the same as `predict/5`.
  """
  @spec predict_all(SP3.t(), vec3() | map(), NaiveDateTime.t(), keyword()) ::
          %{optional(String.t()) => {:ok, observables()} | {:error, term()}}
  def predict_all(%SP3{} = sp3, receiver_ecef, %NaiveDateTime{} = epoch, opts \\ []) do
    sp3
    |> SP3.satellite_ids()
    |> Map.new(fn sat_id -> {sat_id, predict(sp3, sat_id, receiver_ecef, epoch, opts)} end)
  end

  @doc """
  Predict observables for many `{satellite_id, receiver_ecef, epoch}` requests
  against one loaded SP3 product in a single NIF call.

  Each request is fully independent (its own satellite, receiver, and epoch), so
  one batch can mix many satellites, receivers, and epochs. The result list is
  index-aligned with `requests`: element `i` is `{:ok, observables}` or
  `{:error, reason}` for `requests[i]`, so one bad request does not sink the
  batch. The valid requests are predicted as a batch inside the core (one
  boundary crossing); options are the same as `predict/5`.
  """
  @spec predict_batch(SP3.t(), [{String.t(), vec3() | map(), NaiveDateTime.t()}], keyword()) ::
          [{:ok, observables()} | {:error, term()}]
  def predict_batch(%SP3{handle: handle}, requests, opts \\ []) when is_list(requests) do
    carrier_hz = Keyword.get(opts, :carrier_hz, Constants.gps_l1_hz())
    light_time? = Keyword.get(opts, :light_time, true)
    sagnac? = Keyword.get(opts, :sagnac, true)

    prepared = Enum.map(requests, &prepare_batch_request/1)
    nif_requests = for {:ok, {tuple, _epoch}} <- prepared, do: tuple

    nif_results =
      case nif_requests do
        [] -> []
        _ -> NIF.sp3_predict_batch(handle, nif_requests, carrier_hz, light_time?, sagnac?)
      end

    stitch_batch(prepared, nif_results)
  rescue
    e in ErlangError ->
      error = NifCall.error(e, __STACKTRACE__, :sp3_predict_batch)
      Enum.map(requests, fn _ -> error end)
  end

  @doc "Predict a request batch with one structured result per original request."
  @spec predict_batch_detailed(
          SP3.t(),
          [{String.t(), vec3() | map(), NaiveDateTime.t()}],
          keyword()
        ) :: [{:ok, observables()} | {:error, prediction_error()}]
  def predict_batch_detailed(%SP3{handle: handle}, requests, opts \\ []) when is_list(requests) do
    carrier_hz = Keyword.get(opts, :carrier_hz, Constants.gps_l1_hz())
    light_time? = Keyword.get(opts, :light_time, true)
    sagnac? = Keyword.get(opts, :sagnac, true)
    prepared = Enum.map(requests, &prepare_batch_request/1)
    nif_requests = for {:ok, {tuple, _epoch}} <- prepared, do: tuple

    nif_results =
      case nif_requests do
        [] -> []
        _ -> NIF.sp3_predict_batch_detailed(handle, nif_requests, carrier_hz, light_time?, sagnac?)
      end

    stitch_batch_detailed(prepared, nif_results)
  rescue
    e in ErlangError ->
      detail = detailed_input_error(NifCall.error(e, __STACKTRACE__, :sp3_predict_batch_detailed))
      Enum.map(requests, fn _ -> {:error, detail} end)
  end

  # Normalize one batch request into the NIF tuple plus the epoch (kept for the
  # transmit-time reconstruction), or surface the per-request error.
  defp prepare_batch_request({satellite_id, receiver_ecef, %NaiveDateTime{} = epoch}) when is_binary(satellite_id) do
    with {:ok, receiver} <- Types.normalize_ecef(receiver_ecef),
         {:ok, system_letter, prn} <- Types.parse_sat_id(satellite_id),
         {:ok, {jd_whole, jd_fraction}} <- Time.epoch_to_split_jd(epoch) do
      {:ok, {{system_letter, prn, jd_whole, jd_fraction, receiver}, epoch}}
    end
  end

  defp prepare_batch_request(_request), do: {:error, :invalid_request}

  # Walk the prepared requests, consuming one core result per valid request so
  # the returned list stays index-aligned with the input.
  defp stitch_batch([], _results), do: []
  defp stitch_batch([{:error, _reason} = err | rest], results), do: [err | stitch_batch(rest, results)]

  defp stitch_batch([{:ok, {_tuple, epoch}} | rest], [result | results]) do
    decoded =
      case result do
        {:ok, raw} -> {:ok, to_observables_map(raw, epoch)}
        {:error, _reason} = err -> err
      end

    [decoded | stitch_batch(rest, results)]
  end

  defp stitch_batch_detailed([], _results), do: []

  defp stitch_batch_detailed([{:error, reason} | rest], results),
    do: [{:error, detailed_input_error(reason)} | stitch_batch_detailed(rest, results)]

  defp stitch_batch_detailed([{:ok, {_tuple, epoch}} | rest], [result | results]) do
    decoded =
      case result do
        {:ok, raw} -> {:ok, to_observables_map(raw, epoch)}
        {:error, %{family: _family, kind: _kind} = detail} -> {:error, detail}
        {:error, reason} -> {:error, detailed_input_error(reason)}
      end

    [decoded | stitch_batch_detailed(rest, results)]
  end

  defp stitch_batch_detailed([{:ok, {_tuple, _epoch}} | rest], []),
    do: [{:error, detailed_input_error(:missing_prediction_result)} | stitch_batch_detailed(rest, [])]

  @type range_request :: {String.t(), vec3() | map(), number()}

  @type range_result :: %{
          geometric_range_m: float(),
          sat_clock_s: float() | nil,
          transmit_time_j2000_s: float(),
          sat_pos_ecef_m: vec3()
        }

  @typedoc "One emission-media request, `{satellite_id, emission_epoch_j2000_s}`."
  @type emission_media_request :: {String.t(), number()}

  @typedoc "Index-aligned emission-state and media-delay arrays."
  @type emission_media_batch :: %{
          positions_ecef_m: [vec3() | nil],
          clocks_s: [float() | nil],
          ionosphere_slant_delays_m: [float() | nil],
          troposphere_delays_m: [float() | nil],
          statuses: [:valid | :gap | :below_elevation_cutoff | :error],
          element_errors: [term() | nil]
        }

  @type detailed_emission_media_batch :: %{
          positions_ecef_m: [vec3() | nil],
          clocks_s: [float() | nil],
          ionosphere_slant_delays_m: [float() | nil],
          troposphere_delays_m: [float() | nil],
          statuses: [:valid | :gap | :below_elevation_cutoff | :error],
          element_errors: [prediction_error() | nil]
        }

  @doc """
  Predict geometry-only ranges for many `{satellite_id, receiver_ecef, t_rx_j2000_s}`
  requests against one precise-ephemeris source in a single NIF call.

  `source` is a loaded `Sidereon.GNSS.SP3` product, a
  `Sidereon.GNSS.PreciseEphemeris` sample-built source, or a
  `Sidereon.GNSS.PreciseEphemeris.Interpolant` cached source. Each request
  carries its own satellite token, static receiver ECEF position
  (`{x_m, y_m, z_m}` or `%{x_m: _, y_m: _, z_m: _}`), and receive epoch as
  **seconds since J2000 in the source's own time scale**.

  This is the transmit-time geometry a range-only consumer needs, without the
  Doppler / topocentric fields of `predict/5`. On success returns
  `{:ok, results}` where each result is a map:

      %{
        geometric_range_m:      float(),         # metres, after light-time + Sagnac
        sat_clock_s:            float() | nil,   # satellite clock at transmit time
        transmit_time_j2000_s:  float(),         # transmit epoch, seconds since J2000
        sat_pos_ecef_m:         {float(), float(), float()}  # Sagnac-transported sat position
      }

  The core range batch aborts on the first failing request, so a malformed
  request or an ephemeris error (unknown satellite, epoch out of coverage)
  returns `{:error, reason}` for the whole call. Never raises.

  ## Options

    * `:light_time` - apply the light-time / transmit-time correction, default
      `true`. When `false`, the satellite is evaluated at the receive epoch.
    * `:sagnac` - apply the Sagnac / Earth-rotation correction, default `true`.
  """
  @spec predict_ranges(
          SP3.t() | PreciseEphemeris.t() | Interpolant.t() | InterpolantArtifact.t(),
          [range_request()],
          keyword()
        ) ::
          {:ok, [range_result()]} | {:error, term()}
  def predict_ranges(source, requests, opts \\ []) when is_list(requests) do
    light_time? = Keyword.get(opts, :light_time, true)
    sagnac? = Keyword.get(opts, :sagnac, true)

    with {:ok, handle} <- source_handle(source),
         {:ok, nif_requests} <- prepare_range_requests(requests) do
      case NIF.predict_ranges_batch(handle, nif_requests, light_time?, sagnac?) do
        {:ok, rows} -> {:ok, Enum.map(rows, &to_range_map/1)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :predict_ranges_batch)
  end

  @typedoc """
  The transmit-time geometry of a pseudorange as the positioning models place
  it. See `pseudorange_transmit_geometry/6`.
  """
  @type pseudorange_geometry :: %{
          transmit_time_j2000_s: float(),
          signal_flight_time_s: float(),
          transmit_offset_us: integer(),
          sat_clock_s: float() | nil,
          sat_clock_relativity_s: float() | :not_applicable | :unavailable,
          single_frequency_group_delay_s: float() | nil,
          geometric_range_m: float(),
          elevation_deg: float(),
          azimuth_deg: float(),
          sat_pos_ecef_m: vec3(),
          los_unit: vec3()
        }

  @doc """
  The transmit-time geometry of `satellite_id`'s pseudorange `pseudorange_m`,
  time-tagged `epoch` by a receiver at `receiver_ecef`, placed as SPP, the
  static solve, DGNSS and PPP place it (RTKLIB `satposs`).

  The transmission epoch is `t_rx - P / c` less the satellite clock read there,
  from the record selected at the reception epoch, so the receiver clock offset
  the pseudorange carries places the satellite where the signal left it. The
  geometry is the source's state at that epoch, not rotated: the range is
  `|r_s - r_r|` plus the Sagnac term `ω (x_s y_r - y_s x_r) / c` (RTKLIB
  `geodist`), and the line of sight, elevation and azimuth are those of the
  unrotated vector. `signal_flight_time_s` is `t_rx - t_tx`, which holds both
  clock offsets with the flight time.

  `epoch` is the receiver's time tag, a `NaiveDateTime` in the source's time
  scale, converted to seconds since J2000 as the positioning solves convert
  it. `sat_clock_relativity_s` and `single_frequency_group_delay_s` are the
  terms a single-frequency model applies to `sat_clock_s` at the transmission
  epoch, as in `predict/5`.

  `source` is an SP3 product, a broadcast store, a precise-sample source or a
  precise interpolant. `pseudorange_m` has to be a positive finite distance.

  ## Options

    * `:sagnac` - add the Sagnac term, default `true`.
  """
  @spec pseudorange_transmit_geometry(
          SP3.t() | Broadcast.t() | PreciseEphemeris.t() | Interpolant.t() | InterpolantArtifact.t(),
          String.t(),
          {number(), number(), number()} | %{x_m: number(), y_m: number(), z_m: number()},
          NaiveDateTime.t(),
          number(),
          keyword()
        ) :: {:ok, pseudorange_geometry()} | {:error, term()}
  def pseudorange_transmit_geometry(source, satellite_id, receiver_ecef, epoch, pseudorange_m, opts \\ [])
      when is_number(pseudorange_m) do
    sagnac? = Keyword.get(opts, :sagnac, true)

    with {:ok, handle} <- placement_source_handle(source),
         {:ok, receiver} <- Types.normalize_ecef(receiver_ecef),
         {:ok, system_letter, prn} <- Types.parse_sat_id(satellite_id),
         {:ok, t_rx_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      case NIF.observables_pseudorange_transmit_geometry(
             handle,
             system_letter,
             prn,
             receiver,
             t_rx_j2000_s,
             pseudorange_m / 1.0,
             sagnac?
           ) do
        {:ok, result} -> {:ok, to_pseudorange_geometry(result)}
        {:error, _} = err -> err
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :observables_pseudorange_transmit_geometry)
  end

  defp placement_source_handle(%Broadcast{handle: handle}), do: {:ok, handle}
  defp placement_source_handle(source), do: source_handle(source)

  defp to_pseudorange_geometry(
         {[
            transmit_time_j2000_s,
            signal_flight_time_s,
            transmit_offset_us,
            sat_clock_s,
            geometric_range_m,
            elevation_deg,
            azimuth_deg,
            sat_clock_relativity,
            single_frequency_group_delay_s
          ], [sat_pos, los]}
       ) do
    %{
      transmit_time_j2000_s: transmit_time_j2000_s,
      signal_flight_time_s: signal_flight_time_s,
      transmit_offset_us: transmit_offset_us,
      sat_clock_s: sat_clock_s,
      sat_clock_relativity_s: sat_clock_relativity,
      single_frequency_group_delay_s: single_frequency_group_delay_s,
      geometric_range_m: geometric_range_m,
      elevation_deg: elevation_deg,
      azimuth_deg: azimuth_deg,
      sat_pos_ecef_m: sat_pos,
      los_unit: los
    }
  end

  defp source_handle(%SP3{handle: handle}), do: {:ok, handle}
  defp source_handle(%PreciseEphemeris{handle: handle}), do: {:ok, handle}
  defp source_handle(%Interpolant{handle: handle}), do: {:ok, handle}
  defp source_handle(%InterpolantArtifact{interpolant: %Interpolant{handle: handle}}), do: {:ok, handle}
  defp source_handle(_source), do: {:error, :invalid_source}

  defp prepare_range_requests(requests) do
    requests
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, acc} ->
      case prepare_range_request(request) do
        {:ok, tuple} -> {:cont, {:ok, [tuple | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, tuples} -> {:ok, Enum.reverse(tuples)}
      {:error, _} = err -> err
    end
  end

  defp prepare_range_request({satellite_id, receiver_ecef, t_rx_j2000_s})
       when is_binary(satellite_id) and is_number(t_rx_j2000_s) do
    with {:ok, {x, y, z}} <- Types.normalize_ecef(receiver_ecef),
         {:ok, system_letter, prn} <- Types.parse_sat_id(satellite_id) do
      {:ok, {system_letter, prn, {x, y, z}, t_rx_j2000_s * 1.0}}
    end
  end

  defp prepare_range_request(_request), do: {:error, :invalid_request}

  defp to_range_map({geometric_range_m, sat_clock_s, transmit_time_j2000_s, sat_pos_ecef_m}) do
    %{
      geometric_range_m: geometric_range_m,
      sat_clock_s: sat_clock_s,
      transmit_time_j2000_s: transmit_time_j2000_s,
      sat_pos_ecef_m: sat_pos_ecef_m
    }
  end

  @doc """
  Predict emission-epoch satellite states and media delays in one batch call.

  Each request is `{satellite_id, emission_epoch_j2000_s}`. The source is a
  parsed SP3 product, a sample-built precise source, or any
  `Sidereon.GNSS.PreciseEphemeris.Interpolant`, including one opened from
  artifact bytes. The output is a map of index-aligned arrays:

      %{
        positions_ecef_m: [vec3() | nil],
        clocks_s: [float() | nil],
        ionosphere_slant_delays_m: [float() | nil],
        troposphere_delays_m: [float() | nil],
        statuses: [:valid | :gap | :below_elevation_cutoff | :error],
        element_errors: [term() | nil]
      }

  Options:

    * `:carrier_hz` - carrier frequency for ionospheric group delay, default
      GPS L1.
    * `:troposphere` - `false`, `true`, or a keyword list with `:pressure_hpa`,
      `:temperature_k`, and `:relative_humidity`.
    * `:ionosphere` - `nil`, `{:klobuchar, alpha, beta}`,
      `{:klobuchar, %{alpha: alpha, beta: beta}}`, or `{:ionex, handle}`.
    * `:min_elevation_deg` - optional minimum receiver elevation. Rows below
      the cutoff keep state and clock outputs but have nil media delays.
  """
  @spec emission_media_batch(
          SP3.t() | PreciseEphemeris.t() | Interpolant.t() | InterpolantArtifact.t(),
          [emission_media_request()],
          vec3() | map(),
          keyword()
        ) :: {:ok, emission_media_batch()} | {:error, term()}
  def emission_media_batch(source, requests, receiver_ecef, opts \\ []) when is_list(requests) do
    do_emission_media_batch(source, requests, receiver_ecef, opts, false)
  end

  @doc """
  Like `emission_media_batch/4`, with typed cause maps for each failed row in
  `element_errors`. The legacy API keeps its existing error representation.
  """
  @spec emission_media_batch_detailed(
          SP3.t() | PreciseEphemeris.t() | Interpolant.t() | InterpolantArtifact.t(),
          [emission_media_request()],
          vec3() | map(),
          keyword()
        ) :: {:ok, detailed_emission_media_batch()} | {:error, term()}
  def emission_media_batch_detailed(source, requests, receiver_ecef, opts \\ []) when is_list(requests) do
    do_emission_media_batch(source, requests, receiver_ecef, opts, true)
  end

  defp do_emission_media_batch(source, requests, receiver_ecef, opts, detailed?) do
    with {:ok, handle} <- source_handle(source),
         {:ok, nif_requests} <- prepare_emission_requests(requests),
         {:ok, receiver} <- Types.normalize_ecef(receiver_ecef),
         {:ok, carrier_hz} <- emission_number(Keyword.get(opts, :carrier_hz, Constants.gps_l1_hz()), :carrier_hz),
         {:ok, troposphere} <- emission_troposphere(Keyword.get(opts, :troposphere, false), opts),
         {:ok, ionosphere} <- emission_ionosphere(Keyword.get(opts, :ionosphere)),
         {:ok, min_elevation_rad} <- min_elevation_rad(Keyword.get(opts, :min_elevation_deg)) do
      result =
        if detailed? do
          NIF.emission_media_batch_detailed(
            handle,
            nif_requests,
            receiver,
            carrier_hz / 1.0,
            troposphere,
            ionosphere,
            min_elevation_rad
          )
        else
          NIF.emission_media_batch(
            handle,
            nif_requests,
            receiver,
            carrier_hz / 1.0,
            troposphere,
            ionosphere,
            min_elevation_rad
          )
        end

      case result do
        {:ok, tuple} -> {:ok, emission_media_map(tuple)}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :emission_media_batch)
  end

  defp prepare_emission_requests(requests) do
    requests
    |> Enum.reduce_while({:ok, []}, fn request, {:ok, acc} ->
      case prepare_emission_request(request) do
        {:ok, tuple} -> {:cont, {:ok, [tuple | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, tuples} -> {:ok, Enum.reverse(tuples)}
      {:error, _} = err -> err
    end
  end

  defp prepare_emission_request({satellite_id, emission_epoch_j2000_s})
       when is_binary(satellite_id) and is_number(emission_epoch_j2000_s) do
    with {:ok, system_letter, prn} <- Types.parse_sat_id(satellite_id) do
      {:ok, {system_letter, prn, emission_epoch_j2000_s / 1.0}}
    end
  end

  defp prepare_emission_request(_request), do: {:error, :invalid_request}

  defp emission_troposphere(false, _opts), do: {:ok, nil}
  defp emission_troposphere(nil, _opts), do: {:ok, nil}

  defp emission_troposphere(true, opts) do
    emission_met_tuple(opts)
  end

  defp emission_troposphere(tropo_opts, _opts) when is_list(tropo_opts) do
    emission_met_tuple(tropo_opts)
  end

  defp emission_troposphere(_other, _opts), do: {:error, {:invalid_option, :troposphere}}

  defp emission_met_tuple(opts) do
    with {:ok, pressure_hpa} <-
           emission_number(Keyword.get(opts, :pressure_hpa, SidereonConstants.surface_met_pressure_hpa()), :troposphere),
         {:ok, temperature_k} <-
           emission_number(
             Keyword.get(opts, :temperature_k, SidereonConstants.surface_met_temperature_k()),
             :troposphere
           ),
         {:ok, relative_humidity} <-
           emission_number(
             Keyword.get(opts, :relative_humidity, SidereonConstants.surface_met_relative_humidity()),
             :troposphere
           ) do
      {:ok, {pressure_hpa, temperature_k, relative_humidity}}
    end
  end

  defp emission_ionosphere(nil), do: {:ok, nil}
  defp emission_ionosphere(false), do: {:ok, nil}

  defp emission_ionosphere({:klobuchar, %{alpha: alpha, beta: beta}}),
    do: emission_ionosphere({:klobuchar, alpha, beta})

  defp emission_ionosphere({:klobuchar, alpha, beta}) do
    with {:ok, alpha} <- emission_tuple4(alpha, :ionosphere),
         {:ok, beta} <- emission_tuple4(beta, :ionosphere) do
      {:ok, {"klobuchar", alpha, beta}}
    end
  end

  defp emission_ionosphere({:ionex, handle}) when is_reference(handle), do: {:ok, {"ionex", handle}}

  defp emission_ionosphere(_other), do: {:error, {:invalid_option, :ionosphere}}

  defp min_elevation_rad(nil), do: {:ok, nil}

  defp min_elevation_rad(deg) when is_number(deg), do: {:ok, deg / 1.0 * :math.pi() / 180.0}

  defp min_elevation_rad(_other), do: {:error, {:invalid_option, :min_elevation_deg}}

  defp emission_number(value, _option) when is_number(value), do: {:ok, value / 1.0}
  defp emission_number(_value, option), do: {:error, {:invalid_option, option}}

  defp emission_media_map({positions, clocks, ionosphere_slant_delays, troposphere_delays, statuses, element_errors}) do
    %{
      positions_ecef_m: positions,
      clocks_s: clocks,
      ionosphere_slant_delays_m: ionosphere_slant_delays,
      troposphere_delays_m: troposphere_delays,
      statuses: statuses,
      element_errors: element_errors
    }
  end

  defp core_predict(%SP3{handle: handle}, system_letter, prn, receiver, epoch, carrier_hz, light_time?, sagnac?) do
    with {:ok, {jd_whole, jd_fraction}} <- Time.epoch_to_split_jd(epoch) do
      case NIF.sp3_observables(
             handle,
             system_letter,
             prn,
             jd_whole,
             jd_fraction,
             receiver,
             carrier_hz,
             light_time?,
             sagnac?
           ) do
        {:ok, result} -> {:ok, result}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_observables)
  end

  defp core_predict(%Broadcast{handle: handle}, system_letter, prn, receiver, epoch, carrier_hz, light_time?, sagnac?) do
    with {:ok, t_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      case NIF.broadcast_observables(
             handle,
             system_letter,
             prn,
             t_j2000_s,
             receiver,
             carrier_hz,
             light_time?,
             sagnac?
           ) do
        {:ok, result} -> {:ok, result}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :broadcast_observables)
  end

  defp core_predict_detailed(
         %SP3{handle: handle},
         system_letter,
         prn,
         receiver,
         epoch,
         carrier_hz,
         light_time?,
         sagnac?
       ) do
    with {:ok, {jd_whole, jd_fraction}} <- Time.epoch_to_split_jd(epoch) do
      case NIF.sp3_observables_detailed(
             handle,
             system_letter,
             prn,
             jd_whole,
             jd_fraction,
             receiver,
             carrier_hz,
             light_time?,
             sagnac?
           ) do
        {:ok, result} -> {:ok, result}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sp3_observables_detailed)
  end

  defp core_predict_detailed(
         %Broadcast{handle: handle},
         system_letter,
         prn,
         receiver,
         epoch,
         carrier_hz,
         light_time?,
         sagnac?
       ) do
    with {:ok, t_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      case NIF.broadcast_observables_detailed(
             handle,
             system_letter,
             prn,
             t_j2000_s,
             receiver,
             carrier_hz,
             light_time?,
             sagnac?
           ) do
        {:ok, result} -> {:ok, result}
        {:error, _} = err -> err
        other -> {:error, other}
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :broadcast_observables_detailed)
  end

  defp detailed_input_error(reason) do
    {kind, message, field, input_kind} =
      case reason do
        :invalid_receiver -> {"INVALID_RECEIVER", "receiver ECEF input is invalid", "receiver_ecef", nil}
        {:bad_sat_id, _value} -> {"BAD_SATELLITE_ID", "satellite identifier is invalid", "satellite_id", nil}
        :outside_coverage -> {"OUTSIDE_COVERAGE", "epoch is outside source coverage", "epoch", nil}
        other -> {"INPUT_ERROR", inspect(other), nil, nil}
      end

    %{
      family: "ElixirInputError",
      kind: kind,
      message: message,
      field: field,
      reason: reason,
      input_kind: input_kind,
      cause: %{family: "ElixirInputError", kind: kind, message: message, raw: reason}
    }
  end

  defp to_observables_map(
         {[
            range,
            range_rate,
            doppler_hz,
            sat_clock_s,
            elevation_deg,
            azimuth_deg,
            transmit_offset_us,
            _transmit_time_j2000_s,
            sat_clock_relativity,
            single_frequency_group_delay_s
          ], [los, sat_pos, sat_velocity]},
         epoch
       ) do
    transmit_time =
      if transmit_offset_us == 0 do
        epoch
      else
        NaiveDateTime.add(epoch, -transmit_offset_us, :microsecond)
      end

    %{
      geometric_range_m: range,
      range_rate_m_s: range_rate,
      doppler_hz: doppler_hz,
      sat_clock_s: sat_clock_s,
      sat_clock_relativity_s: sat_clock_relativity,
      single_frequency_group_delay_s: single_frequency_group_delay_s,
      elevation_deg: elevation_deg,
      azimuth_deg: azimuth_deg,
      transmit_time: transmit_time,
      los_unit: los,
      sat_pos_ecef_m: sat_pos,
      sat_velocity_m_s: sat_velocity
    }
  end

  defp validate_source_coverage(%SP3{} = sp3, epoch, opts) do
    if extrapolate?(opts) or SP3.covers_epoch?(sp3, epoch) do
      :ok
    else
      {:error, :outside_coverage}
    end
  end

  defp validate_source_coverage(_source, _epoch, _opts), do: :ok

  defp extrapolate?(opts) when is_list(opts), do: Keyword.get(opts, :extrapolate, false) == true
  defp extrapolate?(_opts), do: false

  defp emission_tuple4({a, b, c, d}, option), do: emission_tuple4([a, b, c, d], option)

  defp emission_tuple4([a, b, c, d], _option) when is_number(a) and is_number(b) and is_number(c) and is_number(d),
    do: {:ok, {a / 1.0, b / 1.0, c / 1.0, d / 1.0}}

  defp emission_tuple4(_value, option), do: {:error, {:invalid_option, option}}
end
