defmodule Sidereon.GNSS.RINEX.Clock do
  @moduledoc """
  RINEX clock (`.CLK`) reader for satellite clock-bias records.

  Precise clock products are distributed as RINEX clock files alongside the SP3
  orbit. The SP3 orbit carries satellite clocks too, but only at the SP3 epoch
  spacing (15 minutes for IGS final), whereas the companion `.CLK` file carries
  the same clocks at a much finer cadence (30 seconds for IGS final). Linearly
  interpolating a 15-minute clock across the gap is a metre-level error on the
  faster satellite oscillators; the 30s clock removes almost all of it.

  This reader parses the `AS` (satellite) records of a RINEX clock file
  (versions 2 and 3) into a per-satellite, time-ordered series of clock biases in
  seconds, and interpolates linearly between the two bracketing records at a
  requested epoch:

      AS G05  2026 05 13 00 00  0.000000  2   -2.329120317895e-04  4.4959e-11

  The fields are the record type (`AS`), the satellite id, the epoch
  (year month day hour minute second), the value count, then the clock bias in
  seconds and an optional bias sigma. `AR` (receiver) records are ignored.

  Use `clock_s/3` to read a satellite's interpolated clock bias (seconds) at an
  epoch, matching the convention of `Sidereon.GNSS.SP3.State.clock_s`.

  `load/1` is strict and returns an error when any `AS` record is malformed.
  Use `parse_lossy/1` or `load_lossy/1` only for best-effort recovery from
  products with bad rows.
  """

  alias Sidereon.GNSS.Core.Epoch
  alias Sidereon.NIF

  @enforce_keys [:series]
  defstruct [:series]

  @type t :: %__MODULE__{series: %{String.t() => [{float(), float()}]}}

  @doc """
  Load a RINEX clock file, raising on error.
  """
  @spec load!(String.t()) :: t()
  def load!(path) when is_binary(path) do
    case load(path) do
      {:ok, clock} ->
        clock

      {:error, reason} ->
        raise ArgumentError, "could not load RINEX clock #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Load a RINEX clock file with best-effort row recovery, raising on file errors.

  Malformed `AS` records are skipped. Non-satellite rows are ignored, matching
  `parse_lossy/1`.
  """
  @spec load_lossy!(String.t()) :: t()
  def load_lossy!(path) when is_binary(path) do
    case load_lossy(path) do
      {:ok, clock} ->
        clock

      {:error, reason} ->
        raise ArgumentError, "could not load RINEX clock #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Load a RINEX clock file.

  Returns `{:ok, %Sidereon.GNSS.RINEX.Clock{}}` or `{:error, reason}`. The series is
  per-satellite, sorted ascending by GPS-seconds time tag, with each entry
  `{gps_seconds, clock_bias_s}`.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> parse(contents)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Load a RINEX clock file while skipping malformed `AS` records.

  This is a best-effort parser for recovery workflows. Use `load/1` for normal
  ingestion so malformed clock products are reported.
  """
  @spec load_lossy(String.t()) :: {:ok, t()} | {:error, term()}
  def load_lossy(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> parse_lossy(contents)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parse RINEX clock text while skipping malformed `AS` records.

  Returns `{:ok, %Sidereon.GNSS.RINEX.Clock{}}`. Receiver records and malformed
  satellite records are ignored; valid satellite records remain available
  through `clock_s/3`.
  """
  @spec parse_lossy(binary()) :: {:ok, t()} | {:error, term()}
  def parse_lossy(contents) when is_binary(contents) do
    parse_with(contents, &NIF.rinex_clock_parse_lossy/1)
  end

  @doc """
  Interpolated satellite clock bias in seconds at `epoch`.

  Returns `{:ok, bias_s}` when the satellite has records bracketing the epoch (or
  an exact-match record), `{:error, :no_clock}` when the satellite is unknown or
  the epoch lies outside its record span. Linear interpolation between the two
  nearest records; no extrapolation past the first/last record.
  """
  @spec clock_s(t(), String.t(), NaiveDateTime.t()) :: {:ok, float()} | {:error, :no_clock}
  def clock_s(%__MODULE__{series: series}, satellite_id, %NaiveDateTime{} = epoch)
      when is_binary(satellite_id) do
    NIF.rinex_clock_clock_s(Map.to_list(series), satellite_id, Epoch.datetime_tuple(epoch))
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp parse(contents) do
    parse_with(contents, &NIF.rinex_clock_parse/1)
  end

  defp parse_with(contents, parser) do
    case parser.(contents) do
      {:ok, rows} -> {:ok, %__MODULE__{series: Map.new(rows)}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e in ErlangError ->
      {:error, e.original}
  end
end
