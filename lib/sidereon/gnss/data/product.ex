defmodule Sidereon.GNSS.Data.Product do
  @moduledoc """
  A GNSS product specification: the analysis center, content type, calendar
  date, temporal sampling, and optional issue time that together identify one
  archived file.

  A `Product` is a pure value. It resolves deterministically and without any
  network to a canonical filename, a GPS week, a day-of-year, and a full
  archive URL via `Sidereon.GNSS.Data.Catalog`. Build one with the convenience
  builders (`Sidereon.GNSS.Data.mgex_sp3/2` and friends) or with `new/4`.

  ## Fields

    * `:center`: analysis-center code, e.g. `:gfz`, `:esa`, `:igs`, or an
      ultra-rapid alias such as `:igs_ult`
    * `:content`: content type: `:sp3`, `:clk`, `:nav`, `:ionex`, or `:obs`
      (station observation data, RINEX 3 / CRINEX)
    * `:date`: the product day as a `Date`
    * `:sample`: sampling code string, e.g. `"05M"`, `"30S"`, `"01D"`
    * `:issue`: optional issue time (`"HHMM"`) for sub-daily products such as
      ultra-rapid SP3; daily products leave it `nil`
  """

  alias Sidereon.GNSS.Data.Catalog

  @enforce_keys [:center, :content, :date, :sample]
  defstruct [:center, :content, :date, :sample, :station, :issue]

  @type t :: %__MODULE__{
          center: atom(),
          content: atom(),
          date: Date.t(),
          sample: String.t(),
          station: String.t() | nil,
          issue: String.t() | nil
        }

  @doc """
  Build a `Product`, validating the center, content type, and sampling code.

  Returns `{:ok, %Product{}}` or a tagged error tuple.
  """
  @spec new(atom(), atom(), Date.t(), String.t(), keyword()) ::
          {:ok, t()} | Catalog.error()
  def new(center, content, date, sample, opts \\ [])

  def new(center, :obs, %Date{} = date, sample, opts)
      when is_atom(center) and is_binary(sample) do
    station = Keyword.get(opts, :station)

    # Validate by resolving the station filename, which checks the site id and
    # sampling code in one place.
    with {:ok, _filename} <- Catalog.station_obs_filename(station || "", date, sample) do
      {:ok,
       %__MODULE__{center: center, content: :obs, date: date, sample: sample, station: station}}
    end
  end

  def new(center, content, %Date{} = date, sample, opts)
      when is_atom(center) and is_atom(content) and is_binary(sample) do
    issue = Keyword.get(opts, :issue)

    # Validate by attempting to resolve the canonical name; this checks the
    # center, content type, sampling code, and optional issue time in one place.
    with {:ok, _filename} <- Catalog.canonical_filename(center, content, date, sample, issue) do
      {:ok,
       %__MODULE__{
         center: center,
         content: content,
         date: date,
         sample: sample,
         issue: issue
       }}
    end
  end

  def new(_center, _content, _date, _sample, _opts),
    do: {:error, {:unsupported_product, :bad_arguments}}

  @doc """
  The canonical IGS long-name filename for the product (no `.gz` suffix).
  """
  @spec canonical_filename(t()) :: {:ok, String.t()} | Catalog.error()
  def canonical_filename(%__MODULE__{
        content: :obs,
        station: station,
        date: date,
        sample: sample
      }), do: Catalog.station_obs_filename(station, date, sample)

  def canonical_filename(%__MODULE__{} = p),
    do: Catalog.canonical_filename(p.center, p.content, p.date, p.sample, p.issue)

  @doc """
  The full, compressed archive URL for the product.
  """
  @spec archive_url(t()) :: {:ok, String.t()} | Catalog.error()
  def archive_url(%__MODULE__{content: :obs, station: station, date: date, sample: sample}),
    do: Catalog.station_obs_url(station, date, sample)

  def archive_url(%__MODULE__{} = p),
    do: Catalog.archive_url(p.center, p.content, p.date, p.sample, p.issue)

  @doc """
  The product's GPS week number.
  """
  @spec gps_week(t()) :: non_neg_integer()
  def gps_week(%__MODULE__{date: date}), do: Catalog.gps_week(date)

  @doc """
  The product's day-of-year (`001`-`366`).
  """
  @spec day_of_year(t()) :: 1..366
  def day_of_year(%__MODULE__{date: date}), do: Catalog.day_of_year(date)

  @doc """
  A short, human-readable description used in error messages.
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{} = p) do
    case canonical_filename(p) do
      {:ok, name} -> name
      _ -> "#{p.center}/#{p.content}/#{Date.to_iso8601(p.date)}/#{p.sample}"
    end
  end
end
