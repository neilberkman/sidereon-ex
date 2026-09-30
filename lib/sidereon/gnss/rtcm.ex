defmodule Sidereon.GNSS.RTCM do
  @moduledoc """
  RTCM 3.x differential-GNSS stream decoding.

  RTCM 10403.x is the dominant wire format for real-time GNSS correction and
  observation streams. This module is a thin wrapper over the `sidereon-core`
  `rtcm` sans-I/O decoder: a forgiving frame layer that syncs on the `0xD3`
  preamble and verifies the CRC-24Q, and a canonical message decoder.

  `decode_messages/1` scans a whole byte buffer and returns every CRC-valid
  message; `decode_frame/1` decodes the single frame at the start of a buffer.

  ## Message format

  Each decoded message is a `{type, fields}` pair where `type` is one of
  `:station_coordinates` (1005/1006), `:antenna_descriptor` (1007/1008/1033),
  `:legacy_observations`, `:system_parameters`, `:text`,
  `:network_auxiliary_station`, `:network_correction_differences`,
  `:helmert_transformation`, `:residual_grid`, `:projection`,
  `:network_residuals`, `:physical_reference_station`, `:fkp_gradients`,
  `:gps_ephemeris` (1019), `:glonass_ephemeris` (1020), `:beidou_ephemeris`
  (1042), `:qzss_ephemeris` (1044), `:galileo_fnav_ephemeris` (1045),
  `:galileo_inav_ephemeris` (1046), `:navic_ephemeris` (1041),
  `:glonass_code_phase_biases` (1230),
  `:msm` (MSM1–MSM7 observations), `:ssr` (an SSR message retained as its
  message number and body), `:ssr_vtec` (RTCM 1264 or IGS SSR 4076 subtype 201),
  or `:unsupported` (any
  other number, preserved verbatim). The `fields` map carries raw transmitted
  integer fields for field-mapped variants. Legacy observations expose their
  header and nested satellite measurements as fields. System parameters, text,
  and network auxiliary-station records also expose their retained wire fields.
  Network correction differences, transformation parameters and residual grids,
  projection parameters, network residuals, physical reference stations, and
  FKP gradients expose their transmitted fields and nested records as maps.
  Station coordinates additionally carry the scaled `:x_m` / `:y_m` / `:z_m` /
  `:antenna_height_m` values.

  Station coordinates, antenna descriptors, the six ephemerides and MSM
  messages carry `:trailing_bits`, every body bit after the last field as a list
  of booleans, kept when those bits are anything other than fewer than eight
  zeros (read under the `:lenient` policy only, empty otherwise). MSM messages
  carry `:signal_mask`, the DF395 signal mask as transmitted, since a listed
  signal may have no cell. GLONASS ephemerides carry `:negative_zero`, the
  bitmask of sign-magnitude fields transmitted as negative zero, each read as
  `0`. When a message is built by hand, `:trailing_bits` defaults to `[]`,
  `:negative_zero` to `0`, and a `nil` or absent `:signal_mask` to the mask of
  the cells' signals.

  ## Policy

  `:strict` (the default) refuses input that departs from RTCM 3: frame
  reserved bits that are not zero, bits after a message's last field other
  than fewer than eight zero bits, an MSM cell mask over 64 bits, and an SSR
  body shorter than the records its header counts. `:lenient` reads or writes
  such input and reports each departure as `{:frame_reserved_bits, reserved}`,
  `{:trailing_bits, message_number, bits}`,
  `{:msm_cell_mask_over_64, message_number, cells}` or
  `{:ssr_records_short, message_number, declared, read}`.
  """

  alias Sidereon.NIF
  alias Sidereon.NifCall

  @type message_type ::
          :station_coordinates
          | :antenna_descriptor
          | :legacy_observations
          | :system_parameters
          | :text
          | :network_auxiliary_station
          | :network_correction_differences
          | :helmert_transformation
          | :residual_grid
          | :projection
          | :network_residuals
          | :physical_reference_station
          | :fkp_gradients
          | :gps_ephemeris
          | :glonass_ephemeris
          | :beidou_ephemeris
          | :qzss_ephemeris
          | :galileo_fnav_ephemeris
          | :galileo_inav_ephemeris
          | :navic_ephemeris
          | :glonass_code_phase_biases
          | :msm
          | :ssr
          | :ssr_vtec
          | :unsupported
  @type message :: {message_type(), map()}
  @typedoc "A transmitted satellite correction-difference record."
  @type network_difference_record :: %{
          satellite_id: non_neg_integer(),
          ambiguity_status: non_neg_integer(),
          non_sync_count: non_neg_integer(),
          geometric: integer() | nil,
          iod: non_neg_integer() | nil,
          ionospheric: integer() | nil
        }
  @typedoc "A transmitted network correction-differences message."
  @type network_correction_differences :: %{
          message_number: non_neg_integer(),
          network_id: non_neg_integer(),
          subnetwork_id: non_neg_integer(),
          epoch_time: non_neg_integer(),
          multiple_message: boolean(),
          master_station_id: non_neg_integer(),
          auxiliary_station_id: non_neg_integer(),
          satellite_count: non_neg_integer(),
          satellites: [network_difference_record()],
          trailing_bits: [boolean()]
        }
  @type rotation_point :: %{x: integer(), y: integer(), z: integer()}
  @type helmert_transformation :: %{
          message_number: 1021 | 1022,
          source_name: String.t(),
          target_name: String.t(),
          system_id: non_neg_integer(),
          utilized_messages: non_neg_integer(),
          plate_number: non_neg_integer(),
          computation_indicator: non_neg_integer(),
          height_indicator: non_neg_integer(),
          validity_latitude: integer(),
          validity_longitude: integer(),
          validity_extension_latitude: non_neg_integer(),
          validity_extension_longitude: non_neg_integer(),
          dx: integer(),
          dy: integer(),
          dz: integer(),
          r1: integer(),
          r2: integer(),
          r3: integer(),
          ds: integer(),
          rotation_point: rotation_point() | nil,
          add_as: non_neg_integer(),
          add_bs: non_neg_integer(),
          add_at: non_neg_integer(),
          add_bt: non_neg_integer(),
          horizontal_quality: non_neg_integer(),
          vertical_quality: non_neg_integer(),
          trailing_bits: [boolean()]
        }
  @type grid_residual :: %{horizontal_1: integer(), horizontal_2: integer(), height: integer()}
  @type residual_grid :: %{
          message_number: 1023 | 1024,
          system_id: non_neg_integer(),
          horizontal_shift: boolean(),
          vertical_shift: boolean(),
          origin_1: integer(),
          origin_2: integer(),
          extension_1: non_neg_integer(),
          extension_2: non_neg_integer(),
          mean_offset_1: integer(),
          mean_offset_2: integer(),
          mean_height_offset: integer(),
          residuals: [grid_residual()],
          horizontal_interpolation: non_neg_integer(),
          vertical_interpolation: non_neg_integer(),
          horizontal_quality: non_neg_integer(),
          vertical_quality: non_neg_integer(),
          mjd: non_neg_integer(),
          trailing_bits: [boolean()]
        }
  @type projection :: %{
          message_number: 1025 | 1026 | 1027,
          system_id: non_neg_integer(),
          projection_type: non_neg_integer(),
          parameter_kind: String.t(),
          latitude: integer() | nil,
          longitude: integer() | nil,
          add_scale: integer() | nil,
          false_easting: integer() | nil,
          false_northing: integer() | nil,
          standard_parallel_1: integer() | nil,
          standard_parallel_2: integer() | nil,
          rectification: boolean() | nil,
          azimuth: integer() | nil,
          rectified_to_skew: integer() | nil,
          easting: integer() | nil,
          northing: integer() | nil,
          trailing_bits: [boolean()]
        }
  @type network_residual_record :: %{
          satellite_id: non_neg_integer(),
          s_oc: non_neg_integer(),
          s_od: non_neg_integer(),
          s_oh: non_neg_integer(),
          s_lc: non_neg_integer(),
          s_ld: non_neg_integer()
        }
  @type network_residuals :: %{
          message_number: 1030 | 1031,
          epoch_time: non_neg_integer(),
          reference_station_id: non_neg_integer(),
          reference_station_count: non_neg_integer(),
          satellite_count: non_neg_integer(),
          satellites: [network_residual_record()],
          trailing_bits: [boolean()]
        }
  @type physical_reference_station :: %{
          message_number: 1032,
          non_physical_station_id: non_neg_integer(),
          physical_station_id: non_neg_integer(),
          itrf_realization_year: non_neg_integer(),
          ecef_x: integer(),
          ecef_y: integer(),
          ecef_z: integer(),
          trailing_bits: [boolean()]
        }
  @type fkp_gradient_record :: %{
          satellite_id: non_neg_integer(),
          iod: non_neg_integer(),
          geometric_north: integer(),
          geometric_east: integer(),
          ionospheric_north: integer(),
          ionospheric_east: integer()
        }
  @type fkp_gradients :: %{
          message_number: 1034 | 1035,
          reference_station_id: non_neg_integer(),
          epoch_time: non_neg_integer(),
          satellite_count: non_neg_integer(),
          satellites: [fkp_gradient_record()],
          trailing_bits: [boolean()]
        }
  @typedoc "Structured RTCM encoder refusal with variant-specific payload fields."
  @type encode_error_fields :: %{
          variant: String.t(),
          message_number: integer() | nil,
          field: String.t() | nil,
          value: String.t() | nil,
          minimum: String.t() | nil,
          maximum: String.t() | nil,
          width: integer() | nil,
          encoding: String.t() | nil,
          record: String.t() | nil,
          carried: boolean() | nil,
          satellite: integer() | nil,
          expected: integer() | nil,
          actual: integer() | nil,
          index: integer() | nil,
          orbit: integer() | nil,
          clock: integer() | nil,
          orbit_satellite: integer() | nil,
          clock_satellite: integer() | nil,
          c1: integer() | nil,
          c2: integer() | nil,
          signal: integer() | nil,
          mask: integer() | nil,
          problem: String.t() | nil,
          count: integer() | nil,
          detail: String.t() | nil,
          trailing_bits: [boolean()] | nil
        }
  @typedoc "Structured RTCM conversion refusal with variant-specific payload fields."
  @type conversion_error_fields :: %{
          variant: String.t(),
          message_number: integer() | nil,
          field: String.t() | nil,
          value: integer() | nil,
          width: integer() | nil,
          index: integer() | nil,
          system: String.t() | nil,
          full_week: integer() | nil,
          week: integer() | nil,
          broadcast_prn: integer() | nil,
          nested_variant: String.t() | nil,
          satellite: String.t() | nil,
          reason: String.t() | nil,
          decoded_week: integer() | nil,
          fit_interval_flag: integer() | nil,
          iode: integer() | nil,
          iodc: integer() | nil,
          vtec: map() | nil,
          detail: String.t() | nil
        }
  @type policy :: :strict | :lenient
  @type departure ::
          {:frame_reserved_bits, non_neg_integer()}
          | {:trailing_bits, non_neg_integer(), [boolean()]}
          | {:msm_cell_mask_over_64, non_neg_integer(), non_neg_integer()}
          | {:ssr_records_short, non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {:records_short, non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {:order_exceeds_degree, non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type frame_skip :: %{
          offset: non_neg_integer(),
          message_number: integer() | nil,
          reason: :truncated | :malformed | :departure,
          detail: String.t() | departure() | nil
        }
  @type diagnostics :: %{
          resync_bytes: non_neg_integer(),
          crc_failures: non_neg_integer(),
          skipped_frames: [frame_skip()],
          departures: [{non_neg_integer(), departure()}]
        }

  @doc """
  Decode a complete RTCM 3 byte stream.

  Every byte has to belong to a CRC-valid frame whose body decodes under the
  strict policy. Returns `{:ok, [{type, fields}, ...]}` in stream order, or
  `{:error, text}` naming what was not read: a skipped frame, or bytes outside
  CRC-valid frames (a stray byte, a CRC-24Q failure or a trailing partial
  frame). `decode_stream/2` reads a noisy stream frame by frame and reports
  every skip.
  """
  @spec decode_messages(binary()) :: {:ok, [message()]} | {:error, term()}
  def decode_messages(bytes) when is_binary(bytes) do
    NIF.rtcm_decode_messages(bytes)
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_decode_messages)
  end

  @doc """
  Decode every CRC-valid RTCM 3 frame of a noisy stream and return messages plus
  stream diagnostics.

  Frames whose CRC fails, whose body cannot be decoded, or that depart from the
  format under the `:strict` policy are skipped, and the scan resynchronizes on
  the next preamble. Diagnostics count the bytes passed over while
  resynchronizing (`:resync_bytes`) and the preambles whose frame failed its
  CRC-24Q (`:crc_failures`), list each skipped frame with its reason, and under
  `:lenient` list each departure read with its frame's byte offset.

  Options: `:policy` (`:strict` or `:lenient`, default `:strict`).
  """
  @spec decode_stream(binary(), keyword()) ::
          {:ok, %{messages: [message()], diagnostics: diagnostics()}} | {:error, term()}
  def decode_stream(bytes, opts \\ []) when is_binary(bytes) do
    case NIF.rtcm_decode_stream(bytes, policy(opts)) do
      {:ok, {messages, diagnostics}} ->
        {:ok, %{messages: messages, diagnostics: diagnostics}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_decode_stream)
  end

  @doc """
  Decode every CRC-valid RTCM 3 frame in a byte buffer.
  """
  @spec decode(binary()) :: {:ok, [message()]} | {:error, term()}
  def decode(bytes), do: decode_messages(bytes)

  @doc """
  Decode one RTCM message body under the strict policy.
  """
  @spec decode_message(binary()) :: {:ok, message()} | {:error, term()}
  def decode_message(body) when is_binary(body) do
    case NIF.rtcm_decode_message(body, "strict") do
      {:ok, {message, []}} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_decode_message)
  end

  @doc """
  Decode one RTCM message body under `policy`, returning the departures read
  under `:lenient` (always empty under `:strict`, which refuses them).
  """
  @spec decode_message_with_policy(binary(), policy()) ::
          {:ok, message(), [departure()]} | {:error, term()}
  def decode_message_with_policy(body, policy) when is_binary(body) do
    case NIF.rtcm_decode_message(body, policy_name(policy)) do
      {:ok, {message, departures}} -> {:ok, message, departures}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_decode_message)
  end

  @doc """
  Return the message number from one RTCM message body.
  """
  @spec message_number(binary()) :: {:ok, integer()} | {:error, term()}
  def message_number(body) when is_binary(body) do
    case NIF.rtcm_message_number(body) do
      {:ok, number} -> {:ok, number}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_message_number)
  end

  @doc """
  Return the RINEX LLI bit constants used by the RTCM MSM derivation helpers.
  """
  @spec lli_bits() :: %{loss_of_lock: 1, half_cycle: 2}
  def lli_bits do
    {loss_of_lock, half_cycle} = NIF.rtcm_lli_bits()
    %{loss_of_lock: loss_of_lock, half_cycle: half_cycle}
  end

  @doc """
  Minimum continuous-lock time in milliseconds for an MSM lock indicator.

  `kind` is `"msm4"` or `"msm7"`.
  """
  @spec minimum_lock_time_ms(String.t(), integer()) ::
          {:ok, non_neg_integer() | nil} | {:error, term()}
  def minimum_lock_time_ms(kind, indicator) when is_binary(kind) and is_integer(indicator) do
    case NIF.rtcm_minimum_lock_time_ms(kind, indicator) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_minimum_lock_time_ms)
  end

  @doc """
  Derive the RINEX LLI digit for one signal cell.

  Pass `elapsed_ms` as `nil` for the first observation. When `elapsed_ms` is an
  integer, `previous_min_lock_time_ms` may be `nil` to represent a previous
  reserved indicator.
  """
  @spec derive_lli(integer() | nil, integer() | nil, integer() | nil, boolean()) ::
          non_neg_integer()
  def derive_lli(previous_min_lock_time_ms, elapsed_ms, current_min_lock_time_ms, half_cycle?)
      when (is_integer(previous_min_lock_time_ms) or is_nil(previous_min_lock_time_ms)) and
             (is_integer(elapsed_ms) or is_nil(elapsed_ms)) and
             (is_integer(current_min_lock_time_ms) or is_nil(current_min_lock_time_ms)) and is_boolean(half_cycle?) do
    NIF.rtcm_derive_lli(
      previous_min_lock_time_ms,
      elapsed_ms,
      current_min_lock_time_ms,
      half_cycle?
    )
  end

  @doc """
  Elapsed milliseconds between two raw MSM epoch-time fields for one system.
  """
  @spec msm_epoch_dt_ms(String.t(), integer(), integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def msm_epoch_dt_ms(system, previous, current)
      when is_binary(system) and is_integer(previous) and is_integer(current) do
    case NIF.rtcm_msm_epoch_dt_ms(system, previous, current) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_msm_epoch_dt_ms)
  end

  @doc """
  RINEX observation-code suffix for an MSM signal id, or `nil` if reserved.
  """
  @spec msm_signal_rinex_code(String.t(), integer()) :: {:ok, String.t() | nil} | {:error, term()}
  def msm_signal_rinex_code(system, signal_id) when is_binary(system) and is_integer(signal_id) do
    case NIF.rtcm_msm_signal_rinex_code(system, signal_id) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_msm_signal_rinex_code)
  end

  @doc """
  Derive per-cell LLI rows by running a core lock-time tracker over MSM maps.

  The input is a list of decoded MSM field maps, in stream order. The result is
  one list of `%{satellite_id, signal_id, lli, min_lock_time_ms}` maps per input
  message.
  """
  @spec msm_lli([map()]) :: {:ok, [[map()]]} | {:error, term()}
  def msm_lli(messages) when is_list(messages) do
    {:ok, NIF.rtcm_msm_lli(Enum.map(messages, &with_defaults(:msm, &1)))}
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_msm_lli)
  end

  @doc """
  Evaluate a decoded or constructed `:ssr_vtec` message at receiver and
  transmit-frame satellite ECEF positions in metres.

  The computation epoch is GPS seconds of day from the VTEC message's epoch,
  and the frequency is in hertz. Successful results include each layer's
  pierce-point coordinates, VTEC/STEC, mapping factor, and total code delay and
  carrier-phase advance. Model refusal is returned as a structured
  `{:vtec_evaluation, details}` error.
  """
  @spec evaluate_ssr_vtec(message(), [number()], [number()], number(), number()) ::
          {:ok, map()} | {:error, {:vtec_evaluation, map()} | term()}
  def evaluate_ssr_vtec(
        {:ssr_vtec, fields},
        receiver_ecef_m,
        satellite_transmit_ecef_m,
        gps_seconds_of_day,
        frequency_hz
      )
      when is_map(fields) and is_list(receiver_ecef_m) and is_list(satellite_transmit_ecef_m) do
    NIF.rtcm_ssr_vtec_evaluate(
      with_defaults(:ssr_vtec, fields),
      receiver_ecef_m,
      satellite_transmit_ecef_m,
      gps_seconds_of_day,
      frequency_hz
    )
  rescue
    e in ArgumentError -> {:error, e.message}
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_ssr_vtec_evaluate)
  end

  def evaluate_ssr_vtec(_message, _receiver_ecef_m, _satellite_transmit_ecef_m, _gps_seconds_of_day, _frequency_hz),
    do: {:error, :invalid_ssr_vtec_message}

  @doc """
  Construct a supported RTCM 3 message from a `{type, fields}` pair and encode it
  into a complete transport frame (preamble, length, body, CRC-24Q).

  `type` is one of the supported `message_type/0` atoms (`:unsupported` cannot be
  constructed). `fields` is a map of the raw transmitted fields, the same shape
  `decode_messages/1` produces for that type (the derived `:x_m`/`:y_m`/`:z_m`
  station outputs are ignored when present, so a decoded map round-trips
  directly). Returns `{:ok, frame_binary}` or `{:error, reason}`. A message the
  wire format cannot state is refused rather than written as another satellite
  or signal. The core codec's refusals are `{:error, {:rtcm_encode_error,
  fields}}` with the variant under `:variant`: an MSM satellite id outside
  `1..64`, a signal id outside `1..32`, a satellite or cell listed twice or a
  signal whose satellite is not listed (`"msm_mask"`), and an ephemeris
  satellite field wider than the message's, four bits for QZSS 1044 and six for
  the others (`"satellite_id_out_of_range"`). A satellite or signal number
  outside `0..255`, which the boundary cannot carry, is
  `{:error, {:invalid_input, message}}`.

  The output frame feeds back through `decode_messages/1`, so
  `construct -> encode -> decode` reproduces the same message fields.

  Core encoder and conversion refusals use
  `{:rtcm_encode_error, %{variant: name, ...}}` and
  `{:rtcm_conversion_error, %{variant: name, ...}}`; their maps retain the
  variant payload. Boundary validation failures remain `{:invalid_input, text}`.
  """
  @spec encode_message(message()) :: {:ok, binary()} | {:error, term()}
  def encode_message(message), do: encode_frame(message)

  @doc """
  Construct a supported RTCM 3 message and return its message body.

  Refusals preserve the core error family and its typed payload.
  """
  @spec encode(message()) :: {:ok, binary()} | {:error, term()}
  def encode({type, fields}) when is_atom(type) and is_map(fields) do
    encode_constructed_message(type, fields, &NIF.rtcm_encode/2)
  end

  @doc """
  Construct a supported RTCM 3 message and return its body written under
  `policy`, with the departures written under `:lenient`.

  Under `:lenient` a message's `:trailing_bits` are written back after its last
  field, so a body read under `:lenient` re-encodes byte for byte; `encode/1`
  refuses a nonempty `:trailing_bits`. Every other refusal of `encode/1`
  applies under both policies.
  """
  @spec encode_with_policy(message(), policy()) ::
          {:ok, binary(), [departure()]} | {:error, term()}
  def encode_with_policy({type, fields}, policy) when is_atom(type) and is_map(fields) do
    case NIF.rtcm_encode_with_policy(Atom.to_string(type), with_defaults(type, fields), policy_name(policy)) do
      {:ok, {body, departures}} -> {:ok, body, departures}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_encode_with_policy)
  end

  @doc """
  Construct a supported RTCM 3 message and return its complete frame.

  Refuses a message the wire format cannot state, or a body over the frame
  length limit, with the same typed reasons `encode_message/1` returns.
  """
  @spec encode_frame(message() | binary()) :: {:ok, binary()} | {:error, term()}
  def encode_frame({type, fields}) when is_atom(type) and is_map(fields) do
    encode_constructed_message(type, fields, &NIF.rtcm_encode_frame/2)
  end

  def encode_frame(body) when is_binary(body), do: encode_frame_with_reserved(body, 0)

  @doc """
  Wrap a message body in an RTCM 3 frame whose six reserved header bits hold
  `reserved`, so a frame read with nonzero reserved bits is written back as it
  was read. Refuses a body over the frame length limit, or `reserved` wider
  than six bits, with the core's typed `{:error, {:rtcm_encode_error, fields}}`
  (`reserved` under the variant `"frame_reserved_out_of_range"`).
  """
  @spec encode_frame_with_reserved(binary(), non_neg_integer()) :: {:ok, binary()} | {:error, term()}
  def encode_frame_with_reserved(body, reserved) when is_binary(body) and is_integer(reserved) do
    case NIF.rtcm_encode_frame_body(body, reserved) do
      {:ok, frame} -> {:ok, frame}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_encode_frame_body)
  end

  @doc """
  Decode the single RTCM 3 frame that begins at the start of `bytes`.

  Verifies the preamble and the CRC-24Q. Returns
  `{:ok, %{message_number: n, frame_len: bytes, reserved: bits, body: binary}}`,
  `reserved` being the six header bits between the preamble and the length as
  read, or `{:error, reason}` for a missing preamble, a truncated buffer, or a
  CRC mismatch. `encode_frame_with_reserved/2` writes the body back with the
  same reserved bits.
  """
  @spec decode_frame(binary()) ::
          {:ok,
           %{
             message_number: integer(),
             frame_len: integer(),
             reserved: non_neg_integer(),
             body: binary()
           }}
          | {:error, term()}
  def decode_frame(bytes) when is_binary(bytes) do
    case NIF.rtcm_decode_frame(bytes) do
      {:ok, %{body: body} = frame} -> {:ok, %{frame | body: :erlang.list_to_binary(body)}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_decode_frame)
  end

  defp encode_constructed_message(type, fields, encoder) do
    case encoder.(Atom.to_string(type), with_defaults(type, fields)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ArgumentError -> {:error, e.message}
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rtcm_encode)
  end

  @trailing_bit_types [
    :station_coordinates,
    :antenna_descriptor,
    :legacy_observations,
    :gps_ephemeris,
    :glonass_ephemeris,
    :beidou_ephemeris,
    :qzss_ephemeris,
    :galileo_fnav_ephemeris,
    :galileo_inav_ephemeris,
    :msm,
    :network_correction_differences,
    :helmert_transformation,
    :residual_grid,
    :projection,
    :network_residuals,
    :physical_reference_station,
    :fkp_gradients
  ]

  # The fields a message built by hand may leave out: no trailing bits, no
  # negative-zero fields, and an MSM signal mask taken from the cells.
  defp with_defaults(type, fields) when type in @trailing_bit_types do
    fields
    |> Map.put_new(:trailing_bits, [])
    |> type_defaults(type)
  end

  defp with_defaults(_type, fields), do: fields

  defp type_defaults(fields, :glonass_ephemeris), do: Map.put_new(fields, :negative_zero, 0)
  defp type_defaults(fields, :msm), do: Map.put_new(fields, :signal_mask, nil)
  defp type_defaults(fields, _type), do: fields

  defp policy(opts), do: opts |> Keyword.get(:policy, :strict) |> policy_name()

  defp policy_name(:strict), do: "strict"
  defp policy_name(:lenient), do: "lenient"

  defp policy_name(other),
    do: raise(ArgumentError, "unknown RTCM policy #{inspect(other)}; expected :strict or :lenient")
end
