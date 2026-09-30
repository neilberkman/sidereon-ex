defmodule Sidereon.GNSS.SSR do
  @moduledoc """
  State-space GNSS corrections.

  This module is the Elixir wrapper over the core SSR/HAS correction store and
  corrected broadcast ephemeris source. It holds decoded corrections in a native
  resource and evaluates corrected satellite states through the core.
  """

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.RTCM
  alias Sidereon.GNSS.Time
  alias Sidereon.GNSS.Time.ExactEpochQuery
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}
  @type epoch :: NaiveDateTime.t() | tuple() | number()

  defmodule Solution do
    @moduledoc "SSR solution identity."
    @enforce_keys [:source, :provider_id, :solution_id]
    defstruct [:source, :provider_id, :solution_id]

    @type t :: %__MODULE__{
            source: atom() | String.t(),
            provider_id: integer(),
            solution_id: integer()
          }
  end

  defmodule OrbitCorrection do
    @moduledoc """
    SSR orbit correction.

    `ref_epoch_j2000_s` is the reference time of the rate terms and
    `transmitted_epoch_j2000_s` the epoch the message transmitted, from which
    an RTCM SSR correction's age is gated (for Galileo HAS both are the TOH
    epoch). `has_nav_message` is the Galileo HAS navigation-message index NM as
    transmitted, `nil` for an RTCM SSR correction; a HAS correction whose index
    is reserved (1..7) is kept and not applied.
    """
    @enforce_keys [
      :solution,
      :iode,
      :iod_ssr,
      :radial_m,
      :along_m,
      :cross_m,
      :radial_rate_m_s,
      :along_rate_m_s,
      :cross_rate_m_s,
      :ref_epoch_j2000_s,
      :transmitted_epoch_j2000_s,
      :update_interval_s,
      :crs_regional,
      :reference_point
    ]
    defstruct [
      :solution,
      :iode,
      :iod_ssr,
      :radial_m,
      :along_m,
      :cross_m,
      :radial_rate_m_s,
      :along_rate_m_s,
      :cross_rate_m_s,
      :ref_epoch_j2000_s,
      :transmitted_epoch_j2000_s,
      :update_interval_s,
      :crs_regional,
      :reference_point,
      :has_nav_message
    ]

    @type t :: %__MODULE__{
            solution: Solution.t(),
            iode: integer(),
            iod_ssr: integer(),
            radial_m: float(),
            along_m: float(),
            cross_m: float(),
            radial_rate_m_s: float(),
            along_rate_m_s: float(),
            cross_rate_m_s: float(),
            ref_epoch_j2000_s: float(),
            transmitted_epoch_j2000_s: float(),
            update_interval_s: float(),
            crs_regional: boolean(),
            reference_point: String.t(),
            has_nav_message: non_neg_integer() | nil
          }
  end

  defmodule ClockCorrection do
    @moduledoc """
    SSR clock correction.

    `transmitted_epoch_j2000_s` and `has_nav_message` are as in
    `Sidereon.GNSS.SSR.OrbitCorrection`. The correction adds to the satellite
    clock, as RTCM SSR, IGS SSR and RTKLIB `satpos_ssr` define it.
    """
    @enforce_keys [
      :solution,
      :iod_ssr,
      :c0_m,
      :c1_m_s,
      :c2_m_s2,
      :ref_epoch_j2000_s,
      :transmitted_epoch_j2000_s,
      :update_interval_s,
      :high_rate_c0_m
    ]
    defstruct [
      :solution,
      :iod_ssr,
      :c0_m,
      :c1_m_s,
      :c2_m_s2,
      :ref_epoch_j2000_s,
      :transmitted_epoch_j2000_s,
      :update_interval_s,
      :high_rate_c0_m,
      :has_nav_message
    ]

    @type t :: %__MODULE__{
            solution: Solution.t(),
            iod_ssr: integer(),
            c0_m: float(),
            c1_m_s: float(),
            c2_m_s2: float(),
            ref_epoch_j2000_s: float(),
            transmitted_epoch_j2000_s: float(),
            update_interval_s: float(),
            high_rate_c0_m: float() | nil,
            has_nav_message: non_neg_integer() | nil
          }
  end

  defmodule CorrectionSize do
    @moduledoc "Applied SSR orbit and clock correction magnitudes."
    @enforce_keys [:orbit_m, :clock_m, :orbit_exceeds_limit, :clock_exceeds_limit]
    defstruct [:orbit_m, :clock_m, :orbit_exceeds_limit, :clock_exceeds_limit]

    @type t :: %__MODULE__{
            orbit_m: float(),
            clock_m: float(),
            orbit_exceeds_limit: boolean(),
            clock_exceeds_limit: boolean()
          }
  end

  defmodule OversizedCorrection do
    @moduledoc "An oversized SSR correction applied under the explicit lenient policy."
    @enforce_keys [
      :satellite_id,
      :solution,
      :orbit_ref_epoch_j2000_s,
      :clock_ref_epoch_j2000_s,
      :t_j2000_s,
      :size
    ]
    defstruct [
      :satellite_id,
      :solution,
      :orbit_ref_epoch_j2000_s,
      :clock_ref_epoch_j2000_s,
      :t_j2000_s,
      :size
    ]

    @type t :: %__MODULE__{
            satellite_id: String.t(),
            solution: Solution.t(),
            orbit_ref_epoch_j2000_s: float(),
            clock_ref_epoch_j2000_s: float(),
            t_j2000_s: float(),
            size: CorrectionSize.t()
          }
  end

  @doc "Create an empty correction store."
  @spec new() :: t()
  def new, do: %__MODULE__{handle: NIF.ssr_store_new()}

  @doc """
  Build a correction store from every readable frame of framed RTCM SSR/HAS
  bytes, reporting what was not read or not applied.

  Frames are read under the lenient RTCM policy, so a frame that departs from
  the format is read and the departure recorded. Returns
  `{:ok, store, report}`, `report` holding `:diagnostics` (the stream
  diagnostics `Sidereon.GNSS.RTCM.decode_stream/2` reports: resynchronized
  bytes, CRC-24Q failures, skipped frames with their reasons, and departures),
  `:trailing_partial_frame_len` (the bytes of an unfinished frame at the end)
  and `:ingest_refusals` (each message the store refused, as
  `%{message_number, reason}`). `from_rtcm_strict/4` refuses all of these
  instead.

  `week` and `tow_s` are the receiver time, on the scale named by `:scale`
  (`:gpst` by default); each message's time of week is placed in the week
  nearest it.
  """
  @spec from_rtcm(binary(), non_neg_integer(), number(), keyword()) ::
          {:ok, t(),
           %{
             diagnostics: RTCM.diagnostics(),
             trailing_partial_frame_len: non_neg_integer(),
             ingest_refusals: [%{message_number: integer(), reason: String.t()}]
           }}
          | {:error, term()}
  def from_rtcm(bytes, week, tow_s, opts \\ []) when is_binary(bytes) do
    scale = time_scale(Keyword.get(opts, :scale, :gpst))

    case NIF.ssr_store_from_rtcm(bytes, scale, week, tow_s / 1.0) do
      {handle, report} when is_reference(handle) -> {:ok, %__MODULE__{handle: handle}, report}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :ssr_store_from_rtcm)
  end

  @doc """
  Build a correction store from framed RTCM bytes, refusing anything it cannot
  read under the strict RTCM policy and apply in full: bytes outside a frame, a
  CRC-24Q failure, a trailing partial frame, a frame that does not decode, and
  a message the store refuses.
  """
  @spec from_rtcm_strict(binary(), non_neg_integer(), number(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_rtcm_strict(bytes, week, tow_s, opts \\ []) when is_binary(bytes) do
    scale = time_scale(Keyword.get(opts, :scale, :gpst))

    case NIF.ssr_store_from_rtcm_strict(bytes, scale, week, tow_s / 1.0) do
      handle when is_reference(handle) -> {:ok, %__MODULE__{handle: handle}}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :ssr_store_from_rtcm_strict)
  end

  @doc """
  As `from_rtcm_strict/4`, raising `ArgumentError` on failure.
  """
  @spec from_rtcm!(binary(), non_neg_integer(), number(), keyword()) :: t()
  def from_rtcm!(bytes, week, tow_s, opts \\ []) do
    case from_rtcm_strict(bytes, week, tow_s, opts) do
      {:ok, store} -> store
      {:error, reason} -> raise ArgumentError, "could not decode SSR corrections: #{inspect(reason)}"
    end
  end

  @doc """
  Ingest one decoded RTCM message into an existing correction store.

  Non-SSR RTCM messages are ignored by the core store.
  """
  @spec ingest(t(), RTCM.message(), non_neg_integer(), number()) :: :ok | {:error, term()}
  def ingest(%__MODULE__{handle: handle}, message, week, tow_s) when is_integer(week) and is_number(tow_s) do
    NIF.ssr_store_ingest(handle, message, week, tow_s / 1.0)
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :ssr_store_ingest)
  end

  @doc "Return the latest orbit correction for a satellite."
  @spec orbit(t(), String.t()) :: {:ok, OrbitCorrection.t()} | {:error, term()}
  def orbit(%__MODULE__{handle: handle}, satellite_id) do
    case NIF.ssr_orbit(handle, satellite_id) do
      {:ok, fields} -> {:ok, orbit_struct(fields)}
      {:error, _} = err -> err
    end
  end

  def orbit!(store, satellite_id), do: bang(orbit(store, satellite_id))

  @doc "Return the latest clock correction for a satellite."
  @spec clock(t(), String.t()) :: {:ok, ClockCorrection.t()} | {:error, term()}
  def clock(%__MODULE__{handle: handle}, satellite_id) do
    case NIF.ssr_clock(handle, satellite_id) do
      {:ok, fields} -> {:ok, clock_struct(fields)}
      {:error, _} = err -> err
    end
  end

  def clock!(store, satellite_id), do: bang(clock(store, satellite_id))

  @doc "Return the latest SSR URA index for a satellite."
  @spec ura_index(t(), String.t()) :: {:ok, integer()} | {:error, term()}
  def ura_index(%__MODULE__{handle: handle}, satellite_id), do: NIF.ssr_ura_index(handle, satellite_id)

  def ura_index!(store, satellite_id), do: bang(ura_index(store, satellite_id))

  @doc """
  Evaluate an SSR-corrected broadcast satellite state at an epoch.

  `:correction_size_policy` accepts `:strict` (the default) or `:lenient`.
  Strict mode returns `{:error, {:correction_exceeds_limit, details}}` when
  the applied orbit or clock correction exceeds the RTKLIB limits. This
  refusal is not replaced by a broadcast fallback.
  """
  @spec corrected_position(Broadcast.t(), t(), String.t(), epoch(), keyword()) ::
          {:ok,
           %{
             position_ecef_m: {float(), float(), float()},
             clock_s: float(),
             oversized_corrections: [OversizedCorrection.t()]
           }}
          | {:error, term()}
  def corrected_position(%Broadcast{handle: broadcast}, %__MODULE__{handle: store}, satellite_id, epoch, opts \\ []) do
    with {:ok, t_j2000_s} <- epoch_seconds(epoch) do
      fallback? = Keyword.get(opts, :fallback_to_broadcast, false)
      regional = Keyword.get(opts, :regional_providers, [])
      size_policy = correction_size_policy(Keyword.get(opts, :correction_size_policy, :strict))

      case NIF.ssr_corrected_position(
             broadcast,
             store,
             satellite_id,
             t_j2000_s,
             fallback?,
             regional,
             size_policy
           ) do
        {:ok, {position, clock_s}, oversized} ->
          {:ok,
           %{
             position_ecef_m: position,
             clock_s: clock_s,
             oversized_corrections: Enum.map(oversized, &oversized_correction_struct/1)
           }}

        {:error, _} = err ->
          err
      end
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :ssr_corrected_position)
  end

  def corrected_position!(broadcast, store, satellite_id, epoch, opts \\ []),
    do: bang(corrected_position(broadcast, store, satellite_id, epoch, opts))

  @doc "Evaluate an SSR-corrected state using exact state and record-selection queries."
  @spec corrected_position_at_epoch_query(Broadcast.t(), t(), String.t(), ExactEpochQuery.t(), keyword()) ::
          {:ok,
           %{
             position_ecef_m: {float(), float(), float()},
             clock_s: float(),
             oversized_corrections: [OversizedCorrection.t()]
           }}
          | {:error, term()}
  def corrected_position_at_epoch_query(broadcast, store, satellite_id, epoch, opts \\ [])

  def corrected_position_at_epoch_query(
        %Broadcast{handle: broadcast},
        %__MODULE__{handle: store},
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
      fallback? = Keyword.get(opts, :fallback_to_broadcast, false)
      regional = Keyword.get(opts, :regional_providers, [])
      size_policy = correction_size_policy(Keyword.get(opts, :correction_size_policy, :strict))

      case NIF.ssr_corrected_position_at_epoch_query(
             broadcast,
             store,
             satellite_id,
             epoch,
             selection_epoch,
             fallback?,
             regional,
             size_policy
           ) do
        {:ok, {position, clock_s}, oversized} ->
          {:ok,
           %{
             position_ecef_m: position,
             clock_s: clock_s,
             oversized_corrections: Enum.map(oversized, &oversized_correction_struct/1)
           }}

        {:error, _} = err ->
          err
      end
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :ssr_corrected_position_at_epoch_query)
  end

  def corrected_position_at_epoch_query(_broadcast, _store, _satellite_id, _epoch, _opts),
    do: {:error, :invalid_exact_epoch_query}

  @doc "Read a selected SSR state with independent exact state and selection queries."
  @spec selected_state_at_epoch_queries(
          Broadcast.t(),
          t(),
          String.t(),
          ExactEpochQuery.t(),
          ExactEpochQuery.t(),
          keyword()
        ) :: {:ok, map() | nil} | {:error, term()}
  def selected_state_at_epoch_queries(broadcast, store, satellite_id, state_query, selection_query, opts \\ []) do
    source_exact_epoch_hook(
      broadcast,
      store,
      satellite_id,
      state_query,
      selection_query,
      "selected_state",
      nil,
      opts
    )
  end

  @doc "Read the SSR transmission-placement clock at exact state and selection queries."
  @spec transmit_clock_at_epoch_queries(
          Broadcast.t(),
          t(),
          String.t(),
          ExactEpochQuery.t(),
          ExactEpochQuery.t(),
          keyword()
        ) :: {:ok, %{clock_s: float(), degraded: atom() | nil} | nil} | {:error, term()}
  def transmit_clock_at_epoch_queries(broadcast, store, satellite_id, state_query, selection_query, opts \\ []) do
    source_exact_epoch_hook(
      broadcast,
      store,
      satellite_id,
      state_query,
      selection_query,
      "transmit_clock",
      nil,
      opts
    )
  end

  @doc "Evaluate SSR-source clock relativity for a state at its exact query."
  @spec clock_relativity_for_state_at_epoch_query(
          Broadcast.t(),
          t(),
          String.t(),
          ExactEpochQuery.t(),
          {number(), number(), number()},
          keyword()
        ) :: :not_applicable | :unavailable | {:term, float()} | {:error, term()}
  def clock_relativity_for_state_at_epoch_query(
        broadcast,
        store,
        satellite_id,
        %ExactEpochQuery{} = state_query,
        position_ecef_m,
        opts \\ []
      ) do
    source_exact_epoch_hook(
      broadcast,
      store,
      satellite_id,
      state_query,
      state_query,
      "clock_relativity",
      position_ecef_m,
      opts
    )
  end

  @doc "Read SSR-source position variance at independent exact state and selection queries."
  @spec ephemeris_variance_at_epoch_queries(
          Broadcast.t(),
          t(),
          String.t(),
          ExactEpochQuery.t(),
          ExactEpochQuery.t(),
          keyword()
        ) :: float() | nil | {:error, term()}
  def ephemeris_variance_at_epoch_queries(broadcast, store, satellite_id, state_query, selection_query, opts \\ []) do
    source_exact_epoch_hook(
      broadcast,
      store,
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
         satellite_id,
         %ExactEpochQuery{handle: state_epoch},
         %ExactEpochQuery{handle: selection_epoch},
         hook,
         position_ecef_m,
         opts
       ) do
    case NIF.ssr_source_exact_epoch_hook(
           broadcast,
           store,
           satellite_id,
           state_epoch,
           selection_epoch,
           Keyword.get(opts, :fallback_to_broadcast, false),
           Keyword.get(opts, :regional_providers, []),
           correction_size_policy(Keyword.get(opts, :correction_size_policy, :strict)),
           hook,
           position_ecef_m
         ) do
      {:error, {:correction_exceeds_limit, details}} ->
        {:error, {:correction_exceeds_limit, correction_size_struct(details)}}

      result ->
        decode_source_hook(result)
    end
  rescue
    error in ErlangError -> NifCall.error(error, __STACKTRACE__, :ssr_source_exact_epoch_hook)
  end

  defp source_exact_epoch_hook(_broadcast, _store, _satellite_id, _state, _selection, _hook, _position, _opts),
    do: {:error, :invalid_exact_epoch_query}

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

  @doc "Sample an SSR-corrected broadcast source over a time grid."
  def sample(%Broadcast{handle: broadcast}, %__MODULE__{handle: store}, satellites, {from, to}, step_s, opts \\ []) do
    with {:ok, start_s} <- epoch_seconds(from),
         {:ok, stop_s} <- epoch_seconds(to) do
      fallback? = Keyword.get(opts, :fallback_to_broadcast, false)
      regional = Keyword.get(opts, :regional_providers, [])
      size_policy = correction_size_policy(Keyword.get(opts, :correction_size_policy, :strict))

      rows =
        NIF.ssr_sample_broadcast(
          broadcast,
          store,
          satellites,
          start_s,
          stop_s,
          step_s / 1.0,
          fallback?,
          regional,
          size_policy
        )

      {:ok, Enum.map(rows, &sample_row/1)}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :ssr_sample_broadcast)
  end

  def sample!(broadcast, store, satellites, window, step_s, opts \\ []),
    do: bang(sample(broadcast, store, satellites, window, step_s, opts))

  @doc "Sample SSR states at explicit exact state and selection queries."
  @spec sample_at_epoch_queries(
          Broadcast.t(),
          t(),
          [String.t()],
          [ExactEpochQuery.t() | {ExactEpochQuery.t(), ExactEpochQuery.t()}],
          keyword()
        ) ::
          {:ok, [map()]} | {:error, term()}
  def sample_at_epoch_queries(broadcast, store, satellites, queries, opts \\ [])

  def sample_at_epoch_queries(%Broadcast{} = broadcast, %__MODULE__{} = store, satellites, queries, opts)
      when is_list(satellites) and is_list(queries) do
    with {:ok, query_pairs} <- exact_query_pairs(queries) do
      Enum.reduce_while(satellites, {:ok, []}, fn satellite_id, {:ok, rows} ->
        Enum.reduce_while(query_pairs, {:ok, rows}, fn {state_query, selection_query}, {:ok, acc} ->
          query_opts = Keyword.put(opts, :selection_epoch_query, selection_query)

          case corrected_position_at_epoch_query(
                 broadcast,
                 store,
                 satellite_id,
                 state_query,
                 query_opts
               ) do
            {:ok, result} ->
              row =
                Map.merge(result, %{
                  satellite_id: satellite_id,
                  state_epoch_query: state_query,
                  selection_epoch_query: selection_query
                })

              {:cont, {:ok, [row | acc]}}

            {:error, _} = error ->
              {:halt, error}
          end
        end)
        |> case do
          {:ok, next_rows} -> {:cont, {:ok, next_rows}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, rows} -> {:ok, Enum.reverse(rows)}
        {:error, _} = error -> error
      end
    end
  end

  def sample_at_epoch_queries(_broadcast, _store, _satellites, _queries, _opts),
    do: {:error, :invalid_exact_epoch_query}

  defp exact_query_pairs(queries) do
    Enum.reduce_while(queries, {:ok, []}, fn
      %ExactEpochQuery{} = query, {:ok, acc} ->
        {:cont, {:ok, [{query, query} | acc]}}

      {%ExactEpochQuery{} = state_query, %ExactEpochQuery{} = selection_query}, {:ok, acc} ->
        {:cont, {:ok, [{state_query, selection_query} | acc]}}

      _other, _acc ->
        {:halt, {:error, :invalid_exact_epoch_query}}
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, _} = error -> error
    end
  end

  defp orbit_struct(fields), do: struct!(OrbitCorrection, Map.update!(fields, :solution, &solution_struct/1))
  defp clock_struct(fields), do: struct!(ClockCorrection, Map.update!(fields, :solution, &solution_struct/1))
  defp correction_size_struct(fields), do: struct!(CorrectionSize, fields)

  defp oversized_correction_struct(fields) do
    fields
    |> Map.update!(:solution, &solution_struct/1)
    |> Map.update!(:size, &struct!(CorrectionSize, &1))
    |> then(&struct!(OversizedCorrection, &1))
  end

  defp solution_struct(fields), do: struct!(Solution, Map.update!(fields, :source, &string_atom/1))

  defp sample_row(row), do: %{row | status: string_atom(row.status)}

  defp correction_size_policy(:strict), do: "strict"
  defp correction_size_policy(:lenient), do: "lenient"
  defp correction_size_policy(_), do: "invalid"

  defp epoch_seconds(value) when is_number(value), do: {:ok, value / 1.0}
  defp epoch_seconds(value), do: Time.epoch_to_j2000_seconds_fractional(value)

  defp time_scale(:gpst), do: "GPST"
  defp time_scale(:gst), do: "GST"
  defp time_scale(:bdt), do: "BDT"
  defp time_scale(:utc), do: "UTC"
  defp time_scale(scale) when is_binary(scale), do: String.upcase(scale)

  defp string_atom("rtcm_ssr"), do: :rtcm_ssr
  defp string_atom("galileo_has"), do: :galileo_has
  defp string_atom("igs_ssr"), do: :igs_ssr
  defp string_atom("valid"), do: :valid
  defp string_atom("gap"), do: :gap
  defp string_atom(other), do: other

  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, inspect(reason))
end
