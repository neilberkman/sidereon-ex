defmodule Sidereon.CCSDS.OEM do
  @moduledoc """
  Parse and encode CCSDS Orbit Ephemeris Messages (OEM).

  Supports both the **KVN** (Keyword=Value Notation) and **XML** formats per
  CCSDS 502.0-B. An OEM carries one or more segments, each a metadata block plus
  a time-ordered list of Cartesian state samples (optionally with acceleration)
  and optional covariance blocks. The header, metadata and every comment are
  kept: header and metadata comments in their blocks, and the comments among
  the state lines and covariance matrices at their positions, which the writers
  restore.

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
      {:ok, kvn} = Sidereon.CCSDS.OEM.encode(oem)

      # XML output
      {:ok, xml} = Sidereon.CCSDS.OEM.encode(oem, format: :xml)

      # Round-trip through XML
      {:ok, oem2} = Sidereon.CCSDS.OEM.parse(xml)
  """

  alias Sidereon.CCSDS.Error
  alias Sidereon.CCSDS.OEM
  alias Sidereon.NIF

  @typedoc "A Cartesian triple `{x, y, z}`."
  @type vec3 :: {float(), float(), float()}

  @typedoc """
  Failure reason from the OEM readers and writers, with every field the core
  refusal carries (`t:Sidereon.CCSDS.Error.oem/0`): a missing or invalid field, a
  malformed value, a keyword repeated with a different value, a unit that
  contradicts the standard's table, a document holding several messages, a
  keyword the standard does not define at its position, a KVN line that is not
  blank, a comment or an assignment, text a writer cannot write so that its
  reader returns it unchanged, or (writers only) fields that do not form a
  message, such as a covariance without exactly 21 lower-triangle values.
  """
  @type error :: Error.oem()

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
    One 6x6 covariance block inside a parsed CCSDS OEM segment, held exactly as
    read.

    `lower_triangle` holds the 21 lower-triangle values in keyword order `CX_X`,
    `CY_X`, `CY_Y` ... `CZ_DOT_Z_DOT`, row by row. No definiteness check is
    applied, so a matrix printed to a few digits that falls short of positive
    semidefinite only through that rounding is read. `cov_ref_frame` is the
    optional `COV_REF_FRAME` override, or `nil` to inherit the segment frame.
    `to_matrix/1` expands the values to six symmetric rows.
    """

    @enforce_keys [:epoch, :lower_triangle]
    defstruct [:epoch, :cov_ref_frame, :lower_triangle]

    @type t :: %__MODULE__{
            epoch: String.t(),
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

  defmodule Comment do
    @moduledoc """
    A comment among a segment's state lines or covariance matrices.

    `position` is the number of items of its list that precede the comment:
    state lines for `Segment.data_comments`, covariance matrices for
    `Segment.covariance_comments`.
    """

    @enforce_keys [:position, :text]
    defstruct [:position, :text]

    @type t :: %__MODULE__{position: non_neg_integer(), text: String.t()}
  end

  defmodule SkippedState do
    @moduledoc """
    A KVN ephemeris data line the reader skipped: its one-based `line` number,
    the zero-based index of the `segment` whose data holds it, its `text` with
    surrounding whitespace removed, and the `reason`: `{:item_count, n}` for a
    line holding other than 7 or 10 items, or `{:invalid_field, item, kind}` for
    a numeric item that failed validation, with `item` the item's name as an
    atom and `kind` a `t:Sidereon.CCSDS.Error.input_kind/0`.
    """

    @enforce_keys [:line, :segment, :text, :reason]
    defstruct [:line, :segment, :text, :reason]

    @type t :: %__MODULE__{
            line: pos_integer(),
            segment: non_neg_integer(),
            text: String.t(),
            reason: Error.oem_state_line()
          }
  end

  defmodule Metadata do
    @moduledoc """
    Metadata block for one CCSDS OEM segment. `comments` are the comments after
    `META_START`; `ref_frame_epoch` is the `REF_FRAME_EPOCH` text, kept as
    written.
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
      :interpolation_degree,
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
    One metadata/data segment of a CCSDS OEM, with the comments among its state
    lines and covariance matrices at their positions.
    """

    alias Sidereon.CCSDS.OEM.Comment
    alias Sidereon.CCSDS.OEM.Covariance
    alias Sidereon.CCSDS.OEM.Metadata
    alias Sidereon.CCSDS.OEM.State

    @enforce_keys [:metadata]
    defstruct metadata: nil, data_comments: [], states: [], covariance_comments: [], covariances: []

    @type t :: %__MODULE__{
            metadata: Metadata.t(),
            data_comments: [Comment.t()],
            states: [State.t()],
            covariance_comments: [Comment.t()],
            covariances: [Covariance.t()]
          }
  end

  @enforce_keys [:segments]
  defstruct ccsds_oem_vers: "2.0",
            comments: [],
            classification: nil,
            creation_date: nil,
            originator: nil,
            message_id: nil,
            segments: [],
            skipped_states: []

  @typedoc """
  A CCSDS OEM. `comments` are the header comments. `skipped_states` lists the
  KVN ephemeris data lines the reader skipped; the writers do not write them.
  """
  @type t :: %__MODULE__{
          ccsds_oem_vers: String.t(),
          comments: [String.t()],
          classification: String.t() | nil,
          creation_date: String.t() | nil,
          originator: String.t() | nil,
          message_id: String.t() | nil,
          segments: [Segment.t()],
          skipped_states: [SkippedState.t()]
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

  Returns `{:ok, text}`, or `{:error, reason}` for a message the writer cannot
  write so that its reader returns it unchanged (see `t:error/0`).

  ## Options
    * `:format` - `:kvn` (default) or `:xml`
  """
  @spec encode(t(), keyword()) :: {:ok, String.t()} | {:error, error()}
  def encode(oem, opts \\ [])

  def encode(%__MODULE__{} = oem, opts) do
    case Keyword.get(opts, :format, :kvn) do
      :kvn -> encode_kvn(oem)
      :xml -> encode_xml(oem)
      other -> raise ArgumentError, "unsupported OEM format: #{inspect(other)}"
    end
  end

  @doc """
  Encode an OEM to KVN text explicitly. Returns `{:ok, text}` or
  `{:error, reason}`.
  """
  @spec encode_kvn(t()) :: {:ok, String.t()} | {:error, error()}
  def encode_kvn(%__MODULE__{} = oem), do: NIF.oem_encode_kvn(to_fields(oem))

  @doc """
  Encode an OEM to XML text explicitly. Returns `{:ok, text}` or
  `{:error, reason}`.
  """
  @spec encode_xml(t()) :: {:ok, String.t()} | {:error, error()}
  def encode_xml(%__MODULE__{} = oem), do: NIF.oem_encode_xml(to_fields(oem))

  # --- NIF field marshaling ---

  defp from_fields({:ok, fields}) do
    {:ok,
     %__MODULE__{
       ccsds_oem_vers: fields.ccsds_oem_vers,
       comments: fields.comments,
       classification: fields.classification,
       creation_date: fields.creation_date,
       originator: fields.originator,
       message_id: fields.message_id,
       segments: Enum.map(fields.segments, &segment_from_fields/1),
       skipped_states: Enum.map(fields.skipped_states, &struct(SkippedState, &1))
     }}
  end

  defp from_fields({:error, reason}), do: {:error, reason}

  defp segment_from_fields(seg) do
    %Segment{
      metadata: struct(Metadata, seg.metadata),
      data_comments: Enum.map(seg.data_comments, &struct(Comment, &1)),
      states: Enum.map(seg.states, &struct(State, &1)),
      covariance_comments: Enum.map(seg.covariance_comments, &struct(Comment, &1)),
      covariances: Enum.map(seg.covariances, &struct(Covariance, &1))
    }
  end

  defp to_fields(%__MODULE__{} = oem) do
    %{
      ccsds_oem_vers: oem.ccsds_oem_vers,
      comments: oem.comments,
      classification: oem.classification,
      creation_date: oem.creation_date,
      originator: oem.originator,
      message_id: oem.message_id,
      segments: Enum.map(oem.segments, &segment_to_fields/1)
    }
  end

  defp segment_to_fields(%Segment{} = seg) do
    %{
      metadata: Map.from_struct(seg.metadata),
      data_comments: Enum.map(seg.data_comments, &Map.from_struct/1),
      states: Enum.map(seg.states, &Map.from_struct/1),
      covariance_comments: Enum.map(seg.covariance_comments, &Map.from_struct/1),
      covariances: Enum.map(seg.covariances, &Map.from_struct/1)
    }
  end
end
