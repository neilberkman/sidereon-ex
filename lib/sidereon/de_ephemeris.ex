defmodule Sidereon.DeEphemeris do
  @moduledoc """
  JPL DE binary ephemeris containing constants and geocentric GCRF Sun and Moon states.
  """
  alias Sidereon.NIF

  @enforce_keys [:handle]
  defstruct [:handle]
  @opaque t :: %__MODULE__{handle: reference()}

  defmodule DeBody do
    @moduledoc "Solar-system body selectors for DE mass parameters."
    @type t ::
            :sun
            | :mercury
            | :venus
            | :earth_moon
            | :earth
            | :moon
            | :mars
            | :jupiter
            | :saturn
            | :uranus
            | :neptune
            | :pluto
            | :solar_system
  end

  defmodule DeError do
    @moduledoc "A DE ephemeris loading or evaluation refusal with its details."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}
    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  defmodule DeState do
    @moduledoc "Geocentric GCRF position in metres and velocity in metres per second."
    @enforce_keys [:position_m, :velocity_m_s]
    defstruct [:position_m, :velocity_m_s]
    @type t :: %__MODULE__{position_m: Sidereon.Bodies.vector(), velocity_m_s: Sidereon.Bodies.vector()}
  end

  defmodule DeSunMoon do
    @moduledoc "Geocentric Sun and Moon states at the same epoch."
    @enforce_keys [:sun, :moon]
    defstruct [:sun, :moon]
    @type t :: %__MODULE__{sun: DeState.t(), moon: DeState.t()}
  end

  @doc "Load a JPL DE binary ephemeris from a file."
  @spec load(Path.t()) :: {:ok, t()} | {:error, DeError.t()}
  def load(path), do: decode_handle(NIF.de_load(path))

  @doc "Parse a JPL DE binary ephemeris from bytes."
  @spec from_bytes(binary()) :: {:ok, t()} | {:error, DeError.t()}
  def from_bytes(bytes), do: decode_handle(NIF.de_from_bytes(bytes))

  @doc "Return the gravitational mass parameter in cubic metres per square second, if present."
  @spec gm_m3_s2(t(), DeBody.t()) :: {:ok, float() | nil} | {:error, DeError.t()}
  def gm_m3_s2(%__MODULE__{handle: handle}, body), do: decode(NIF.de_gm_m3_s2(handle, body))

  @doc "Return the Sun and Moon states at TDB seconds past J2000."
  @spec sun_moon_at_tdb_seconds(t(), number()) :: {:ok, DeSunMoon.t()} | {:error, DeError.t()}
  def sun_moon_at_tdb_seconds(%__MODULE__{handle: handle}, epoch) do
    with {:ok, {sun, moon}} <- decode(NIF.de_sun_moon_at_tdb_seconds(handle, epoch / 1.0)) do
      {:ok, %DeSunMoon{sun: struct!(DeState, sun), moon: struct!(DeState, moon)}}
    end
  end

  @doc "Return geocentric GCRF Sun and Moon positions, in metres, at TDB seconds past J2000."
  @spec sun_moon_positions_at_tdb_seconds(t(), number()) ::
          {:ok, {Sidereon.Bodies.vector(), Sidereon.Bodies.vector()}} | {:error, DeError.t()}
  def sun_moon_positions_at_tdb_seconds(%__MODULE__{handle: handle}, epoch),
    do: decode(NIF.de_sun_moon_positions_at_tdb_seconds(handle, epoch / 1.0))

  defp decode_handle(result) do
    with {:ok, handle} <- decode(result), do: {:ok, %__MODULE__{handle: handle}}
  end

  defp decode({:error, details}), do: {:error, struct!(DeError, details)}
  defp decode({:ok, _value} = result), do: result

  @doc "Return the DE ephemeris version number."
  @spec version(t()) :: non_neg_integer()
  def version(%__MODULE__{handle: handle}), do: NIF.de_version(handle)

  @doc "Return the number of bytes per binary record."
  @spec record_size(t()) :: pos_integer()
  def record_size(%__MODULE__{handle: handle}), do: NIF.de_record_size(handle)

  @doc "Return the coverage bounds in TDB seconds past J2000."
  @spec coverage_tdb_seconds(t()) :: {float(), float()}
  def coverage_tdb_seconds(%__MODULE__{handle: handle}), do: NIF.de_coverage_tdb_seconds(handle)

  @doc "Return the named constants from the binary header."
  @spec constants(t()) :: %{String.t() => float()}
  def constants(%__MODULE__{handle: handle}), do: NIF.de_constants(handle)

  @doc "Return the astronomical unit in metres."
  @spec astronomical_unit_m(t()) :: float()
  def astronomical_unit_m(%__MODULE__{handle: handle}), do: NIF.de_astronomical_unit_m(handle)

  @doc "Return the Earth-to-Moon mass ratio."
  @spec earth_moon_mass_ratio(t()) :: float()
  def earth_moon_mass_ratio(%__MODULE__{handle: handle}), do: NIF.de_earth_moon_mass_ratio(handle)
end
