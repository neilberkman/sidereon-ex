defmodule Sidereon.Format.TLE do
  @moduledoc """
  Parse and encode Two-Line Element sets.

  TLE is the legacy fixed-width format for satellite orbital elements,
  designed for 80-column punch cards in the 1960s. Despite its age,
  it remains the most widely used format for distributing orbital data.

  The format grammar lives in the Rust core (`astrodynamics::tle`): fixed-width
  field extraction and validation, the modulo-10 checksum, the "assumed decimal"
  drag-term codec, per-field number formatting, and the two-digit-year pivot.
  This module keeps the Sidereon API shape: it marshals the epoch between its native
  `DateTime` and the `(epoch_year, epoch_day_of_year)` pair the core exposes,
  applies input defaults, logs advisory checksum warnings, and maps errors.

  ## Parsing

  The parser is liberal in what it accepts:
  - Trailing whitespace and extra characters are trimmed
  - Leading dots in floats (`.123` → `0.123`)
  - Spaces in numeric fields

  Checksum validation is performed and reported but does not prevent parsing.

  ## Examples

      {:ok, elements} = Sidereon.Format.TLE.parse(line1, line2)
      {:ok, {line1, line2}} = Sidereon.Format.TLE.encode(elements)
  """

  alias Sidereon.Elements
  alias Sidereon.NIF

  require Logger

  @microseconds_per_day 86_400 * 1_000_000

  @type encode_error ::
          {:missing_field, atom()}
          | {:invalid_field, atom(), term()}
          | {:encode_error, String.t()}

  @doc """
  Parse a two-line element set into an `%Sidereon.Elements{}` struct.

  Returns `{:ok, elements}` or `{:error, reason}`.
  Logs a warning if checksums are invalid but still parses.

  ## Examples

      iex> {:ok, el} = Sidereon.Format.TLE.parse(
      ...>   "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993",
      ...>   "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
      ...> )
      iex> el.catalog_number
      "25544"
      iex> el.inclination_deg
      51.6414

  """
  @spec parse(String.t(), String.t()) :: {:ok, Elements.t()} | {:error, String.t()}
  def parse(longstr1, longstr2) do
    case NIF.tle_parse(longstr1, longstr2) do
      {:ok, fields, checksum_warnings} ->
        log_checksum_warnings(checksum_warnings)
        {:ok, build_elements(fields)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Encode an `%Sidereon.Elements{}` struct as TLE-format strings.

  Returns `{:ok, {line1, line2}}`: two 69-character strings with valid
  checksums, or `{:error, reason}` for malformed elements. Round-trips are
  character-exact for standard TLEs.

  ## Examples

      iex> l1 = "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
      iex> l2 = "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"
      iex> {:ok, el} = Sidereon.Format.TLE.parse(l1, l2)
      iex> {:ok, {gen_l1, gen_l2}} = Sidereon.Format.TLE.encode(el)
      iex> gen_l1 == l1
      true
      iex> gen_l2 == l2
      true

  """
  @spec encode(Elements.t()) :: {:ok, {String.t(), String.t()}} | {:error, encode_error()}
  def encode(%Elements{} = el) do
    with {:ok, fields} <- encode_fields(el) do
      encode_with_nif(fields)
    end
  end

  @doc """
  Like `encode/1` but raises on malformed elements.
  """
  @spec encode!(Elements.t()) :: {String.t(), String.t()}
  def encode!(%Elements{} = el) do
    case encode(el) do
      {:ok, lines} ->
        lines

      {:error, reason} ->
        raise ArgumentError, "could not encode TLE: #{inspect(reason)}"
    end
  end

  # -- Parse: marshal the core result into the public struct --

  defp build_elements(fields) do
    %Elements{
      catalog_number: fields.catalog_number,
      classification: fields.classification,
      international_designator: fields.international_designator,
      epoch: calculate_epoch(fields.epoch_year, fields.epoch_day_of_year),
      mean_motion_dot: fields.mean_motion_dot,
      mean_motion_double_dot: fields.mean_motion_double_dot,
      bstar: fields.bstar,
      ephemeris_type: fields.ephemeris_type,
      elset_number: fields.elset_number,
      inclination_deg: fields.inclination_deg,
      raan_deg: fields.raan_deg,
      eccentricity: fields.eccentricity,
      arg_perigee_deg: fields.arg_perigee_deg,
      mean_anomaly_deg: fields.mean_anomaly_deg,
      mean_motion: fields.mean_motion,
      rev_number: fields.rev_number
    }
  end

  defp log_checksum_warnings(warnings) do
    Enum.each(warnings, fn {label, expected, computed} ->
      Logger.warning("TLE #{label} checksum mismatch: expected #{expected}, computed #{computed}")
    end)
  end

  # Build a UTC DateTime from the TLE epoch year and one-based fractional
  # day-of-year. This is the host's native epoch type; the format parsing itself
  # lives in the core.
  defp calculate_epoch(year, epochdays) do
    days_from_jan1 = epochdays - 1
    whole_days = trunc(days_from_jan1)
    fractional_day = days_from_jan1 - whole_days

    start = DateTime.new!(Date.new!(year, 1, 1), Time.new!(0, 0, 0, 0), "Etc/UTC")
    with_days = DateTime.add(start, whole_days, :day)
    microseconds = round(fractional_day * @microseconds_per_day)
    DateTime.add(with_days, microseconds, :microsecond)
  end

  # -- Encode: normalize inputs and marshal the epoch for the core --

  defp encode_fields(%Elements{} = el) do
    with {:ok, catalog_number} <- required_catalog_number(el),
         {:ok, classification} <- required_classification(el),
         {:ok, international_designator} <- required_string(el, :international_designator),
         {:ok, epoch} <- required_datetime(el, :epoch),
         {:ok, mean_motion_dot} <- required_float(el, :mean_motion_dot),
         {:ok, mean_motion_double_dot} <- required_float(el, :mean_motion_double_dot),
         {:ok, bstar} <- required_float(el, :bstar),
         {:ok, ephemeris_type} <- required_integer(el, :ephemeris_type),
         {:ok, elset_number} <- required_bounded_integer(el, :elset_number, 0, 9999),
         {:ok, inclination_deg} <- required_float(el, :inclination_deg),
         {:ok, raan_deg} <- required_float(el, :raan_deg),
         {:ok, eccentricity} <- required_float(el, :eccentricity),
         {:ok, arg_perigee_deg} <- required_float(el, :arg_perigee_deg),
         {:ok, mean_anomaly_deg} <- required_float(el, :mean_anomaly_deg),
         {:ok, mean_motion} <- required_float(el, :mean_motion),
         {:ok, rev_number} <- required_bounded_integer(el, :rev_number, 0, 99_999) do
      {:ok,
       %{
         catalog_number: catalog_number,
         classification: classification,
         international_designator: international_designator,
         epoch_year: epoch.year,
         epoch_day_of_year: epoch_day_of_year(epoch),
         mean_motion_dot: mean_motion_dot,
         mean_motion_double_dot: mean_motion_double_dot,
         bstar: bstar,
         ephemeris_type: ephemeris_type,
         elset_number: elset_number,
         inclination_deg: inclination_deg,
         raan_deg: raan_deg,
         eccentricity: eccentricity,
         arg_perigee_deg: arg_perigee_deg,
         mean_anomaly_deg: mean_anomaly_deg,
         mean_motion: mean_motion,
         rev_number: rev_number
       }}
    end
  end

  # Fractional one-based day-of-year of a UTC DateTime (the TLE epoch convention).
  defp epoch_day_of_year(epoch) do
    jan1 = DateTime.new!(Date.new!(epoch.year, 1, 1), Time.new!(0, 0, 0, 0), "Etc/UTC")
    diff_us = DateTime.diff(epoch, jan1, :microsecond)
    1.0 + diff_us / @microseconds_per_day
  end

  defp encode_with_nif(fields) do
    {:ok, NIF.tle_encode(fields)}
  rescue
    e in ErlangError -> {:error, {:encode_error, Exception.message(e)}}
  end

  defp required_catalog_number(%Elements{} = el) do
    with {:ok, value} <- required_string(el, :catalog_number) do
      catalog_number = String.trim(value)

      cond do
        catalog_number == "" ->
          {:error, {:invalid_field, :catalog_number, value}}

        String.length(catalog_number) > 5 ->
          {:error, {:invalid_field, :catalog_number, catalog_number}}

        true ->
          {:ok, catalog_number}
      end
    end
  end

  defp required_classification(%Elements{} = el) do
    with {:ok, value} <- required_string(el, :classification) do
      if String.length(value) == 1 do
        {:ok, value}
      else
        {:error, {:invalid_field, :classification, value}}
      end
    end
  end

  defp required_string(%Elements{} = el, field) do
    case Map.fetch!(el, field) do
      nil -> {:error, {:missing_field, field}}
      value when is_binary(value) -> {:ok, value}
      value -> {:error, {:invalid_field, field, value}}
    end
  end

  defp required_datetime(%Elements{} = el, field) do
    case Map.fetch!(el, field) do
      nil -> {:error, {:missing_field, field}}
      %DateTime{} = value -> {:ok, value}
      value -> {:error, {:invalid_field, field, value}}
    end
  end

  defp required_float(%Elements{} = el, field) do
    case Map.fetch!(el, field) do
      nil -> {:error, {:missing_field, field}}
      value when is_float(value) -> {:ok, value}
      value when is_integer(value) -> {:ok, value * 1.0}
      value -> {:error, {:invalid_field, field, value}}
    end
  end

  defp required_integer(%Elements{} = el, field) do
    case Map.fetch!(el, field) do
      nil -> {:error, {:missing_field, field}}
      value when is_integer(value) -> {:ok, value}
      value -> {:error, {:invalid_field, field, value}}
    end
  end

  defp required_bounded_integer(%Elements{} = el, field, min, max) do
    with {:ok, value} <- required_integer(el, field) do
      if value >= min and value <= max do
        {:ok, value}
      else
        {:error, {:invalid_field, field, value}}
      end
    end
  end
end
