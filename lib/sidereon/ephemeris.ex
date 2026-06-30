defmodule Sidereon.Ephemeris do
  @moduledoc """
  JPL/NAIF SPK (DAF `.bsp`) ephemeris kernel reader.

  Computes positions and velocities of solar system bodies, spacecraft, and
  minor planets from JPL SPK/BSP kernels (DE421, DE440, Horizons exports, etc.).

  The kernel is parsed once into a loaded handle by `load/1`; querying never
  re-reads the file. Reading and evaluation are delegated to
  `sidereon_core::astro::spk`, the validated SPK reader shared by the rest of the
  engine and by the other language bindings. It evaluates SPK segment types 2
  (Chebyshev position), 3 (Chebyshev state), and 21 (Extended Modified Difference
  Arrays), so DE-series planetary kernels and Horizons spacecraft / asteroid
  kernels are all supported through the same code path.

  ## Example

      {:ok, eph} = Sidereon.Ephemeris.load("de421.bsp")

      # Position and velocity at an ephemeris epoch (TDB seconds past J2000):
      {:ok, state} = Sidereon.Ephemeris.state(eph, :moon, :earth, 0.0)
      state.position_km
      state.velocity_km_s

      # Convenience: position only, from a DateTime or Julian Date (TDB):
      {:ok, {x, y, z}} = Sidereon.Ephemeris.position(eph, :sun, :earth, ~U[2024-01-01 12:00:00Z])

      # The parsed segment table:
      Sidereon.Ephemeris.segments(eph)

  ## Bodies

  Bodies may be given as atoms (`:ssb` / `:solar_system_barycenter`, `:mercury`,
  `:venus`, `:earth_moon_barycenter` / `:emb`, `:mars`, `:jupiter`, `:saturn`,
  `:uranus`, `:neptune`, `:pluto`, `:sun`, `:moon`, `:earth`) or as raw NAIF
  integer codes. Integer codes pass straight through to the reader, which is how
  spacecraft and minor-planet kernels are queried (e.g. `20000433` for 433 Eros).
  """

  alias Sidereon.NIF

  defstruct [:handle]

  @typedoc "A loaded SPK kernel handle."
  @type t :: %__MODULE__{handle: reference()}
  @type body :: atom() | integer()
  @type epoch :: DateTime.t() | NaiveDateTime.t() | float() | integer()
  @type vec3 :: {float(), float(), float()}

  @typedoc "One parsed SPK segment descriptor."
  @type segment :: %{
          name: String.t(),
          target: integer(),
          center: integer(),
          frame: integer(),
          data_type: integer(),
          start_et: float(),
          stop_et: float(),
          start_address: integer(),
          end_address: integer()
        }

  @typedoc "A body-to-center state from a kernel query."
  @type state :: %{
          target: integer(),
          center: integer(),
          position_km: vec3(),
          velocity_km_s: vec3() | nil,
          frame: integer()
        }

  @type load_error :: {:file_error, File.posix()} | {:invalid_path, term()} | {:parse_error, term()}
  @type state_error ::
          {:invalid_body, term()}
          | {:unknown_body, integer()}
          | {:no_segment_path, integer(), integer()}
          | {:nif_error, term()}
  @type position_error :: state_error() | {:invalid_datetime, term()}

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
  Load and parse an SPK/BSP ephemeris file into a handle.

  The file is read and parsed exactly once; the returned handle holds the parsed
  kernel and is passed to `state/4`, `segments/1`, and `position/4`. Returns
  `{:ok, ephemeris}` or `{:error, reason}` when the file cannot be read or parsed.

  ## Example

      {:ok, eph} = Sidereon.Ephemeris.load("/path/to/de421.bsp")
  """
  @spec load(term()) :: {:ok, t()} | {:error, load_error()}
  def load(path) when is_binary(path) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, bytes} -> load_bytes(bytes)
      {:error, reason} -> {:error, {:file_error, reason}}
    end
  end

  def load(path), do: {:error, {:invalid_path, path}}

  @doc """
  Parse an SPK/BSP ephemeris kernel from an in-memory byte buffer.

  Returns `{:ok, ephemeris}` or `{:error, {:parse_error, reason}}`.
  """
  @spec load_bytes(binary()) :: {:ok, t()} | {:error, {:parse_error, term()}}
  def load_bytes(bytes) when is_binary(bytes) do
    case NIF.spk_load(bytes) do
      handle when is_reference(handle) -> {:ok, %__MODULE__{handle: handle}}
      {:error, reason} -> {:error, {:parse_error, reason}}
      other -> {:error, {:parse_error, other}}
    end
  rescue
    e in ErlangError -> {:error, {:parse_error, e.original}}
  end

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
  The kernel's parsed segment descriptors, in DAF summary order.

  Each entry is a map with `:name`, `:target`, `:center`, `:frame`,
  `:data_type`, `:start_et`, `:stop_et`, `:start_address`, and `:end_address`.
  Coverage epochs (`:start_et` / `:stop_et`) are ephemeris (TDB) seconds past
  J2000.
  """
  @spec segments(t()) :: [segment()]
  def segments(%__MODULE__{handle: handle}), do: NIF.spk_segments(handle)

  @doc """
  The DAF internal file name recorded in the kernel header.
  """
  @spec internal_name(t()) :: String.t()
  def internal_name(%__MODULE__{handle: handle}), do: NIF.spk_internal_name(handle)

  @doc """
  Query the state of `target` relative to `center` at ephemeris epoch
  `et_seconds` (TDB seconds past J2000).

  This is the primary query, matching the other language bindings: it resolves
  and chains segments as needed and returns both position and velocity. Returns
  `{:ok, state}` where `state` is a map with `:target`, `:center`,
  `:position_km` (a `{x, y, z}` tuple, km), `:velocity_km_s` (a `{vx, vy, vz}`
  tuple in km/s, or `nil` when the resolved path runs through a position-only
  type-2 segment), and `:frame` (the NAIF reference-frame id, J2000/ICRF for
  standard kernels).

  `target` and `center` are body atoms (see module docs) or NAIF integer codes.

  Returns `{:error, {:invalid_body, body}}` for an unknown atom,
  `{:error, {:unknown_body, code}}` when a body is absent from the kernel,
  `{:error, {:no_segment_path, target, center}}` when no segment chain connects
  them, and `{:error, {:nif_error, reason}}` when a chain exists but none covers
  the epoch or the path needs an unsupported segment type.

  ## Example

      {:ok, state} = Sidereon.Ephemeris.state(eph, :moon, :earth, 0.0)
  """
  @spec state(t(), body(), body(), number()) :: {:ok, state()} | {:error, state_error()}
  def state(%__MODULE__{handle: handle}, target, center, et_seconds) do
    with {:ok, target_code} <- resolve_body_code(target),
         {:ok, center_code} <- resolve_body_code(center) do
      spk_state(handle, target_code, center_code, et_seconds * 1.0)
    end
  end

  @doc """
  Like `state/4` but raises on failure.
  """
  @spec state!(t(), body(), body(), number()) :: state()
  def state!(%__MODULE__{} = ephemeris, target, center, et_seconds) do
    case state(ephemeris, target, center, et_seconds) do
      {:ok, state} ->
        state

      {:error, reason} ->
        raise ArgumentError, "could not compute ephemeris state: #{inspect(reason)}"
    end
  end

  @doc """
  Compute the position of `target` relative to `observer` at the given time.

  A position-only convenience over `state/4` that accepts a calendar epoch.
  Returns `{:ok, {x, y, z}}` in km in the J2000/ICRF reference frame, or
  `{:error, reason}`.

  The `target` and `observer` are body atoms (see module docs) or NAIF integer
  codes. The `datetime` can be a `DateTime`, a `NaiveDateTime`, or a Julian Date
  (TDB) as a float.

  ## Examples

      {:ok, {x, y, z}} = Sidereon.Ephemeris.position(eph, :moon, :earth, datetime)

      # Raw NAIF code (433 Eros) against a Horizons kernel:
      {:ok, {x, y, z}} = Sidereon.Ephemeris.position(eph, 20_000_433, :sun, jd_tdb)
  """
  @spec position(t(), body(), body(), epoch()) ::
          {:ok, vec3()} | {:error, position_error()}
  def position(%__MODULE__{} = ephemeris, target, observer, datetime) do
    with {:ok, et_seconds} <- to_et_seconds(datetime),
         {:ok, %{position_km: position}} <- state(ephemeris, target, observer, et_seconds) do
      {:ok, position}
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

  defp spk_state(handle, target_code, center_code, et_seconds) do
    case NIF.spk_state(handle, target_code, center_code, et_seconds) do
      {:ok, state} -> {:ok, state}
      {:error, {:unknown_body, _code}} = error -> error
      {:error, {:no_segment_path, _target, _center}} = error -> error
      {:error, reason} -> {:error, {:nif_error, reason}}
    end
  rescue
    e in ErlangError -> {:error, {:nif_error, e.original}}
  end

  # Convert a calendar epoch or Julian Date (TDB) to ephemeris seconds past
  # J2000, going through the precise time-scale and split-JD NIFs so the
  # integer-day subtraction stays exact.
  defp to_et_seconds(%DateTime{} = dt), do: et_from_utc(dt)
  defp to_et_seconds(%NaiveDateTime{} = dt), do: et_from_utc(dt)

  defp to_et_seconds(jd) when is_float(jd) do
    whole = Float.floor(jd)
    et_from_split(whole, jd - whole)
  end

  defp to_et_seconds(jd) when is_integer(jd), do: et_from_split(jd * 1.0, 0.0)
  defp to_et_seconds(datetime), do: {:error, {:invalid_datetime, datetime}}

  defp et_from_utc(dt) do
    second_with_micro = dt.second + elem(dt.microsecond, 0) / 1_000_000

    {whole, fraction} =
      NIF.utc_to_tdb_jd_split(dt.year, dt.month, dt.day, dt.hour, dt.minute, second_with_micro)

    et_from_split(whole, fraction)
  rescue
    e in ErlangError -> {:error, {:nif_error, e.original}}
  end

  defp et_from_split(whole, fraction) do
    {:ok, NIF.j2000_seconds_from_split(whole, fraction)}
  rescue
    e in ErlangError -> {:error, {:nif_error, e.original}}
  end
end
