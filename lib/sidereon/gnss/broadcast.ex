defmodule Sidereon.GNSS.Broadcast do
  @moduledoc """
  A parsed RINEX broadcast-navigation product (GPS LNAV, Galileo I/NAV+F/NAV,
  BeiDou D1/D2, GLONASS).

  Holds the broadcast Keplerian elements and clock terms as a resource handle,
  the broadcast-ephemeris counterpart to `Sidereon.GNSS.SP3`. Pass a handle to
  `Sidereon.GNSS.Positioning.solve/4` to position from broadcast ephemeris instead
  of a precise SP3 product. The navigation file is parsed exactly once; the
  parsed product is held as a reference, not re-parsed per call.

  Parsing covers RINEX 2.xx, 3.xx and 4.xx files: GPS, QZSS, Galileo, BeiDou
  (including BeiDou geostationary satellites) and NavIC Keplerian records,
  GPS/QZSS CNAV-family records, and GLONASS (a PZ-90.11 state-vector model
  propagated by Runge-Kutta integration rather than Keplerian elements). A
  block that cannot be read is left out and reported by `skipped/1`, and a
  departure from the format read through by `departures/1`; one bad record
  does not cost the file's other records.

  The orbit and clock models follow IS-GPS-200 (GPS LNAV), the Galileo OS-SIS-ICD
  (I/NAV + F/NAV), and the BeiDou BDS-SIS-ICD (D1/D2), parsed from RINEX 3.x/4.xx
  navigation records.

  The handle API applies the core store's selection: among a satellite's
  records a query selects as RTKLIB `seleph` and `selgeph` do, and a selected
  record RTKLIB `satexclude` excludes (unhealthy, or with an accuracy worse
  than RTKLIB's limit) yields no state. The direct
  `parse_rinex_nav_records/1`, `parse_rinex_nav_lenient/1`,
  `parse_rinex_glonass_records/1`, `parse_rinex_glonass_lenient/1`, and
  `encode_rinex_nav/1` routes expose the caller-owned raw record-list contracts
  without that selection.

  ## Epochs

  `position/3` interprets the query epoch in GPS time (GPST). A `NaiveDateTime` or
  `{{year, month, day}, {hour, minute, second}}` is converted to a continuous
  second-of-J2000 via `Sidereon.GNSS.Time`; the crate maps that onto each system's
  own time scale (BDT for BeiDou, UTC-referenced for GLONASS) before selecting the
  governing record. No leap-second shifting is applied to the supplied epoch.
  """

  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.Core.Types
  alias Sidereon.GNSS.Time
  alias Sidereon.NIF
  alias Sidereon.NifCall

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: reference()}
  @type nav_message ::
          :gps_lnav
          | :gps_cnav
          | :gps_cnav2
          | :qzss_lnav
          | :qzss_cnav
          | :qzss_cnav2
          | :galileo_inav
          | :galileo_fnav
          | :galileo_unclassified
          | :beidou_d1
          | :beidou_d2
          | :navic_lnav
  @type message_preference :: :legacy | :modern

  defmodule State do
    @moduledoc """
    A broadcast-evaluated satellite state at one epoch.

    Position is ITRF/IGS-realization ECEF, in meters (frame and unit fixed in the
    field names). `clock_s` is the satellite clock offset in seconds: the
    broadcast clock polynomial and the relativistic term, without the broadcast
    group delay (GPS and QZSS TGD, Galileo BGD, BeiDou TGD1, CNAV TGD less ISC),
    as RTKLIB `satposs` returns it. That delay is a single-frequency term, which
    the single-frequency positioning models apply to the pseudorange. The sign convention matches `Sidereon.GNSS.SP3`:
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
    One Keplerian broadcast ephemeris record from RINEX NAV.

    The Keplerian elements and clock polynomial use SI units. `message` is a
    stable lowercase atom matching the core/Python labels. `sv_accuracy_m` is
    `nil` where the record states no accuracy (a blank or unreadable field, or a
    CNAV URA index that carries no prediction), and `fit_interval_s` is `nil`
    where the record states no fit interval.
    """

    alias Sidereon.GNSS.Broadcast.ClockPolynomial
    alias Sidereon.GNSS.Broadcast.KeplerianElements

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
            message: Broadcast.nav_message(),
            week: non_neg_integer(),
            elements: KeplerianElements.t(),
            clock: ClockPolynomial.t(),
            group_delay_s: float(),
            sv_health: float(),
            sv_accuracy_m: float() | nil,
            fit_interval_s: float() | nil
          }
  end

  defmodule WeekTow do
    @moduledoc """
    GNSS week and time-of-week tagged with its native time scale.
    """
    @enforce_keys [:system, :week, :tow_s]
    defstruct [:system, :week, :tow_s]

    @type t :: %__MODULE__{system: String.t(), week: non_neg_integer(), tow_s: float()}
  end

  defmodule Issue do
    @moduledoc """
    Broadcast issue value plus the navigation-message family that carried it.
    """
    @enforce_keys [:issue, :message]
    defstruct [:issue, :message]

    @type t :: %__MODULE__{issue: non_neg_integer(), message: Broadcast.nav_message()}
  end

  defmodule GroupDelays do
    @moduledoc """
    Broadcast group-delay fields preserved from a NAV record.
    """
    defstruct [
      :gps_tgd_s,
      :galileo_bgd_e5a_e1_s,
      :galileo_bgd_e5b_e1_s,
      :beidou_tgd1_s,
      :beidou_tgd2_s,
      :cnav_isc_l1ca_s,
      :cnav_isc_l2c_s,
      :cnav_isc_l5i5_s,
      :cnav_isc_l5q5_s,
      :cnav_isc_l1cd_s,
      :cnav_isc_l1cp_s
    ]

    @type t :: %__MODULE__{}
  end

  defmodule StatedNavFields do
    @moduledoc """
    Fields of a legacy broadcast record that the orbit and clock models do not
    read, as the record states them, so that a record written back restates
    them.

    Each field is `nil` for a blank field or one the source does not carry:

      * `orbit5_field2` - BROADCAST ORBIT-5 field 2: GPS/QZSS codes on L2, the
        Galileo data-source word, spare for BeiDou and NavIC.
      * `orbit5_field4` - BROADCAST ORBIT-5 field 4: GPS/QZSS L2 P data flag,
        spare elsewhere.
      * `orbit6_field4` - BROADCAST ORBIT-6 field 4: GPS/QZSS IODC, NavIC spare.
      * `transmission_time_sow` - BROADCAST ORBIT-7 field 1: transmission time
        of message, seconds of week, as stated.
      * `orbit7_field2` - BROADCAST ORBIT-7 field 2: the GPS fit interval, the
        QZSS fit flag, the BeiDou AODC, spare for Galileo and NavIC.
      * `orbit7_field3`, `orbit7_field4` - BROADCAST ORBIT-7 spare fields.
    """
    defstruct orbit5_field2: nil,
              orbit5_field4: nil,
              orbit6_field4: nil,
              transmission_time_sow: nil,
              orbit7_field2: nil,
              orbit7_field3: nil,
              orbit7_field4: nil

    @type t :: %__MODULE__{
            orbit5_field2: float() | nil,
            orbit5_field4: float() | nil,
            orbit6_field4: float() | nil,
            transmission_time_sow: float() | nil,
            orbit7_field2: float() | nil,
            orbit7_field3: float() | nil,
            orbit7_field4: float() | nil
          }
  end

  defmodule CnavParameters do
    @moduledoc """
    CNAV/CNAV-2 fields that have no LNAV counterpart.
    """
    @enforce_keys [
      :adot_m_s,
      :delta_n0_dot_rad_s2,
      :top,
      :ura_ed_index,
      :ura_ned0_index,
      :ura_ned1_index,
      :ura_ned2_index,
      :transmission_time_sow
    ]
    defstruct [
      :adot_m_s,
      :delta_n0_dot_rad_s2,
      :top,
      :ura_ed_index,
      :ura_ed_nominal_m,
      :ura_ned0_index,
      :ura_ned0_nominal_m,
      :ura_ned1_index,
      :ura_ned2_index,
      :transmission_time_sow,
      :flags
    ]

    @type t :: %__MODULE__{top: WeekTow.t()}
  end

  defmodule CnavCorrections do
    @moduledoc """
    Core-evaluated CNAV single-frequency clock corrections in seconds.
    """
    defstruct [:l1ca_s, :l2c_s, :l5i5_s, :l5q5_s, :l1cp_s, :l1cd_s]

    @type t :: %__MODULE__{}
  end

  defmodule DetailedRecord do
    @moduledoc """
    One broadcast record with issue, time tags, group delays, CNAV fields and
    the stated fields the models do not read.

    `issue_of_data` is `nil` for a GPS/QZSS CNAV-family record, whose RINEX 4
    record carries no issue of data. `sv_accuracy_m` is `nil` where the record
    states no accuracy. `stated` holds the fields the orbit and clock models do
    not read (see `Sidereon.GNSS.Broadcast.StatedNavFields`).
    """
    alias Broadcast.{
      ClockPolynomial,
      CnavCorrections,
      CnavParameters,
      GroupDelays,
      Issue,
      KeplerianElements,
      StatedNavFields
    }

    @enforce_keys [
      :satellite_id,
      :message,
      :issue_of_data,
      :week,
      :toe,
      :toc,
      :elements,
      :clock,
      :group_delays,
      :cnav_corrections,
      :group_delay_s,
      :sv_health
    ]
    defstruct [
      :satellite_id,
      :message,
      :issue_of_data,
      :week,
      :toe,
      :toc,
      :elements,
      :clock,
      :group_delays,
      :cnav,
      :cnav_corrections,
      :group_delay_s,
      :sv_health,
      :sv_accuracy_m,
      :fit_interval_s,
      stated: %StatedNavFields{}
    ]

    @type t :: %__MODULE__{
            satellite_id: String.t(),
            message: Broadcast.nav_message(),
            issue_of_data: Issue.t() | nil,
            week: non_neg_integer(),
            toe: WeekTow.t(),
            toc: WeekTow.t(),
            elements: KeplerianElements.t(),
            clock: ClockPolynomial.t(),
            group_delays: GroupDelays.t(),
            cnav: CnavParameters.t() | nil,
            cnav_corrections: CnavCorrections.t(),
            group_delay_s: float(),
            sv_health: float(),
            sv_accuracy_m: float() | nil,
            fit_interval_s: float() | nil,
            stated: StatedNavFields.t()
          }
  end

  defmodule SkippedNavBlock do
    @moduledoc """
    A RINEX NAV block that could not be read, with the 1-based line of its first
    line (the frame marker in RINEX 4) and the reason.

    Header failures remain errors; this struct reports body blocks, and body
    lines that belong to no record, that the reader left out.
    """

    @enforce_keys [:satellite, :message, :line]
    defstruct [:satellite, :message, :line]

    @type t :: %__MODULE__{satellite: String.t(), message: String.t(), line: pos_integer()}
  end

  defmodule NavDiagnostic do
    @moduledoc """
    A departure from the RINEX NAV format that a lenient reader read through.

    The record or header value it concerns is kept; the strict reader refuses it
    with `message`. `line` is the 1-based line of the record or header line, and
    `satellite` the record's satellite token, empty for a header line.
    """

    @enforce_keys [:line, :satellite, :message]
    defstruct [:line, :satellite, :message]

    @type t :: %__MODULE__{line: pos_integer(), satellite: String.t(), message: String.t()}
  end

  defmodule OtherNavBlock do
    @moduledoc """
    A RINEX NAV block that lenient Keplerian parsing read but does not return
    as a record: a GLONASS or SBAS record, a RINEX 4 system time offset, Earth
    orientation or ionosphere frame, or a message that is recognized and not
    decoded (BeiDou CNAV-1/2/3, NavIC L1).
    """

    @enforce_keys [:line, :satellite, :message_token, :kind]
    defstruct [:line, :satellite, :message_token, :kind]

    @type kind ::
            :glonass
            | :sbas
            | :system_time_offset
            | :earth_orientation
            | :ionosphere
            | :not_decoded
    @type t :: %__MODULE__{
            line: pos_integer(),
            satellite: String.t(),
            message_token: String.t() | nil,
            kind: kind()
          }
  end

  defmodule RinexNavParse do
    @moduledoc """
    Result of lenient RINEX NAV parsing.

    `records` preserves the Keplerian records in file order. `skipped` reports
    the blocks the reader could not read, `departures` the departures from the
    format it read through in the records it kept and in the header, and `other`
    every other block of the file.
    """

    alias Broadcast.{DetailedRecord, NavDiagnostic, OtherNavBlock, SkippedNavBlock}

    @enforce_keys [:records, :skipped, :departures, :other]
    defstruct [:records, :skipped, :departures, :other]

    @type t :: %__MODULE__{
            records: [DetailedRecord.t()],
            skipped: [SkippedNavBlock.t()],
            departures: [NavDiagnostic.t()],
            other: [OtherNavBlock.t()]
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

  defmodule SkippedGlonass do
    @moduledoc """
    Identity of a GLONASS RINEX record skipped because its satellite slot cannot
    be represented by the core's GLONASS record type, with the 1-based line of
    the record's first line.
    """

    @enforce_keys [:token, :line]
    defstruct [:token, :line]

    @typedoc "A skipped GLONASS satellite token as it appeared in the RINEX file."
    @type t :: %__MODULE__{token: String.t(), line: pos_integer()}
  end

  defmodule GlonassParse do
    @moduledoc """
    Result of lenient raw GLONASS RINEX navigation parsing.

    `records` preserves readable records in source order. `skipped` reports
    the source tokens for records whose slot the core could not represent.
    `invalid` reports records of representable slots that could not be read,
    and `departures` the departures from the format read through in the
    records kept.
    """

    alias Broadcast.{GlonassRecord, NavDiagnostic, SkippedGlonass, SkippedNavBlock}

    @enforce_keys [:records, :skipped, :invalid, :departures]
    defstruct [:records, :skipped, :invalid, :departures]

    @typedoc "Readable GLONASS records plus skipped, unreadable and departing records."
    @type t :: %__MODULE__{
            records: [GlonassRecord.t()],
            skipped: [SkippedGlonass.t()],
            invalid: [SkippedNavBlock.t()],
            departures: [NavDiagnostic.t()]
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
    Broadcast ionosphere coefficients from a RINEX NAV header and its RINEX 4
    ionosphere frames.

    GPS, BeiDou, QZSS and NavIC Klobuchar coefficient sets, the Galileo NeQuick
    G coefficients `{ai0, ai1, ai2}` with the disturbance flags as stated, and
    the BeiDou BDGIM coefficients `alpha1..alpha9` from a RINEX 4 `CNVX` frame
    are exposed independently. A set that neither the header nor a frame states
    is `nil`.
    """

    alias Sidereon.GNSS.Broadcast.KlobucharAlphaBeta

    @enforce_keys [:gps, :beidou]
    defstruct [
      :gps,
      :beidou,
      qzss: nil,
      navic: nil,
      galileo: nil,
      galileo_disturbance_flags: nil,
      beidou_bdgim: nil
    ]

    @type t :: %__MODULE__{
            gps: KlobucharAlphaBeta.t() | nil,
            beidou: KlobucharAlphaBeta.t() | nil,
            qzss: KlobucharAlphaBeta.t() | nil,
            navic: KlobucharAlphaBeta.t() | nil,
            galileo: {float(), float(), float()} | nil,
            galileo_disturbance_flags: float() | nil,
            beidou_bdgim: [float()] | nil
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
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def parse(text, opts \\ []) when is_binary(text) do
    preference = Keyword.get(opts, :message_preference, :legacy)

    result =
      case preference do
        :legacy -> NIF.broadcast_parse(text)
        :modern -> NIF.broadcast_parse_with_preference(text, "modern")
      end

    case result do
      handle when is_reference(handle) -> {:ok, %__MODULE__{handle: handle}}
      {:error, _} = err -> err
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :broadcast_parse)
  end

  @doc """
  Parse all supported RINEX NAV records in file order without the broadcast
  store's health, message-family, or CNAV usability filters.

  The returned `DetailedRecord` values retain the full core record needed by
  `encode_rinex_nav/1`, including issue/time tags, group delays, and CNAV
  parameters.
  """
  @spec parse_rinex_nav_records(String.t()) ::
          {:ok, [DetailedRecord.t()]} | {:error, term()}
  def parse_rinex_nav_records(text) when is_binary(text) do
    case NIF.rinex_nav_parse_records(text) do
      {:ok, records} -> {:ok, Enum.map(records, &decode_detailed_record/1)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_nav_parse_records)
  end

  @doc """
  Parse supported RINEX NAV records leniently.

  Header errors remain `{:error, reason}`. Blocks that cannot be read are
  omitted from `records` and reported in `skipped` with their line; departures
  from the format read through are reported in `departures`, and every block
  of another kind (GLONASS, SBAS, RINEX 4 non-ephemeris frames, messages not
  decoded) in `other`. Records remain in file order.
  """
  @spec parse_rinex_nav_lenient(String.t()) ::
          {:ok, RinexNavParse.t()} | {:error, term()}
  def parse_rinex_nav_lenient(text) when is_binary(text) do
    case NIF.rinex_nav_parse_lenient(text) do
      {:ok, %{records: records, skipped: skipped, departures: departures, other: other}} ->
        {:ok,
         %RinexNavParse{
           records: Enum.map(records, &decode_detailed_record/1),
           skipped: Enum.map(skipped, &struct(SkippedNavBlock, &1)),
           departures: Enum.map(departures, &struct(NavDiagnostic, &1)),
           other: Enum.map(other, &decode_other_block/1)
         }}

      {:error, _} = err ->
        err

      other ->
        {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_nav_parse_lenient)
  end

  @doc """
  Encode a caller-supplied list of full broadcast records to canonical RINEX
  NAV text.

  This is independent of a parsed `Broadcast` handle and does not apply the
  store's default filtering policy. Pass `DetailedRecord` values such as those
  returned by `parse_rinex_nav_records/1`; the list may be reordered or
  reduced by the caller. The text is RINEX 3.04, or RINEX 4.02 frames when a
  CNAV-family record is present, with a `PGM / RUN BY / DATE` header record.

  Returns `{:error, {:not_representable, line, reason}}` for a record set the
  writer refuses: one holding both a CNAV-family record, which only RINEX 4
  holds, and an unclassified Galileo record, which only RINEX 3 holds. `line`
  is 0 for a record built in code.
  """
  @spec encode_rinex_nav([DetailedRecord.t()]) :: {:ok, String.t()} | {:error, term()}
  def encode_rinex_nav(records) when is_list(records) do
    case NIF.rinex_nav_encode(Enum.map(records, &encode_detailed_record/1)) do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in [ErlangError, FunctionClauseError, KeyError] -> {:error, Exception.message(e)}
  end

  def encode_rinex_nav(records), do: {:error, {:invalid_records, records}}

  @doc """
  Parse every representable GLONASS state-vector record from RINEX NAV text.

  This direct parser returns every readable record in file order, whatever its
  health.
  """
  @spec parse_rinex_glonass_records(String.t()) ::
          {:ok, [GlonassRecord.t()]} | {:error, term()}
  def parse_rinex_glonass_records(text) when is_binary(text) do
    case NIF.rinex_nav_parse_glonass_records(text) do
      {:ok, records} -> {:ok, Enum.map(records, &decode_glonass_record/1)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_nav_parse_glonass_records)
  end

  @doc """
  Parse raw GLONASS RINEX NAV records while retaining skipped slot identities.

  The core parser keeps every readable record and reports the source token of
  every unrepresentable GLONASS slot, each record of a representable slot that
  could not be read, and each departure from the format read through. Every
  list preserves source order.
  """
  @spec parse_rinex_glonass_lenient(String.t()) ::
          {:ok, GlonassParse.t()} | {:error, term()}
  def parse_rinex_glonass_lenient(text) when is_binary(text) do
    case NIF.rinex_nav_parse_glonass_lenient(text) do
      {:ok, %{records: records, skipped: skipped, invalid: invalid, departures: departures}} ->
        {:ok,
         %GlonassParse{
           records: Enum.map(records, &decode_glonass_record/1),
           skipped: Enum.map(skipped, &struct(SkippedGlonass, &1)),
           invalid: Enum.map(invalid, &struct(SkippedNavBlock, &1)),
           departures: Enum.map(departures, &struct(NavDiagnostic, &1))
         }}

      {:error, _} = err ->
        err

      other ->
        {:error, other}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :rinex_nav_parse_glonass_lenient)
  end

  @doc """
  Number of Keplerian records held by the parsed product.
  """
  @spec record_count(t()) :: non_neg_integer()
  def record_count(%__MODULE__{handle: handle}) do
    NIF.broadcast_record_count(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read broadcast record count: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Keplerian broadcast records held by the parsed product.

  The store keeps the records of the messages used for single-frequency
  positioning: GPS LNAV, GPS/QZSS CNAV-family, QZSS LNAV, Galileo I/NAV and
  Galileo records whose data sources name no single message, BeiDou D1/D2 and
  NavIC LNAV. Health does not filter them: a query selects among a satellite's
  records as RTKLIB `seleph` does, and a selected record RTKLIB `satexclude`
  excludes yields no state.
  """
  @spec records(t()) :: [Record.t()]
  def records(%__MODULE__{handle: handle}) do
    handle
    |> NIF.broadcast_records()
    |> Enum.map(&decode_record/1)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read broadcast records: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Detailed GPS, Galileo, BeiDou, and CNAV-family records in file order.
  """
  @spec records_detailed(t()) :: [DetailedRecord.t()]
  def records_detailed(%__MODULE__{handle: handle}) do
    handle
    |> NIF.broadcast_records_detailed()
    |> Enum.map(&decode_detailed_record/1)
  rescue
    e in ErlangError ->
      reraise ArgumentError,
              [message: "could not read detailed broadcast records: #{NifCall.describe(e)}"],
              __STACKTRACE__
  end

  @doc """
  GPS/QZSS record-family preference used by mixed LNAV/CNAV selection.
  """
  @spec message_preference(t()) :: message_preference()
  def message_preference(%__MODULE__{handle: handle}) do
    case NIF.broadcast_message_preference(handle) do
      "legacy" -> :legacy
      "modern" -> :modern
    end
  end

  @doc """
  Serialize the Keplerian broadcast records to RINEX navigation text.

  Returns `{:ok, text}`: RINEX 3.04, or RINEX 4.02 frames when a CNAV-family
  record is present. Re-parsing the output reconstructs the same records. The
  text covers the records `records/1` returns; GLONASS state-vector records are
  not serialized. Returns `{:error, {:not_representable, line, reason}}` for a
  record set the writer refuses (a CNAV-family record together with an
  unclassified Galileo record).
  """
  @spec encode_nav(t()) ::
          {:ok, String.t()} | {:error, {:not_representable, non_neg_integer(), String.t()}}
  def encode_nav(%__MODULE__{handle: handle}) do
    NIF.broadcast_encode_nav(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not serialize broadcast records: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Blocks of the navigation file the parsed product could not read, each with
  its line and reason. One unreadable record does not cost the file's other
  records.
  """
  @spec skipped(t()) :: [SkippedNavBlock.t()]
  def skipped(%__MODULE__{handle: handle}) do
    handle
    |> NIF.broadcast_skipped()
    |> Enum.map(&struct(SkippedNavBlock, &1))
  rescue
    e in ErlangError ->
      reraise ArgumentError,
              [message: "could not read skipped broadcast blocks: #{NifCall.describe(e)}"],
              __STACKTRACE__
  end

  @doc """
  Departures from the RINEX NAV format the parsed product read through,
  including header records whose values cannot be read.
  """
  @spec departures(t()) :: [NavDiagnostic.t()]
  def departures(%__MODULE__{handle: handle}) do
    handle
    |> NIF.broadcast_departures()
    |> Enum.map(&struct(NavDiagnostic, &1))
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read broadcast departures: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Number of GLONASS state-vector records held by the parsed product.
  """
  @spec glonass_record_count(t()) :: non_neg_integer()
  def glonass_record_count(%__MODULE__{handle: handle}) do
    NIF.broadcast_glonass_record_count(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read GLONASS record count: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  GLONASS broadcast state-vector records held by the parsed product. Health
  does not filter them; a query selects as RTKLIB `selgeph` does and a
  selected record that is not healthy yields no state.
  """
  @spec glonass_records(t()) :: [GlonassRecord.t()]
  def glonass_records(%__MODULE__{handle: handle}) do
    handle
    |> NIF.broadcast_glonass_records()
    |> Enum.map(&decode_glonass_record/1)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read GLONASS records: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Broadcast ionosphere coefficients over the whole file.

  Each set is the one of its system and model transmitted latest, from the
  header or a RINEX 4 ionosphere frame; a set neither states is `nil`.
  """
  @spec iono_corrections(t()) :: IonoCorrections.t()
  def iono_corrections(%__MODULE__{handle: handle}) do
    handle
    |> NIF.broadcast_iono_corrections()
    |> decode_iono()
  rescue
    e in ErlangError ->
      reraise ArgumentError,
              [message: "could not read broadcast ionosphere coefficients: #{NifCall.describe(e)}"],
              __STACKTRACE__
  end

  @doc """
  Broadcast ionosphere coefficients in effect at `epoch` (GPS time): each set
  is the one of its system and model transmitted latest at or before it.
  """
  @spec iono_corrections_at(t(), NaiveDateTime.t() | tuple()) ::
          {:ok, IonoCorrections.t()} | {:error, term()}
  def iono_corrections_at(%__MODULE__{handle: handle}, epoch) do
    with {:ok, t_j2000_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      {:ok, handle |> NIF.broadcast_iono_corrections_at(t_j2000_s) |> decode_iono()}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :broadcast_iono_corrections_at)
  end

  @doc """
  GPS minus UTC leap seconds from the NAV header, if present.
  """
  @spec leap_seconds(t()) :: float() | nil
  def leap_seconds(%__MODULE__{handle: handle}) do
    NIF.broadcast_leap_seconds(handle)
  rescue
    e in ErlangError ->
      reraise ArgumentError, [message: "could not read broadcast leap seconds: #{NifCall.describe(e)}"], __STACKTRACE__
  end

  @doc """
  Nominal CNAV URA in metres for a URA ED/NED0 index.
  """
  @spec cnav_ura_nominal(integer()) :: float() | nil
  def cnav_ura_nominal(index) when is_integer(index), do: NIF.broadcast_cnav_ura_nominal(index)

  @doc """
  Time-dependent CNAV URA_NED bound in metres.
  """
  @spec cnav_ura_ned(CnavParameters.t(), WeekTow.t()) :: float() | nil
  def cnav_ura_ned(%CnavParameters{} = cnav, %WeekTow{} = time) do
    NIF.broadcast_cnav_ura_ned(encode_cnav(cnav), time.system, time.week, time.tow_s)
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
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :broadcast_position)
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

  defp decode_detailed_record(raw) do
    %DetailedRecord{
      satellite_id: raw.satellite_id,
      message: decode_message(raw.message),
      issue_of_data: decode_issue(raw.issue_of_data),
      week: raw.week,
      toe: decode_week_tow(raw.toe),
      toc: decode_week_tow(raw.toc),
      elements: decode_elements(raw.elements),
      clock: decode_clock(raw.clock),
      group_delays: struct(GroupDelays, raw.group_delays),
      cnav: decode_cnav(raw.cnav),
      cnav_corrections: struct(CnavCorrections, raw.cnav_corrections),
      group_delay_s: raw.group_delay_s,
      sv_health: raw.sv_health,
      sv_accuracy_m: raw.sv_accuracy_m,
      fit_interval_s: raw.fit_interval_s,
      stated: struct(StatedNavFields, raw.stated)
    }
  end

  defp decode_week_tow(raw), do: %WeekTow{system: raw.system, week: raw.week, tow_s: raw.tow_s}

  defp decode_issue(nil), do: nil
  defp decode_issue(raw), do: %Issue{issue: raw.issue, message: decode_message(raw.message)}

  defp decode_cnav(nil), do: nil

  defp decode_cnav(raw) do
    %CnavParameters{
      adot_m_s: raw.adot_m_s,
      delta_n0_dot_rad_s2: raw.delta_n0_dot_rad_s2,
      top: decode_week_tow(raw.top),
      ura_ed_index: raw.ura_ed_index,
      ura_ed_nominal_m: raw.ura_ed_nominal_m,
      ura_ned0_index: raw.ura_ned0_index,
      ura_ned0_nominal_m: raw.ura_ned0_nominal_m,
      ura_ned1_index: raw.ura_ned1_index,
      ura_ned2_index: raw.ura_ned2_index,
      transmission_time_sow: raw.transmission_time_sow,
      flags: raw.flags
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

  defp decode_glonass_record({satellite_id, toe_utc_j2000_s, position_m, velocity_m_s, acceleration_m_s2, meta}) do
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

  defp decode_iono(raw) do
    %IonoCorrections{
      gps: decode_klobuchar(raw.gps),
      beidou: decode_klobuchar(raw.beidou),
      qzss: decode_klobuchar(raw.qzss),
      navic: decode_klobuchar(raw.navic),
      galileo: raw.galileo,
      galileo_disturbance_flags: raw.galileo_disturbance_flags,
      beidou_bdgim: raw.beidou_bdgim
    }
  end

  defp decode_other_block(raw) do
    %OtherNavBlock{
      line: raw.line,
      satellite: raw.satellite,
      message_token: raw.message_token,
      kind: decode_other_kind(raw.kind)
    }
  end

  defp decode_other_kind("glonass"), do: :glonass
  defp decode_other_kind("sbas"), do: :sbas
  defp decode_other_kind("system_time_offset"), do: :system_time_offset
  defp decode_other_kind("earth_orientation"), do: :earth_orientation
  defp decode_other_kind("ionosphere"), do: :ionosphere
  defp decode_other_kind("not_decoded"), do: :not_decoded

  defp decode_klobuchar(nil), do: nil

  defp decode_klobuchar({alpha, beta}) do
    %KlobucharAlphaBeta{alpha: List.to_tuple(alpha), beta: List.to_tuple(beta)}
  end

  defp decode_message("gps_lnav"), do: :gps_lnav
  defp decode_message("gps_cnav"), do: :gps_cnav
  defp decode_message("gps_cnav2"), do: :gps_cnav2
  defp decode_message("qzss_lnav"), do: :qzss_lnav
  defp decode_message("qzss_cnav"), do: :qzss_cnav
  defp decode_message("qzss_cnav2"), do: :qzss_cnav2
  defp decode_message("galileo_inav"), do: :galileo_inav
  defp decode_message("galileo_fnav"), do: :galileo_fnav
  defp decode_message("galileo_unclassified"), do: :galileo_unclassified
  defp decode_message("beidou_d1"), do: :beidou_d1
  defp decode_message("beidou_d2"), do: :beidou_d2
  defp decode_message("navic_lnav"), do: :navic_lnav

  defp encode_message(:gps_lnav), do: "gps_lnav"
  defp encode_message(:gps_cnav), do: "gps_cnav"
  defp encode_message(:gps_cnav2), do: "gps_cnav2"
  defp encode_message(:qzss_lnav), do: "qzss_lnav"
  defp encode_message(:qzss_cnav), do: "qzss_cnav"
  defp encode_message(:qzss_cnav2), do: "qzss_cnav2"
  defp encode_message(:galileo_inav), do: "galileo_inav"
  defp encode_message(:galileo_fnav), do: "galileo_fnav"
  defp encode_message(:galileo_unclassified), do: "galileo_unclassified"
  defp encode_message(:beidou_d1), do: "beidou_d1"
  defp encode_message(:beidou_d2), do: "beidou_d2"
  defp encode_message(:navic_lnav), do: "navic_lnav"

  defp encode_detailed_record(%DetailedRecord{} = record) do
    %{
      satellite_id: record.satellite_id,
      message: encode_message(record.message),
      issue_of_data: encode_issue(record.issue_of_data),
      week: record.week,
      toe: %{system: record.toe.system, week: record.toe.week, tow_s: record.toe.tow_s},
      toc: %{system: record.toc.system, week: record.toc.week, tow_s: record.toc.tow_s},
      elements: encode_elements(record.elements),
      clock: encode_clock(record.clock),
      group_delays: Map.from_struct(record.group_delays),
      cnav: encode_cnav(record.cnav),
      cnav_corrections: Map.from_struct(record.cnav_corrections),
      group_delay_s: record.group_delay_s,
      sv_health: record.sv_health,
      sv_accuracy_m: record.sv_accuracy_m,
      fit_interval_s: record.fit_interval_s,
      stated: encode_stated(record.stated)
    }
  end

  defp encode_issue(nil), do: nil
  defp encode_issue(%Issue{} = issue), do: %{issue: issue.issue, message: encode_message(issue.message)}

  defp encode_stated(nil), do: Map.from_struct(%StatedNavFields{})
  defp encode_stated(%StatedNavFields{} = stated), do: Map.from_struct(stated)

  defp encode_elements(%KeplerianElements{} = elements) do
    [
      elements.sqrt_a,
      elements.e,
      elements.m0,
      elements.delta_n,
      elements.omega0,
      elements.i0,
      elements.omega,
      elements.omega_dot,
      elements.idot,
      elements.cuc,
      elements.cus,
      elements.crc,
      elements.crs,
      elements.cic,
      elements.cis,
      elements.toe_sow
    ]
  end

  defp encode_clock(%ClockPolynomial{} = clock) do
    {clock.af0, clock.af1, clock.af2, clock.toc_sow}
  end

  defp encode_cnav(%CnavParameters{} = cnav) do
    %{
      adot_m_s: cnav.adot_m_s,
      delta_n0_dot_rad_s2: cnav.delta_n0_dot_rad_s2,
      top: %{system: cnav.top.system, week: cnav.top.week, tow_s: cnav.top.tow_s},
      ura_ed_index: cnav.ura_ed_index,
      ura_ed_nominal_m: cnav.ura_ed_nominal_m,
      ura_ned0_index: cnav.ura_ned0_index,
      ura_ned0_nominal_m: cnav.ura_ned0_nominal_m,
      ura_ned1_index: cnav.ura_ned1_index,
      ura_ned2_index: cnav.ura_ned2_index,
      transmission_time_sow: cnav.transmission_time_sow,
      flags: cnav.flags
    }
  end

  defp encode_cnav(nil), do: nil
end
