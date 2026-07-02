defmodule Sidereon.GNSS.SBAS do
  @moduledoc """
  Satellite-based augmentation corrections.

  The correction store, SBAS message decoding, corrected broadcast ephemeris
  source, and corrected SPP solve all delegate to the core SBAS implementation.
  """

  alias Sidereon.Constants
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Positioning.Decode
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

  defmodule Message do
    @moduledoc "Decoded SBAS message metadata."
    @enforce_keys [:kind, :message_type, :preamble, :details]
    defstruct [:kind, :message_type, :preamble, :details]

    @type t :: %__MODULE__{
            kind: atom() | String.t(),
            message_type: integer(),
            preamble: integer(),
            details: String.t()
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

  @doc "Decode one 250-bit framed or 226-bit body SBAS message."
  @spec decode(binary(), atom() | String.t()) :: {:ok, Message.t()} | {:error, term()}
  def decode(bytes, form \\ :body_226) when is_binary(bytes) do
    case NIF.sbas_decode(bytes, form_name(form)) do
      {:ok, fields} -> {:ok, message_struct(fields)}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def decode!(bytes, form \\ :body_226), do: bang(decode(bytes, form))

  @doc "Parse ESA EMS-style SBAS log lines."
  def parse_ems(text) when is_binary(text), do: {:ok, Enum.map(NIF.sbas_parse_ems(text), &block_struct/1)}

  def parse_ems!(text), do: bang(parse_ems(text))

  @doc "Parse RTKLIB SBAS log lines."
  def parse_rtklib(text) when is_binary(text), do: {:ok, Enum.map(NIF.sbas_parse_rtklib(text), &block_struct/1)}

  def parse_rtklib!(text), do: bang(parse_rtklib(text))

  @doc "Create an empty correction store."
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
  defp message_struct(fields), do: struct!(Message, Map.update!(fields, :kind, &kind_atom/1))
  defp sample_row(row), do: %{row | status: kind_atom(row.status)}

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
