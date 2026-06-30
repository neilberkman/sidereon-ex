defmodule Sidereon.CCSDS.OEM do
  @moduledoc """
  Parse and encode CCSDS Orbit Ephemeris Messages (OEM).

  Supports both the **KVN** (Keyword=Value Notation) and **XML** formats per
  CCSDS 502.0-B. An OEM carries one or more segments, each a metadata block plus
  a time-ordered list of Cartesian state samples (optionally with acceleration)
  and optional covariance blocks.

  `parse/1` auto-detects the format from the first non-whitespace character: a
  leading `<` is treated as XML, anything else as KVN. Date/time fields are
  preserved as raw strings exactly as written; the message round-trips through
  the canonical struct without calendar rewriting.

  ## Examples

      {:ok, oem} = Sidereon.CCSDS.OEM.parse(kvn_string)
      [segment | _] = oem.segments
      segment.metadata.object_name
      [state | _] = segment.states
      state.position_km            # {x, y, z} in km

      # KVN output (default)
      kvn = Sidereon.CCSDS.OEM.encode(oem)

      # XML output
      xml = Sidereon.CCSDS.OEM.encode(oem, format: :xml)

      # Round-trip through XML
      {:ok, oem2} = Sidereon.CCSDS.OEM.parse(xml)
  """

  alias Sidereon.CCSDS.OEM
  alias Sidereon.NIF

  @typedoc "A Cartesian triple `{x, y, z}`."
  @type vec3 :: {float(), float(), float()}

  @typedoc "Failure reason from the OEM readers."
  @type error :: :missing_field | :invalid_field | :malformed

  defmodule State do
    @moduledoc """
    One Cartesian state sample inside a parsed CCSDS OEM segment.

    `position_km` and `velocity_km_s` are `{x, y, z}` tuples in the segment's
    reference frame. `acceleration_km_s2` is the optional `{x, y, z}`
    acceleration, or `nil` when the message carries no acceleration column.
    """

    @enforce_keys [:epoch, :position_km, :velocity_km_s]
    defstruct [:epoch, :position_km, :velocity_km_s, :acceleration_km_s2]

    @type t :: %__MODULE__{
            epoch: String.t(),
            position_km: OEM.vec3(),
            velocity_km_s: OEM.vec3(),
            acceleration_km_s2: OEM.vec3() | nil
          }
  end

  defmodule Covariance do
    @moduledoc """
    One 6x6 covariance block inside a parsed CCSDS OEM segment.

    `matrix` is a row-major list of six six-element rows. `cov_ref_frame` is the
    optional `COV_REF_FRAME` override, or `nil` to inherit the segment frame.
    """

    @enforce_keys [:epoch, :matrix]
    defstruct [:epoch, :cov_ref_frame, :matrix]

    @type t :: %__MODULE__{
            epoch: String.t(),
            cov_ref_frame: String.t() | nil,
            matrix: [[float()]]
          }
  end

  defmodule Metadata do
    @moduledoc """
    Metadata block for one CCSDS OEM segment.
    """

    @enforce_keys [
      :object_name,
      :object_id,
      :center_name,
      :ref_frame,
      :time_system,
      :start_time,
      :stop_time
    ]
    defstruct [
      :object_name,
      :object_id,
      :center_name,
      :ref_frame,
      :time_system,
      :start_time,
      :stop_time,
      :useable_start_time,
      :useable_stop_time,
      :interpolation,
      :interpolation_degree
    ]

    @type t :: %__MODULE__{
            object_name: String.t(),
            object_id: String.t(),
            center_name: String.t(),
            ref_frame: String.t(),
            time_system: String.t(),
            start_time: String.t(),
            stop_time: String.t(),
            useable_start_time: String.t() | nil,
            useable_stop_time: String.t() | nil,
            interpolation: String.t() | nil,
            interpolation_degree: non_neg_integer() | nil
          }
  end

  defmodule Segment do
    @moduledoc """
    One metadata/data segment of a CCSDS OEM.
    """

    alias Sidereon.CCSDS.OEM.Covariance
    alias Sidereon.CCSDS.OEM.Metadata
    alias Sidereon.CCSDS.OEM.State

    @enforce_keys [:metadata]
    defstruct metadata: nil, states: [], covariances: []

    @type t :: %__MODULE__{
            metadata: Metadata.t(),
            states: [State.t()],
            covariances: [Covariance.t()]
          }
  end

  @enforce_keys [:segments]
  defstruct ccsds_oem_vers: "2.0",
            creation_date: nil,
            originator: nil,
            segments: [],
            skipped_states: 0

  @type t :: %__MODULE__{
          ccsds_oem_vers: String.t(),
          creation_date: String.t() | nil,
          originator: String.t() | nil,
          segments: [Segment.t()],
          skipped_states: non_neg_integer()
        }

  @doc """
  Parse an OEM in either KVN or XML format.

  Format is auto-detected from the first non-whitespace character: `<` routes to
  the XML parser, anything else to the KVN parser.

  Returns `{:ok, %Sidereon.CCSDS.OEM{}}` or `{:error, reason}`.
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
  Parse an OEM in KVN format explicitly. Skips format auto-detection.
  """
  @spec parse_kvn(String.t()) :: {:ok, t()} | {:error, error()}
  def parse_kvn(text) when is_binary(text) do
    text |> NIF.oem_parse_kvn() |> from_fields()
  end

  @doc """
  Parse an OEM in XML format explicitly. Skips format auto-detection.
  """
  @spec parse_xml(String.t()) :: {:ok, t()} | {:error, error()}
  def parse_xml(text) when is_binary(text) do
    text |> NIF.oem_parse_xml() |> from_fields()
  end

  @doc """
  Encode an OEM.

  ## Options
    * `:format` - `:kvn` (default) or `:xml`
  """
  @spec encode(t(), keyword()) :: String.t()
  def encode(oem, opts \\ [])

  def encode(%__MODULE__{} = oem, opts) do
    case Keyword.get(opts, :format, :kvn) do
      :kvn -> encode_kvn(oem)
      :xml -> encode_xml(oem)
      other -> raise ArgumentError, "unsupported OEM format: #{inspect(other)}"
    end
  end

  @doc """
  Encode an OEM to KVN text explicitly.
  """
  @spec encode_kvn(t()) :: String.t()
  def encode_kvn(%__MODULE__{} = oem), do: NIF.oem_encode_kvn(to_fields(oem))

  @doc """
  Encode an OEM to XML text explicitly.
  """
  @spec encode_xml(t()) :: String.t()
  def encode_xml(%__MODULE__{} = oem), do: NIF.oem_encode_xml(to_fields(oem))

  # --- NIF field marshaling ---

  defp from_fields({:ok, fields}) do
    {:ok,
     %__MODULE__{
       ccsds_oem_vers: fields.ccsds_oem_vers,
       creation_date: fields.creation_date,
       originator: fields.originator,
       segments: Enum.map(fields.segments, &segment_from_fields/1),
       skipped_states: fields.skipped_states
     }}
  end

  defp from_fields({:error, reason}), do: {:error, reason}

  defp segment_from_fields(seg) do
    %Segment{
      metadata: metadata_from_fields(seg.metadata),
      states: Enum.map(seg.states, &state_from_fields/1),
      covariances: Enum.map(seg.covariances, &covariance_from_fields/1)
    }
  end

  defp metadata_from_fields(m) do
    %Metadata{
      object_name: m.object_name,
      object_id: m.object_id,
      center_name: m.center_name,
      ref_frame: m.ref_frame,
      time_system: m.time_system,
      start_time: m.start_time,
      stop_time: m.stop_time,
      useable_start_time: m.useable_start_time,
      useable_stop_time: m.useable_stop_time,
      interpolation: m.interpolation,
      interpolation_degree: m.interpolation_degree
    }
  end

  defp state_from_fields(s) do
    %State{
      epoch: s.epoch,
      position_km: s.position_km,
      velocity_km_s: s.velocity_km_s,
      acceleration_km_s2: s.acceleration_km_s2
    }
  end

  defp covariance_from_fields(c) do
    %Covariance{epoch: c.epoch, cov_ref_frame: c.cov_ref_frame, matrix: c.matrix}
  end

  defp to_fields(%__MODULE__{} = oem) do
    %{
      ccsds_oem_vers: oem.ccsds_oem_vers,
      creation_date: oem.creation_date,
      originator: oem.originator,
      segments: Enum.map(oem.segments, &segment_to_fields/1),
      skipped_states: oem.skipped_states
    }
  end

  defp segment_to_fields(%Segment{} = seg) do
    %{
      metadata: metadata_to_fields(seg.metadata),
      states: Enum.map(seg.states, &state_to_fields/1),
      covariances: Enum.map(seg.covariances, &covariance_to_fields/1)
    }
  end

  defp metadata_to_fields(%Metadata{} = m) do
    %{
      object_name: m.object_name,
      object_id: m.object_id,
      center_name: m.center_name,
      ref_frame: m.ref_frame,
      time_system: m.time_system,
      start_time: m.start_time,
      stop_time: m.stop_time,
      useable_start_time: m.useable_start_time,
      useable_stop_time: m.useable_stop_time,
      interpolation: m.interpolation,
      interpolation_degree: m.interpolation_degree
    }
  end

  defp state_to_fields(%State{} = s) do
    %{
      epoch: s.epoch,
      position_km: s.position_km,
      velocity_km_s: s.velocity_km_s,
      acceleration_km_s2: s.acceleration_km_s2
    }
  end

  defp covariance_to_fields(%Covariance{} = c) do
    %{epoch: c.epoch, cov_ref_frame: c.cov_ref_frame, matrix: c.matrix}
  end
end
