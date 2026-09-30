defmodule Sidereon.GNSS.SBAS do
  @moduledoc """
  Satellite-based augmentation corrections.

  The correction store, SBAS message decoding, corrected broadcast ephemeris
  source, and corrected SPP solve all delegate to the core SBAS implementation.
  """

  alias __MODULE__.{ProtectionGeometry, SbasErrorModel, SbasKMultipliers, SbasPlError, SbasProtection}
  alias Sidereon.Constants
  alias Sidereon.GNSS.ARAIM
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Core.Types
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.Positioning.Decode
  alias Sidereon.GNSS.SBAS
  alias Sidereon.GNSS.Time
  alias Sidereon.GNSS.Time.ExactEpoch
  alias Sidereon.GNSS.Time.ExactEpochQuery
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @default_initial_guess {0.0, 0.0, 0.0, 0.0}
  @default_alpha {0.0, 0.0, 0.0, 0.0}
  @default_beta {0.0, 0.0, 0.0, 0.0}
  @default_pressure_hpa Constants.surface_met_pressure_hpa()
  @default_temperature_k Constants.surface_met_temperature_k()
  @default_relative_humidity Constants.surface_met_relative_humidity()

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}
  @type epoch :: NaiveDateTime.t() | tuple() | number()
  @type sbas_encode_error_fields :: %{
          variant: String.t(),
          message_type: non_neg_integer() | nil,
          field: String.t() | nil,
          index: non_neg_integer() | nil,
          value: String.t() | nil,
          width: non_neg_integer() | nil,
          signed: boolean() | nil,
          preamble: non_neg_integer() | nil,
          bytes: non_neg_integer() | nil,
          bits_past_payload: boolean() | nil,
          part: String.t() | nil,
          expected: [integer()] | nil,
          found: [integer()] | nil,
          expected_count: non_neg_integer() | nil,
          found_count: non_neg_integer() | nil,
          half: non_neg_integer() | nil,
          velocity_code: boolean() | nil,
          record: non_neg_integer() | nil,
          reason: String.t() | nil
        }
  @type error ::
          :not_found
          | :invalid_input
          | String.t()
          | {:sbas_encode_error, sbas_encode_error_fields()}
          | Sidereon.argument_error()
  @type policy :: :strict | :lenient
  @type departure ::
          {:unrecognized_preamble, 0..255}
          | {:declared_message_type, 0..63, 0..63}

  defmodule Message do
    @moduledoc """
    Decoded SBAS message.

    `:message_type` and `:preamble` are the raw wire values. `:payload` contains
    decoded fields in SBAS wire units, for example PRC values, UDREI values,
    masks, long-term records, or IGP delay entries depending on `:kind`.
    """

    @enforce_keys [:kind, :message_type, :preamble, :details, :payload]
    defstruct [:kind, :message_type, :preamble, :details, :payload]

    @type t :: %__MODULE__{
            kind: atom() | String.t(),
            message_type: integer(),
            preamble: integer(),
            details: String.t(),
            payload: map()
          }
  end

  defmodule LogBlock do
    @moduledoc """
    One SBAS log block with decoded message metadata.

    `declared_message_type` is the message type the record's own field states
    (the EMS message-type field, or the fourth header field of an RTKLIB
    record), `nil` for an eight-field comma line, which carries none.
    `pad_bits` holds the six bits completing the last byte of the block, as
    read.
    """
    @enforce_keys [:satellite_id, :epoch_scale, :week, :tow_s, :form, :bytes, :message]
    defstruct [
      :satellite_id,
      :epoch_scale,
      :week,
      :tow_s,
      :form,
      :bytes,
      :declared_message_type,
      :pad_bits,
      :message
    ]

    @type t :: %__MODULE__{
            satellite_id: String.t(),
            epoch_scale: String.t(),
            week: integer(),
            tow_s: float(),
            form: String.t(),
            bytes: [byte()],
            declared_message_type: 0..63 | nil,
            pad_bits: 0..63,
            message: Message.t()
          }
  end

  defmodule Log do
    @moduledoc """
    Everything an EMS or RTKLIB SBAS log reader read. Each input line appears
    exactly once: as a block, a skipped line or a refused line.

      * `blocks` - records in input order;
      * `skipped_lines` - `{line, kind}` for each line read as no record,
        `kind` being `:blank`, `:comment` or `:non_record`;
      * `refused_lines` - `{line, reason}` for each record line left unread
        while the rest of the log was read: `{:ambiguous_week, week}` for a
        NovAtel OEM3 week below 1024 read without a reference week, or
        `{:checksum_mismatch, written | nil, computed}` for a NovAtel line
        whose checksum differs;
      * `departures` - `{line, departure}` read under `:lenient`.
    """
    alias Sidereon.GNSS.SBAS
    alias Sidereon.GNSS.SBAS.LogBlock

    @enforce_keys [:blocks, :skipped_lines, :refused_lines, :departures]
    defstruct [:blocks, :skipped_lines, :refused_lines, :departures]

    @type t :: %__MODULE__{
            blocks: [LogBlock.t()],
            skipped_lines: [{pos_integer(), :blank | :comment | :non_record}],
            refused_lines: [{pos_integer(), tuple()}],
            departures: [{pos_integer(), SBAS.departure()}]
          }
  end

  defmodule ProtectionRow do
    @moduledoc """
    One satellite row in an SBAS protection-level geometry snapshot.

    `:line_of_sight` is an ECEF receiver-to-satellite unit vector, and
    `:elevation_rad` is the receiver elevation angle in radians.
    """

    @enforce_keys [:id, :line_of_sight, :system, :elevation_rad]
    defstruct [:id, :line_of_sight, :system, :elevation_rad]

    @type t :: %__MODULE__{
            id: String.t(),
            line_of_sight: {float(), float(), float()},
            system: String.t(),
            elevation_rad: float()
          }

    @doc """
    Build an SBAS protection geometry row.
    """
    @spec new(String.t(), {number(), number(), number()}, number(), atom() | String.t() | nil) :: t()
    def new(id, line_of_sight, elevation_rad, system \\ nil) do
      %__MODULE__{
        id: id,
        line_of_sight: line_of_sight,
        system: system || String.first(id),
        elevation_rad: elevation_rad / 1.0
      }
    end

    @doc false
    @spec to_nif_tuple(t()) :: {:ok, tuple()} | {:error, term()}
    def to_nif_tuple(%__MODULE__{id: id, line_of_sight: los, system: system, elevation_rad: elevation_rad}) do
      with {:ok, {e_x, e_y, e_z}} <- Types.normalize_ecef(los, :bad_line_of_sight),
           {:ok, system} <- ARAIM.system_letter(system) do
        {:ok, {id, {e_x, e_y, e_z}, system, elevation_rad / 1.0}}
      end
    end
  end

  defmodule ProtectionGeometry do
    @moduledoc """
    SBAS protection-level geometry.

    `:receiver` is `{lat_rad, lon_rad, height_m}`. `:clock_systems` is the
    ordered receiver-clock column list, encoded as GNSS system letters.
    """

    alias Sidereon.GNSS.SBAS.ProtectionRow

    @enforce_keys [:rows, :receiver, :clock_systems]
    defstruct [:rows, :receiver, :clock_systems]

    @type receiver :: {float(), float(), float()}
    @type t :: %__MODULE__{
            rows: [ProtectionRow.t()],
            receiver: receiver(),
            clock_systems: [String.t()]
          }

    @doc """
    Build an SBAS protection-level geometry snapshot.
    """
    @spec new([ProtectionRow.t()], {number(), number(), number()}, [atom() | String.t()]) :: t()
    def new(rows, {lat_rad, lon_rad, height_m}, clock_systems) when is_list(rows) and is_list(clock_systems) do
      %__MODULE__{
        rows: rows,
        receiver: {lat_rad / 1.0, lon_rad / 1.0, height_m / 1.0},
        clock_systems: clock_systems
      }
    end

    @doc false
    @spec to_nif_terms(t()) :: {:ok, {[tuple()], tuple(), [String.t()]}} | {:error, term()}
    def to_nif_terms(%__MODULE__{rows: rows, receiver: receiver, clock_systems: clock_systems}) do
      with {:ok, row_terms} <- rows(rows),
           {:ok, clock_terms} <- systems(clock_systems) do
        {:ok, {row_terms, receiver, clock_terms}}
      end
    end

    defp rows(rows) do
      rows
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case ProtectionRow.to_nif_tuple(row) do
          {:ok, tuple} -> {:cont, {:ok, [tuple | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        {:error, _} = err -> err
      end
    end

    defp systems(clock_systems) do
      clock_systems
      |> Enum.reduce_while({:ok, []}, fn system, {:ok, acc} ->
        case ARAIM.system_letter(system) do
          {:ok, letter} -> {:cont, {:ok, [letter | acc]}}
          {:error, _} = err -> {:halt, err}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        {:error, _} = err -> err
      end
    end
  end

  defmodule SbasKMultipliers do
    @moduledoc """
    SBAS protection-level multipliers.
    """

    @enforce_keys [:k_h, :k_v]
    defstruct [:k_h, :k_v]

    @type t :: %__MODULE__{k_h: float(), k_v: float()}

    @doc """
    Build SBAS protection-level multipliers.
    """
    @spec new(number(), number()) :: t()
    def new(k_h, k_v), do: %__MODULE__{k_h: k_h / 1.0, k_v: k_v / 1.0}

    @doc """
    Return the precision-approach SBAS multipliers.
    """
    @spec precision_approach() :: t()
    def precision_approach do
      {k_h, k_v} = NIF.sbas_pl_k_precision_approach()
      new(k_h, k_v)
    end

    @doc """
    Return the en-route through non-precision-approach SBAS multipliers.
    """
    @spec en_route_npa() :: t()
    def en_route_npa do
      {k_h, k_v} = NIF.sbas_pl_k_en_route_npa()
      new(k_h, k_v)
    end

    @doc false
    @spec to_nif_tuple(t()) :: tuple()
    def to_nif_tuple(%__MODULE__{} = k), do: {k.k_h, k.k_v}
  end

  defmodule SbasProtection do
    @moduledoc """
    SBAS protection-level output for one geometry snapshot.
    """

    @enforce_keys [:hpl_m, :vpl_m, :d_major_m, :sigma_u_m, :d_east_m, :d_north_m, :d_en_m2]
    defstruct [:hpl_m, :vpl_m, :d_major_m, :sigma_u_m, :d_east_m, :d_north_m, :d_en_m2]

    @type t :: %__MODULE__{
            hpl_m: float(),
            vpl_m: float(),
            d_major_m: float(),
            sigma_u_m: float(),
            d_east_m: float(),
            d_north_m: float(),
            d_en_m2: float()
          }
  end

  defmodule SbasSisError do
    @moduledoc """
    One satellite's SBAS one-sigma range-error budget.
    """

    @enforce_keys [:id, :sigma_flt_m, :sigma_uire_m, :sigma_air_m, :sigma_tropo_m]
    defstruct [:id, :sigma_flt_m, :sigma_uire_m, :sigma_air_m, :sigma_tropo_m]

    @type t :: %__MODULE__{
            id: String.t(),
            sigma_flt_m: float(),
            sigma_uire_m: float(),
            sigma_air_m: float(),
            sigma_tropo_m: float()
          }

    @doc """
    Build an SBAS satellite range-error row.
    """
    @spec new(String.t(), number(), number(), number(), number()) :: t()
    def new(id, sigma_flt_m, sigma_uire_m, sigma_air_m, sigma_tropo_m) do
      %__MODULE__{
        id: id,
        sigma_flt_m: sigma_flt_m / 1.0,
        sigma_uire_m: sigma_uire_m / 1.0,
        sigma_air_m: sigma_air_m / 1.0,
        sigma_tropo_m: sigma_tropo_m / 1.0
      }
    end

    @doc false
    @spec to_nif_tuple(t()) :: tuple()
    def to_nif_tuple(%__MODULE__{} = row) do
      {row.id, row.sigma_flt_m, row.sigma_uire_m, row.sigma_air_m, row.sigma_tropo_m}
    end
  end

  defmodule AirborneModel do
    @moduledoc """
    SBAS airborne receiver and multipath contribution model.
    """

    @enforce_keys [:sigma_noise_divergence_m]
    defstruct [:sigma_noise_divergence_m]

    @type t :: %__MODULE__{sigma_noise_divergence_m: float()}

    @doc """
    Build an airborne receiver model from its receiver noise term.
    """
    @spec new(number()) :: t()
    def new(sigma_noise_divergence_m) do
      %__MODULE__{sigma_noise_divergence_m: sigma_noise_divergence_m / 1.0}
    end

    @doc """
    Return the core default airborne receiver model.
    """
    @spec aad_a() :: t()
    def aad_a, do: new(NIF.sbas_pl_airborne_aad_a())

    @doc false
    @spec to_nif_term(t()) :: float()
    def to_nif_term(%__MODULE__{} = model), do: model.sigma_noise_divergence_m
  end

  defmodule DegradationParams do
    @moduledoc """
    Supplied SBAS degradation terms for protection-level error modeling.
    """

    @enforce_keys [:delta_udre, :eps_fc_m, :eps_rrc_m, :eps_ltc_m, :eps_er_m, :eps_iono_m, :rss_udre]
    defstruct [:delta_udre, :eps_fc_m, :eps_rrc_m, :eps_ltc_m, :eps_er_m, :eps_iono_m, :rss_udre]

    @type t :: %__MODULE__{
            delta_udre: float(),
            eps_fc_m: float(),
            eps_rrc_m: float(),
            eps_ltc_m: float(),
            eps_er_m: float(),
            eps_iono_m: float(),
            rss_udre: boolean()
          }

    @doc """
    Build SBAS degradation parameters from options.
    """
    @spec new(keyword()) :: t()
    def new(opts \\ []) when is_list(opts) do
      defaults = none()

      %__MODULE__{
        delta_udre: Keyword.get(opts, :delta_udre, defaults.delta_udre) / 1.0,
        eps_fc_m: Keyword.get(opts, :eps_fc_m, defaults.eps_fc_m) / 1.0,
        eps_rrc_m: Keyword.get(opts, :eps_rrc_m, defaults.eps_rrc_m) / 1.0,
        eps_ltc_m: Keyword.get(opts, :eps_ltc_m, defaults.eps_ltc_m) / 1.0,
        eps_er_m: Keyword.get(opts, :eps_er_m, defaults.eps_er_m) / 1.0,
        eps_iono_m: Keyword.get(opts, :eps_iono_m, defaults.eps_iono_m) / 1.0,
        rss_udre: Keyword.get(opts, :rss_udre, defaults.rss_udre)
      }
    end

    @doc """
    Return the core no-degradation parameters.
    """
    @spec none() :: t()
    def none do
      {delta_udre, eps_fc_m, eps_rrc_m, eps_ltc_m, eps_er_m, eps_iono_m, rss_udre} =
        NIF.sbas_pl_degradation_none()

      %__MODULE__{
        delta_udre: delta_udre,
        eps_fc_m: eps_fc_m,
        eps_rrc_m: eps_rrc_m,
        eps_ltc_m: eps_ltc_m,
        eps_er_m: eps_er_m,
        eps_iono_m: eps_iono_m,
        rss_udre: rss_udre
      }
    end

    @doc false
    @spec to_nif_tuple(t()) :: tuple()
    def to_nif_tuple(%__MODULE__{} = params) do
      {
        params.delta_udre,
        params.eps_fc_m,
        params.eps_rrc_m,
        params.eps_ltc_m,
        params.eps_er_m,
        params.eps_iono_m,
        params.rss_udre
      }
    end
  end

  defmodule SbasErrorModel do
    @moduledoc """
    Index-aligned SBAS range-error model for protection-level geometry rows.
    """

    alias Sidereon.GNSS.SBAS.AirborneModel
    alias Sidereon.GNSS.SBAS.DegradationParams
    alias Sidereon.GNSS.SBAS.ProtectionGeometry
    alias Sidereon.GNSS.SBAS.SbasSisError
    alias Sidereon.NIF
    alias Sidereon.NifCall

    @enforce_keys [:rows]
    defstruct [:rows]

    @type t :: %__MODULE__{rows: [SbasSisError.t()]}

    @doc """
    Build an SBAS error model from supplied per-satellite rows.
    """
    @spec new([SbasSisError.t()]) :: t()
    def new(rows) when is_list(rows), do: %__MODULE__{rows: rows}

    @doc """
    Build an SBAS error model from a decoded SBAS correction store.
    """
    @spec from_store(
            SBAS.t(),
            String.t(),
            ProtectionGeometry.t(),
            AirborneModel.t(),
            SBAS.epoch(),
            DegradationParams.t()
          ) :: {:ok, t()} | {:error, term()}
    def from_store(
          %SBAS{handle: handle},
          geo_id,
          %ProtectionGeometry{} = geometry,
          %AirborneModel{} = airborne,
          epoch,
          %DegradationParams{} = degradation
        ) do
      with {:ok, {rows, receiver, clock_systems}} <- ProtectionGeometry.to_nif_terms(geometry),
           {:ok, epoch_j2000_s} <- epoch_seconds(epoch) do
        case NIF.sbas_pl_error_model_from_store(
               handle,
               geo_id,
               rows,
               receiver,
               clock_systems,
               AirborneModel.to_nif_term(airborne),
               epoch_j2000_s,
               DegradationParams.to_nif_tuple(degradation)
             ) do
          {:ok, terms} -> {:ok, new(Enum.map(terms, &sis_error/1))}
          {:error, _reason} = err -> err
        end
      end
    rescue
      e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sbas_pl_error_model_from_store)
    end

    @doc false
    @spec to_nif_rows(t()) :: [tuple()]
    def to_nif_rows(%__MODULE__{rows: rows}), do: Enum.map(rows, &SbasSisError.to_nif_tuple/1)

    defp epoch_seconds(value) when is_number(value), do: {:ok, value / 1.0}
    defp epoch_seconds(value), do: Time.epoch_to_j2000_seconds_fractional(value)

    defp sis_error(fields) do
      %SbasSisError{
        id: fields.id,
        sigma_flt_m: fields.sigma_flt_m,
        sigma_uire_m: fields.sigma_uire_m,
        sigma_air_m: fields.sigma_air_m,
        sigma_tropo_m: fields.sigma_tropo_m
      }
    end
  end

  defmodule SbasPlError do
    @moduledoc """
    SBAS protection-level error reasons.
    """

    @type t ::
            :insufficient_geometry
            | :numerical_failure
            | :invalid_error_model
            | {:ut1_outside_coverage, :before_coverage | :after_coverage}
            | term()
  end

  @doc """
  Compute SBAS horizontal and vertical protection levels.

  The error model supplies one range-error budget per geometry row. Returned
  values are meters except `:d_en_m2`, which is square meters.
  """
  @spec sbas_protection_levels(ProtectionGeometry.t(), SbasErrorModel.t(), SbasKMultipliers.t()) ::
          {:ok, SbasProtection.t()} | {:error, SbasPlError.t() | Sidereon.argument_error()}
  def sbas_protection_levels(
        %ProtectionGeometry{} = geometry,
        %SbasErrorModel{} = error_model,
        %SbasKMultipliers{} = k \\ SbasKMultipliers.precision_approach()
      ) do
    with {:ok, {rows, receiver, clock_systems}} <- ProtectionGeometry.to_nif_terms(geometry) do
      case NIF.sbas_pl_protection_levels(
             rows,
             receiver,
             clock_systems,
             SbasErrorModel.to_nif_rows(error_model),
             SbasKMultipliers.to_nif_tuple(k)
           ) do
        {:ok, fields} -> {:ok, sbas_protection(fields)}
        {:error, _reason} = err -> err
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sbas_pl_protection_levels)
  end

  @doc """
  Decode one 250-bit framed or 226-bit body SBAS message under the strict
  policy, which refuses a preamble other than `0x53`, `0x9A` and `0xC6`.
  """
  @spec decode(binary(), atom() | String.t()) :: {:ok, Message.t()} | {:error, error()}
  def decode(bytes, form \\ :body_226) when is_binary(bytes) do
    case NIF.sbas_decode(bytes, form_name(form), "strict") do
      {:ok, {fields, _pad_bits, []}} -> {:ok, message_struct(fields)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sbas_decode)
  end

  @doc """
  Encode a raw unsupported SBAS payload.

  `data` must hold the 27-byte 212-bit payload. Options select `:form`
  (`:body_226` by default), `:policy` (`:strict` by default), and `:pad_bits`
  (zero by default). Strict mode returns typed `:sbas_encode_error` fields for
  encoder refusals; lenient mode reports an unrecognized preamble as a departure.
  """
  @spec encode_unsupported(0..63, 0..255, binary(), keyword()) ::
          {:ok, binary(), [departure()]} | {:error, error()}
  def encode_unsupported(message_type, preamble, data, opts \\ [])

  def encode_unsupported(message_type, preamble, data, opts)
      when is_integer(message_type) and message_type in 0..63 and is_integer(preamble) and preamble in 0..255 and
             is_binary(data) and is_list(opts) do
    form = Keyword.get(opts, :form, :body_226)
    policy = Keyword.get(opts, :policy, :strict)
    pad_bits = Keyword.get(opts, :pad_bits, 0)

    if is_integer(pad_bits) and pad_bits in 0..63 do
      case NIF.sbas_encode_unsupported(
             preamble,
             message_type,
             data,
             form_name(form),
             pad_bits,
             policy_name(policy)
           ) do
        {:ok, {bytes, departures}} -> {:ok, bytes, departures}
        {:error, _} = error -> error
      end
    else
      {:error, :invalid_input}
    end
  rescue
    error in [ArgumentError, ErlangError] ->
      NifCall.error(error, __STACKTRACE__, :sbas_encode_unsupported)
  end

  def encode_unsupported(_message_type, _preamble, _data, _opts), do: {:error, :invalid_input}

  @doc """
  Decode one SBAS block under `policy`.

  Returns `{:ok, message, %{pad_bits: bits, departures: departures}}`:
  `pad_bits` are the six bits completing the last byte, as read, and
  `departures` those read under `:lenient` (a preamble other than the three
  SBAS values, as `{:unrecognized_preamble, preamble}`). A length or CRC
  failure is refused under both policies.
  """
  @spec decode_with_policy(binary(), atom() | String.t(), policy()) ::
          {:ok, Message.t(), %{pad_bits: 0..63, departures: [departure()]}} | {:error, error()}
  def decode_with_policy(bytes, form, policy) when is_binary(bytes) do
    case NIF.sbas_decode(bytes, form_name(form), policy_name(policy)) do
      {:ok, {fields, pad_bits, departures}} ->
        {:ok, message_struct(fields), %{pad_bits: pad_bits, departures: departures}}

      {:error, _} = err ->
        err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sbas_decode)
  end

  @doc "Decode one 250-bit framed or 226-bit body SBAS message or raise."
  @spec decode!(binary(), atom() | String.t()) :: Message.t()
  def decode!(bytes, form \\ :body_226), do: bang(decode(bytes, form))

  @doc """
  Parse ESA EMS-style SBAS log lines under the strict policy.

  Returns `{:error, reason}` for a record line the log reader would refuse or
  leave unread; `parse_ems_log/2` reads the rest of such a log and reports it.
  """
  @spec parse_ems(String.t()) :: {:ok, [LogBlock.t()]} | {:error, term()}
  def parse_ems(text) when is_binary(text), do: blocks_result(NIF.sbas_parse_ems(text))

  @doc "Parse ESA EMS-style SBAS log lines or raise."
  @spec parse_ems!(String.t()) :: [LogBlock.t()]
  def parse_ems!(text), do: bang(parse_ems(text))

  @doc """
  Parse RTKLIB SBAS log lines under the strict policy; errors as `parse_ems/1`.
  """
  @spec parse_rtklib(String.t()) :: {:ok, [LogBlock.t()]} | {:error, term()}
  def parse_rtklib(text) when is_binary(text), do: blocks_result(NIF.sbas_parse_rtklib(text))

  defp blocks_result({:error, _} = err), do: err
  defp blocks_result(blocks) when is_list(blocks), do: {:ok, Enum.map(blocks, &block_struct/1)}

  @doc "Parse RTKLIB SBAS log lines or raise."
  @spec parse_rtklib!(String.t()) :: [LogBlock.t()]
  def parse_rtklib!(text), do: bang(parse_rtklib(text))

  @doc """
  Read an EMS log, keeping every line's disposition; see `Sidereon.GNSS.SBAS.Log`.

  Options: `:policy` (`:strict` by default; `:lenient` reads a record whose
  declared message type differs from the type its message carries and
  reports it) and `:reference_week` (a full GPS week near the log's time,
  which resolves a NovAtel OEM3 10-bit week).
  """
  @spec parse_ems_log(String.t(), keyword()) :: {:ok, Log.t()} | {:error, term()}
  def parse_ems_log(text, opts \\ []) when is_binary(text), do: parse_log(:sbas_parse_ems_log, text, opts)

  @doc """
  Read an RTKLIB SBAS log, keeping every line's disposition; options as
  `parse_ems_log/2`.
  """
  @spec parse_rtklib_log(String.t(), keyword()) :: {:ok, Log.t()} | {:error, term()}
  def parse_rtklib_log(text, opts \\ []) when is_binary(text), do: parse_log(:sbas_parse_rtklib_log, text, opts)

  defp parse_log(fun, text, opts) do
    policy = policy_name(Keyword.get(opts, :policy, :strict))

    case apply(NIF, fun, [text, policy, Keyword.get(opts, :reference_week)]) do
      {:ok, {blocks, skipped, refused, departures}} ->
        {:ok,
         %SBAS.Log{
           blocks: Enum.map(blocks, &block_struct/1),
           skipped_lines: Enum.map(skipped, fn {line, kind} -> {line, skipped_kind(kind)} end),
           refused_lines: refused,
           departures: departures
         }}

      {:error, _} = err ->
        err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, fun)
  end

  defp skipped_kind("blank"), do: :blank
  defp skipped_kind("comment"), do: :comment
  defp skipped_kind("non_record"), do: :non_record

  defp policy_name(:strict), do: "strict"
  defp policy_name(:lenient), do: "lenient"

  defp policy_name(other),
    do: raise(ArgumentError, "unknown SBAS policy #{inspect(other)}; expected :strict or :lenient")

  @doc "Create an empty correction store."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      handle:
        NIF.sbas_store_new(
          Keyword.get(opts, :max_staleness_s, 360.0) / 1.0,
          Keyword.get(opts, :allow_partial, false)
        )
    }
  end

  @doc "Build a correction store from EMS log text."
  def store_from_ems(text, opts \\ []) when is_binary(text) do
    build_store(:sbas_store_from_ems, [text], opts)
  end

  def store_from_ems!(text, opts \\ []), do: bang(store_from_ems(text, opts))

  @doc "Build a correction store from RTKLIB SBAS log text."
  def store_from_rtklib(text, opts \\ []) when is_binary(text) do
    build_store(:sbas_store_from_rtklib, [text], opts)
  end

  def store_from_rtklib!(text, opts \\ []), do: bang(store_from_rtklib(text, opts))

  @doc "Build a correction store from decoded message tuples."
  def store_from_messages(messages, opts \\ []) when is_list(messages) do
    terms =
      Enum.map(messages, fn
        {bytes, form, geo, scale, week, tow_s} ->
          {bytes, form_name(form), geo, time_scale(scale), week, tow_s / 1.0}

        %{bytes: bytes, form: form, geo: geo, scale: scale, week: week, tow_s: tow_s} ->
          {bytes, form_name(form), geo, time_scale(scale), week, tow_s / 1.0}
      end)

    build_store(:sbas_store_from_messages, [terms], opts)
  end

  def store_from_messages!(messages, opts \\ []), do: bang(store_from_messages(messages, opts))

  @doc "Return ready SBAS GEO ids for an epoch."
  def ready_geos(%__MODULE__{handle: handle}, epoch) do
    with {:ok, t_j2000_s} <- epoch_seconds(epoch) do
      {:ok, NIF.sbas_ready_geos(handle, t_j2000_s)}
    end
  end

  def ready_geos!(store, epoch), do: bang(ready_geos(store, epoch))

  def fast(%__MODULE__{handle: handle}, geo_id, satellite_id), do: NIF.sbas_fast(handle, geo_id, satellite_id)
  def fast!(store, geo_id, satellite_id), do: bang(fast(store, geo_id, satellite_id))

  @doc """
  Count the corrections a source GEO addressed to active PRN-mask bits that name
  no satellite, per 1-based PRN mask number.

  The RTCA DO-229 mask numbers 1..37 are GPS, 38..61 GLONASS slots 1..24 and
  120..158 SBAS; any other active bit keeps its place among the active bits, so
  the corrections after it still reach their own satellites, and the
  corrections addressed to it are applied to no satellite and counted here.
  `geo_id` is the GEO's broadcast PRN token, such as `"S120"`, as
  `ready_geos/2` returns it. Returns `{:ok, %{mask_number => count}}`,
  `{:error, :not_found}` when the GEO has no partition in the store, or
  `{:error, reason}` for a GEO id that names no SBAS satellite.
  """
  @spec unassigned_mask_corrections(t(), String.t()) ::
          {:ok, %{pos_integer() => non_neg_integer()}} | {:error, term()}
  def unassigned_mask_corrections(%__MODULE__{handle: handle}, geo_id) when is_binary(geo_id) do
    case NIF.sbas_unassigned_mask_corrections(handle, geo_id) do
      {:ok, counts} -> {:ok, Map.new(counts)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sbas_unassigned_mask_corrections)
  end

  def unassigned_mask_corrections!(store, geo_id), do: bang(unassigned_mask_corrections(store, geo_id))

  def long_term(%__MODULE__{handle: handle}, geo_id, satellite_id), do: NIF.sbas_long_term(handle, geo_id, satellite_id)
  def long_term!(store, geo_id, satellite_id), do: bang(long_term(store, geo_id, satellite_id))

  def iono_grid(%__MODULE__{handle: handle}, geo_id), do: NIF.sbas_iono_grid(handle, geo_id)
  def iono_grid!(store, geo_id), do: bang(iono_grid(store, geo_id))

  def geo_nav(%__MODULE__{handle: handle}, geo_id), do: NIF.sbas_geo_nav(handle, geo_id)
  def geo_nav!(store, geo_id), do: bang(geo_nav(store, geo_id))

  @doc "Evaluate an SBAS-corrected broadcast satellite state."
  def corrected_position(
        %Broadcast{handle: broadcast},
        %__MODULE__{handle: store},
        geo_id,
        satellite_id,
        epoch,
        opts \\ []
      ) do
    with {:ok, t_j2000_s} <- epoch_seconds(epoch) do
      mode = mode_name(Keyword.get(opts, :mode, :mixed))

      case NIF.sbas_corrected_position(broadcast, store, geo_id, satellite_id, t_j2000_s, mode) do
        {:ok, {position, clock_s}} -> {:ok, %{position_ecef_m: position, clock_s: clock_s}}
        {:error, _} = err -> err
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sbas_corrected_position)
  end

  def corrected_position!(broadcast, store, geo_id, satellite_id, epoch, opts \\ []),
    do: bang(corrected_position(broadcast, store, geo_id, satellite_id, epoch, opts))

  @doc "Evaluate an SBAS-corrected state at exact state and broadcast-selection queries."
  @spec corrected_position_at_epoch_query(
          Broadcast.t(),
          t(),
          String.t(),
          String.t(),
          ExactEpochQuery.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def corrected_position_at_epoch_query(broadcast, store, geo_id, satellite_id, epoch, opts \\ [])

  def corrected_position_at_epoch_query(
        %Broadcast{handle: broadcast},
        %__MODULE__{handle: store},
        geo_id,
        satellite_id,
        %ExactEpochQuery{handle: epoch},
        opts
      ) do
    selection_epoch =
      case Keyword.get(opts, :selection_epoch_query) do
        %ExactEpochQuery{handle: handle} -> handle
        nil -> epoch
        _ -> nil
      end

    if is_nil(selection_epoch) do
      {:error, :invalid_exact_epoch_query}
    else
      mode = mode_name(Keyword.get(opts, :mode, :mixed))

      case NIF.sbas_corrected_position_at_epoch_query(
             broadcast,
             store,
             geo_id,
             satellite_id,
             epoch,
             selection_epoch,
             mode
           ) do
        {:ok, {position, clock_s}} -> {:ok, %{position_ecef_m: position, clock_s: clock_s}}
        {:error, _} = error -> error
      end
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :sbas_corrected_position_at_epoch_query)
  end

  def corrected_position_at_epoch_query(_broadcast, _store, _geo, _satellite, _epoch, _opts),
    do: {:error, :invalid_exact_epoch_query}

  @doc "Read an SBAS-selected state using exact state and broadcast-selection queries."
  @spec selected_state_at_epoch_queries(
          Broadcast.t(),
          t(),
          String.t(),
          String.t(),
          ExactEpochQuery.t(),
          ExactEpochQuery.t(),
          keyword()
        ) :: {:ok, map() | nil} | {:error, term()}
  def selected_state_at_epoch_queries(broadcast, store, geo_id, satellite_id, state_query, selection_query, opts \\ []) do
    source_exact_epoch_hook(
      broadcast,
      store,
      geo_id,
      satellite_id,
      state_query,
      selection_query,
      "selected_state",
      nil,
      opts
    )
  end

  @doc "Read the SBAS transmission-placement clock at exact state and selection queries."
  @spec transmit_clock_at_epoch_queries(
          Broadcast.t(),
          t(),
          String.t(),
          String.t(),
          ExactEpochQuery.t(),
          ExactEpochQuery.t(),
          keyword()
        ) :: {:ok, %{clock_s: float(), degraded: atom() | nil} | nil} | {:error, term()}
  def transmit_clock_at_epoch_queries(broadcast, store, geo_id, satellite_id, state_query, selection_query, opts \\ []) do
    source_exact_epoch_hook(
      broadcast,
      store,
      geo_id,
      satellite_id,
      state_query,
      selection_query,
      "transmit_clock",
      nil,
      opts
    )
  end

  @doc "Evaluate SBAS-source clock relativity for a state at its exact query."
  @spec clock_relativity_for_state_at_epoch_query(
          Broadcast.t(),
          t(),
          String.t(),
          String.t(),
          ExactEpochQuery.t(),
          {number(), number(), number()},
          keyword()
        ) :: :not_applicable | :unavailable | {:term, float()} | {:error, term()}
  def clock_relativity_for_state_at_epoch_query(
        broadcast,
        store,
        geo_id,
        satellite_id,
        %ExactEpochQuery{} = state_query,
        position_ecef_m,
        opts \\ []
      ) do
    source_exact_epoch_hook(
      broadcast,
      store,
      geo_id,
      satellite_id,
      state_query,
      state_query,
      "clock_relativity",
      position_ecef_m,
      opts
    )
  end

  @doc "Read SBAS-source position variance at independent exact state and selection queries."
  @spec ephemeris_variance_at_epoch_queries(
          Broadcast.t(),
          t(),
          String.t(),
          String.t(),
          ExactEpochQuery.t(),
          ExactEpochQuery.t(),
          keyword()
        ) :: float() | nil | {:error, term()}
  def ephemeris_variance_at_epoch_queries(
        broadcast,
        store,
        geo_id,
        satellite_id,
        state_query,
        selection_query,
        opts \\ []
      ) do
    source_exact_epoch_hook(
      broadcast,
      store,
      geo_id,
      satellite_id,
      state_query,
      selection_query,
      "ephemeris_variance",
      nil,
      opts
    )
  end

  defp source_exact_epoch_hook(
         %Broadcast{handle: broadcast},
         %__MODULE__{handle: store},
         geo_id,
         satellite_id,
         %ExactEpochQuery{handle: state_epoch},
         %ExactEpochQuery{handle: selection_epoch},
         hook,
         position_ecef_m,
         opts
       ) do
    NIF.sbas_source_exact_epoch_hook(
      broadcast,
      store,
      geo_id,
      satellite_id,
      state_epoch,
      selection_epoch,
      mode_name(Keyword.get(opts, :mode, :mixed)),
      hook,
      position_ecef_m
    )
    |> decode_source_hook()
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :sbas_source_exact_epoch_hook)
  end

  defp source_exact_epoch_hook(
         _broadcast,
         _store,
         _geo_id,
         _satellite_id,
         _state_query,
         _selection_query,
         _hook,
         _position,
         _opts
       ), do: {:error, :invalid_exact_epoch_query}

  defp decode_source_hook({:ok, nil}), do: {:ok, nil}

  defp decode_source_hook({:ok, {position_x, position_y, position_z, clock_s, group_delay_s, degraded}}) do
    {:ok,
     %{
       position_ecef_m: {position_x, position_y, position_z},
       clock_s: clock_s,
       group_delay_s: group_delay_s,
       degraded: degraded
     }}
  end

  defp decode_source_hook({:ok, {clock_s, degraded}}), do: {:ok, %{clock_s: clock_s, degraded: degraded}}

  defp decode_source_hook({:error, _} = error), do: error
  defp decode_source_hook(value) when is_number(value) or is_nil(value), do: value
  defp decode_source_hook(value), do: value

  @doc "Sample an SBAS-corrected broadcast source over a grid."
  def sample(
        %Broadcast{handle: broadcast},
        %__MODULE__{handle: store},
        geo_id,
        satellites,
        {from, to},
        step_s,
        opts \\ []
      ) do
    with {:ok, start_s} <- epoch_seconds(from),
         {:ok, stop_s} <- epoch_seconds(to) do
      rows =
        NIF.sbas_sample_broadcast(
          broadcast,
          store,
          geo_id,
          satellites,
          start_s,
          stop_s,
          step_s / 1.0,
          mode_name(Keyword.get(opts, :mode, :mixed))
        )

      {:ok, Enum.map(rows, &sample_row/1)}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sbas_sample_broadcast)
  end

  def sample!(broadcast, store, geo_id, satellites, window, step_s, opts \\ []),
    do: bang(sample(broadcast, store, geo_id, satellites, window, step_s, opts))

  @doc """
  Run SPP against an SBAS-corrected broadcast source.

  The `:qzss_clock` (`:gps` or `:separate`) and `:troposphere_model`
  (`:rtklib` or `:saastamoinen_niell`) options select the core solve models.
  """
  def solve_broadcast(
        %Broadcast{handle: broadcast},
        %__MODULE__{handle: store},
        geo_id,
        observations,
        epoch,
        opts \\ []
      ) do
    with {:ok, qzss_clock, troposphere_model} <- Positioning.model_options(opts),
         {:ok, t_rx_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch),
         {:ok, second_of_day} <- Time.second_of_day(epoch),
         {:ok, day_of_year} <- Time.day_of_year(epoch) do
      glonass_channels =
        Keyword.get(opts, :glonass_channels, %{})
        |> Enum.map(fn {slot, channel} -> {slot, channel} end)

      NIF.sbas_spp_solve_broadcast(
        broadcast,
        store,
        geo_id,
        mode_name(Keyword.get(opts, :mode, :mixed)),
        Enum.map(observations, fn {sat, pr} -> {sat, pr / 1.0} end),
        t_rx_j2000_s,
        second_of_day,
        day_of_year,
        tuple4(Keyword.get(opts, :initial_guess, @default_initial_guess)),
        Keyword.get(opts, :ionosphere, true),
        Keyword.get(opts, :troposphere, false),
        tuple4(Keyword.get(opts, :klobuchar_alpha, @default_alpha)),
        tuple4(Keyword.get(opts, :klobuchar_beta, @default_beta)),
        Keyword.get(opts, :pressure_hpa, @default_pressure_hpa) / 1.0,
        Keyword.get(opts, :temperature_k, @default_temperature_k) / 1.0,
        Keyword.get(opts, :relative_humidity, @default_relative_humidity) / 1.0,
        Keyword.get(opts, :with_geodetic, true),
        Keyword.get(opts, :max_pdop),
        Keyword.get(opts, :coarse_search),
        glonass_channels,
        qzss_clock,
        troposphere_model
      )
      |> Decode.decode()
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :sbas_spp_solve_broadcast)
  end

  def solve_broadcast!(broadcast, store, geo_id, observations, epoch, opts \\ []),
    do: bang(solve_broadcast(broadcast, store, geo_id, observations, epoch, opts))

  @doc "Run SPP at an exact receive epoch against an SBAS-corrected broadcast source."
  @spec solve_broadcast_at_exact_epoch(
          Broadcast.t(),
          t(),
          String.t(),
          [{String.t(), number()}],
          epoch(),
          ExactEpoch.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def solve_broadcast_at_exact_epoch(broadcast, store, geo_id, observations, civil_epoch, exact_epoch, opts \\ [])

  def solve_broadcast_at_exact_epoch(
        %Broadcast{handle: broadcast},
        %__MODULE__{handle: store},
        geo_id,
        observations,
        civil_epoch,
        %ExactEpoch{handle: exact_handle} = exact_epoch,
        opts
      ) do
    with {:ok, civil_exact_epoch} <- sbas_exact_civil_epoch(civil_epoch),
         true <- ExactEpoch.compare(civil_exact_epoch, exact_epoch) == :equal || {:error, :epoch_label_mismatch},
         {:ok, second_of_day} <- Time.second_of_day(civil_epoch),
         {:ok, day_of_year} <- Time.day_of_year(civil_epoch),
         :ok <- sbas_validate_max_pdop(Keyword.get(opts, :max_pdop)),
         {:ok, coarse_search_seeds} <- sbas_coarse_search_count(Keyword.get(opts, :coarse_search)),
         {:ok, qzss_clock, troposphere_model} <- Positioning.model_options(opts) do
      glonass_channels = Keyword.get(opts, :glonass_channels, %{}) |> Enum.to_list()

      NIF.sbas_spp_solve_broadcast_exact(
        broadcast,
        store,
        geo_id,
        mode_name(Keyword.get(opts, :mode, :mixed)),
        Enum.map(observations, fn {satellite_id, pseudorange_m} ->
          {satellite_id, pseudorange_m / 1.0}
        end),
        exact_handle,
        second_of_day,
        day_of_year,
        tuple4(Keyword.get(opts, :initial_guess, @default_initial_guess)),
        Keyword.get(opts, :ionosphere, true),
        Keyword.get(opts, :troposphere, false),
        tuple4(Keyword.get(opts, :klobuchar_alpha, @default_alpha)),
        tuple4(Keyword.get(opts, :klobuchar_beta, @default_beta)),
        Keyword.get(opts, :pressure_hpa, @default_pressure_hpa) / 1.0,
        Keyword.get(opts, :temperature_k, @default_temperature_k) / 1.0,
        Keyword.get(opts, :relative_humidity, @default_relative_humidity) / 1.0,
        Keyword.get(opts, :with_geodetic, true),
        optional_float(Keyword.get(opts, :max_pdop)),
        coarse_search_seeds,
        glonass_channels,
        qzss_clock,
        troposphere_model
      )
      |> Decode.decode()
    else
      {:error, _reason} = error -> error
      false -> {:error, :epoch_label_mismatch}
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :sbas_spp_solve_broadcast_exact)
  end

  def solve_broadcast_at_exact_epoch(_broadcast, _store, _geo_id, _observations, _civil_epoch, _exact_epoch, _opts),
    do: {:error, :invalid_exact_epoch}

  defp sbas_exact_civil_epoch(%NaiveDateTime{
         year: year,
         month: month,
         day: day,
         hour: hour,
         minute: minute,
         second: second,
         microsecond: {microsecond, _precision}
       }) do
    ExactEpoch.from_civil(year, month, day, hour, minute, second + microsecond / 1_000_000)
  end

  defp sbas_exact_civil_epoch({{year, month, day}, {hour, minute, second}}) do
    ExactEpoch.from_civil(year, month, day, hour, minute, second)
  end

  defp sbas_exact_civil_epoch(_epoch), do: {:error, :invalid_epoch}

  defp sbas_validate_max_pdop(nil), do: :ok
  defp sbas_validate_max_pdop(value) when is_number(value) and value > 0, do: :ok
  defp sbas_validate_max_pdop(_value), do: {:error, {:invalid_option, :max_pdop}}

  defp sbas_coarse_search_count(nil), do: {:ok, nil}
  defp sbas_coarse_search_count(false), do: {:ok, nil}
  defp sbas_coarse_search_count(true), do: {:ok, 24}
  defp sbas_coarse_search_count(count) when is_integer(count) and count > 0, do: {:ok, count}

  defp sbas_coarse_search_count(_value), do: {:error, {:invalid_option, :coarse_search}}

  defp optional_float(nil), do: nil
  defp optional_float(value), do: value / 1.0

  defp sbas_protection(fields) do
    %SbasProtection{
      hpl_m: fields.hpl_m,
      vpl_m: fields.vpl_m,
      d_major_m: fields.d_major_m,
      sigma_u_m: fields.sigma_u_m,
      d_east_m: fields.d_east_m,
      d_north_m: fields.d_north_m,
      d_en_m2: fields.d_en_m2
    }
  end

  defp build_store(nif, args, opts) do
    args = args ++ [Keyword.get(opts, :max_staleness_s, 360.0) / 1.0, Keyword.get(opts, :allow_partial, false)]

    case apply(NIF, nif, args) do
      handle when is_reference(handle) -> {:ok, %__MODULE__{handle: handle}}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, nif)
  end

  defp block_struct(fields), do: struct!(LogBlock, Map.update!(fields, :message, &message_struct/1))
  defp message_struct(fields), do: struct!(Message, fields |> Map.update!(:kind, &kind_atom/1) |> decode_payload())
  defp sample_row(row), do: %{row | status: kind_atom(row.status)}

  defp decode_payload(%{payload: payload} = fields) when is_map(payload) do
    %{fields | payload: payload}
  end

  defp form_name(:framed_250), do: "framed_250"
  defp form_name(:body_226), do: "body_226"
  defp form_name(value) when is_binary(value), do: value

  defp mode_name(:mixed), do: "mixed"
  defp mode_name(:mixed_augmentation), do: "mixed_augmentation"
  defp mode_name(:sbas_only), do: "sbas_only"
  defp mode_name(value) when is_binary(value), do: value

  defp time_scale(:gpst), do: "GPST"
  defp time_scale(:gst), do: "GST"
  defp time_scale(:bdt), do: "BDT"
  defp time_scale(:utc), do: "UTC"
  defp time_scale(value) when is_binary(value), do: String.upcase(value)

  defp epoch_seconds(value) when is_number(value), do: {:ok, value / 1.0}
  defp epoch_seconds(value), do: Time.epoch_to_j2000_seconds_fractional(value)

  defp tuple4({a, b, c, d}), do: {a / 1.0, b / 1.0, c / 1.0, d / 1.0}
  defp tuple4([a, b, c, d]), do: tuple4({a, b, c, d})

  defp kind_atom("do_not_use"), do: :do_not_use
  defp kind_atom("prn_mask"), do: :prn_mask
  defp kind_atom("fast_corrections"), do: :fast_corrections
  defp kind_atom("integrity"), do: :integrity
  defp kind_atom("fast_degradation"), do: :fast_degradation
  defp kind_atom("geo_nav"), do: :geo_nav
  defp kind_atom("network_time"), do: :network_time
  defp kind_atom("geo_almanac"), do: :geo_almanac
  defp kind_atom("igp_mask"), do: :igp_mask
  defp kind_atom("mixed_corrections"), do: :mixed_corrections
  defp kind_atom("long_term_corrections"), do: :long_term_corrections
  defp kind_atom("iono_delays"), do: :iono_delays
  defp kind_atom("unsupported"), do: :unsupported
  defp kind_atom("valid"), do: :valid
  defp kind_atom("gap"), do: :gap
  defp kind_atom(other), do: other

  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, inspect(reason))
end
