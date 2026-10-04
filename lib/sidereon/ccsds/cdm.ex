defmodule Sidereon.CCSDS.CDM do
  @moduledoc """
  Parse and encode CCSDS Conjunction Data Messages (CDM).

  Supports both the **KVN** (Keyword=Value Notation) and **XML** formats
  per CCSDS 508.0-B-1. CDMs describe a predicted close approach between
  two space objects, including states, covariances, and collision
  probability.

  `parse/1` auto-detects the format based on the first non-whitespace
  character: a leading `<` is treated as XML, anything else as KVN.

  Every item of CCSDS 508.0-B-1 tables 3-1 to 3-4 and every comment is kept:
  the header, the relative metadata/data (relative state, screening period
  and volume), and for each object its metadata, OD parameters, additional
  parameters, state and the RTN covariance through rows 7 to 9. A KVN comment
  belongs to the block of the keyword after it. The covariance is held as
  stated, without a positive-semidefinite check; `CDM.ObjectData` documents the
  row groups.

  ## Examples

      {:ok, cdm} = Sidereon.CCSDS.CDM.parse(kvn_string)
      cdm.tca                    # ~U[2010-03-13 22:37:52.618Z]
      cdm.miss_distance_m        # 715.0
      cdm.collision_probability  # 4.835e-05

      # KVN output (default)
      {:ok, kvn} = Sidereon.CCSDS.CDM.encode(cdm)

      # XML output
      {:ok, xml} = Sidereon.CCSDS.CDM.encode(cdm, format: :xml)

      # Round-trip through XML
      {:ok, cdm2} = Sidereon.CCSDS.CDM.parse(xml)
  """

  alias Sidereon.CCSDS.Error
  alias Sidereon.NIF

  defmodule OdParameters do
    @moduledoc """
    OD parameters of one CDM object (CCSDS 508.0-B-1 table 3-4). Spans are in
    days; the observation and track counts are non-negative integers.
    """

    @type t :: %__MODULE__{
            comments: [String.t()],
            time_lastob_start: String.t() | nil,
            time_lastob_end: String.t() | nil,
            recommended_od_span_d: float() | nil,
            actual_od_span_d: float() | nil,
            obs_available: non_neg_integer() | nil,
            obs_used: non_neg_integer() | nil,
            tracks_available: non_neg_integer() | nil,
            tracks_used: non_neg_integer() | nil,
            residuals_accepted_pct: float() | nil,
            weighted_rms: float() | nil
          }

    defstruct comments: [],
              time_lastob_start: nil,
              time_lastob_end: nil,
              recommended_od_span_d: nil,
              actual_od_span_d: nil,
              obs_available: nil,
              obs_used: nil,
              tracks_available: nil,
              tracks_used: nil,
              residuals_accepted_pct: nil,
              weighted_rms: nil
  end

  defmodule AdditionalParameters do
    @moduledoc """
    Additional parameters of one CDM object (CCSDS 508.0-B-1 table 3-4): areas
    in m², mass in kg, the drag and SRP coefficients times area over mass in
    m²/kg, thrust acceleration in m/s² and SEDR in W/kg.
    """

    @type t :: %__MODULE__{
            comments: [String.t()],
            area_pc_m2: float() | nil,
            area_drg_m2: float() | nil,
            area_srp_m2: float() | nil,
            mass_kg: float() | nil,
            cd_area_over_mass_m2_kg: float() | nil,
            cr_area_over_mass_m2_kg: float() | nil,
            thrust_acceleration_m_s2: float() | nil,
            sedr_w_kg: float() | nil
          }

    defstruct comments: [],
              area_pc_m2: nil,
              area_drg_m2: nil,
              area_srp_m2: nil,
              mass_kg: nil,
              cd_area_over_mass_m2_kg: nil,
              cr_area_over_mass_m2_kg: nil,
              thrust_acceleration_m_s2: nil,
              sedr_w_kg: nil
  end

  defmodule ObjectData do
    @moduledoc """
    Object-specific data block inside a parsed CCSDS CDM.

    The RTN covariance is held as stated, in row groups of its lower triangle:
    `covariance_rtn` the six position terms, `velocity_covariance_rtn` the 15
    terms of rows 4 to 6, and `drag_covariance_rtn`, `srp_covariance_rtn` and
    `thrust_covariance_rtn` the 7, 8 and 9 terms of rows 7, 8 and 9, each `nil`
    when the message gives none of it. Values are in the units of 508.0-B-1
    table 3-4.
    """

    alias Sidereon.CCSDS.CDM.AdditionalParameters
    alias Sidereon.CCSDS.CDM.OdParameters

    @type t :: %__MODULE__{
            metadata_comments: [String.t()],
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
            od_parameters: OdParameters.t(),
            additional_parameters: AdditionalParameters.t(),
            state_comments: [String.t()],
            state: {{float(), float(), float()}, {float(), float(), float()}} | nil,
            covariance_comments: [String.t()],
            covariance_rtn: list(float()) | nil,
            velocity_covariance_rtn: list(float()) | nil,
            drag_covariance_rtn: list(float()) | nil,
            srp_covariance_rtn: list(float()) | nil,
            thrust_covariance_rtn: list(float()) | nil
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
      :velocity_covariance_rtn,
      :drag_covariance_rtn,
      :srp_covariance_rtn,
      :thrust_covariance_rtn,
      metadata_comments: [],
      od_parameters: %OdParameters{},
      additional_parameters: %AdditionalParameters{},
      state_comments: [],
      covariance_comments: []
    ]
  end

  @typedoc "An RTN triple whose components are each `nil` when not stated."
  @type optional_triple :: {float() | nil, float() | nil, float() | nil}

  @typedoc """
  A CCSDS CDM. `ccsds_cdm_vers` is the version the message states, or `nil`;
  the writers state it only when present. `comments` are the header comments
  and `relative_comments` those of the relative metadata/data. The screening
  period and entry and exit times are kept as written; `screen_volume_m` holds
  the three screening-volume sizes.
  """
  @type t :: %__MODULE__{
          ccsds_cdm_vers: String.t() | nil,
          comments: [String.t()],
          creation_date: DateTime.t() | nil,
          originator: String.t() | nil,
          message_for: String.t() | nil,
          message_id: String.t() | nil,
          relative_comments: [String.t()],
          tca: DateTime.t() | nil,
          miss_distance_m: float() | nil,
          relative_speed_m_s: float() | nil,
          relative_position_rtn_m: optional_triple(),
          relative_velocity_rtn_m_s: optional_triple(),
          start_screen_period: String.t() | nil,
          stop_screen_period: String.t() | nil,
          screen_volume_frame: String.t() | nil,
          screen_volume_shape: String.t() | nil,
          screen_volume_m: optional_triple(),
          screen_entry_time: String.t() | nil,
          screen_exit_time: String.t() | nil,
          collision_probability: float() | nil,
          collision_probability_method: String.t() | nil,
          hard_body_radius_m: float() | nil,
          object1: ObjectData.t() | nil,
          object2: ObjectData.t() | nil
        }

  defstruct [
    :ccsds_cdm_vers,
    :creation_date,
    :originator,
    :message_for,
    :message_id,
    :tca,
    :miss_distance_m,
    :relative_speed_m_s,
    :start_screen_period,
    :stop_screen_period,
    :screen_volume_frame,
    :screen_volume_shape,
    :screen_entry_time,
    :screen_exit_time,
    :collision_probability,
    :collision_probability_method,
    :hard_body_radius_m,
    :object1,
    :object2,
    comments: [],
    relative_comments: [],
    relative_position_rtn_m: {nil, nil, nil},
    relative_velocity_rtn_m_s: {nil, nil, nil},
    screen_volume_m: {nil, nil, nil}
  ]

  @plain_fields [
    :ccsds_cdm_vers,
    :comments,
    :originator,
    :message_for,
    :relative_comments,
    :miss_distance_m,
    :relative_speed_m_s,
    :relative_position_rtn_m,
    :relative_velocity_rtn_m_s,
    :start_screen_period,
    :stop_screen_period,
    :screen_volume_frame,
    :screen_volume_shape,
    :screen_volume_m,
    :screen_entry_time,
    :screen_exit_time,
    :collision_probability,
    :collision_probability_method,
    :hard_body_radius_m
  ]

  @doc """
  Parse a CDM in either KVN or XML format.

  Format is auto-detected from the first non-whitespace character: `<`
  routes to the XML parser, anything else to the KVN parser.

  Returns `{:ok, %CDM{}}` or `{:error, reason}`.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, Error.cdm()}
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
  @spec parse_kvn(String.t()) :: {:ok, t()} | {:error, Error.cdm()}
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
       struct(
         __MODULE__,
         fields
         |> Map.take(@plain_fields)
         |> Map.merge(%{
           creation_date: creation,
           message_id: msg_id,
           tca: tca,
           object1: build_object(fields.object1),
           object2: build_object(fields.object2)
         })
       )}
    end
  end

  defp from_fields({:error, reason}), do: {:error, reason}

  defp build_object(obj) do
    struct(
      ObjectData,
      Map.merge(obj, %{
        od_parameters: struct(OdParameters, obj.od_parameters),
        additional_parameters: struct(AdditionalParameters, obj.additional_parameters)
      })
    )
  end

  @doc """
  Encode a CDM.

  Returns `{:ok, text}`, or `{:error, reason}` for a message the writer cannot
  write so that its reader returns it unchanged (such as text with a line break
  in KVN, or a retained comment that would read back as a hard-body radius the
  message does not hold) or a covariance row group of the wrong length.

  ## Options
    * `:format` - `:kvn` (default) or `:xml`
  """
  @spec encode(t(), keyword()) :: {:ok, String.t()} | {:error, Error.cdm()}
  def encode(cdm, opts \\ [])

  def encode(%__MODULE__{} = cdm, opts) do
    case Keyword.get(opts, :format, :kvn) do
      :kvn -> encode_kvn(cdm)
      :xml -> encode_xml(cdm)
      other -> raise ArgumentError, "unsupported CDM format: #{inspect(other)}"
    end
  end

  @doc """
  Encode a CDM to KVN format explicitly. Returns `{:ok, text}` or
  `{:error, reason}`.
  """
  @spec encode_kvn(t()) :: {:ok, String.t()} | {:error, Error.cdm()}
  def encode_kvn(%__MODULE__{} = cdm) do
    # The core owns the KVN line layout and number formatting; the host formats
    # the date/time fields to strings first.
    NIF.cdm_encode_kvn(encode_fields(cdm))
  end

  defp encode_fields(%__MODULE__{} = cdm) do
    cdm
    |> Map.take(@plain_fields)
    |> Map.merge(%{
      creation_date: format_datetime(cdm.creation_date),
      message_id: cdm.message_id,
      tca: format_datetime(cdm.tca),
      object1: encode_object_fields(cdm.object1),
      object2: encode_object_fields(cdm.object2)
    })
  end

  defp encode_object_fields(%ObjectData{} = obj) do
    obj
    |> Map.from_struct()
    |> Map.merge(%{
      od_parameters: Map.from_struct(obj.od_parameters),
      additional_parameters: Map.from_struct(obj.additional_parameters)
    })
  end

  @doc """
  Encode a CDM to XML format explicitly.

  Produces a document matching the CCSDS 508.0-B-1 CDM XML schema's
  top-level shape (cdm > header/body > segment > metadata/data). This
  is the canonical XML form used for inter-system exchange alongside KVN.
  Returns `{:ok, text}` or `{:error, reason}`.
  """
  @spec encode_xml(t()) :: {:ok, String.t()} | {:error, Error.cdm()}
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
  @spec parse_xml(String.t()) :: {:ok, t()} | {:error, Error.cdm()}
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
