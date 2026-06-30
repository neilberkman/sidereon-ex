defmodule Sidereon.CCSDS.CDM do
  @moduledoc """
  Parse and encode CCSDS Conjunction Data Messages (CDM).

  Supports both the **KVN** (Keyword=Value Notation) and **XML** formats
  per CCSDS 508.0-B-1. CDMs describe a predicted close approach between
  two space objects, including states, covariances, and collision
  probability.

  `parse/1` auto-detects the format based on the first non-whitespace
  character: a leading `<` is treated as XML, anything else as KVN.

  ## Examples

      {:ok, cdm} = Sidereon.CCSDS.CDM.parse(kvn_string)
      cdm.tca                    # ~U[2010-03-13 22:37:52.618Z]
      cdm.miss_distance_m        # 715.0
      cdm.collision_probability  # 4.835e-05

      # KVN output (default)
      kvn = Sidereon.CCSDS.CDM.encode(cdm)

      # XML output
      xml = Sidereon.CCSDS.CDM.encode(cdm, format: :xml)

      # Round-trip through XML
      {:ok, cdm2} = Sidereon.CCSDS.CDM.parse(xml)
  """

  alias Sidereon.NIF

  defmodule ObjectData do
    @moduledoc """
    Object-specific data block inside a parsed CCSDS CDM.
    """

    @type t :: %__MODULE__{
            object_designator: String.t() | nil,
            catalog_name: String.t() | nil,
            object_name: String.t() | nil,
            international_designator: String.t() | nil,
            object_type: String.t() | nil,
            operator_contact_position: String.t() | nil,
            operator_organization: String.t() | nil,
            operator_phone: String.t() | nil,
            operator_email: String.t() | nil,
            ephemeris_name: String.t() | nil,
            covariance_method: String.t() | nil,
            maneuverable: String.t() | nil,
            orbit_center: String.t() | nil,
            ref_frame: String.t() | nil,
            gravity_model: String.t() | nil,
            atmospheric_model: String.t() | nil,
            n_body_perturbations: String.t() | nil,
            solar_rad_pressure: String.t() | nil,
            earth_tides: String.t() | nil,
            intrack_thrust: String.t() | nil,
            state: {{float(), float(), float()}, {float(), float(), float()}} | nil,
            covariance_rtn: list(float()) | nil,
            velocity_covariance_rtn: list(float()) | nil
          }

    defstruct [
      :object_designator,
      :catalog_name,
      :object_name,
      :international_designator,
      :object_type,
      :operator_contact_position,
      :operator_organization,
      :operator_phone,
      :operator_email,
      :ephemeris_name,
      :covariance_method,
      :maneuverable,
      :orbit_center,
      :ref_frame,
      :gravity_model,
      :atmospheric_model,
      :n_body_perturbations,
      :solar_rad_pressure,
      :earth_tides,
      :intrack_thrust,
      :state,
      :covariance_rtn,
      :velocity_covariance_rtn
    ]
  end

  @type t :: %__MODULE__{
          creation_date: DateTime.t() | nil,
          originator: String.t() | nil,
          message_id: String.t() | nil,
          tca: DateTime.t() | nil,
          miss_distance_m: float() | nil,
          relative_speed_m_s: float() | nil,
          collision_probability: float() | nil,
          collision_probability_method: String.t() | nil,
          hard_body_radius_m: float() | nil,
          object1: ObjectData.t() | nil,
          object2: ObjectData.t() | nil
        }

  defstruct [
    :creation_date,
    :originator,
    :message_id,
    :tca,
    :miss_distance_m,
    :relative_speed_m_s,
    :collision_probability,
    :collision_probability_method,
    :hard_body_radius_m,
    :object1,
    :object2
  ]

  @doc """
  Parse a CDM in either KVN or XML format.

  Format is auto-detected from the first non-whitespace character: `<`
  routes to the XML parser, anything else to the KVN parser.

  Returns `{:ok, %CDM{}}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(string) when is_binary(string) do
    trimmed = String.trim_leading(string)

    if String.starts_with?(trimmed, "<") do
      parse_xml(string)
    else
      parse_kvn(string)
    end
  end

  @doc """
  Parse a CDM in KVN format explicitly. Skips format auto-detection.
  """
  @spec parse_kvn(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_kvn(kvn_string) when is_binary(kvn_string) do
    # The core owns KVN tokenization, unit stripping, HBR recovery, object-block
    # splitting, and the state-vector completeness check; it returns the date/time
    # fields as raw strings for the host to resolve to its native DateTime.
    kvn_string |> NIF.cdm_parse_kvn() |> from_fields()
  end

  # Resolve the core-returned field map (date/time fields as raw strings) into the
  # public struct. Shared by the KVN and XML readers, which differ only in the NIF
  # they call; the date/time resolution and MESSAGE_ID presence check are the host's.
  defp from_fields({:ok, fields}) do
    with {:ok, tca} <- parse_datetime(fields.tca),
         {:ok, creation} <- parse_datetime(fields.creation_date),
         {:ok, msg_id} <- required(fields.message_id, "missing MESSAGE_ID") do
      {:ok,
       %__MODULE__{
         creation_date: creation,
         originator: fields.originator,
         message_id: msg_id,
         tca: tca,
         miss_distance_m: fields.miss_distance_m,
         relative_speed_m_s: fields.relative_speed_m_s,
         collision_probability: fields.collision_probability,
         collision_probability_method: fields.collision_probability_method,
         hard_body_radius_m: fields.hard_body_radius_m,
         object1: build_object(fields.object1),
         object2: build_object(fields.object2)
       }}
    end
  end

  defp from_fields({:error, reason}), do: {:error, reason}

  defp build_object(obj) do
    %ObjectData{
      object_designator: obj.object_designator,
      catalog_name: obj.catalog_name,
      object_name: obj.object_name,
      international_designator: obj.international_designator,
      object_type: obj.object_type,
      operator_contact_position: obj.operator_contact_position,
      operator_organization: obj.operator_organization,
      operator_phone: obj.operator_phone,
      operator_email: obj.operator_email,
      ephemeris_name: obj.ephemeris_name,
      covariance_method: obj.covariance_method,
      maneuverable: obj.maneuverable,
      orbit_center: obj.orbit_center,
      ref_frame: obj.ref_frame,
      gravity_model: obj.gravity_model,
      atmospheric_model: obj.atmospheric_model,
      n_body_perturbations: obj.n_body_perturbations,
      solar_rad_pressure: obj.solar_rad_pressure,
      earth_tides: obj.earth_tides,
      intrack_thrust: obj.intrack_thrust,
      state: obj.state,
      covariance_rtn: obj.covariance_rtn,
      velocity_covariance_rtn: obj.velocity_covariance_rtn
    }
  end

  @doc """
  Encode a CDM.

  ## Options
    * `:format` - `:kvn` (default) or `:xml`
  """
  @spec encode(t(), keyword()) :: String.t()
  def encode(cdm, opts \\ [])

  def encode(%__MODULE__{} = cdm, opts) do
    case Keyword.get(opts, :format, :kvn) do
      :kvn -> encode_kvn(cdm)
      :xml -> encode_xml(cdm)
      other -> raise ArgumentError, "unsupported CDM format: #{inspect(other)}"
    end
  end

  @doc """
  Encode a CDM to KVN format explicitly.
  """
  @spec encode_kvn(t()) :: String.t()
  def encode_kvn(%__MODULE__{} = cdm) do
    # The core owns the KVN line layout and number formatting; the host formats
    # the date/time fields to strings first.
    NIF.cdm_encode_kvn(encode_fields(cdm))
  end

  defp encode_fields(%__MODULE__{} = cdm) do
    %{
      creation_date: format_datetime(cdm.creation_date),
      originator: cdm.originator,
      message_id: cdm.message_id,
      tca: format_datetime(cdm.tca),
      miss_distance_m: cdm.miss_distance_m,
      relative_speed_m_s: cdm.relative_speed_m_s,
      collision_probability: cdm.collision_probability,
      collision_probability_method: cdm.collision_probability_method,
      hard_body_radius_m: cdm.hard_body_radius_m,
      object1: encode_object_fields(cdm.object1),
      object2: encode_object_fields(cdm.object2)
    }
  end

  defp encode_object_fields(obj) do
    %{
      object_designator: obj.object_designator,
      catalog_name: obj.catalog_name,
      object_name: obj.object_name,
      international_designator: obj.international_designator,
      object_type: obj.object_type,
      operator_contact_position: obj.operator_contact_position,
      operator_organization: obj.operator_organization,
      operator_phone: obj.operator_phone,
      operator_email: obj.operator_email,
      ephemeris_name: obj.ephemeris_name,
      covariance_method: obj.covariance_method,
      maneuverable: obj.maneuverable,
      orbit_center: obj.orbit_center,
      ref_frame: obj.ref_frame,
      gravity_model: obj.gravity_model,
      atmospheric_model: obj.atmospheric_model,
      n_body_perturbations: obj.n_body_perturbations,
      solar_rad_pressure: obj.solar_rad_pressure,
      earth_tides: obj.earth_tides,
      intrack_thrust: obj.intrack_thrust,
      state: obj.state,
      covariance_rtn: obj.covariance_rtn,
      velocity_covariance_rtn: obj.velocity_covariance_rtn
    }
  end

  @doc """
  Encode a CDM to XML format explicitly.

  Produces a document matching the CCSDS 508.0-B-1 CDM XML schema's
  top-level shape (cdm > header/body > segment > metadata/data). This
  is the canonical XML form used for inter-system exchange alongside KVN.
  """
  @spec encode_xml(t()) :: String.t()
  def encode_xml(%__MODULE__{} = cdm) do
    # The core owns the XML document layout, number formatting, and entity
    # escaping; the host formats the date/time fields to strings first.
    NIF.cdm_encode_xml(encode_fields(cdm))
  end

  @doc """
  Convert a parsed CDM to inputs for `Sidereon.Collision.probability/1`.
  """
  @spec to_collision_params(t()) :: map()
  def to_collision_params(%__MODULE__{} = cdm) do
    {r1, v1} = cdm.object1.state
    {r2, v2} = cdm.object2.state

    # Extract 3x3 position covariance from RTN (first 3x3 block)
    {:ok, cov1_rtn} = Sidereon.Covariance.extract_pos_cov(cdm.object1.covariance_rtn)
    {:ok, cov2_rtn} = Sidereon.Covariance.extract_pos_cov(cdm.object2.covariance_rtn)

    # Convert RTN covariance to ECI using the object's state
    {:ok, cov1_eci} = Sidereon.Covariance.rtn_to_eci(cov1_rtn, r1, v1)
    {:ok, cov2_eci} = Sidereon.Covariance.rtn_to_eci(cov2_rtn, r2, v2)

    # Convert m² to km²
    cov1_km2 = m2_to_km2(cov1_eci)
    cov2_km2 = m2_to_km2(cov2_eci)

    hbr_km = (cdm.hard_body_radius_m || 15.0) / 1000.0

    %{
      r1: r1,
      v1: v1,
      cov1: cov1_km2,
      r2: r2,
      v2: v2,
      cov2: cov2_km2,
      hard_body_radius_km: hbr_km
    }
  end

  defp m2_to_km2(cov), do: Enum.map(cov, fn row -> Enum.map(row, &(&1 * 1.0e-6)) end)

  # --- XML parse ---

  @doc """
  Parse a CDM in XML format explicitly. Skips format auto-detection.
  """
  @spec parse_xml(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_xml(xml) when is_binary(xml) do
    # The core owns comment/prologue stripping, flat leaf-element extraction,
    # segment splitting, and the state-vector completeness check; it returns the
    # date/time fields as raw strings for the host to resolve to its native
    # DateTime, exactly like the KVN reader.
    xml |> NIF.cdm_parse_xml() |> from_fields()
  end

  # --- Helpers ---

  defp required(nil, reason), do: {:error, reason}
  defp required(val, _), do: {:ok, val}

  defp parse_datetime(nil), do: {:error, "missing datetime"}

  defp parse_datetime(str) do
    # 1. Try ISO8601 directly (handles Z and +HH:MM offsets)
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        # 2. Try with assumed UTC 'Z' if no offset is present
        if String.contains?(str, ["Z", "+", "-"]) do
          # Fallback for Naive strings that might be in a different format
          case NaiveDateTime.from_iso8601(str) do
            {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
            {:error, _} -> {:error, "bad datetime: #{str}"}
          end
        else
          case DateTime.from_iso8601(str <> "Z") do
            {:ok, dt, _} -> {:ok, dt}
            _ -> {:error, "bad datetime: #{str}"}
          end
        end
    end
  end

  defp format_datetime(%DateTime{} = dt) do
    dt |> DateTime.to_iso8601() |> String.replace("Z", "")
  end
end
