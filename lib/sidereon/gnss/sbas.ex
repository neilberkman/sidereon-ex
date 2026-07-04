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
  alias Sidereon.GNSS.Positioning.Decode
  alias Sidereon.GNSS.SBAS
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

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
  @type error :: :not_found | :invalid_input | String.t()

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
    @moduledoc "One SBAS log block with decoded message metadata."
    @enforce_keys [:satellite_id, :epoch_scale, :week, :tow_s, :form, :bytes, :message]
    defstruct [:satellite_id, :epoch_scale, :week, :tow_s, :form, :bytes, :message]

    @type t :: %__MODULE__{
            satellite_id: String.t(),
            epoch_scale: String.t(),
            week: integer(),
            tow_s: float(),
            form: String.t(),
            bytes: [byte()],
            message: Message.t()
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
            epoch(),
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
      e in ErlangError -> {:error, e.original}
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

    @type t :: :insufficient_geometry | :numerical_failure | :invalid_error_model | term()
  end

  @doc """
  Compute SBAS horizontal and vertical protection levels.

  The error model supplies one range-error budget per geometry row. Returned
  values are meters except `:d_en_m2`, which is square meters.
  """
  @spec sbas_protection_levels(ProtectionGeometry.t(), SbasErrorModel.t(), SbasKMultipliers.t()) ::
          {:ok, SbasProtection.t()} | {:error, SbasPlError.t()}
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
    e in ErlangError -> {:error, e.original}
  end

  @doc "Decode one 250-bit framed or 226-bit body SBAS message."
  @spec decode(binary(), atom() | String.t()) :: {:ok, Message.t()} | {:error, error()}
  def decode(bytes, form \\ :body_226) when is_binary(bytes) do
    case NIF.sbas_decode(bytes, form_name(form)) do
      {:ok, fields} -> {:ok, message_struct(fields)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc "Decode one 250-bit framed or 226-bit body SBAS message or raise."
  @spec decode!(binary(), atom() | String.t()) :: Message.t()
  def decode!(bytes, form \\ :body_226), do: bang(decode(bytes, form))

  @doc "Parse ESA EMS-style SBAS log lines."
  @spec parse_ems(String.t()) :: {:ok, [LogBlock.t()]}
  def parse_ems(text) when is_binary(text), do: {:ok, Enum.map(NIF.sbas_parse_ems(text), &block_struct/1)}

  @doc "Parse ESA EMS-style SBAS log lines or raise."
  @spec parse_ems!(String.t()) :: [LogBlock.t()]
  def parse_ems!(text), do: bang(parse_ems(text))

  @doc "Parse RTKLIB SBAS log lines."
  @spec parse_rtklib(String.t()) :: {:ok, [LogBlock.t()]}
  def parse_rtklib(text) when is_binary(text), do: {:ok, Enum.map(NIF.sbas_parse_rtklib(text), &block_struct/1)}

  @doc "Parse RTKLIB SBAS log lines or raise."
  @spec parse_rtklib!(String.t()) :: [LogBlock.t()]
  def parse_rtklib!(text), do: bang(parse_rtklib(text))

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
    e in ErlangError -> {:error, e.original}
  end

  def corrected_position!(broadcast, store, geo_id, satellite_id, epoch, opts \\ []),
    do: bang(corrected_position(broadcast, store, geo_id, satellite_id, epoch, opts))

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
    e in ErlangError -> {:error, e.original}
  end

  def sample!(broadcast, store, geo_id, satellites, window, step_s, opts \\ []),
    do: bang(sample(broadcast, store, geo_id, satellites, window, step_s, opts))

  @doc "Run SPP against an SBAS-corrected broadcast source."
  def solve_broadcast(
        %Broadcast{handle: broadcast},
        %__MODULE__{handle: store},
        geo_id,
        observations,
        epoch,
        opts \\ []
      ) do
    with {:ok, t_rx_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
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
        Time.second_of_day(epoch),
        Time.day_of_year(epoch),
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
        glonass_channels
      )
      |> Decode.decode()
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def solve_broadcast!(broadcast, store, geo_id, observations, epoch, opts \\ []),
    do: bang(solve_broadcast(broadcast, store, geo_id, observations, epoch, opts))

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
    e in ErlangError -> {:error, e.original}
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
