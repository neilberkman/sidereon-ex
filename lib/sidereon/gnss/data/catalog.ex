defmodule Sidereon.GNSS.Data.Catalog do
  @moduledoc """
  Detailed, read-only access to core catalog queries.

  These explicit counterparts preserve structured catalog failures as
  `%CatalogError{}` values. The higher-level `Sidereon.GNSS.Data` functions
  retain their established return values for compatibility.
  """

  alias Sidereon.GNSS.Distribution.ProductIdentity
  alias Sidereon.GNSS.ExactCache
  alias Sidereon.NIF

  defmodule CatalogError do
    @moduledoc "Typed details returned by a core GNSS catalog query."
    @enforce_keys [:kind, :fields, :message]
    defstruct [:kind, :fields, :message]

    @type t :: %__MODULE__{
            kind: atom(),
            fields: %{optional(atom()) => term()},
            message: String.t()
          }
  end

  @doc """
  Return the solution class while retaining typed catalog errors.

  This explicit query is useful when callers need the core error kind and
  fields. `Sidereon.GNSS.Data.product_solution_class/2` keeps its legacy terms.
  """
  @spec product_solution_class(term(), term()) :: {:ok, String.t()} | {:error, CatalogError.t() | term()}
  def product_solution_class(center, product_type) do
    NIF.data_product_solution_class_catalog_details(
      normalize_code(center),
      normalize_code(product_type)
    )
    |> preserve_catalog_error()
  end

  @doc """
  Return the SP3 first-content convention while retaining typed catalog errors.

  The result on success is the core `{value, offset_seconds}` pair. Catalog
  failures include their kind, every variant-specific field, and exact message.
  """
  @spec sp3_content_start_convention(term(), Date.t() | NaiveDateTime.t() | tuple(), term() | nil) ::
          {:ok, {String.t(), integer()}} | {:error, CatalogError.t() | term()}
  def sp3_content_start_convention(center, date, issue \\ nil) do
    with {:ok, {year, month, day}} <- date_parts(date) do
      center = normalize_code(center)
      issue = if !is_nil(issue), do: to_string(issue)

      NIF.data_sp3_content_start_convention_catalog_details(
        center,
        year,
        month,
        day,
        issue
      )
      |> preserve_catalog_error()
    end
  end

  @doc """
  Validate a public product identity through the core catalog while retaining
  all typed field and filename diagnostics.
  """
  @spec validate_product_identity(ProductIdentity.t()) ::
          {:ok, term()} | {:error, CatalogError.t() | term()}
  def validate_product_identity(%ProductIdentity{} = identity) do
    identity
    |> ExactCache.identity_fields()
    |> NIF.data_validate_product_identity_catalog_details()
    |> preserve_catalog_error()
  end

  @doc """
  Resolve an exact product identity while retaining typed catalog errors.
  """
  @spec product_identity(term(), term(), Date.t() | NaiveDateTime.t() | tuple(), term() | nil, term() | nil) ::
          {:ok, term()} | {:error, CatalogError.t() | term()}
  def product_identity(center, product_type, date, sample \\ nil, issue \\ nil) do
    with {:ok, {year, month, day}} <- date_parts(date) do
      NIF.data_product_identity_catalog_details(
        normalize_code(center),
        normalize_code(product_type),
        year,
        month,
        day,
        if(!is_nil(sample), do: to_string(sample)),
        if(!is_nil(issue), do: to_string(issue))
      )
      |> preserve_catalog_error()
    end
  end

  @doc """
  Return ultra-rapid issue candidates for a date-time while retaining typed
  date and issue diagnostics.
  """
  @spec ultra_issue_candidates(term(), NaiveDateTime.t() | DateTime.t() | tuple()) ::
          {:ok, term()} | {:error, CatalogError.t() | term()}
  def ultra_issue_candidates(center, target) do
    with {:ok, {year, month, day, hour, minute, second}} <- datetime_parts(target) do
      NIF.data_ultra_issue_candidates_catalog_details(
        normalize_code(center),
        year,
        month,
        day,
        hour,
        minute,
        second
      )
      |> preserve_catalog_error()
    end
  end

  @doc """
  Return the latest ultra-rapid issue at or before a UTC instant.

  `available_issues` is `nil` when availability is unknown, or a list of
  `{date, issue}` tuples such as `{{2026, 1, 2}, "0000"}` when it is known.
  """
  @spec latest_ultra_issue(term(), NaiveDateTime.t() | DateTime.t() | tuple(), list() | nil) ::
          {:ok, term()} | {:error, CatalogError.t() | term()}
  def latest_ultra_issue(center, target, available_issues \\ nil) do
    with {:ok, {year, month, day, hour, minute, second}} <- datetime_parts(target) do
      available =
        if !is_nil(available_issues) do
          Enum.map(available_issues, fn {{issue_year, issue_month, issue_day}, issue} ->
            {issue_year, issue_month, issue_day, to_string(issue)}
          end)
        end

      NIF.data_latest_ultra_issue_catalog_details(
        normalize_code(center),
        year,
        month,
        day,
        hour,
        minute,
        second,
        available
      )
      |> preserve_catalog_error()
    end
  end

  @doc """
  Return the next nominal issue due while retaining typed catalog errors.
  """
  @spec next_issue_due(term(), term(), NaiveDateTime.t() | DateTime.t() | tuple()) ::
          {:ok, term()} | {:error, CatalogError.t() | term()}
  def next_issue_due(center, product_type, target) do
    with {:ok, {year, month, day, hour, minute, second}} <- datetime_parts(target) do
      NIF.data_next_issue_due_catalog_details(
        normalize_code(center),
        normalize_code(product_type),
        year,
        month,
        day,
        hour,
        minute,
        second
      )
      |> preserve_catalog_error()
    end
  end

  @doc """
  Convert a GPS week and day-of-week to a civil date, preserving range errors.
  """
  @spec date_from_gps_week_day(non_neg_integer(), integer()) ::
          {:ok, {integer(), integer(), integer()}} | {:error, CatalogError.t() | term()}
  def date_from_gps_week_day(week, day_of_week) when is_integer(week) and week >= 0 and is_integer(day_of_week) do
    NIF.data_product_date_from_gps_week_day_catalog_details(week, day_of_week)
    |> preserve_catalog_error()
  end

  @doc """
  Parse an archive listing without reducing an unreadable-listing failure to a
  legacy reason tuple.
  """
  @spec parse_archive_listing(binary()) :: {:ok, term()} | {:error, CatalogError.t() | term()}
  def parse_archive_listing(body) when is_binary(body) do
    NIF.data_parse_archive_listing_catalog_details(body) |> preserve_catalog_error()
  end

  @doc """
  Derive a Skadi tile id while retaining invalid tile-index details.
  """
  @spec skadi_tile_id(integer(), integer()) :: {:ok, String.t()} | {:error, CatalogError.t() | term()}
  def skadi_tile_id(latitude_index, longitude_index) when is_integer(latitude_index) and is_integer(longitude_index) do
    NIF.data_skadi_tile_id_catalog_details(latitude_index, longitude_index)
    |> preserve_catalog_error()
  end

  @doc """
  Parse a Skadi tile id while retaining invalid tile-id details.
  """
  @spec parse_skadi_tile_id(String.t()) :: {:ok, term()} | {:error, CatalogError.t() | term()}
  def parse_skadi_tile_id(tile_id) when is_binary(tile_id) do
    NIF.data_parse_skadi_tile_id_catalog_details(tile_id) |> preserve_catalog_error()
  end

  @doc """
  Derive a terrain tile index while retaining invalid-coordinate details.
  """
  @spec terrain_tile_index(number(), number()) :: {:ok, term()} | {:error, CatalogError.t() | term()}
  def terrain_tile_index(latitude, longitude) when is_number(latitude) and is_number(longitude) do
    NIF.data_terrain_tile_index_catalog_details(latitude / 1.0, longitude / 1.0)
    |> preserve_catalog_error()
  end

  @doc """
  Confirm that a center and product pair has a cataloged open mirror.
  """
  @spec open_mirror(term(), term()) :: {:ok, :ok} | {:error, CatalogError.t() | term()}
  def open_mirror(center, product_type) do
    NIF.data_open_mirror_catalog_details(
      normalize_code(center),
      normalize_code(product_type)
    )
    |> preserve_catalog_error()
  end

  @doc """
  Resolve an explicit distributor for an exact identity while retaining
  distributor, mirror, and era diagnostics.
  """
  @spec distribution_location(ProductIdentity.t(), atom() | String.t()) ::
          {:ok, term()} | {:error, CatalogError.t() | term()}
  def distribution_location(%ProductIdentity{} = identity, source) do
    NIF.data_distribution_location_for_identity_catalog_details(
      ExactCache.identity_fields(identity),
      normalize_source(source)
    )
    |> preserve_catalog_error()
  end

  @doc """
  Validate an exact product request and its ordered distributor choices.
  """
  @spec product_request(ProductIdentity.t(), [atom() | String.t()]) ::
          {:ok, term()} | {:error, CatalogError.t() | term()}
  def product_request(%ProductIdentity{} = identity, distributors) when is_list(distributors) do
    sources = Enum.map(distributors, &normalize_source/1)

    NIF.data_product_request_catalog_details(
      ExactCache.identity_fields(identity),
      sources
    )
    |> preserve_catalog_error()
  end

  @doc """
  Return a station observation filename while retaining station and date
  validation diagnostics.
  """
  @spec station_obs_filename(String.t(), Date.t() | tuple(), String.t()) ::
          {:ok, String.t()} | {:error, CatalogError.t() | term()}
  def station_obs_filename(station, date, sample) do
    with {:ok, {year, month, day}} <- date_parts(date) do
      NIF.data_station_obs_filename_catalog_details(station, year, month, day, sample)
      |> preserve_catalog_error()
    end
  end

  @doc """
  Select the newest matching product in a readable archive listing, retaining
  any catalog diagnostics.
  """
  @spec newest_published_product(term(), term(), [{String.t(), String.t() | nil}]) ::
          {:ok, term()} | {:error, CatalogError.t() | term()}
  def newest_published_product(center, product_type, objects) when is_list(objects) do
    NIF.data_newest_published_product_catalog_details(
      normalize_code(center),
      normalize_code(product_type),
      objects
    )
    |> preserve_catalog_error()
  end

  defp preserve_catalog_error({:error, {:unsupported_product, {:catalog_error, details}}}) when is_map(details) do
    {:error,
     %CatalogError{
       kind: Map.fetch!(details, :kind),
       fields: Map.drop(details, [:kind, :message]),
       message: Map.fetch!(details, :message)
     }}
  end

  defp preserve_catalog_error(result), do: result

  defp normalize_source(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_source(value) when is_binary(value), do: value
  defp normalize_source(value), do: to_string(value)

  defp normalize_code(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_code(value) when is_binary(value), do: value
  defp normalize_code(value), do: to_string(value)

  defp date_parts(%Date{year: year, month: month, day: day}), do: {:ok, {year, month, day}}

  defp date_parts(%NaiveDateTime{year: year, month: month, day: day}), do: {:ok, {year, month, day}}

  defp date_parts({year, month, day}) when is_integer(year) and is_integer(month) and is_integer(day),
    do: {:ok, {year, month, day}}

  defp datetime_parts(%NaiveDateTime{} = target),
    do: {:ok, {target.year, target.month, target.day, target.hour, target.minute, target.second}}

  defp datetime_parts(%DateTime{} = target) do
    utc = DateTime.from_unix!(DateTime.to_unix(target, :second), :second)
    {:ok, {utc.year, utc.month, utc.day, utc.hour, utc.minute, utc.second}}
  end

  defp datetime_parts({year, month, day, hour, minute, second}), do: {:ok, {year, month, day, hour, minute, second}}
end
