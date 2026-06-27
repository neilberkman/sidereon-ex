defmodule Sidereon.GNSS.Broadcast do
  @moduledoc """
  A parsed RINEX broadcast-navigation product (GPS LNAV, Galileo I/NAV+F/NAV,
  BeiDou D1/D2, GLONASS).

  Holds the broadcast Keplerian elements and clock terms as a resource handle,
  the broadcast-ephemeris counterpart to `Sidereon.GNSS.SP3`. Pass a handle to
  `Sidereon.GNSS.Positioning.solve/4` to position from broadcast ephemeris instead
  of a precise SP3 product. The navigation file is parsed exactly once; the
  parsed product is held as a reference, not re-parsed per call.

  Parsing covers RINEX 3.x and 4.xx files: GPS, Galileo, and BeiDou records
  (including BeiDou geostationary satellites), and GLONASS (a PZ-90.11
  state-vector model propagated by Runge-Kutta integration rather than Keplerian
  elements). Other constellations in a mixed file are skipped, as are version-4
  CNAV-family messages.

  The orbit and clock models follow IS-GPS-200 (GPS LNAV), the Galileo OS-SIS-ICD
  (I/NAV + F/NAV), and the BeiDou BDS-SIS-ICD (D1/D2), parsed from RINEX 3.x/4.xx
  navigation records.

  ## Epochs

  `position/3` interprets the query epoch in GPS time (GPST). A `NaiveDateTime` or
  `{{year, month, day}, {hour, minute, second}}` is converted to a continuous
  second-of-J2000 via `Sidereon.GNSS.Time`; the crate maps that onto each system's
  own time scale (BDT for BeiDou, UTC-referenced for GLONASS) before selecting the
  governing record. No leap-second shifting is applied to the supplied epoch.
  """

  alias Sidereon.GNSS.Core.Types
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}
  @type nav_message :: :gps_lnav | :galileo_inav | :galileo_fnav | :beidou_d1 | :beidou_d2

  defmodule State do
    @moduledoc """
    A broadcast-evaluated satellite state at one epoch.

    Position is ITRF/IGS-realization ECEF, in meters (frame and unit fixed in the
    field names). `clock_s` is the satellite clock offset in seconds, the
    broadcast clock-polynomial total including the relativistic eccentricity term
    and the broadcast group delay. The sign convention matches `Sidereon.GNSS.SP3`:
    a positive `clock_s` means the satellite clock is **ahead** of system time, so
    the geometric range correction is `range + c * clock_s`.
    """
    @enforce_keys [:x_m, :y_m, :z_m, :clock_s]
    defstruct [:x_m, :y_m, :z_m, :clock_s]

    @type t :: %__MODULE__{
            x_m: float(),
            y_m: float(),
            z_m: float(),
            clock_s: float()
          }
  end

  defmodule KeplerianElements do
    @moduledoc """
    Broadcast Keplerian orbital elements.

    Units are SI: angles in radians, correction terms in radians or meters as
    named, and `toe_sow` in seconds of the constellation week.
    """

    @enforce_keys [
      :sqrt_a,
      :e,
      :m0,
      :delta_n,
      :omega0,
      :i0,
      :omega,
      :omega_dot,
      :idot,
      :cuc,
      :cus,
      :crc,
      :crs,
      :cic,
      :cis,
      :toe_sow
    ]
    defstruct [
      :sqrt_a,
      :e,
      :m0,
      :delta_n,
      :omega0,
      :i0,
      :omega,
      :omega_dot,
      :idot,
      :cuc,
      :cus,
      :crc,
      :crs,
      :cic,
      :cis,
      :toe_sow
    ]

    @type t :: %__MODULE__{
            sqrt_a: float(),
            e: float(),
            m0: float(),
            delta_n: float(),
            omega0: float(),
            i0: float(),
            omega: float(),
            omega_dot: float(),
            idot: float(),
            cuc: float(),
            cus: float(),
            crc: float(),
            crs: float(),
            cic: float(),
            cis: float(),
            toe_sow: float()
          }
  end

  defmodule ClockPolynomial do
    @moduledoc """
    Broadcast satellite-clock polynomial.

    `af0`, `af1`, and `af2` are seconds, seconds per second, and seconds per
    second squared. `toc_sow` is seconds of the constellation week.
    """

    @enforce_keys [:af0, :af1, :af2, :toc_sow]
    defstruct [:af0, :af1, :af2, :toc_sow]

    @type t :: %__MODULE__{
            af0: float(),
            af1: float(),
            af2: float(),
            toc_sow: float()
          }
  end

  defmodule Record do
    @moduledoc """
    One GPS, Galileo, or BeiDou broadcast ephemeris record from RINEX NAV.

    The Keplerian elements and clock polynomial use SI units. `message` is a
    stable lowercase atom matching the core/Python labels.
    """

    @enforce_keys [
      :satellite_id,
      :message,
      :week,
      :elements,
      :clock,
      :group_delay_s,
      :sv_health,
      :sv_accuracy_m,
      :fit_interval_s
    ]
    defstruct [
      :satellite_id,
      :message,
      :week,
      :elements,
      :clock,
      :group_delay_s,
      :sv_health,
      :sv_accuracy_m,
      :fit_interval_s
    ]

    @type t :: %__MODULE__{
            satellite_id: String.t(),
            message: Sidereon.GNSS.Broadcast.nav_message(),
            week: non_neg_integer(),
            elements: Sidereon.GNSS.Broadcast.KeplerianElements.t(),
            clock: Sidereon.GNSS.Broadcast.ClockPolynomial.t(),
            group_delay_s: float(),
            sv_health: float(),
            sv_accuracy_m: float(),
            fit_interval_s: float() | nil
          }
  end

  defmodule GlonassRecord do
    @moduledoc """
    One GLONASS broadcast state-vector record.

    `toe_utc_j2000_s` is UTC seconds past J2000. Position is PZ-90.11 ECEF
    meters, velocity is meters per second, and acceleration is meters per second
    squared.
    """

    @enforce_keys [
      :satellite_id,
      :toe_utc_j2000_s,
      :position_m,
      :velocity_m_s,
      :acceleration_m_s2,
      :clock_bias_s,
      :gamma_n,
      :sv_health,
      :freq_channel
    ]
    defstruct [
      :satellite_id,
      :toe_utc_j2000_s,
      :position_m,
      :velocity_m_s,
      :acceleration_m_s2,
      :clock_bias_s,
      :gamma_n,
      :sv_health,
      :freq_channel
    ]

    @type vec3 :: {float(), float(), float()}
    @type t :: %__MODULE__{
            satellite_id: String.t(),
            toe_utc_j2000_s: float(),
            position_m: vec3(),
            velocity_m_s: vec3(),
            acceleration_m_s2: vec3(),
            clock_bias_s: float(),
            gamma_n: float(),
            sv_health: float(),
            freq_channel: integer()
          }
  end

  defmodule KlobucharAlphaBeta do
    @moduledoc """
    Klobuchar alpha and beta ionosphere coefficients.

    `alpha` and `beta` are the four coefficient values broadcast by the RINEX
    NAV header for a constellation.
    """

    @enforce_keys [:alpha, :beta]
    defstruct [:alpha, :beta]

    @type coeffs :: {float(), float(), float(), float()}
    @type t :: %__MODULE__{alpha: coeffs(), beta: coeffs()}
  end

  defmodule IonoCorrections do
    @moduledoc """
    Broadcast ionosphere coefficients parsed from a RINEX NAV header.

    GPS and BeiDou Klobuchar-8 coefficient sets are exposed independently. A
    missing header pair is returned as `nil`.
    """

    @enforce_keys [:gps, :beidou]
    defstruct [:gps, :beidou]

    @type t :: %__MODULE__{
            gps: Sidereon.GNSS.Broadcast.KlobucharAlphaBeta.t() | nil,
            beidou: Sidereon.GNSS.Broadcast.KlobucharAlphaBeta.t() | nil
          }
  end

  @doc """
  Parse a RINEX 3.x or 4.xx navigation file from disk.

  Returns `{:ok, %Sidereon.GNSS.Broadcast{}}` or `{:error, reason}`. The file
  is read and parsed once; the parsed product is held as a resource handle.
  """
  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
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
      {:ok, eph} ->
        eph

      {:error, reason} ->
        raise ArgumentError, "could not load RINEX NAV #{path}: #{inspect(reason)}"
    end
  end

  @doc """
  Parse an in-memory RINEX 3.x or 4.xx navigation text buffer into a handle.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(text) when is_binary(text) do
    case NIF.broadcast_parse(text) do
      handle when is_reference(handle) -> {:ok, %__MODULE__{handle: handle}}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Number of usable GPS, Galileo, and BeiDou records held by the parsed product.
  """
  @spec record_count(t()) :: non_neg_integer()
  def record_count(%__MODULE__{handle: handle}) do
    NIF.broadcast_record_count(handle)
  rescue
    e in ErlangError ->
      raise ArgumentError, "could not read broadcast record count: #{inspect(e.original)}"
  end

  @doc """
  Usable GPS, Galileo, and BeiDou broadcast records in file order.

  The returned records are the core store's default SPP policy output: healthy
  GPS LNAV, Galileo I/NAV, and BeiDou D1/D2 records. Galileo F/NAV and unhealthy
  satellites are not included in this accessor.
  """
  @spec records(t()) :: [Record.t()]
  def records(%__MODULE__{handle: handle}) do
    handle
    |> NIF.broadcast_records()
    |> Enum.map(&decode_record/1)
  rescue
    e in ErlangError ->
      raise ArgumentError, "could not read broadcast records: #{inspect(e.original)}"
  end

  @doc """
  Number of healthy GLONASS state-vector records held by the parsed product.
  """
  @spec glonass_record_count(t()) :: non_neg_integer()
  def glonass_record_count(%__MODULE__{handle: handle}) do
    NIF.broadcast_glonass_record_count(handle)
  rescue
    e in ErlangError ->
      raise ArgumentError, "could not read GLONASS record count: #{inspect(e.original)}"
  end

  @doc """
  Healthy GLONASS broadcast state-vector records in file order.
  """
  @spec glonass_records(t()) :: [GlonassRecord.t()]
  def glonass_records(%__MODULE__{handle: handle}) do
    handle
    |> NIF.broadcast_glonass_records()
    |> Enum.map(&decode_glonass_record/1)
  rescue
    e in ErlangError ->
      raise ArgumentError, "could not read GLONASS records: #{inspect(e.original)}"
  end

  @doc """
  Broadcast ionosphere coefficients parsed from the NAV header.

  Returns GPS and BeiDou Klobuchar-8 coefficient sets when present, otherwise
  `nil` for each missing set.
  """
  @spec iono_corrections(t()) :: IonoCorrections.t()
  def iono_corrections(%__MODULE__{handle: handle}) do
    {gps, beidou} = NIF.broadcast_iono_corrections(handle)

    %IonoCorrections{
      gps: decode_klobuchar(gps),
      beidou: decode_klobuchar(beidou)
    }
  rescue
    e in ErlangError ->
      raise ArgumentError,
            "could not read broadcast ionosphere coefficients: #{inspect(e.original)}"
  end

  @doc """
  GPS minus UTC leap seconds from the NAV header, if present.
  """
  @spec leap_seconds(t()) :: float() | nil
  def leap_seconds(%__MODULE__{handle: handle}) do
    NIF.broadcast_leap_seconds(handle)
  rescue
    e in ErlangError ->
      raise ArgumentError, "could not read broadcast leap seconds: #{inspect(e.original)}"
  end

  @doc """
  Evaluate the broadcast state of satellite `sat_id` at `epoch`.

  `sat_id` is the canonical RINEX token, e.g. `"G01"` (GPS PRN 1), `"E12"`,
  `"C30"`, `"R07"`. `epoch` is a `NaiveDateTime` or a
  `{{year, month, day}, {hour, minute, second}}` tuple, interpreted in GPS time.

  Returns `{:ok, %Sidereon.GNSS.Broadcast.State{}}` with the ECEF position (meters)
  and satellite clock offset (seconds), `{:error, :no_ephemeris}` when no
  broadcast record covers that satellite at that epoch (the validity window has no
  match; this is **not** extrapolated), or `{:error, reason}` for a malformed
  satellite token or a non-integer-second tuple epoch.

  Evaluating the same satellite across a window reuses the parsed handle; the
  navigation file is never re-read.
  """
  @spec position(t(), String.t(), NaiveDateTime.t() | tuple()) ::
          {:ok, State.t()} | {:error, term()}
  def position(%__MODULE__{handle: handle}, sat_id, epoch) when is_binary(sat_id) do
    with {:ok, system_letter, prn} <- Types.parse_sat_id(sat_id),
         {:ok, t_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      case NIF.broadcast_position(handle, system_letter, prn, t_j2000_s) do
        {x_m, y_m, z_m, clock_s} ->
          {:ok, %State{x_m: x_m, y_m: y_m, z_m: z_m, clock_s: clock_s}}

        nil ->
          {:error, :no_ephemeris}

        {:error, _} = err ->
          err

        other ->
          {:error, other}
      end
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  # --- helpers -------------------------------------------------------------

  defp decode_record({satellite_id, message, week, elements, clock, meta}) do
    {group_delay_s, sv_health, sv_accuracy_m, fit_interval_s} = meta

    %Record{
      satellite_id: satellite_id,
      message: decode_message(message),
      week: week,
      elements: decode_elements(elements),
      clock: decode_clock(clock),
      group_delay_s: group_delay_s,
      sv_health: sv_health,
      sv_accuracy_m: sv_accuracy_m,
      fit_interval_s: fit_interval_s
    }
  end

  defp decode_elements([
         sqrt_a,
         e,
         m0,
         delta_n,
         omega0,
         i0,
         omega,
         omega_dot,
         idot,
         cuc,
         cus,
         crc,
         crs,
         cic,
         cis,
         toe_sow
       ]) do
    %KeplerianElements{
      sqrt_a: sqrt_a,
      e: e,
      m0: m0,
      delta_n: delta_n,
      omega0: omega0,
      i0: i0,
      omega: omega,
      omega_dot: omega_dot,
      idot: idot,
      cuc: cuc,
      cus: cus,
      crc: crc,
      crs: crs,
      cic: cic,
      cis: cis,
      toe_sow: toe_sow
    }
  end

  defp decode_clock({af0, af1, af2, toc_sow}) do
    %ClockPolynomial{af0: af0, af1: af1, af2: af2, toc_sow: toc_sow}
  end

  defp decode_glonass_record(
         {satellite_id, toe_utc_j2000_s, position_m, velocity_m_s, acceleration_m_s2, meta}
       ) do
    {clock_bias_s, gamma_n, sv_health, freq_channel} = meta

    %GlonassRecord{
      satellite_id: satellite_id,
      toe_utc_j2000_s: toe_utc_j2000_s,
      position_m: position_m,
      velocity_m_s: velocity_m_s,
      acceleration_m_s2: acceleration_m_s2,
      clock_bias_s: clock_bias_s,
      gamma_n: gamma_n,
      sv_health: sv_health,
      freq_channel: freq_channel
    }
  end

  defp decode_klobuchar(nil), do: nil

  defp decode_klobuchar({alpha, beta}) do
    %KlobucharAlphaBeta{alpha: List.to_tuple(alpha), beta: List.to_tuple(beta)}
  end

  defp decode_message("gps_lnav"), do: :gps_lnav
  defp decode_message("galileo_inav"), do: :galileo_inav
  defp decode_message("galileo_fnav"), do: :galileo_fnav
  defp decode_message("beidou_d1"), do: :beidou_d1
  defp decode_message("beidou_d2"), do: :beidou_d2
end
