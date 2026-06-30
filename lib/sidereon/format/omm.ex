defmodule Sidereon.Format.OMM do
  @moduledoc """
  Parse and encode CCSDS Orbit Mean-Elements Messages (OMM).

  OMM is the modern standard format for orbital data, carrying the same
  elements as TLE plus metadata such as originator, reference frame, time
  system, and mean-element theory. CelesTrak and Space-Track distribute OMM
  messages as KVN, XML, and JSON.

  `parse_kvn/1`, `parse_xml/1`, `parse_json/1`, and string `parse/1` return a
  typed `%Sidereon.Format.OMM{}` that preserves the OMM metadata and
  microsecond epoch fields. The legacy decoded-map `parse/1` clause is kept for
  CelesTrak JSON maps and returns `%Sidereon.Elements{}`.
  """

  alias Sidereon.Elements
  alias Sidereon.NIF

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
            microsecond: integer()
          }

    defstruct [:year, :month, :day, :hour, :minute, :second, :microsecond]
  end

  @type t :: %__MODULE__{
          ccsds_omm_vers: String.t(),
          creation_date: String.t() | nil,
          originator: String.t() | nil,
          object_name: String.t() | nil,
          object_id: String.t() | nil,
          center_name: String.t() | nil,
          ref_frame: String.t() | nil,
          time_system: String.t() | nil,
          mean_element_theory: String.t() | nil,
          epoch: Epoch.t(),
          mean_motion: float(),
          eccentricity: float(),
          inclination_deg: float(),
          ra_of_asc_node_deg: float(),
          arg_of_pericenter_deg: float(),
          mean_anomaly_deg: float(),
          ephemeris_type: integer(),
          classification_type: String.t(),
          norad_cat_id: integer(),
          element_set_no: integer(),
          rev_at_epoch: integer(),
          bstar: float(),
          mean_motion_dot: float(),
          mean_motion_ddot: float()
        }

  defstruct ccsds_omm_vers: "2.0",
            creation_date: nil,
            originator: nil,
            object_name: nil,
            object_id: nil,
            center_name: nil,
            ref_frame: nil,
            time_system: nil,
            mean_element_theory: nil,
            epoch: nil,
            mean_motion: nil,
            eccentricity: nil,
            inclination_deg: nil,
            ra_of_asc_node_deg: nil,
            arg_of_pericenter_deg: nil,
            mean_anomaly_deg: nil,
            ephemeris_type: 0,
            classification_type: "U",
            norad_cat_id: nil,
            element_set_no: 999,
            rev_at_epoch: 0,
            bstar: 0.0,
            mean_motion_dot: 0.0,
            mean_motion_ddot: 0.0

  @type parse_error ::
          {:missing_field, String.t()}
          | {:invalid_field, String.t(), term()}

  @type encode_error ::
          {:missing_field, atom()}
          | {:invalid_field, atom(), term()}
          | String.t()

  @doc """
  Parse an OMM from text or from a decoded JSON map.

  For binary input, the text format is auto-detected: a leading `<` selects XML,
  a leading `{` or `[` selects JSON, and all other input is parsed as KVN. Text
  parsing returns `{:ok, %Sidereon.Format.OMM{}}` or `{:error, reason}`.

  For map input, accepts decoded CelesTrak/Space-Track OMM JSON maps with field
  names such as `"NORAD_CAT_ID"`, `"INCLINATION"`, and `"MEAN_MOTION"`. This
  legacy path returns `{:ok, %Sidereon.Elements{}}` and handles both numeric and
  string values for numeric fields.

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
      ...>   "MEAN_MOTION" => 15.5
      ...> })
      iex> el.catalog_number
      "25544"
      iex> el.object_name
      "ISS (ZARYA)"

  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
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
         {:ok, ndot} <- to_float_field(omm, "MEAN_MOTION_DOT"),
         {:ok, nddot} <- to_float_field(omm, "MEAN_MOTION_DDOT"),
         {:ok, bstar} <- to_float_field(omm, "BSTAR"),
         {:ok, inclination_deg} <- required_float_field(omm, "INCLINATION"),
         {:ok, raan_deg} <- required_float_field(omm, "RA_OF_ASC_NODE"),
         {:ok, eccentricity} <- required_float_field(omm, "ECCENTRICITY"),
         {:ok, arg_perigee_deg} <- required_float_field(omm, "ARG_OF_PERICENTER"),
         {:ok, mean_anomaly_deg} <- required_float_field(omm, "MEAN_ANOMALY"),
         {:ok, mean_motion} <- required_float_field(omm, "MEAN_MOTION") do
      {:ok,
       %Elements{
         object_name: omm["OBJECT_NAME"],
         catalog_number: to_string(omm["NORAD_CAT_ID"]),
         classification: omm["CLASSIFICATION_TYPE"] || "U",
         international_designator: omm["OBJECT_ID"] || "",
         epoch: epoch,
         mean_motion_dot: ndot,
         mean_motion_double_dot: nddot,
         bstar: bstar,
         ephemeris_type: omm["EPHEMERIS_TYPE"] || 0,
         elset_number: omm["ELEMENT_SET_NO"] || 999,
         inclination_deg: inclination_deg,
         raan_deg: raan_deg,
         eccentricity: eccentricity,
         arg_perigee_deg: arg_perigee_deg,
         mean_anomaly_deg: mean_anomaly_deg,
         mean_motion: mean_motion,
         rev_number: omm["REV_AT_EPOCH"] || 0
       }}
    end
  end

  @doc """
  Parse CCSDS OMM KVN text into a typed OMM struct.

  Returns `{:ok, %Sidereon.Format.OMM{}}` or `{:error, reason}`.
  """
  @spec parse_kvn(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_kvn(text) when is_binary(text) do
    text |> NIF.omm_parse_kvn() |> from_nif_fields()
  end

  @doc """
  Parse CCSDS OMM XML text into a typed OMM struct.

  Returns `{:ok, %Sidereon.Format.OMM{}}` or `{:error, reason}`.
  """
  @spec parse_xml(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_xml(text) when is_binary(text) do
    text |> NIF.omm_parse_xml() |> from_nif_fields()
  end

  @doc """
  Parse CCSDS/CelesTrak OMM JSON text into a typed OMM struct.

  JSON input may be a single OMM object or an array of OMM objects; the core
  parser follows CelesTrak convention and selects the first array item.

  Returns `{:ok, %Sidereon.Format.OMM{}}` or `{:error, reason}`.
  """
  @spec parse_json(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse_json(text) when is_binary(text) do
    text |> NIF.omm_parse_json() |> from_nif_fields()
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

  OMM-specific metadata remains available on the original OMM struct; the
  returned `%Sidereon.Elements{}` carries the TLE-compatible mean elements.

  Returns `{:ok, elements}` or `{:error, reason}`.
  """
  @spec to_elements(t()) :: {:ok, Elements.t()} | {:error, encode_error()}
  def to_elements(%__MODULE__{} = omm) do
    with {:ok, epoch} <- epoch_to_datetime(omm.epoch) do
      {:ok,
       %Elements{
         object_name: omm.object_name,
         catalog_number: Integer.to_string(omm.norad_cat_id),
         classification: omm.classification_type || "U",
         international_designator: omm.object_id || "",
         epoch: epoch,
         mean_motion_dot: omm.mean_motion_dot,
         mean_motion_double_dot: omm.mean_motion_ddot,
         bstar: omm.bstar,
         ephemeris_type: omm.ephemeris_type,
         elset_number: omm.element_set_no,
         inclination_deg: omm.inclination_deg,
         raan_deg: omm.ra_of_asc_node_deg,
         eccentricity: omm.eccentricity,
         arg_perigee_deg: omm.arg_of_pericenter_deg,
         mean_anomaly_deg: omm.mean_anomaly_deg,
         mean_motion: omm.mean_motion,
         rev_number: omm.rev_at_epoch
       }}
    end
  end

  # -- Text parse/encode helpers --

  defp from_nif_fields({:ok, fields}) do
    {:ok,
     %__MODULE__{
       ccsds_omm_vers: fields.ccsds_omm_vers,
       creation_date: fields.creation_date,
       originator: fields.originator,
       object_name: fields.object_name,
       object_id: fields.object_id,
       center_name: fields.center_name,
       ref_frame: fields.ref_frame,
       time_system: fields.time_system,
       mean_element_theory: fields.mean_element_theory,
       epoch: build_epoch(fields.epoch),
       mean_motion: fields.mean_motion,
       eccentricity: fields.eccentricity,
       inclination_deg: fields.inclination_deg,
       ra_of_asc_node_deg: fields.ra_of_asc_node_deg,
       arg_of_pericenter_deg: fields.arg_of_pericenter_deg,
       mean_anomaly_deg: fields.mean_anomaly_deg,
       ephemeris_type: fields.ephemeris_type,
       classification_type: fields.classification_type,
       norad_cat_id: fields.norad_cat_id,
       element_set_no: fields.element_set_no,
       rev_at_epoch: fields.rev_at_epoch,
       bstar: fields.bstar,
       mean_motion_dot: fields.mean_motion_dot,
       mean_motion_ddot: fields.mean_motion_ddot
     }}
  end

  defp from_nif_fields({:error, reason}), do: {:error, reason}

  defp build_epoch(fields) do
    %Epoch{
      year: fields.year,
      month: fields.month,
      day: fields.day,
      hour: fields.hour,
      minute: fields.minute,
      second: fields.second,
      microsecond: fields.microsecond
    }
  end

  defp encode_with_nif(%__MODULE__{} = omm, fun) do
    with {:ok, fields} <- to_nif_fields(omm) do
      fun.(fields)
    end
  rescue
    e in ErlangError -> {:error, Exception.message(e)}
  end

  defp to_nif_fields(%__MODULE__{} = omm) do
    with {:ok, epoch} <- epoch_fields(omm.epoch),
         {:ok, ccsds_omm_vers} <- required_string(omm, :ccsds_omm_vers),
         {:ok, classification_type} <- required_string(omm, :classification_type),
         {:ok, mean_motion} <- required_float(omm, :mean_motion),
         {:ok, eccentricity} <- required_float(omm, :eccentricity),
         {:ok, inclination_deg} <- required_float(omm, :inclination_deg),
         {:ok, ra_of_asc_node_deg} <- required_float(omm, :ra_of_asc_node_deg),
         {:ok, arg_of_pericenter_deg} <- required_float(omm, :arg_of_pericenter_deg),
         {:ok, mean_anomaly_deg} <- required_float(omm, :mean_anomaly_deg),
         {:ok, bstar} <- required_float(omm, :bstar),
         {:ok, mean_motion_dot} <- required_float(omm, :mean_motion_dot),
         {:ok, mean_motion_ddot} <- required_float(omm, :mean_motion_ddot),
         {:ok, ephemeris_type} <- required_integer(omm, :ephemeris_type),
         {:ok, norad_cat_id} <- required_integer(omm, :norad_cat_id),
         {:ok, element_set_no} <- required_integer(omm, :element_set_no),
         {:ok, rev_at_epoch} <- required_integer(omm, :rev_at_epoch),
         {:ok, creation_date} <- optional_string(omm, :creation_date),
         {:ok, originator} <- optional_string(omm, :originator),
         {:ok, object_name} <- optional_string(omm, :object_name),
         {:ok, object_id} <- optional_string(omm, :object_id),
         {:ok, center_name} <- optional_string(omm, :center_name),
         {:ok, ref_frame} <- optional_string(omm, :ref_frame),
         {:ok, time_system} <- optional_string(omm, :time_system),
         {:ok, mean_element_theory} <- optional_string(omm, :mean_element_theory) do
      {:ok,
       %{
         ccsds_omm_vers: ccsds_omm_vers,
         creation_date: creation_date,
         originator: originator,
         object_name: object_name,
         object_id: object_id,
         center_name: center_name,
         ref_frame: ref_frame,
         time_system: time_system,
         mean_element_theory: mean_element_theory,
         epoch: epoch,
         mean_motion: mean_motion,
         eccentricity: eccentricity,
         inclination_deg: inclination_deg,
         ra_of_asc_node_deg: ra_of_asc_node_deg,
         arg_of_pericenter_deg: arg_of_pericenter_deg,
         mean_anomaly_deg: mean_anomaly_deg,
         ephemeris_type: ephemeris_type,
         classification_type: classification_type,
         norad_cat_id: norad_cat_id,
         element_set_no: element_set_no,
         rev_at_epoch: rev_at_epoch,
         bstar: bstar,
         mean_motion_dot: mean_motion_dot,
         mean_motion_ddot: mean_motion_ddot
       }}
    end
  end

  defp epoch_fields(%Epoch{} = epoch) do
    fields = [:year, :month, :day, :hour, :minute, :second, :microsecond]

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

  defp to_float_field(omm, key) do
    case omm[key] do
      nil -> {:ok, 0.0}
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

  defp required_string(struct, field) do
    case Map.fetch!(struct, field) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, {:missing_field, field}}
      value -> {:error, {:invalid_field, field, value}}
    end
  end

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

  defp required_integer(struct, field) do
    case Map.fetch!(struct, field) do
      value when is_integer(value) -> {:ok, value}
      nil -> {:error, {:missing_field, field}}
      value -> {:error, {:invalid_field, field, value}}
    end
  end
end
