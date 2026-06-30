defmodule Sidereon.CCSDS.OPM do
  @moduledoc """
  Parse and encode CCSDS Orbit Parameter Messages (OPM).

  Supports both the **KVN** (Keyword=Value Notation) and **XML** formats per
  CCSDS 502.0-B. An OPM carries a single epoch's Cartesian state plus optional
  Keplerian elements, spacecraft parameters, a 6x6 covariance, and a list of
  maneuvers.

  `parse/1` auto-detects the format from the first non-whitespace character: a
  leading `<` is treated as XML, anything else as KVN. Date/time fields are
  preserved as raw strings exactly as written.

  ## Examples

      {:ok, opm} = Sidereon.CCSDS.OPM.parse(kvn_string)
      opm.metadata.object_name
      opm.state.position_km        # {x, y, z} in km
      opm.keplerian.anomaly        # {:true_anomaly, deg} or {:mean_anomaly, deg}

      # KVN output (default)
      kvn = Sidereon.CCSDS.OPM.encode(opm)

      # XML output
      xml = Sidereon.CCSDS.OPM.encode(opm, format: :xml)

      # Round-trip through XML
      {:ok, opm2} = Sidereon.CCSDS.OPM.parse(xml)
  """

  alias Sidereon.CCSDS.OPM
  alias Sidereon.NIF

  @typedoc "A Cartesian triple `{x, y, z}`."
  @type vec3 :: {float(), float(), float()}

  @typedoc "Failure reason from the OPM readers."
  @type error :: :missing_field | :invalid_field | :malformed

  defmodule Metadata do
    @moduledoc """
    OPM metadata block.
    """

    @enforce_keys [:object_name, :object_id, :center_name, :ref_frame, :time_system]
    defstruct [:object_name, :object_id, :center_name, :ref_frame, :time_system]

    @type t :: %__MODULE__{
            object_name: String.t(),
            object_id: String.t(),
            center_name: String.t(),
            ref_frame: String.t(),
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
    defstruct [:epoch, :position_km, :velocity_km_s]

    @type t :: %__MODULE__{
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
      :gm_km3_s2
    ]

    @type anomaly :: {:true_anomaly, float()} | {:mean_anomaly, float()}

    @type t :: %__MODULE__{
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

    defstruct [:mass_kg, :solar_rad_area_m2, :solar_rad_coeff, :drag_area_m2, :drag_coeff]

    @type t :: %__MODULE__{
            mass_kg: float() | nil,
            solar_rad_area_m2: float() | nil,
            solar_rad_coeff: float() | nil,
            drag_area_m2: float() | nil,
            drag_coeff: float() | nil
          }
  end

  defmodule Covariance do
    @moduledoc """
    Optional OPM 6x6 covariance. `matrix` is a row-major list of six six-element
    rows.
    """

    @enforce_keys [:matrix]
    defstruct [:cov_ref_frame, :matrix]

    @type t :: %__MODULE__{
            cov_ref_frame: String.t() | nil,
            matrix: [[float()]]
          }
  end

  defmodule Maneuver do
    @moduledoc """
    One OPM maneuver block. `dv_km_s` is the `{x, y, z}` delta-v in the maneuver
    reference frame.
    """

    @enforce_keys [:epoch_ignition, :duration_s, :delta_mass_kg, :ref_frame, :dv_km_s]
    defstruct [:epoch_ignition, :duration_s, :delta_mass_kg, :ref_frame, :dv_km_s]

    @type t :: %__MODULE__{
            epoch_ignition: String.t(),
            duration_s: float(),
            delta_mass_kg: float(),
            ref_frame: String.t(),
            dv_km_s: OPM.vec3()
          }
  end

  @enforce_keys [:metadata, :state]
  defstruct ccsds_opm_vers: "2.0",
            creation_date: nil,
            originator: nil,
            metadata: nil,
            state: nil,
            keplerian: nil,
            spacecraft: nil,
            covariance: nil,
            maneuvers: []

  @type t :: %__MODULE__{
          ccsds_opm_vers: String.t(),
          creation_date: String.t() | nil,
          originator: String.t() | nil,
          metadata: Metadata.t(),
          state: State.t(),
          keplerian: Keplerian.t() | nil,
          spacecraft: Spacecraft.t() | nil,
          covariance: Covariance.t() | nil,
          maneuvers: [Maneuver.t()]
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

  ## Options
    * `:format` - `:kvn` (default) or `:xml`
  """
  @spec encode(t(), keyword()) :: String.t()
  def encode(opm, opts \\ [])

  def encode(%__MODULE__{} = opm, opts) do
    case Keyword.get(opts, :format, :kvn) do
      :kvn -> encode_kvn(opm)
      :xml -> encode_xml(opm)
      other -> raise ArgumentError, "unsupported OPM format: #{inspect(other)}"
    end
  end

  @doc """
  Encode an OPM to KVN text explicitly.
  """
  @spec encode_kvn(t()) :: String.t()
  def encode_kvn(%__MODULE__{} = opm), do: NIF.opm_encode_kvn(to_fields(opm))

  @doc """
  Encode an OPM to XML text explicitly.
  """
  @spec encode_xml(t()) :: String.t()
  def encode_xml(%__MODULE__{} = opm), do: NIF.opm_encode_xml(to_fields(opm))

  # --- NIF field marshaling ---

  defp from_fields({:ok, fields}) do
    {:ok,
     %__MODULE__{
       ccsds_opm_vers: fields.ccsds_opm_vers,
       creation_date: fields.creation_date,
       originator: fields.originator,
       metadata: metadata_from_fields(fields.metadata),
       state: state_from_fields(fields.state),
       keplerian: keplerian_from_fields(fields.keplerian),
       spacecraft: spacecraft_from_fields(fields.spacecraft),
       covariance: covariance_from_fields(fields.covariance),
       maneuvers: Enum.map(fields.maneuvers, &maneuver_from_fields/1)
     }}
  end

  defp from_fields({:error, reason}), do: {:error, reason}

  defp metadata_from_fields(m) do
    %Metadata{
      object_name: m.object_name,
      object_id: m.object_id,
      center_name: m.center_name,
      ref_frame: m.ref_frame,
      time_system: m.time_system
    }
  end

  defp state_from_fields(s) do
    %State{epoch: s.epoch, position_km: s.position_km, velocity_km_s: s.velocity_km_s}
  end

  defp keplerian_from_fields(nil), do: nil

  defp keplerian_from_fields(k) do
    %Keplerian{
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
    %Spacecraft{
      mass_kg: s.mass_kg,
      solar_rad_area_m2: s.solar_rad_area_m2,
      solar_rad_coeff: s.solar_rad_coeff,
      drag_area_m2: s.drag_area_m2,
      drag_coeff: s.drag_coeff
    }
  end

  defp covariance_from_fields(nil), do: nil

  defp covariance_from_fields(c) do
    %Covariance{cov_ref_frame: c.cov_ref_frame, matrix: c.matrix}
  end

  defp maneuver_from_fields(m) do
    %Maneuver{
      epoch_ignition: m.epoch_ignition,
      duration_s: m.duration_s,
      delta_mass_kg: m.delta_mass_kg,
      ref_frame: m.ref_frame,
      dv_km_s: m.dv_km_s
    }
  end

  defp to_fields(%__MODULE__{} = opm) do
    %{
      ccsds_opm_vers: opm.ccsds_opm_vers,
      creation_date: opm.creation_date,
      originator: opm.originator,
      metadata: metadata_to_fields(opm.metadata),
      state: state_to_fields(opm.state),
      keplerian: keplerian_to_fields(opm.keplerian),
      spacecraft: spacecraft_to_fields(opm.spacecraft),
      covariance: covariance_to_fields(opm.covariance),
      maneuvers: Enum.map(opm.maneuvers, &maneuver_to_fields/1)
    }
  end

  defp metadata_to_fields(%Metadata{} = m) do
    %{
      object_name: m.object_name,
      object_id: m.object_id,
      center_name: m.center_name,
      ref_frame: m.ref_frame,
      time_system: m.time_system
    }
  end

  defp state_to_fields(%State{} = s) do
    %{epoch: s.epoch, position_km: s.position_km, velocity_km_s: s.velocity_km_s}
  end

  defp keplerian_to_fields(nil), do: nil

  defp keplerian_to_fields(%Keplerian{} = k) do
    {kind, deg} = anomaly_to_fields(k.anomaly)

    %{
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

  defp spacecraft_to_fields(%Spacecraft{} = s) do
    %{
      mass_kg: s.mass_kg,
      solar_rad_area_m2: s.solar_rad_area_m2,
      solar_rad_coeff: s.solar_rad_coeff,
      drag_area_m2: s.drag_area_m2,
      drag_coeff: s.drag_coeff
    }
  end

  defp covariance_to_fields(nil), do: nil

  defp covariance_to_fields(%Covariance{} = c) do
    %{cov_ref_frame: c.cov_ref_frame, matrix: c.matrix}
  end

  defp maneuver_to_fields(%Maneuver{} = m) do
    %{
      epoch_ignition: m.epoch_ignition,
      duration_s: m.duration_s,
      delta_mass_kg: m.delta_mass_kg,
      ref_frame: m.ref_frame,
      dv_km_s: m.dv_km_s
    }
  end
end
