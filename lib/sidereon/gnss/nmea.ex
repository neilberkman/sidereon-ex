defmodule Sidereon.GNSS.NMEA do
  @moduledoc """
  NMEA 0183 parsing, epoch accumulation, and GGA writing.
  """

  alias Sidereon.NIF

  defmodule Sentence do
    @moduledoc """
    One decoded NMEA sentence.
    """
    @enforce_keys [:talker, :kind, :body, :diagnostics]
    defstruct [:talker, :system, :kind, :body, :diagnostics]

    @type t :: %__MODULE__{
            talker: String.t(),
            system: String.t() | nil,
            kind: atom(),
            body: map(),
            diagnostics: map()
          }
  end

  defmodule Snapshot do
    @moduledoc """
    One accumulated NMEA epoch snapshot.
    """
    defstruct [
      :time_of_day,
      :date,
      :gga,
      :rmc,
      :gll,
      :gst,
      :vtg,
      :zda,
      :gsa,
      :gsv,
      :sentence_count,
      :diagnostics,
      :position_geodetic,
      :pdop,
      :hdop,
      :vdop,
      :used_satellites,
      :satellites_in_view
    ]

    @type t :: %__MODULE__{}
  end

  defmodule Accumulator do
    @moduledoc """
    Resource-backed incremental NMEA accumulator.
    """
    @enforce_keys [:handle]
    defstruct [:handle]

    @type t :: %__MODULE__{handle: reference()}
  end

  @doc """
  Parse one NMEA sentence.
  """
  @spec parse_sentence(String.t()) :: {:ok, %{sentence: Sentence.t(), diagnostics: map()}} | {:error, term()}
  def parse_sentence(line) when is_binary(line) do
    with {:ok, result} <- NIF.nmea_parse_sentence(line) do
      {:ok, %{sentence: decode_sentence(result.sentence, result.diagnostics), diagnostics: result.diagnostics}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Forgiving parse of a text buffer into supported NMEA sentences.
  """
  @spec parse(String.t()) :: {:ok, %{sentences: [Sentence.t()], diagnostics: map()}} | {:error, term()}
  def parse(text) when is_binary(text) do
    with {:ok, result} <- NIF.nmea_parse(text) do
      {:ok, %{sentences: decode_sentences(result.sentences), diagnostics: result.diagnostics}}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Parse a text buffer and group decoded sentences into epochs.
  """
  @spec group_epochs(String.t()) :: {:ok, %{sentences: [Sentence.t()], epochs: [Snapshot.t()], diagnostics: map()}}
  def group_epochs(text) when is_binary(text) do
    with {:ok, result} <- NIF.nmea_group_epochs(text) do
      {:ok,
       %{
         sentences: decode_sentences(result.sentences),
         epochs: Enum.map(result.epochs, &decode_snapshot/1),
         diagnostics: result.diagnostics
       }}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Create an incremental accumulator for chunked NMEA streams.
  """
  @spec accumulator(keyword()) :: {:ok, Accumulator.t()} | {:error, term()}
  def accumulator(opts \\ []) do
    date = accumulator_date(Keyword.get(opts, :date))
    max_sentences = Keyword.get(opts, :max_sentences_per_epoch, 0)

    case NIF.nmea_accumulator_new(date, max_sentences) do
      {:ok, handle} -> {:ok, %Accumulator{handle: handle}}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Push bytes into an accumulator.
  """
  @spec push(Accumulator.t(), binary()) ::
          {:ok, %{sentences: [Sentence.t()], snapshots: [Snapshot.t()], diagnostics: map()}} | {:error, term()}
  def push(%Accumulator{handle: handle}, bytes) when is_binary(bytes) do
    case NIF.nmea_accumulator_push(handle, bytes) do
      {:ok, output} ->
        {:ok,
         %{
           sentences: decode_sentences(output.sentences),
           snapshots: Enum.map(output.snapshots, &decode_snapshot/1),
           diagnostics: output.diagnostics
         }}

      {:error, _reason} = err ->
        err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Finish an accumulator and return the trailing epoch, if any.
  """
  @spec finish(Accumulator.t()) :: {:ok, Snapshot.t() | nil} | {:error, term()}
  def finish(%Accumulator{handle: handle}) do
    case NIF.nmea_accumulator_finish(handle) do
      {:ok, nil} -> {:ok, nil}
      {:ok, snapshot} -> {:ok, decode_snapshot(snapshot)}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Number of retained partial-line bytes in an accumulator.
  """
  @spec retained_len(Accumulator.t()) :: non_neg_integer()
  def retained_len(%Accumulator{handle: handle}) do
    NIF.nmea_accumulator_retained_len(handle)
  end

  @doc """
  Write a GGA sentence from validated GGA fields.
  """
  @spec write_gga(keyword() | map()) :: {:ok, String.t()} | {:error, term()}
  def write_gga(fields) when is_list(fields) or is_map(fields) do
    case NIF.nmea_write_gga(gga_term(fields)) do
      {:ok, sentence} -> {:ok, sentence}
      {:error, _reason} = err -> err
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp decode_sentences(sentences), do: Enum.map(sentences, &decode_sentence(&1, %{}))

  defp decode_sentence(raw, diagnostics) do
    %Sentence{
      talker: raw.talker,
      system: raw.system,
      kind: kind_atom(raw.kind),
      body: sentence_body(raw),
      diagnostics: diagnostics
    }
  end

  defp sentence_body(%{kind: "gga", gga: body}), do: body
  defp sentence_body(%{kind: "rmc", rmc: body}), do: body
  defp sentence_body(%{kind: "gsa", gsa: body}), do: body
  defp sentence_body(%{kind: "gsv", gsv: body}), do: body
  defp sentence_body(%{kind: "gst", gst: body}), do: body
  defp sentence_body(%{kind: "vtg", vtg: body}), do: body
  defp sentence_body(%{kind: "gll", gll: body}), do: body
  defp sentence_body(%{kind: "zda", zda: body}), do: body

  defp decode_snapshot(raw) do
    struct(Snapshot, %{
      time_of_day: raw.time_of_day,
      date: raw.date,
      gga: raw.gga,
      rmc: raw.rmc,
      gll: raw.gll,
      gst: raw.gst,
      vtg: raw.vtg,
      zda: raw.zda,
      gsa: raw.gsa,
      gsv: raw.gsv,
      sentence_count: raw.sentence_count,
      diagnostics: raw.diagnostics,
      position_geodetic: raw.position_geodetic,
      pdop: raw.pdop,
      hdop: raw.hdop,
      vdop: raw.vdop,
      used_satellites: raw.used_satellites,
      satellites_in_view: raw.satellites_in_view
    })
  end

  defp kind_atom("gga"), do: :gga
  defp kind_atom("rmc"), do: :rmc
  defp kind_atom("gsa"), do: :gsa
  defp kind_atom("gsv"), do: :gsv
  defp kind_atom("gst"), do: :gst
  defp kind_atom("vtg"), do: :vtg
  defp kind_atom("gll"), do: :gll
  defp kind_atom("zda"), do: :zda

  defp accumulator_date(nil), do: nil
  defp accumulator_date(%Date{} = date), do: {date.year, date.month, date.day}
  defp accumulator_date({year, month, day}), do: {year, month, day}

  defp gga_term(fields) do
    %{
      talker: get_field(fields, :talker, "GP"),
      time_seconds_of_day: get_field(fields, :time_seconds_of_day, nil),
      latitude_deg: get_field(fields, :latitude_deg, nil),
      longitude_deg: get_field(fields, :longitude_deg, nil),
      coordinate_decimals: get_field(fields, :coordinate_decimals, 4),
      quality: quality(get_field(fields, :quality, nil)),
      satellites_used: get_field(fields, :satellites_used, nil),
      hdop: get_field(fields, :hdop, nil),
      altitude_msl_m: get_field(fields, :altitude_msl_m, nil),
      geoid_separation_m: get_field(fields, :geoid_separation_m, nil),
      differential_age_s: get_field(fields, :differential_age_s, nil),
      differential_station_id: get_field(fields, :differential_station_id, nil)
    }
  end

  defp get_field(fields, key, default) when is_list(fields), do: Keyword.get(fields, key, default)
  defp get_field(fields, key, default) when is_map(fields), do: Map.get(fields, key, default)

  defp quality(nil), do: nil
  defp quality(value) when is_integer(value), do: value
  defp quality(:invalid), do: 0
  defp quality(:gps_sps), do: 1
  defp quality(:differential), do: 2
  defp quality(:pps), do: 3
  defp quality(:rtk_fixed), do: 4
  defp quality(:rtk_float), do: 5
  defp quality(:estimated), do: 6
  defp quality(:manual), do: 7
  defp quality(:simulator), do: 8
end
