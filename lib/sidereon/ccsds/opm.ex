defmodule Sidereon.CCSDS.OPM do
  @moduledoc """
  Parse and encode CCSDS Orbit Parameter Messages (OPM).

  Supports both the **KVN** (Keyword=Value Notation) and **XML** formats per
  CCSDS 502.0-B. An OPM carries a single epoch's Cartesian state plus optional
  Keplerian elements, spacecraft parameters, a 6x6 covariance, a list of
  maneuvers and `USER_DEFINED_*` parameters. Every item of CCSDS 502.0-B-3
  tables 3-1 to 3-3 is kept, with the comments of each block: a KVN comment
  belongs to the block of the keyword after it and is written at the start of
  that block.

  `parse/1` auto-detects the format from the first non-whitespace character: a
  leading `<` is treated as XML, anything else as KVN. Date/time fields are
  preserved as raw strings exactly as written.

  ## Examples

      {:ok, opm} = Sidereon.CCSDS.OPM.parse(kvn_string)
      opm.metadata.object_name
      opm.state.position_km        # {x, y, z} in km
      opm.keplerian.anomaly        # {:true_anomaly, deg} or {:mean_anomaly, deg}

      # KVN output (default)
      {:ok, kvn} = Sidereon.CCSDS.OPM.encode(opm)

      # XML output
      {:ok, xml} = Sidereon.CCSDS.OPM.encode(opm, format: :xml)

      # Round-trip through XML
      {:ok, opm2} = Sidereon.CCSDS.OPM.parse(xml)
  """

  alias Sidereon.CCSDS.Error
  alias Sidereon.CCSDS.OPM
  alias Sidereon.NIF

  @typedoc "A Cartesian triple `{x, y, z}`."
  @type vec3 :: {float(), float(), float()}

  @typedoc """
  Failure reason from the OPM readers and writers, with every field the core
  refusal carries (`t:Sidereon.CCSDS.Error.opm/0`): a missing or invalid field, a
  malformed value, a keyword repeated with a different value, a unit that
  contradicts the standard's table, a document holding several messages, a
  keyword the standard does not define at its position, a KVN line that is not
  blank, a comment or an assignment, text a writer cannot write so that its
  reader returns it unchanged, or (writers only) fields that do not form a
  message, such as a covariance without exactly 21 lower-triangle values.
  """
  @type error :: Error.opm()

  defmodule Metadata do
    @moduledoc """
    OPM metadata block. `ref_frame_epoch` is the `REF_FRAME_EPOCH` text, kept
    as written.
    """

    @enforce_keys [:object_name, :object_id, :center_name, :ref_frame, :time_system]
    defstruct [
      :object_name,
      :object_id,
      :center_name,
      :ref_frame,
      :time_system,
      comments: [],
      ref_frame_epoch: nil
    ]

    @type t :: %__MODULE__{
            comments: [String.t()],
            object_name: String.t(),
            object_id: String.t(),
            center_name: String.t(),
            ref_frame: String.t(),
            ref_frame_epoch: String.t() | nil,
            time_system: String.t()
          }
  end

  defmodule State do
    @moduledoc """
    OPM Cartesian state vector.

    `position_km` and `velocity_km_s` are `{x, y, z}` tuples in the metadata
    reference frame.
    """

    @enforce_keys [:epoch, :position_km, :velocity_km_s]
    defstruct [:epoch, :position_km, :velocity_km_s, comments: []]

    @type t :: %__MODULE__{
            comments: [String.t()],
            epoch: String.t(),
            position_km: OPM.vec3(),
            velocity_km_s: OPM.vec3()
          }
  end

  defmodule Keplerian do
    @moduledoc """
    Optional OPM Keplerian elements.

    `anomaly` is a tagged tuple, either `{:true_anomaly, deg}` or
    `{:mean_anomaly, deg}`, preserving which anomaly keyword the message carried.
    """

    @enforce_keys [
      :semi_major_axis_km,
      :eccentricity,
      :inclination_deg,
      :ra_of_asc_node_deg,
      :arg_of_pericenter_deg,
      :anomaly,
      :gm_km3_s2
    ]
    defstruct [
      :semi_major_axis_km,
      :eccentricity,
      :inclination_deg,
      :ra_of_asc_node_deg,
      :arg_of_pericenter_deg,
      :anomaly,
      :gm_km3_s2,
      comments: []
    ]

    @type anomaly :: {:true_anomaly, float()} | {:mean_anomaly, float()}

    @type t :: %__MODULE__{
            comments: [String.t()],
            semi_major_axis_km: float(),
            eccentricity: float(),
            inclination_deg: float(),
            ra_of_asc_node_deg: float(),
            arg_of_pericenter_deg: float(),
            anomaly: anomaly(),
            gm_km3_s2: float()
          }
  end

  defmodule Spacecraft do
    @moduledoc """
    Optional OPM spacecraft parameters. Every field is optional.
    """

    defstruct [
      :mass_kg,
      :solar_rad_area_m2,
      :solar_rad_coeff,
      :drag_area_m2,
      :drag_coeff,
      comments: []
    ]

    @type t :: %__MODULE__{
            comments: [String.t()],
            mass_kg: float() | nil,
            solar_rad_area_m2: float() | nil,
            solar_rad_coeff: float() | nil,
            drag_area_m2: float() | nil,
            drag_coeff: float() | nil
          }
  end

  defmodule Covariance do
    @moduledoc """
    Optional OPM 6x6 covariance, held exactly as read.

    `lower_triangle` holds the 21 lower-triangle values in keyword order `CX_X`,
    `CY_X`, `CY_Y`, `CZ_X`, `CZ_Y`, `CZ_Z`, `CX_DOT_X` ... `CZ_DOT_Z_DOT`. No
    symmetry or definiteness check is applied, so a matrix that falls short of
    positive semidefinite only through the digits it is printed to is read.
    `to_matrix/1` expands it to six symmetric rows.
    """

    @enforce_keys [:lower_triangle]
    defstruct [:cov_ref_frame, :lower_triangle, comments: []]

    @type t :: %__MODULE__{
            comments: [String.t()],
            cov_ref_frame: String.t() | nil,
            lower_triangle: [float()]
          }

    @doc """
    The symmetric 6x6 matrix, as six six-element rows, that the 21
    lower-triangle values state. The values are placed as read; nothing is
    validated.
    """
    @spec to_matrix(t()) :: [[float()]]
    def to_matrix(%__MODULE__{lower_triangle: values}) when length(values) == 21 do
      tuple = List.to_tuple(values)

      for row <- 0..5 do
        for col <- 0..5 do
          {i, j} = if row >= col, do: {row, col}, else: {col, row}
          elem(tuple, div(i * (i + 1), 2) + j)
        end
      end
    end
  end

  defmodule UserDefined do
    @moduledoc """
    One `USER_DEFINED_*` parameter: the text after `USER_DEFINED_` and its
    value, verbatim.
    """

    @enforce_keys [:parameter, :value]
    defstruct [:parameter, :value]

    @type t :: %__MODULE__{parameter: String.t(), value: String.t()}
  end

  defmodule Maneuver do
    @moduledoc """
    One OPM maneuver block. `dv_km_s` is the `{x, y, z}` delta-v in the maneuver
    reference frame.
    """

    @enforce_keys [:epoch_ignition, :duration_s, :delta_mass_kg, :ref_frame, :dv_km_s]
    defstruct [:epoch_ignition, :duration_s, :delta_mass_kg, :ref_frame, :dv_km_s, comments: []]

    @type t :: %__MODULE__{
            comments: [String.t()],
            epoch_ignition: String.t(),
            duration_s: float(),
            delta_mass_kg: float(),
            ref_frame: String.t(),
            dv_km_s: OPM.vec3()
          }
  end

  @enforce_keys [:metadata, :state]
  defstruct ccsds_opm_vers: "2.0",
            comments: [],
            classification: nil,
            creation_date: nil,
            originator: nil,
            message_id: nil,
            metadata: nil,
            state: nil,
            keplerian: nil,
            spacecraft: nil,
            covariance: nil,
            maneuvers: [],
            user_defined: [],
            user_defined_comments: []

  @typedoc """
  A CCSDS OPM. `comments` are the header comments; `classification` and
  `message_id` are the optional header items of table 3-1.
  """
  @type t :: %__MODULE__{
          ccsds_opm_vers: String.t(),
          comments: [String.t()],
          classification: String.t() | nil,
          creation_date: String.t() | nil,
          originator: String.t() | nil,
          message_id: String.t() | nil,
          metadata: Metadata.t(),
          state: State.t(),
          keplerian: Keplerian.t() | nil,
          spacecraft: Spacecraft.t() | nil,
          covariance: Covariance.t() | nil,
          maneuvers: [Maneuver.t()],
          user_defined: [UserDefined.t()],
          user_defined_comments: [String.t()]
        }

  @doc """
  Parse an OPM in either KVN or XML format.

  Format is auto-detected from the first non-whitespace character: `<` routes to
  the XML parser, anything else to the KVN parser.

  Returns `{:ok, %Sidereon.CCSDS.OPM{}}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, error()}
  def parse(string) when is_binary(string) do
    if string |> String.trim_leading() |> String.starts_with?("<") do
      parse_xml(string)
    else
      parse_kvn(string)
    end
  end

  @doc """
  Parse an OPM in KVN format explicitly. Skips format auto-detection.
  """
  @spec parse_kvn(String.t()) :: {:ok, t()} | {:error, error()}
  def parse_kvn(text) when is_binary(text) do
    text |> NIF.opm_parse_kvn() |> from_fields()
  end

  @doc """
  Parse an OPM in XML format explicitly. Skips format auto-detection.
  """
  @spec parse_xml(String.t()) :: {:ok, t()} | {:error, error()}
  def parse_xml(text) when is_binary(text) do
    text |> NIF.opm_parse_xml() |> from_fields()
  end

  @doc """
  Encode an OPM.

  Returns `{:ok, text}`, or `{:error, reason}` for a message the writer cannot
  write so that its reader returns it unchanged (see `t:error/0`).

  ## Options
    * `:format` - `:kvn` (default) or `:xml`
  """
  @spec encode(t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def encode(opm, opts \\ [])

  def encode(%__MODULE__{} = opm, opts) do
    case Keyword.get(opts, :format, :kvn) do
      :kvn -> encode_kvn(opm)
      :xml -> encode_xml(opm)
      other -> raise ArgumentError, "unsupported OPM format: #{inspect(other)}"
    end
  end

  @doc """
  Encode an OPM to KVN text explicitly. Returns `{:ok, text}` or
  `{:error, reason}`.
  """
  @spec encode_kvn(t()) :: {:ok, String.t()} | {:error, error()}
  def encode_kvn(%__MODULE__{} = opm), do: NIF.opm_encode_kvn(to_fields(opm))

  @doc """
  Encode an OPM to XML text explicitly. Returns `{:ok, text}` or
  `{:error, reason}`.
  """
  @spec encode_xml(t()) :: {:ok, String.t()} | {:error, error()}
  def encode_xml(%__MODULE__{} = opm), do: NIF.opm_encode_xml(to_fields(opm))

  # --- NIF field marshaling ---

  defp from_fields({:ok, fields}) do
    {:ok,
     %__MODULE__{
       ccsds_opm_vers: fields.ccsds_opm_vers,
       comments: fields.comments,
       classification: fields.classification,
       creation_date: fields.creation_date,
       originator: fields.originator,
       message_id: fields.message_id,
       metadata: metadata_from_fields(fields.metadata),
       state: state_from_fields(fields.state),
       keplerian: keplerian_from_fields(fields.keplerian),
       spacecraft: spacecraft_from_fields(fields.spacecraft),
       covariance: covariance_from_fields(fields.covariance),
       maneuvers: Enum.map(fields.maneuvers, &maneuver_from_fields/1),
       user_defined: Enum.map(fields.user_defined, &struct(UserDefined, &1)),
       user_defined_comments: fields.user_defined_comments
     }}
  end

  defp from_fields({:error, reason}), do: {:error, reason}

  defp metadata_from_fields(m) do
    struct(Metadata, m)
  end

  defp state_from_fields(s) do
    struct(State, s)
  end

  defp keplerian_from_fields(nil), do: nil

  defp keplerian_from_fields(k) do
    %Keplerian{
      comments: k.comments,
      semi_major_axis_km: k.semi_major_axis_km,
      eccentricity: k.eccentricity,
      inclination_deg: k.inclination_deg,
      ra_of_asc_node_deg: k.ra_of_asc_node_deg,
      arg_of_pericenter_deg: k.arg_of_pericenter_deg,
      anomaly: anomaly_from_fields(k.anomaly_kind, k.anomaly_deg),
      gm_km3_s2: k.gm_km3_s2
    }
  end

  defp anomaly_from_fields("MEAN", deg), do: {:mean_anomaly, deg}
  defp anomaly_from_fields(_true_or_other, deg), do: {:true_anomaly, deg}

  defp spacecraft_from_fields(nil), do: nil

  defp spacecraft_from_fields(s) do
    struct(Spacecraft, s)
  end

  defp covariance_from_fields(nil), do: nil
  defp covariance_from_fields(c), do: struct(Covariance, c)

  defp maneuver_from_fields(m), do: struct(Maneuver, m)

  defp to_fields(%__MODULE__{} = opm) do
    %{
      ccsds_opm_vers: opm.ccsds_opm_vers,
      comments: opm.comments,
      classification: opm.classification,
      creation_date: opm.creation_date,
      originator: opm.originator,
      message_id: opm.message_id,
      metadata: metadata_to_fields(opm.metadata),
      state: state_to_fields(opm.state),
      keplerian: keplerian_to_fields(opm.keplerian),
      spacecraft: spacecraft_to_fields(opm.spacecraft),
      covariance: covariance_to_fields(opm.covariance),
      maneuvers: Enum.map(opm.maneuvers, &maneuver_to_fields/1),
      user_defined: Enum.map(opm.user_defined, &Map.from_struct/1),
      user_defined_comments: opm.user_defined_comments
    }
  end

  defp metadata_to_fields(%Metadata{} = m), do: Map.from_struct(m)

  defp state_to_fields(%State{} = s), do: Map.from_struct(s)

  defp keplerian_to_fields(nil), do: nil

  defp keplerian_to_fields(%Keplerian{} = k) do
    {kind, deg} = anomaly_to_fields(k.anomaly)

    %{
      comments: k.comments,
      semi_major_axis_km: k.semi_major_axis_km,
      eccentricity: k.eccentricity,
      inclination_deg: k.inclination_deg,
      ra_of_asc_node_deg: k.ra_of_asc_node_deg,
      arg_of_pericenter_deg: k.arg_of_pericenter_deg,
      anomaly_kind: kind,
      anomaly_deg: deg,
      gm_km3_s2: k.gm_km3_s2
    }
  end

  defp anomaly_to_fields({:mean_anomaly, deg}), do: {"MEAN", deg}
  defp anomaly_to_fields({:true_anomaly, deg}), do: {"TRUE", deg}

  defp spacecraft_to_fields(nil), do: nil

  defp spacecraft_to_fields(%Spacecraft{} = s), do: Map.from_struct(s)

  defp covariance_to_fields(nil), do: nil
  defp covariance_to_fields(%Covariance{} = c), do: Map.from_struct(c)

  defp maneuver_to_fields(%Maneuver{} = m), do: Map.from_struct(m)
end
