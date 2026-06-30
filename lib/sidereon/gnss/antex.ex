defmodule Sidereon.GNSS.Antex do
  @moduledoc """
  Parser and lookup helpers for ANTEX 1.4 receiver and satellite antenna blocks.

  The ANTEX parser, satellite validity lookup, and PCO/PCV interpolation live in
  the Rust GNSS core. This module preserves Sidereon' public structs and API shape.
  """

  alias Sidereon.GNSS.Antex.Antenna
  alias Sidereon.GNSS.Antex.Frequency
  alias Sidereon.GNSS.Core.Epoch
  alias Sidereon.NIF

  @enforce_keys [:antennas]
  defstruct [:antennas, :handle]

  defmodule Antenna do
    @moduledoc false
    @enforce_keys [
      :id,
      :kind,
      :type,
      :serial,
      :dazi_deg,
      :zenith_start_deg,
      :zenith_end_deg,
      :zenith_step_deg,
      :sinex_code,
      :frequencies
    ]

    defstruct [
      :id,
      :kind,
      :type,
      :serial,
      :dazi_deg,
      :zenith_start_deg,
      :zenith_end_deg,
      :zenith_step_deg,
      :sinex_code,
      :valid_from,
      :valid_until,
      :frequencies
    ]
  end

  defmodule Frequency do
    @moduledoc false
    @enforce_keys [:frequency, :pco_m, :pcv_samples]
    defstruct [:frequency, :pco_m, :pcv_samples]
  end

  @type t :: %__MODULE__{antennas: %{optional(String.t()) => Antenna.t()}}

  @type parse_error :: {:error, term()}

  @doc """
  Load and parse an ANTEX file from `path`.
  """
  @spec load(String.t()) :: {:ok, t()} | parse_error
  def load(path) when is_binary(path) do
    with {:ok, text} <- File.read(path) do
      parse(text)
    end
  end

  @doc """
  Like `load/1` but raises on failure.
  """
  @spec load!(String.t()) :: t()
  def load!(path) when is_binary(path) do
    case load(path) do
      {:ok, antex} ->
        antex

      {:error, reason} ->
        raise ArgumentError, "could not load ANTEX #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Parse ANTEX text already in memory.
  """
  @spec parse(binary()) :: {:ok, t()} | parse_error
  def parse(text) when is_binary(text) do
    case NIF.antex_parse(text) do
      {:ok, rows, handle} -> {:ok, %__MODULE__{antennas: decode_antennas(rows), handle: handle}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      {:error, e}
  end

  @doc """
  Serialize a parsed ANTEX product back to ANTEX 1.4 text.

  Round-trips with `parse/1`: re-parsing the output yields an equal product. The
  serializer works on the full parsed product held alongside the decoded
  antennas, so multi-interval antenna blocks are re-emitted, not just the
  latest-wins view exposed by `antenna/2`.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{handle: handle}) when is_reference(handle) do
    NIF.antex_encode(handle)
  end

  @doc """
  Return an antenna by its `TYPE / SERIAL` key.
  """
  @spec antenna(t(), String.t()) :: Antenna.t() | nil
  def antenna(%__MODULE__{antennas: antennas}, id) when is_binary(id) do
    Map.get(antennas, String.trim(id))
  end

  @doc """
  Return the satellite antenna block for PRN `prn` (e.g. `"G05"`) valid at the
  given epoch, or `nil` if none.
  """
  @spec satellite_antenna(t(), String.t(), NaiveDateTime.t()) :: Antenna.t() | nil
  def satellite_antenna(%__MODULE__{antennas: antennas}, prn, %NaiveDateTime{} = epoch) when is_binary(prn) do
    case NIF.antex_satellite_antenna(
           antenna_terms(Map.values(antennas)),
           prn,
           Epoch.datetime_tuple(epoch)
         ) do
      {:ok, row} -> decode_antenna(row)
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Frequency-dependent PCO (north/east/up in meters).
  """
  @spec pco(Antenna.t(), String.t()) ::
          {:ok, {float(), float(), float()}} | {:error, :unknown_frequency}
  def pco(%Antenna{} = antenna, frequency) when is_binary(frequency) do
    case NIF.antex_pco(antenna_term(antenna), frequency) do
      {:ok, pco_m} -> {:ok, pco_m}
      {:error, :unknown_frequency} -> {:error, :unknown_frequency}
    end
  end

  @doc """
  Like `pco/2` but raises on unknown frequency.
  """
  @spec pco!(Antenna.t(), String.t()) :: {float(), float(), float()}
  def pco!(%Antenna{} = antenna, frequency) when is_binary(frequency) do
    case pco(antenna, frequency) do
      {:ok, pco_m} ->
        pco_m

      {:error, :unknown_frequency} ->
        raise ArgumentError, "unknown frequency #{inspect(frequency)} for #{inspect(antenna.id)}"
    end
  end

  @doc """
  Frequency-dependent phase-center variation in meters.

  Interpolation is linear in zenith and azimuth. Azimuth is optional: when not
  given (or when the antenna has no azimuth-dependent rows), the NOAZI row is
  used.
  """
  @spec pcv(Antenna.t(), String.t(), float(), float() | nil) ::
          {:ok, float()} | {:error, :unknown_frequency}
  def pcv(%Antenna{} = antenna, frequency, zenith_deg, azimuth_deg \\ nil) when is_number(zenith_deg) do
    azimuth = if is_number(azimuth_deg), do: azimuth_deg / 1.0

    case NIF.antex_pcv(antenna_term(antenna), frequency, zenith_deg / 1.0, azimuth) do
      {:ok, value_m} -> {:ok, value_m}
      {:error, :unknown_frequency} -> {:error, :unknown_frequency}
    end
  end

  @doc """
  Like `pcv/4` but raises on unknown frequency.
  """
  @spec pcv!(Antenna.t(), String.t(), float(), float() | nil) :: float()
  def pcv!(%Antenna{} = antenna, frequency, zenith_deg, azimuth_deg \\ nil) when is_number(zenith_deg) do
    case pcv(antenna, frequency, zenith_deg, azimuth_deg) do
      {:ok, value_m} ->
        value_m

      {:error, :unknown_frequency} ->
        raise ArgumentError, "unknown frequency #{inspect(frequency)} for #{inspect(antenna.id)}"
    end
  end

  defp decode_antennas(rows) do
    rows
    |> Enum.map(&decode_antenna/1)
    |> Map.new(fn antenna -> {antenna.id, antenna} end)
  end

  defp decode_antenna(
         {{id, kind, type, serial}, {dazi_deg, zenith_start_deg, zenith_end_deg, zenith_step_deg},
          {sinex_code, valid_from, valid_until}, frequencies}
       ) do
    %Antenna{
      id: id,
      kind: decode_kind(kind),
      type: type,
      serial: serial,
      dazi_deg: dazi_deg,
      zenith_start_deg: zenith_start_deg,
      zenith_end_deg: zenith_end_deg,
      zenith_step_deg: zenith_step_deg,
      sinex_code: sinex_code,
      valid_from: decode_datetime(valid_from),
      valid_until: decode_datetime(valid_until),
      frequencies: decode_frequencies(frequencies)
    }
  end

  defp decode_frequencies(frequencies) do
    Map.new(frequencies, fn {frequency, pco_m, pcv_samples} ->
      {frequency,
       %Frequency{
         frequency: frequency,
         pco_m: pco_m,
         pcv_samples: Enum.map(pcv_samples, &decode_pcv_sample/1)
       }}
    end)
  end

  defp decode_pcv_sample({grid, azimuth_deg, zenith_deg, value_m}) do
    %{
      grid: decode_grid(grid),
      azimuth_deg: azimuth_deg,
      zenith_deg: zenith_deg,
      value_m: value_m
    }
  end

  defp antenna_terms(antennas), do: Enum.map(antennas, &antenna_term/1)

  defp antenna_term(%Antenna{} = antenna) do
    {{antenna.id, encode_kind(antenna.kind), antenna.type, antenna.serial},
     {antenna.dazi_deg, antenna.zenith_start_deg, antenna.zenith_end_deg, antenna.zenith_step_deg},
     {antenna.sinex_code, encode_datetime(antenna.valid_from), encode_datetime(antenna.valid_until)},
     frequency_terms(antenna.frequencies)}
  end

  defp frequency_terms(frequencies) do
    frequencies
    |> Map.values()
    |> Enum.map(fn %Frequency{} = frequency ->
      {frequency.frequency, frequency.pco_m, Enum.map(frequency.pcv_samples, &pcv_sample_term/1)}
    end)
  end

  defp pcv_sample_term(%{grid: grid, azimuth_deg: azimuth_deg, zenith_deg: zenith_deg, value_m: value_m}) do
    {encode_grid(grid), azimuth_deg, zenith_deg, value_m}
  end

  defp decode_kind("satellite"), do: :satellite
  defp decode_kind(_), do: :receiver

  defp encode_kind(:satellite), do: "satellite"
  defp encode_kind(_), do: "receiver"

  defp decode_grid("azi"), do: :azi
  defp decode_grid(_), do: :noazi

  defp encode_grid(:azi), do: "azi"
  defp encode_grid(_), do: "noazi"

  defp decode_datetime(nil), do: nil

  defp decode_datetime({{year, month, day}, {hour, minute, second, microsecond}}) do
    {:ok, datetime} =
      NaiveDateTime.new(
        year,
        month,
        day,
        hour,
        minute,
        second,
        {microsecond, 6}
      )

    datetime
  end

  defp encode_datetime(datetime), do: Epoch.maybe_datetime_tuple(datetime)
end
