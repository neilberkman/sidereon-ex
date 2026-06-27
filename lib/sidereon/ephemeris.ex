defmodule Sidereon.Ephemeris do
  @moduledoc """
  JPL SPK/BSP ephemeris file reader.

  Computes positions of solar system bodies, spacecraft, and minor planets
  using JPL SPK/BSP kernels (DE421, DE440, Horizons exports, etc.).

  Reading is delegated to `sidereon_core::astro::spk`, the validated SPK reader
  shared by the rest of the engine. It evaluates SPK segment types 2 (Chebyshev
  position), 3 (Chebyshev state), and 21 (Extended Modified Difference Arrays),
  so DE-series planetary kernels and Horizons spacecraft / asteroid kernels are
  all supported through the same code path.

  ## Example

      {:ok, eph} = Sidereon.Ephemeris.load("de421.bsp")
      {:ok, {x, y, z}} = Sidereon.Ephemeris.position(eph, :sun, :earth, ~U[2024-01-01 12:00:00Z])

  ## Bodies

  Bodies may be given as atoms (`:ssb` / `:solar_system_barycenter`, `:mercury`,
  `:venus`, `:earth_moon_barycenter` / `:emb`, `:mars`, `:jupiter`, `:saturn`,
  `:uranus`, `:neptune`, `:pluto`, `:sun`, `:moon`, `:earth`) or as raw NAIF
  integer codes. Integer codes pass straight through to the reader, which is how
  spacecraft and minor-planet kernels are queried (e.g. `20000433` for 433 Eros).
  """

  defstruct [:path]

  @type t :: %__MODULE__{path: String.t()}
  @type body :: atom() | integer()
  @type epoch :: DateTime.t() | NaiveDateTime.t() | float() | integer()
  @type vec3 :: {float(), float(), float()}
  @type load_error :: {:file_error, File.posix()} | {:invalid_path, term()}
  @type position_error ::
          {:invalid_body, term()}
          | {:invalid_datetime, term()}
          | {:nif_error, term()}

  # Body atom -> NAIF integer code. Integer codes are accepted directly, so this
  # only needs the conventional names; the reader resolves the rest.
  @body_codes %{
    ssb: 0,
    solar_system_barycenter: 0,
    mercury: 1,
    mercury_barycenter: 1,
    venus: 2,
    venus_barycenter: 2,
    earth_moon_barycenter: 3,
    emb: 3,
    mars: 4,
    mars_barycenter: 4,
    jupiter: 5,
    jupiter_barycenter: 5,
    saturn: 6,
    saturn_barycenter: 6,
    uranus: 7,
    uranus_barycenter: 7,
    neptune: 8,
    neptune_barycenter: 8,
    pluto: 9,
    pluto_barycenter: 9,
    sun: 10,
    moon: 301,
    earth: 399
  }

  @doc """
  Load an SPK/BSP ephemeris file.

  Returns `{:ok, ephemeris}` with a handle that can be passed to `position/4`,
  or `{:error, reason}` when the file cannot be loaded.
  The file is not held open; it is read on each `position/4` call.

  ## Example

      {:ok, eph} = Sidereon.Ephemeris.load("/path/to/de421.bsp")
  """
  @spec load(term()) :: {:ok, t()} | {:error, load_error()}
  def load(path) when is_binary(path) do
    expanded = Path.expand(path)

    case File.stat(expanded) do
      {:ok, %File.Stat{type: :regular}} -> {:ok, %__MODULE__{path: expanded}}
      {:ok, _stat} -> {:error, {:invalid_path, path}}
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  def load(path), do: {:error, {:invalid_path, path}}

  @doc """
  Like `load/1` but raises on failure.
  """
  @spec load!(String.t()) :: t()
  def load!(path) when is_binary(path) do
    case load(path) do
      {:ok, ephemeris} ->
        ephemeris

      {:error, reason} ->
        raise ArgumentError, "could not load SPK/BSP #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Compute the position of `target` relative to `observer` at the given time.

  Returns `{:ok, {x, y, z}}` in km in the J2000/ICRF reference frame, or
  `{:error, reason}`.

  The `target` and `observer` are body atoms (see module docs) or
  NAIF integer codes.

  The `datetime` can be a `DateTime`, a `NaiveDateTime`, or a Julian Date
  (TDB) as a float.

  ## Examples

      {:ok, {x, y, z}} = Sidereon.Ephemeris.position(eph, :moon, :earth, datetime)

      # Raw NAIF code (433 Eros) against a Horizons kernel:
      {:ok, {x, y, z}} = Sidereon.Ephemeris.position(eph, 20_000_433, :sun, jd_tdb)
  """
  @spec position(t(), body(), body(), epoch()) ::
          {:ok, vec3()} | {:error, position_error()}
  def position(%__MODULE__{path: path}, target, observer, datetime) do
    with {:ok, target_code} <- resolve_body_code(target),
         {:ok, observer_code} <- resolve_body_code(observer),
         {:ok, {whole, fraction}} <- to_jd_tdb_split(datetime) do
      get_body_position(path, target_code, observer_code, whole, fraction)
    end
  end

  @doc """
  Like `position/4` but raises on failure.
  """
  @spec position!(t(), body(), body(), epoch()) :: vec3()
  def position!(%__MODULE__{} = ephemeris, target, observer, datetime) do
    case position(ephemeris, target, observer, datetime) do
      {:ok, position} ->
        position

      {:error, reason} ->
        raise ArgumentError, "could not compute ephemeris position: #{inspect(reason)}"
    end
  end

  # ------------------------------------------------------------------
  # Private helpers
  # ------------------------------------------------------------------

  defp resolve_body_code(atom) when is_atom(atom) do
    case Map.fetch(@body_codes, atom) do
      {:ok, code} -> {:ok, code}
      :error -> {:error, {:invalid_body, atom}}
    end
  end

  defp resolve_body_code(code) when is_integer(code), do: {:ok, code}
  defp resolve_body_code(other), do: {:error, {:invalid_body, other}}

  # Convert UTC datetime to split TDB Julian Date {whole, fraction} using
  # the precise time scale NIF. The split form preserves full precision
  # for the Chebyshev argument computation inside the SPK reader.
  defp to_jd_tdb_split(%DateTime{} = dt) do
    second_with_micro = dt.second + elem(dt.microsecond, 0) / 1_000_000

    utc_to_tdb_jd_split(dt.year, dt.month, dt.day, dt.hour, dt.minute, second_with_micro)
  end

  defp to_jd_tdb_split(%NaiveDateTime{} = dt) do
    second_with_micro = dt.second + elem(dt.microsecond, 0) / 1_000_000

    utc_to_tdb_jd_split(dt.year, dt.month, dt.day, dt.hour, dt.minute, second_with_micro)
  end

  # If a float is passed, assume it's already TDB Julian Date.
  # Split into integer day + fraction for precision.
  defp to_jd_tdb_split(jd) when is_float(jd), do: {:ok, {Float.floor(jd), jd - Float.floor(jd)}}
  defp to_jd_tdb_split(jd) when is_integer(jd), do: {:ok, {jd * 1.0, 0.0}}
  defp to_jd_tdb_split(datetime), do: {:error, {:invalid_datetime, datetime}}

  defp utc_to_tdb_jd_split(year, month, day, hour, minute, second) do
    {:ok, Sidereon.NIF.utc_to_tdb_jd_split(year, month, day, hour, minute, second)}
  rescue
    e in ErlangError -> {:error, {:nif_error, e.original}}
  end

  defp get_body_position(path, target_code, observer_code, whole, fraction) do
    case Sidereon.NIF.get_body_position(
           path,
           target_code,
           observer_code,
           whole,
           fraction
         ) do
      {x, y, z} when is_float(x) and is_float(y) and is_float(z) ->
        {:ok, {x, y, z}}

      {:error, reason} ->
        {:error, {:nif_error, reason}}

      other ->
        {:error, {:nif_error, other}}
    end
  rescue
    e in ErlangError -> {:error, {:nif_error, e.original}}
  end
end
