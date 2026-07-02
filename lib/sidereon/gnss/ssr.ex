defmodule Sidereon.GNSS.SSR do
  @moduledoc """
  State-space GNSS corrections.

  This module is the Elixir wrapper over the core SSR/HAS correction store and
  corrected broadcast ephemeris source. It holds decoded corrections in a native
  resource and evaluates corrected satellite states through the core.
  """

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

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
    @moduledoc "SSR orbit correction."
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
      :update_interval_s,
      :crs_regional,
      :reference_point
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
            update_interval_s: float(),
            crs_regional: boolean(),
            reference_point: String.t()
          }
  end

  defmodule ClockCorrection do
    @moduledoc "SSR clock correction."
    @enforce_keys [
      :solution,
      :iod_ssr,
      :c0_m,
      :c1_m_s,
      :c2_m_s2,
      :ref_epoch_j2000_s,
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
      :update_interval_s,
      :high_rate_c0_m
    ]

    @type t :: %__MODULE__{
            solution: Solution.t(),
            iod_ssr: integer(),
            c0_m: float(),
            c1_m_s: float(),
            c2_m_s2: float(),
            ref_epoch_j2000_s: float(),
            update_interval_s: float(),
            high_rate_c0_m: float() | nil
          }
  end

  @doc "Create an empty correction store."
  @spec new() :: t()
  def new, do: %__MODULE__{handle: NIF.ssr_store_new()}

  @doc """
  Decode framed RTCM SSR/HAS messages into a correction store.
  """
  @spec from_rtcm(binary(), non_neg_integer(), number(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_rtcm(bytes, week, tow_s, opts \\ []) when is_binary(bytes) do
    scale = time_scale(Keyword.get(opts, :scale, :gpst))

    case NIF.ssr_store_from_rtcm(bytes, scale, week, tow_s / 1.0) do
      handle when is_reference(handle) -> {:ok, %__MODULE__{handle: handle}}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def from_rtcm!(bytes, week, tow_s, opts \\ []) do
    case from_rtcm(bytes, week, tow_s, opts) do
      {:ok, store} -> store
      {:error, reason} -> raise ArgumentError, "could not decode SSR corrections: #{inspect(reason)}"
    end
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
  """
  @spec corrected_position(Broadcast.t(), t(), String.t(), epoch(), keyword()) ::
          {:ok, %{position_ecef_m: {float(), float(), float()}, clock_s: float()}} | {:error, term()}
  def corrected_position(%Broadcast{handle: broadcast}, %__MODULE__{handle: store}, satellite_id, epoch, opts \\ []) do
    with {:ok, t_j2000_s} <- epoch_seconds(epoch) do
      fallback? = Keyword.get(opts, :fallback_to_broadcast, false)
      regional = Keyword.get(opts, :regional_providers, [])

      case NIF.ssr_corrected_position(broadcast, store, satellite_id, t_j2000_s, fallback?, regional) do
        {:ok, {position, clock_s}} -> {:ok, %{position_ecef_m: position, clock_s: clock_s}}
        {:error, _} = err -> err
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def corrected_position!(broadcast, store, satellite_id, epoch, opts \\ []),
    do: bang(corrected_position(broadcast, store, satellite_id, epoch, opts))

  @doc "Sample an SSR-corrected broadcast source over a time grid."
  def sample(%Broadcast{handle: broadcast}, %__MODULE__{handle: store}, satellites, {from, to}, step_s, opts \\ []) do
    with {:ok, start_s} <- epoch_seconds(from),
         {:ok, stop_s} <- epoch_seconds(to) do
      fallback? = Keyword.get(opts, :fallback_to_broadcast, false)
      regional = Keyword.get(opts, :regional_providers, [])

      rows =
        NIF.ssr_sample_broadcast(
          broadcast,
          store,
          satellites,
          start_s,
          stop_s,
          step_s / 1.0,
          fallback?,
          regional
        )

      {:ok, Enum.map(rows, &sample_row/1)}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def sample!(broadcast, store, satellites, window, step_s, opts \\ []),
    do: bang(sample(broadcast, store, satellites, window, step_s, opts))

  defp orbit_struct(fields), do: struct!(OrbitCorrection, Map.update!(fields, :solution, &solution_struct/1))
  defp clock_struct(fields), do: struct!(ClockCorrection, Map.update!(fields, :solution, &solution_struct/1))
  defp solution_struct(fields), do: struct!(Solution, Map.update!(fields, :source, &string_atom/1))

  defp sample_row(row), do: %{row | status: string_atom(row.status)}

  defp epoch_seconds(value) when is_number(value), do: {:ok, value / 1.0}
  defp epoch_seconds(value), do: Time.epoch_to_j2000_seconds_fractional(value)

  defp time_scale(:gpst), do: "GPST"
  defp time_scale(:gst), do: "GST"
  defp time_scale(:bdt), do: "BDT"
  defp time_scale(:utc), do: "UTC"
  defp time_scale(scale) when is_binary(scale), do: String.upcase(scale)

  defp string_atom("rtcm_ssr"), do: :rtcm_ssr
  defp string_atom("galileo_has"), do: :galileo_has
  defp string_atom("valid"), do: :valid
  defp string_atom("gap"), do: :gap
  defp string_atom(other), do: other

  defp bang({:ok, value}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, inspect(reason))
end
