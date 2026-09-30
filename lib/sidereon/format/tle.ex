defmodule Sidereon.Format.TLE do
  @moduledoc """
  Parse and encode Two-Line Element sets.

  TLE is the legacy fixed-width format for satellite orbital elements,
  designed for 80-column punch cards in the 1960s. Despite its age,
  it remains the most widely used format for distributing orbital data.

  The format grammar lives in the Rust core (`sidereon_core::astro::tle`): fixed-width
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

  Column 69 holds the modulo-10 checksum of columns 1-68. Under the default
  `policy: :strict`, a digit that disagrees with the checksum, or a column 69
  that is not a digit, is refused. `policy: :lenient` reads such a line, as
  Vallado's `twoline2rv` does, and reports each finding as a checksum warning.
  A line that ends before column 69 carries no checksum; it is read and
  reported under both policies.

  ## Examples

      {:ok, elements} = Sidereon.Format.TLE.parse(line1, line2)
      {:ok, {line1, line2}} = Sidereon.Format.TLE.encode(elements)
  """

  alias Sidereon.CCSDS.Error
  alias Sidereon.Elements
  alias Sidereon.NIF
  alias Sidereon.NifCall

  require Logger

  @microseconds_per_day 86_400 * 1_000_000

  @typedoc "How column 69, the line checksum, is treated."
  @type policy :: :strict | :lenient

  @typedoc """
  A line whose column 69 did not confirm its checksum: the line label
  (`"line 1"` or `"line 2"`), what column 69 held (`{:mismatch, digit}`,
  `{:not_digit, character}` or `:missing`), and the checksum computed from
  columns 1-68.
  """
  @type checksum_warning ::
          {String.t(), {:mismatch, 0..9} | {:not_digit, String.t()} | :missing, 0..9}

  @typedoc """
  Why a stretch of a TLE file did not become a satellite: `{:invalid, reason}`
  for an element set refused by the TLE grammar, the checksum policy or SGP4
  initialization, `:missing_line_2` for a line 1 with no line 2 after it,
  `:orphan_line_2` for a line 2 with no line 1 before it, and `:orphan_name`
  for a name line not followed by an element set.
  """
  @type record_issue ::
          {:invalid, Error.sgp4()} | :missing_line_2 | :orphan_line_2 | :orphan_name

  @typedoc "A rejected stretch of a TLE file, with the one-based line number of its first line."
  @type rejected_record :: %{
          line_number: pos_integer(),
          name: String.t(),
          issue: record_issue()
        }

  @typedoc "A satellite read from a TLE file."
  @type file_satellite :: %{
          name: String.t(),
          tle: Elements.t(),
          line_number: pos_integer(),
          checksum_warnings: [checksum_warning()]
        }

  @type encode_error ::
          {:missing_field, atom()}
          | {:invalid_field, atom(), term()}
          | {:encode_error, Error.tle()}
          | Sidereon.argument_error()

  @doc """
  Parse a two-line element set into an `%Sidereon.Elements{}` struct.

  Returns `{:ok, elements}` or `{:error, reason}`. Each checksum warning the
  policy accepts is logged; `parse_with_warnings/3` returns them instead.

  ## Options

    * `:policy` - `:strict` (default) or `:lenient`; see the module
      documentation.

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
  @spec parse(String.t(), String.t(), keyword()) ::
          {:ok, Elements.t()} | {:error, Error.tle() | {:invalid_field, :policy, term()}}
  def parse(longstr1, longstr2, opts \\ []) do
    case parse_with_warnings(longstr1, longstr2, opts) do
      {:ok, elements, checksum_warnings} ->
        log_checksum_warnings(checksum_warnings)
        {:ok, elements}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parse a two-line element set, returning the checksum warnings the policy
  accepted alongside the elements instead of logging them.

  Returns `{:ok, elements, checksum_warnings}` or `{:error, reason}`. Takes the
  same options as `parse/3`.
  """
  @spec parse_with_warnings(String.t(), String.t(), keyword()) ::
          {:ok, Elements.t(), [checksum_warning()]}
          | {:error, Error.tle() | {:invalid_field, :policy, term()}}
  def parse_with_warnings(longstr1, longstr2, opts \\ []) do
    with {:ok, policy} <- policy_opt(opts) do
      case NIF.tle_parse(longstr1, longstr2, policy) do
        {:ok, fields, checksum_warnings} -> {:ok, build_elements(fields), checksum_warnings}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Parse a multi-record TLE file (CelesTrak / Space-Track style).

  Accepts the common variants in a single pass: bare two-line element sets,
  three-line sets (a name line followed by lines 1 and 2), and CelesTrak
  `0 NAME` name lines. Blank lines, CRLF endings, and surrounding whitespace are
  tolerated.

  Returns `{:ok, %{satellites: satellites, rejected: rejected, skipped: n}}`.
  Each satellite is a map with `name`, `tle`, `line_number` (the one-based line
  of its line 1) and `checksum_warnings`. Each `tle` is a fully populated
  `%Sidereon.Elements{}` (with `object_name` set to the record's name, or `nil`
  for a bare two-line set) ready for `Sidereon.propagate/2`,
  `Sidereon.look_angle/3`, and friends. `name` is the empty string for a bare
  two-line record. `rejected` lists every other non-blank line in file order,
  each with its line number, its name line and the reason (see
  `t:record_issue/0`); one bad record never discards the others. `skipped` is
  the length of `rejected`, so an empty file (`satellites: []`, `skipped: 0`)
  is distinguishable from a fully corrupt one.

  ## Options

    * `:policy` - `:strict` (default) or `:lenient`; under `:strict` a record
      whose checksum digit disagrees, or whose column 69 is not a digit, is
      rejected, and under `:lenient` it is kept and each finding is listed in
      its `checksum_warnings`.

  ## Examples

      iex> text = \"\"\"
      ...> ISS (ZARYA)
      ...> 1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993
      ...> 2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106
      ...> \"\"\"
      iex> {:ok, %{satellites: [sat], skipped: 0}} = Sidereon.Format.TLE.parse_file(text)
      iex> sat.name
      "ISS (ZARYA)"
      iex> sat.tle.catalog_number
      "25544"

  """
  @spec parse_file(String.t(), keyword()) ::
          {:ok,
           %{
             satellites: [file_satellite()],
             rejected: [rejected_record()],
             skipped: non_neg_integer()
           }}
          | {:error, {:invalid_field, :policy, term()}}
  def parse_file(text, opts \\ []) when is_binary(text) do
    with {:ok, policy} <- policy_opt(opts) do
      {:ok, satellites, rejected} = NIF.parse_tle_file(text, policy)

      parsed =
        Enum.map(satellites, fn {name, fields, line_number, checksum_warnings} ->
          object_name = if name != "", do: name

          %{
            name: name,
            tle: %{build_elements(fields) | object_name: object_name},
            line_number: line_number,
            checksum_warnings: checksum_warnings
          }
        end)

      rejected =
        Enum.map(rejected, fn {line_number, name, issue} ->
          %{line_number: line_number, name: name, issue: issue}
        end)

      {:ok, %{satellites: parsed, rejected: rejected, skipped: length(rejected)}}
    end
  end

  defp policy_opt(opts) do
    case Keyword.get(opts, :policy, :strict) do
      policy when policy in [:strict, :lenient] -> {:ok, policy}
      other -> {:error, {:invalid_field, :policy, other}}
    end
  end

  @doc """
  Encode an `%Sidereon.Elements{}` struct as TLE-format strings.

  Returns `{:ok, {line1, line2}}`: two 69-character strings with valid
  checksums, or `{:error, reason}` for malformed elements. Round-trips are
  character-exact for standard TLEs. A TLE states a catalog number, so
  elements without one, as `Sidereon.Format.OMM.to_elements/1` gives for an
  OMM without `NORAD_CAT_ID`, are refused with
  `{:error, {:missing_field, :catalog_number}}`.

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
      mean_motion_double_dot_text: fields.mean_motion_double_dot_text,
      bstar: fields.bstar,
      bstar_text: fields.bstar_text,
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
    Enum.each(warnings, fn
      {label, {:mismatch, expected}, computed} ->
        Logger.warning("TLE #{label} checksum mismatch: column 69 holds #{expected}, computed #{computed}")

      {label, {:not_digit, found}, computed} ->
        Logger.warning("TLE #{label} column 69 holds #{inspect(found)}, not the checksum digit #{computed}")

      {label, :missing, computed} ->
        Logger.warning("TLE #{label} ends before column 69 and carries no checksum (computed #{computed})")
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
         {:ok, bstar_text} <- optional_string(el, :bstar_text),
         {:ok, mean_motion_double_dot_text} <- optional_string(el, :mean_motion_double_dot_text),
         {:ok, ephemeris_type} <- optional_bounded_integer(el, :ephemeris_type, 0, 9),
         {:ok, elset_number} <- optional_bounded_integer(el, :elset_number, 0, 9999),
         {:ok, inclination_deg} <- required_float(el, :inclination_deg),
         {:ok, raan_deg} <- required_float(el, :raan_deg),
         {:ok, eccentricity} <- required_float(el, :eccentricity),
         {:ok, arg_perigee_deg} <- required_float(el, :arg_perigee_deg),
         {:ok, mean_anomaly_deg} <- required_float(el, :mean_anomaly_deg),
         {:ok, mean_motion} <- required_float(el, :mean_motion),
         {:ok, rev_number} <- optional_bounded_integer(el, :rev_number, 0, 99_999) do
      {:ok,
       %{
         catalog_number: catalog_number,
         classification: classification,
         international_designator: international_designator,
         epoch_year: epoch.year,
         epoch_day_of_year: epoch_day_of_year(epoch),
         mean_motion_dot: mean_motion_dot,
         mean_motion_double_dot: mean_motion_double_dot,
         mean_motion_double_dot_text: mean_motion_double_dot_text,
         bstar: bstar,
         bstar_text: bstar_text,
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
    case NIF.tle_encode(fields) do
      {:ok, lines} -> {:ok, lines}
      {:error, message} -> {:error, {:encode_error, message}}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :tle_encode)
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

  defp optional_string(%Elements{} = el, field) do
    case Map.get(el, field) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      value -> {:error, {:invalid_field, field, value}}
    end
  end

  # A `nil` field is written blank, as a blank field reads back as `nil`.
  defp optional_bounded_integer(%Elements{} = el, field, min, max) do
    case Map.fetch!(el, field) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      value -> {:error, {:invalid_field, field, value}}
    end
  end
end
