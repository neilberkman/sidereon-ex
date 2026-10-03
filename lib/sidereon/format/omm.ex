defmodule Sidereon.Format.OMM do
  @moduledoc """
  Parse and encode CCSDS Orbit Mean-Elements Messages (OMM).

  OMM is the modern standard format for orbital data, carrying the same
  elements as TLE plus metadata such as originator, reference frame, time
  system, and mean-element theory. CelesTrak and Space-Track distribute OMM
  messages as KVN, XML, and JSON.

  `parse_kvn/1`, `parse_xml/1`, `parse_json/1`, and string `parse/1` return a
  typed `%Sidereon.Format.OMM{}` that keeps every item of CCSDS 502.0-B-3
  tables 4-1 to 4-3 the message states: the header, metadata, mean elements,
  spacecraft parameters, TLE-related parameters, covariance, `USER_DEFINED_*`
  parameters and the comments of each block. A keyword the message does not
  state is `nil`; no reader fills in a default. `parse_xml_all/1` and
  `parse_json_array/1` read documents holding several OMMs. The legacy
  decoded-map `parse/1` clause is kept for CelesTrak JSON maps and returns
  `%Sidereon.Elements{}`.

  Each writer returns `{:error, reason}` for a message it cannot write so that
  its reader returns it unchanged, such as text with a line break in KVN, a
  character XML 1.0 cannot carry, a non-finite number, or, in GP JSON, a
  comment other than the single header comment GP JSON carries.
  """

  alias Sidereon.CCSDS.Error
  alias Sidereon.Elements
  alias Sidereon.NIF
  alias Sidereon.NifCall

  defmodule Epoch do
    @moduledoc """
    UTC calendar epoch carried by an OMM `EPOCH` field.

    The fields preserve the core OMM representation at microsecond precision
    instead of immediately reducing the value to a `DateTime`.
    """

    @type t :: %__MODULE__{
            year: integer(),
            month: integer(),
            day: integer(),
            hour: integer(),
            minute: integer(),
            second: integer(),
            microsecond: integer(),
            femtosecond: integer()
          }

    defstruct [:year, :month, :day, :hour, :minute, :second, :microsecond, femtosecond: 0]
  end

  defmodule Spacecraft do
    @moduledoc """
    OMM spacecraft parameters (CCSDS 502.0-B-3 table 4-3). Present on an OMM
    when any of its keywords occurs, even with a blank value.
    """

    @type t :: %__MODULE__{
            comments: [String.t()],
            mass_kg: float() | nil,
            solar_rad_area_m2: float() | nil,
            solar_rad_coeff: float() | nil,
            drag_area_m2: float() | nil,
            drag_coeff: float() | nil
          }

    defstruct comments: [],
              mass_kg: nil,
              solar_rad_area_m2: nil,
              solar_rad_coeff: nil,
              drag_area_m2: nil,
              drag_coeff: nil
  end

  defmodule Covariance do
    @moduledoc """
    OMM position/velocity covariance (CCSDS 502.0-B-3 table 4-3), kept exactly
    as read.

    `lower_triangle` holds the 21 lower-triangle values in keyword order `CX_X`,
    `CY_X`, `CY_Y`, `CZ_X`, `CZ_Y`, `CZ_Z`, `CX_DOT_X` ... `CZ_DOT_Z_DOT`: km²
    for two position components, km²/s for one position and one velocity
    component, km²/s² for two velocity components. `cov_ref_frame` is `nil`
    when the matrix is in the OMM's `REF_FRAME`.
    """

    @type t :: %__MODULE__{
            comments: [String.t()],
            cov_ref_frame: String.t() | nil,
            lower_triangle: [float()]
          }

    defstruct comments: [], cov_ref_frame: nil, lower_triangle: []
  end

  defmodule UserDefined do
    @moduledoc """
    One `USER_DEFINED_*` parameter: the text after `USER_DEFINED_` (the XML
    `parameter` attribute) and its value, verbatim.
    """

    @type t :: %__MODULE__{parameter: String.t(), value: String.t()}

    @enforce_keys [:parameter, :value]
    defstruct [:parameter, :value]
  end

  defmodule Comments do
    @moduledoc """
    Comments of the OMM header, metadata, mean-elements, TLE-parameters and
    user-defined blocks, each in source order. Spacecraft and covariance
    comments live in `Sidereon.Format.OMM.Spacecraft` and
    `Sidereon.Format.OMM.Covariance`.
    """

    @type t :: %__MODULE__{
            header: [String.t()],
            metadata: [String.t()],
            mean_elements: [String.t()],
            tle_parameters: [String.t()],
            user_defined: [String.t()]
          }

    defstruct header: [], metadata: [], mean_elements: [], tle_parameters: [], user_defined: []
  end

  @typedoc """
  A CCSDS OMM.

  `ccsds_omm_vers` is the version the message states, or `nil`, as CelesTrak
  GP JSON and CSV state none; each writer states it only when present. At
  least one of `mean_motion` (rev/day) and `semi_major_axis_km` is present in
  a message read from text. The TLE-related parameters are `nil` when the
  message does not state them, since table 4-3 requires them only for
  SGP/SGP4 element sets. `bterm_m2_kg` and `agom_m2_kg` are the SGP4-XP `BTERM`
  and `AGOM` (m²/kg); `gm_km3_s2` is `GM` (km³/s²).

  `exact_sgp4_epoch` and `quantize_tle_derived_fields` retain the core OMM's
  in-memory SGP4 conversion policy across the NIF boundary. They are not CCSDS
  wire fields.
  """
  @type t :: %__MODULE__{
          ccsds_omm_vers: String.t() | nil,
          classification: String.t() | nil,
          creation_date: String.t() | nil,
          originator: String.t() | nil,
          message_id: String.t() | nil,
          object_name: String.t() | nil,
          object_id: String.t() | nil,
          center_name: String.t() | nil,
          ref_frame: String.t() | nil,
          ref_frame_epoch: String.t() | nil,
          time_system: String.t() | nil,
          mean_element_theory: String.t() | nil,
          epoch: Epoch.t(),
          mean_motion: float() | nil,
          semi_major_axis_km: float() | nil,
          eccentricity: float(),
          inclination_deg: float(),
          ra_of_asc_node_deg: float(),
          arg_of_pericenter_deg: float(),
          mean_anomaly_deg: float(),
          gm_km3_s2: float() | nil,
          spacecraft: Spacecraft.t() | nil,
          ephemeris_type: integer() | nil,
          classification_type: String.t() | nil,
          norad_cat_id: non_neg_integer() | nil,
          element_set_no: integer() | nil,
          rev_at_epoch: integer() | nil,
          bstar: float() | nil,
          bterm_m2_kg: float() | nil,
          mean_motion_dot: float() | nil,
          mean_motion_ddot: float() | nil,
          agom_m2_kg: float() | nil,
          covariance: Covariance.t() | nil,
          user_defined: [UserDefined.t()],
          comments: Comments.t(),
          exact_sgp4_epoch: {float(), float()} | nil,
          quantize_tle_derived_fields: boolean()
        }

  defstruct ccsds_omm_vers: nil,
            classification: nil,
            creation_date: nil,
            originator: nil,
            message_id: nil,
            object_name: nil,
            object_id: nil,
            center_name: nil,
            ref_frame: nil,
            ref_frame_epoch: nil,
            time_system: nil,
            mean_element_theory: nil,
            epoch: nil,
            mean_motion: nil,
            semi_major_axis_km: nil,
            eccentricity: nil,
            inclination_deg: nil,
            ra_of_asc_node_deg: nil,
            arg_of_pericenter_deg: nil,
            mean_anomaly_deg: nil,
            gm_km3_s2: nil,
            spacecraft: nil,
            ephemeris_type: nil,
            classification_type: nil,
            norad_cat_id: nil,
            element_set_no: nil,
            rev_at_epoch: nil,
            bstar: nil,
            bterm_m2_kg: nil,
            mean_motion_dot: nil,
            mean_motion_ddot: nil,
            agom_m2_kg: nil,
            covariance: nil,
            user_defined: [],
            # A call rather than `%Comments{}`: a struct literal cannot name a
            # module nested in the one whose struct is being defined.
            comments: struct(Comments),
            exact_sgp4_epoch: nil,
            quantize_tle_derived_fields: true

  @typedoc """
  A record `parse_xml_all/1` or `parse_json_array/1` could not read: its
  zero-based position in the document and the reason.
  """
  @type skipped_record :: {non_neg_integer(), Error.omm()}

  @typedoc """
  A refusal of the decoded-map `parse/1`: a missing or unreadable key, named
  as the key it reads.
  """
  @type parse_error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @typedoc """
  A reader, writer or element-set refusal from the core
  (`t:Sidereon.CCSDS.Error.omm/0`), or `{:invalid_field, field, value}` for a
  struct field that does not hold a value of its type.
  """
  @type error :: Error.omm() | {:invalid_field, atom(), term()}

  @type encode_error :: error()

  @doc """
  Parse an OMM from text or from a decoded JSON map.

  For binary input, the text format is auto-detected: a leading `<` selects XML,
  a leading `{` or `[` selects JSON, and all other input is parsed as KVN. Text
  parsing returns `{:ok, %Sidereon.Format.OMM{}}` or `{:error, reason}`.

  For map input, accepts decoded CelesTrak/Space-Track OMM JSON maps with field
  names such as `"NORAD_CAT_ID"`, `"INCLINATION"`, and `"MEAN_MOTION"`. This
  legacy path returns `{:ok, %Sidereon.Elements{}}` and handles both numeric and
  string values for numeric fields. `"MEAN_MOTION"` and `"BSTAR"`, which SGP4
  propagates with, are required; an unstated mean-motion derivative,
  `"CLASSIFICATION_TYPE"`, `"EPHEMERIS_TYPE"`, `"ELEMENT_SET_NO"` or
  `"REV_AT_EPOCH"` is `nil`.

  ## Examples

      iex> {:ok, el} = Sidereon.Format.OMM.parse(%{
      ...>   "NORAD_CAT_ID" => 25544,
      ...>   "OBJECT_NAME" => "ISS (ZARYA)",
      ...>   "EPOCH" => "2024-01-01T00:00:00",
      ...>   "INCLINATION" => 51.6,
      ...>   "RA_OF_ASC_NODE" => 300.0,
      ...>   "ECCENTRICITY" => 0.0007,
      ...>   "ARG_OF_PERICENTER" => 90.0,
      ...>   "MEAN_ANOMALY" => 270.0,
      ...>   "MEAN_MOTION" => 15.5,
      ...>   "BSTAR" => 0.0001
      ...> })
      iex> el.catalog_number
      "25544"
      iex> el.object_name
      "ISS (ZARYA)"

  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, Error.omm()}
  @spec parse(map()) :: {:ok, Elements.t()} | {:error, parse_error()}
  def parse(text) when is_binary(text) do
    text
    |> String.trim_leading()
    |> String.first()
    |> case do
      "<" -> parse_xml(text)
      "{" -> parse_json(text)
      "[" -> parse_json(text)
      _ -> parse_kvn(text)
    end
  end

  def parse(omm) when is_map(omm) do
    with {:ok, epoch} <- parse_epoch(omm["EPOCH"]),
         {:ok, ndot} <- optional_float_field(omm, "MEAN_MOTION_DOT"),
         {:ok, nddot} <- optional_float_field(omm, "MEAN_MOTION_DDOT"),
         {:ok, bstar} <- required_float_field(omm, "BSTAR"),
         {:ok, inclination_deg} <- required_float_field(omm, "INCLINATION"),
         {:ok, raan_deg} <- required_float_field(omm, "RA_OF_ASC_NODE"),
         {:ok, eccentricity} <- required_float_field(omm, "ECCENTRICITY"),
         {:ok, arg_perigee_deg} <- required_float_field(omm, "ARG_OF_PERICENTER"),
         {:ok, mean_anomaly_deg} <- required_float_field(omm, "MEAN_ANOMALY"),
         {:ok, mean_motion} <- required_float_field(omm, "MEAN_MOTION") do
      {:ok,
       %Elements{
         object_name: omm["OBJECT_NAME"],
         catalog_number: catalog_number(omm["NORAD_CAT_ID"]),
         classification: omm["CLASSIFICATION_TYPE"],
         international_designator: omm["OBJECT_ID"] || "",
         epoch: epoch,
         mean_motion_dot: ndot,
         mean_motion_double_dot: nddot,
         bstar: bstar,
         ephemeris_type: omm["EPHEMERIS_TYPE"],
         elset_number: omm["ELEMENT_SET_NO"],
         inclination_deg: inclination_deg,
         raan_deg: raan_deg,
         eccentricity: eccentricity,
         arg_perigee_deg: arg_perigee_deg,
         mean_anomaly_deg: mean_anomaly_deg,
         mean_motion: mean_motion,
         rev_number: omm["REV_AT_EPOCH"]
       }}
    end
  end

  @doc """
  Parse CCSDS OMM KVN text into a typed OMM struct.

  Returns `{:ok, %Sidereon.Format.OMM{}}` or `{:error, reason}`.
  """
  @spec parse_kvn(String.t()) :: {:ok, t()} | {:error, Error.omm()}
  def parse_kvn(text) when is_binary(text) do
    text |> NIF.omm_parse_kvn() |> from_nif_fields()
  end

  @doc """
  Parse CCSDS OMM XML text into a typed OMM struct.

  Returns `{:ok, %Sidereon.Format.OMM{}}` or `{:error, reason}`.
  """
  @spec parse_xml(String.t()) :: {:ok, t()} | {:error, Error.omm()}
  def parse_xml(text) when is_binary(text) do
    text |> NIF.omm_parse_xml() |> from_nif_fields()
  end

  @doc """
  Parse every OMM of a CCSDS OMM XML document: a single message or an NDM
  combined instantiation (CCSDS 505.0-B-3 4.11).

  Returns `{:ok, omms, skipped}`, where `skipped` lists each message that could
  not be read as `{index, reason}`, or `{:error, reason}` for a document that
  cannot be read at all.
  """
  @spec parse_xml_all(String.t()) :: {:ok, [t()], [skipped_record()]} | {:error, Error.omm()}
  def parse_xml_all(text) when is_binary(text) do
    text |> NIF.omm_parse_xml_all() |> from_nif_array()
  end

  @doc """
  Parse CCSDS/CelesTrak OMM JSON text holding one record into a typed OMM
  struct.

  JSON input may be a single OMM object or an array holding one object. A
  document holding several records is refused; `parse_json_array/1` reads
  them.

  Returns `{:ok, %Sidereon.Format.OMM{}}` or `{:error, reason}`.
  """
  @spec parse_json(String.t()) :: {:ok, t()} | {:error, Error.omm()}
  def parse_json(text) when is_binary(text) do
    text |> NIF.omm_parse_json() |> from_nif_fields()
  end

  @doc """
  Parse a CelesTrak/Space-Track GP JSON array of OMM records.

  Returns `{:ok, omms, skipped}`, where `skipped` lists each array element that
  could not be read as `{index, reason}`, or `{:error, reason}`.
  """
  @spec parse_json_array(String.t()) :: {:ok, [t()], [skipped_record()]} | {:error, Error.omm()}
  def parse_json_array(text) when is_binary(text) do
    text |> NIF.omm_parse_json_array() |> from_nif_array()
  end

  @doc """
  Encode an OMM value.

  A typed `%Sidereon.Format.OMM{}` is serialized as text. The `:format` option
  may be `:kvn`, `:xml`, or `:json` and defaults to `:kvn`.

  The legacy `%Sidereon.Elements{}` clause returns a JSON-compatible map with
  standard OMM field names.
  """
  @spec encode(t() | Elements.t()) :: {:ok, String.t()} | {:error, encode_error()} | map()
  @spec encode(t(), keyword()) :: {:ok, String.t()} | {:error, encode_error()}
  def encode(value, opts \\ [])

  def encode(%__MODULE__{} = omm, opts) do
    case Keyword.get(opts, :format, :kvn) do
      :kvn -> encode_kvn(omm)
      :xml -> encode_xml(omm)
      :json -> encode_json(omm)
      other -> {:error, {:invalid_field, :format, other}}
    end
  end

  def encode(%Elements{} = el, []) do
    %{
      "OBJECT_NAME" => el.object_name,
      "OBJECT_ID" => el.international_designator,
      "NORAD_CAT_ID" => safe_int(el.catalog_number),
      "CLASSIFICATION_TYPE" => el.classification,
      "EPOCH" => DateTime.to_iso8601(el.epoch),
      "MEAN_MOTION_DOT" => el.mean_motion_dot,
      "MEAN_MOTION_DDOT" => el.mean_motion_double_dot,
      "BSTAR" => el.bstar,
      "EPHEMERIS_TYPE" => el.ephemeris_type,
      "ELEMENT_SET_NO" => el.elset_number,
      "INCLINATION" => el.inclination_deg,
      "RA_OF_ASC_NODE" => el.raan_deg,
      "ECCENTRICITY" => el.eccentricity,
      "ARG_OF_PERICENTER" => el.arg_perigee_deg,
      "MEAN_ANOMALY" => el.mean_anomaly_deg,
      "MEAN_MOTION" => el.mean_motion,
      "REV_AT_EPOCH" => el.rev_number
    }
  end

  def encode(%Elements{}, opts), do: {:error, {:invalid_field, :opts, opts}}

  @doc """
  Encode a typed OMM struct as CCSDS OMM KVN text.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec encode_kvn(t()) :: {:ok, String.t()} | {:error, encode_error()}
  def encode_kvn(%__MODULE__{} = omm), do: encode_with_nif(omm, &NIF.omm_encode_kvn/1)

  @doc """
  Encode a typed OMM struct as CCSDS OMM XML text.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec encode_xml(t()) :: {:ok, String.t()} | {:error, encode_error()}
  def encode_xml(%__MODULE__{} = omm), do: encode_with_nif(omm, &NIF.omm_encode_xml/1)

  @doc """
  Encode a typed OMM struct as CCSDS/CelesTrak OMM JSON text.

  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec encode_json(t()) :: {:ok, String.t()} | {:error, encode_error()}
  def encode_json(%__MODULE__{} = omm), do: encode_with_nif(omm, &NIF.omm_encode_json/1)

  @doc """
  Encode a typed OMM struct as GP JSON, leaving out every comment GP JSON
  cannot carry: all but the single header comment. A spacecraft-parameters
  block that held only comments is still written, as `"MASS": null`.

  `encode_json/1` refuses such a record instead; use this function only when
  that loss is acceptable. Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec encode_json_discarding_comments(t()) :: {:ok, String.t()} | {:error, encode_error()}
  def encode_json_discarding_comments(%__MODULE__{} = omm),
    do: encode_with_nif(omm, &NIF.omm_encode_json_discarding_comments/1)

  @doc """
  Alias for `encode_kvn/1`, matching the core and Python binding terminology.
  """
  @spec to_kvn_string(t()) :: {:ok, String.t()} | {:error, encode_error()}
  def to_kvn_string(%__MODULE__{} = omm), do: encode_kvn(omm)

  @doc """
  Alias for `encode_xml/1`, matching the core and Python binding terminology.
  """
  @spec to_xml_string(t()) :: {:ok, String.t()} | {:error, encode_error()}
  def to_xml_string(%__MODULE__{} = omm), do: encode_xml(omm)

  @doc """
  Alias for `encode_json/1`, matching the core and Python binding terminology.
  """
  @spec to_json_string(t()) :: {:ok, String.t()} | {:error, encode_error()}
  def to_json_string(%__MODULE__{} = omm), do: encode_json(omm)

  @doc """
  Convert a typed OMM struct to `%Sidereon.Elements{}` for SGP4 propagation.

  The elements are the SGP4 element set the core forms from the OMM
  (`Omm::to_element_set`); OMM-specific metadata remains available on the
  original OMM struct. The core refuses:

    * a stated `MEAN_ELEMENT_THEORY` other than `SGP4`, `SGP/SGP4` or `SDP4`,
      `CENTER_NAME` other than `EARTH`, `REF_FRAME` other than `TEME` or
      `TIME_SYSTEM` other than `UTC` (compared ignoring surrounding whitespace
      and letter case), in that order, with `{:incompatible_metadata, field,
      value}`, since the elements would then not be the Earth-centred TEME UTC
      SGP4 elements (CCSDS 502.0-B-3 4.2.4.6); an absent or blank value is not
      refused;
    * an OMM without `MEAN_MOTION` or `BSTAR`, which SGP4 propagates with, with
      `{:missing_field, :mean_motion}` or `{:missing_field, :bstar}`;
    * an epoch that names no UTC instant, or an element that is not finite or
      out of range, with `{:invalid_field, field, kind}`.

  An OMM without `NORAD_CAT_ID` gives elements whose `catalog_number` is
  `nil`. `epoch_jd` is the epoch as the core's split Julian date, with the
  epoch's femtoseconds and a UTC leap second (`23:59:60`) kept, and
  propagation uses it; `epoch` is that instant as a `DateTime` to the
  microsecond, so a leap-second epoch reads as the start of the next day, the
  same Julian date. An epoch of whole microseconds, which python-sgp4 reads,
  gives elements with `omm_epoch_days` set, which SGP4 initialises as
  python-sgp4 initialises the OMM, and `bstar` and `mean_motion_double_dot`
  as stated; any other epoch bridges the OMM as a TLE, and `bstar` and
  `mean_motion_double_dot` are quantized to the values the TLE fields hold.
  A value no TLE field holds passes through unquantized. Unstated mean-motion
  derivatives and bookkeeping fields stay `nil`.

  Returns `{:ok, elements}` or `{:error, reason}`.
  """
  @spec to_elements(t()) :: {:ok, Elements.t()} | {:error, encode_error()}
  def to_elements(%__MODULE__{} = omm) do
    with {:ok, fields} <- to_nif_fields(omm),
         {:ok, set} <- NIF.omm_to_element_set(fields),
         {:ok, epoch} <- epoch_instant(omm.epoch) do
      {:ok,
       %Elements{
         object_name: omm.object_name,
         catalog_number: set.catalog_number && Integer.to_string(set.catalog_number),
         classification: omm.classification_type,
         international_designator: omm.object_id || "",
         epoch: epoch,
         epoch_jd: epoch_jd(set.epoch_jd),
         omm_epoch_days: set.omm_epoch_days,
         mean_motion_dot: set.mean_motion_dot,
         mean_motion_double_dot: set.mean_motion_double_dot,
         bstar: set.bstar,
         ephemeris_type: omm.ephemeris_type,
         elset_number: omm.element_set_no,
         inclination_deg: set.inclination_deg,
         raan_deg: set.right_ascension_deg,
         eccentricity: set.eccentricity,
         arg_perigee_deg: set.argument_of_perigee_deg,
         mean_anomaly_deg: set.mean_anomaly_deg,
         mean_motion: set.mean_motion_rev_per_day,
         rev_number: omm.rev_at_epoch
       }}
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :omm_to_element_set)
  end

  # The epoch as a `DateTime` to the microsecond. A UTC leap second, which a
  # `DateTime` cannot hold, is the instant after 23:59:59 by its seconds, the
  # same Julian date the core forms for it. The core has already checked that
  # the epoch names a UTC instant.
  defp epoch_instant(%Epoch{second: 60} = epoch) do
    with {:ok, datetime} <- epoch_to_datetime(%{epoch | second: 59}) do
      {:ok, DateTime.add(datetime, 1, :second)}
    end
  end

  defp epoch_instant(epoch), do: epoch_to_datetime(epoch)

  defp epoch_jd({jd_whole, jd_fraction}), do: %{jd_whole: jd_whole, jd_fraction: jd_fraction}

  # -- Text parse/encode helpers --

  defp from_nif_fields({:ok, fields}), do: {:ok, build_omm(fields)}

  defp from_nif_fields({:error, reason}), do: {:error, reason}

  defp from_nif_array({:ok, omms, skipped}), do: {:ok, Enum.map(omms, &build_omm/1), skipped}
  defp from_nif_array({:error, reason}), do: {:error, reason}

  @plain_fields [
    :ccsds_omm_vers,
    :classification,
    :creation_date,
    :originator,
    :message_id,
    :object_name,
    :object_id,
    :center_name,
    :ref_frame,
    :ref_frame_epoch,
    :time_system,
    :mean_element_theory,
    :mean_motion,
    :semi_major_axis_km,
    :eccentricity,
    :inclination_deg,
    :ra_of_asc_node_deg,
    :arg_of_pericenter_deg,
    :mean_anomaly_deg,
    :gm_km3_s2,
    :ephemeris_type,
    :classification_type,
    :norad_cat_id,
    :element_set_no,
    :rev_at_epoch,
    :bstar,
    :bterm_m2_kg,
    :mean_motion_dot,
    :mean_motion_ddot,
    :agom_m2_kg,
    :exact_sgp4_epoch,
    :quantize_tle_derived_fields
  ]

  defp build_omm(fields) do
    plain = Map.take(fields, @plain_fields)

    struct(
      __MODULE__,
      Map.merge(plain, %{
        epoch: build_epoch(fields.epoch),
        spacecraft: build_spacecraft(fields.spacecraft),
        covariance: build_covariance(fields.covariance),
        user_defined: Enum.map(fields.user_defined, &%UserDefined{parameter: &1.parameter, value: &1.value}),
        comments: struct(Comments, fields.comments)
      })
    )
  end

  defp build_spacecraft(nil), do: nil
  defp build_spacecraft(fields), do: struct(Spacecraft, fields)

  defp build_covariance(nil), do: nil
  defp build_covariance(fields), do: struct(Covariance, fields)

  defp build_epoch(fields) do
    %Epoch{
      year: fields.year,
      month: fields.month,
      day: fields.day,
      hour: fields.hour,
      minute: fields.minute,
      second: fields.second,
      microsecond: fields.microsecond,
      femtosecond: Map.get(fields, :femtosecond, 0)
    }
  end

  defp encode_with_nif(%__MODULE__{} = omm, fun) do
    with {:ok, fields} <- to_nif_fields(omm) do
      fun.(fields)
    end
  rescue
    e in ErlangError -> NifCall.error(e, __STACKTRACE__, :omm_encode)
  end

  defp to_nif_fields(%__MODULE__{} = omm) do
    with {:ok, epoch} <- epoch_fields(omm.epoch),
         {:ok, required_floats} <-
           collect(
             [:eccentricity, :inclination_deg, :ra_of_asc_node_deg, :arg_of_pericenter_deg, :mean_anomaly_deg],
             &required_float(omm, &1)
           ),
         {:ok, optional_floats} <-
           collect(
             [
               :mean_motion,
               :semi_major_axis_km,
               :gm_km3_s2,
               :bstar,
               :bterm_m2_kg,
               :mean_motion_dot,
               :mean_motion_ddot,
               :agom_m2_kg
             ],
             &optional_float(omm, &1)
           ),
         {:ok, optional_integers} <-
           collect(
             [:ephemeris_type, :norad_cat_id, :element_set_no, :rev_at_epoch],
             &optional_integer(omm, &1)
           ),
         {:ok, optional_strings} <-
           collect(
             [
               :ccsds_omm_vers,
               :classification,
               :creation_date,
               :originator,
               :message_id,
               :object_name,
               :object_id,
               :center_name,
               :ref_frame,
               :ref_frame_epoch,
               :time_system,
               :mean_element_theory,
               :classification_type
             ],
             &optional_string(omm, &1)
           ),
         {:ok, spacecraft} <- spacecraft_fields(omm.spacecraft),
         {:ok, covariance} <- covariance_fields(omm.covariance),
         {:ok, user_defined} <- user_defined_fields(omm.user_defined),
         {:ok, comments} <- comments_fields(omm.comments),
         {:ok, exact_sgp4_epoch} <- exact_sgp4_epoch_fields(omm.exact_sgp4_epoch),
         {:ok, quantize_tle_derived_fields} <-
           boolean_field(omm.quantize_tle_derived_fields, :quantize_tle_derived_fields) do
      {:ok,
       required_floats
       |> Map.merge(optional_floats)
       |> Map.merge(optional_integers)
       |> Map.merge(optional_strings)
       |> Map.merge(%{
         epoch: epoch,
         spacecraft: spacecraft,
         covariance: covariance,
         user_defined: user_defined,
         comments: comments,
         exact_sgp4_epoch: exact_sgp4_epoch,
         quantize_tle_derived_fields: quantize_tle_derived_fields
       })}
    end
  end

  defp collect(fields, fun) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case fun.(field) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp spacecraft_fields(nil), do: {:ok, nil}

  defp spacecraft_fields(%Spacecraft{} = spacecraft) do
    with {:ok, comments} <- string_list(spacecraft.comments, :spacecraft_comments),
         {:ok, values} <-
           collect(
             [:mass_kg, :solar_rad_area_m2, :solar_rad_coeff, :drag_area_m2, :drag_coeff],
             &optional_float(spacecraft, &1)
           ) do
      {:ok, Map.put(values, :comments, comments)}
    end
  end

  defp spacecraft_fields(value), do: {:error, {:invalid_field, :spacecraft, value}}

  defp covariance_fields(nil), do: {:ok, nil}

  defp covariance_fields(%Covariance{lower_triangle: values} = covariance)
       when is_list(values) and length(values) == 21 do
    with {:ok, comments} <- string_list(covariance.comments, :covariance_comments),
         {:ok, cov_ref_frame} <- optional_string(covariance, :cov_ref_frame),
         {:ok, lower_triangle} <- float_list(values, :covariance) do
      {:ok, %{comments: comments, cov_ref_frame: cov_ref_frame, lower_triangle: lower_triangle}}
    end
  end

  defp covariance_fields(value), do: {:error, {:invalid_field, :covariance, value}}

  defp user_defined_fields(parameters) when is_list(parameters) do
    parameters
    |> Enum.reduce_while({:ok, []}, fn
      %UserDefined{parameter: parameter, value: value}, {:ok, acc}
      when is_binary(parameter) and is_binary(value) ->
        {:cont, {:ok, [%{parameter: parameter, value: value} | acc]}}

      other, _acc ->
        {:halt, {:error, {:invalid_field, :user_defined, other}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp user_defined_fields(value), do: {:error, {:invalid_field, :user_defined, value}}

  defp comments_fields(%Comments{} = comments) do
    collect(
      [:header, :metadata, :mean_elements, :tle_parameters, :user_defined],
      &string_list(Map.fetch!(comments, &1), :comments)
    )
  end

  defp comments_fields(value), do: {:error, {:invalid_field, :comments, value}}

  defp exact_sgp4_epoch_fields(nil), do: {:ok, nil}

  defp exact_sgp4_epoch_fields({whole, fraction}) when is_float(whole) and is_float(fraction),
    do: {:ok, {whole, fraction}}

  defp exact_sgp4_epoch_fields(value), do: {:error, {:invalid_field, :exact_sgp4_epoch, value}}

  defp boolean_field(value, _field) when is_boolean(value), do: {:ok, value}
  defp boolean_field(value, field), do: {:error, {:invalid_field, field, value}}

  defp string_list(values, field) when is_list(values) do
    if Enum.all?(values, &is_binary/1),
      do: {:ok, values},
      else: {:error, {:invalid_field, field, values}}
  end

  defp string_list(values, field), do: {:error, {:invalid_field, field, values}}

  defp float_list(values, field) do
    if Enum.all?(values, &is_number/1),
      do: {:ok, Enum.map(values, &(&1 * 1.0))},
      else: {:error, {:invalid_field, field, values}}
  end

  defp epoch_fields(%Epoch{} = epoch) do
    fields = [:year, :month, :day, :hour, :minute, :second, :microsecond, :femtosecond]

    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case Map.fetch!(epoch, field) do
        value when is_integer(value) -> {:cont, {:ok, Map.put(acc, field, value)}}
        value -> {:halt, {:error, {:invalid_field, field, value}}}
      end
    end)
  end

  defp epoch_fields(value), do: {:error, {:invalid_field, :epoch, value}}

  defp epoch_to_datetime(%Epoch{} = epoch) do
    with {:ok, date} <- Date.new(epoch.year, epoch.month, epoch.day),
         {:ok, time} <- Time.new(epoch.hour, epoch.minute, epoch.second, {epoch.microsecond, 6}),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, datetime}
    else
      {:error, reason} -> {:error, {:invalid_field, :epoch, reason}}
    end
  end

  defp epoch_to_datetime(value), do: {:error, {:invalid_field, :epoch, value}}

  # -- Legacy decoded-map parser helpers --

  defp catalog_number(nil), do: nil
  defp catalog_number(value), do: to_string(value)

  defp parse_epoch(nil), do: {:error, {:missing_field, "EPOCH"}}

  defp parse_epoch(epoch_str) when is_binary(epoch_str) do
    case DateTime.from_iso8601(epoch_str) do
      {:ok, dt, _offset} ->
        {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(epoch_str) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          {:error, _reason} -> {:error, {:invalid_field, "EPOCH", epoch_str}}
        end
    end
  end

  defp parse_epoch(value), do: {:error, {:invalid_field, "EPOCH", value}}

  defp optional_float_field(omm, key) do
    case omm[key] do
      nil -> {:ok, nil}
      value -> parse_float_field(key, value)
    end
  end

  defp required_float_field(omm, key) do
    case Map.fetch(omm, key) do
      {:ok, nil} -> {:error, {:missing_field, key}}
      {:ok, value} -> parse_float_field(key, value)
      :error -> {:error, {:missing_field, key}}
    end
  end

  defp parse_float_field(_key, value) when is_float(value), do: {:ok, value}
  defp parse_float_field(_key, value) when is_integer(value), do: {:ok, value * 1.0}

  defp parse_float_field(key, value) when is_binary(value) do
    trimmed = String.trim(value)

    case Float.parse(trimmed) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, {:invalid_field, key, value}}
    end
  end

  defp parse_float_field(key, value), do: {:error, {:invalid_field, key, value}}

  defp safe_int(s) when is_binary(s), do: s |> String.trim() |> String.to_integer()
  defp safe_int(n) when is_integer(n), do: n

  # -- Validation helpers used by text encoding --

  defp optional_string(struct, field) do
    case Map.fetch!(struct, field) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      value -> {:error, {:invalid_field, field, value}}
    end
  end

  defp required_float(struct, field) do
    case Map.fetch!(struct, field) do
      value when is_float(value) and value != :nan and value not in [:infinity, :neg_infinity] ->
        {:ok, value}

      value when is_integer(value) ->
        {:ok, value * 1.0}

      nil ->
        {:error, {:missing_field, field}}

      value ->
        {:error, {:invalid_field, field, value}}
    end
  end

  defp optional_float(struct, field) do
    case Map.fetch!(struct, field) do
      nil -> {:ok, nil}
      _value -> required_float(struct, field)
    end
  end

  defp optional_integer(struct, field) do
    case Map.fetch!(struct, field) do
      nil -> {:ok, nil}
      value when is_integer(value) -> {:ok, value}
      value -> {:error, {:invalid_field, field, value}}
    end
  end
end
