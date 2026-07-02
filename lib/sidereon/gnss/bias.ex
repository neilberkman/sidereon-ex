defmodule Sidereon.GNSS.Bias do
  @moduledoc """
  DCB and OSB bias products backed by the core bias parsers.
  """

  alias Sidereon.GNSS.Time
  alias Sidereon.NIF

  defmodule Set do
    @moduledoc """
    Parsed DCB or OSB bias product.
    """
    @enforce_keys [:handle]
    defstruct [:handle, :info]
    @type t :: %__MODULE__{handle: reference(), info: map() | nil}
  end

  defmodule Record do
    @moduledoc """
    One bias record decoded from a DCB or OSB product.
    """
    @enforce_keys [:kind, :target, :obs1, :value, :is_phase]
    defstruct [
      :kind,
      :target,
      :svn,
      :obs1,
      :obs2,
      :valid_from,
      :valid_until,
      :value,
      :sigma,
      :slope,
      :slope_sigma,
      :is_phase
    ]
  end

  def load_bias_sinex(path), do: load_resource(:bias_load_sinex, [path])
  def load_bias_sinex_lossy(path), do: load_lossy(:bias_load_sinex_lossy, [path])
  def parse_bias_sinex(bytes), do: load_resource(:bias_parse_sinex, [bytes])
  def parse_bias_sinex_lossy(bytes), do: load_lossy(:bias_parse_sinex_lossy, [bytes])

  def load_code_dcb(path, opts \\ []), do: load_resource(:bias_load_code_dcb, [path, dcb_options(opts)])
  def load_code_dcb_lossy(path, opts \\ []), do: load_lossy(:bias_load_code_dcb_lossy, [path, dcb_options(opts)])
  def parse_code_dcb(bytes, opts \\ []), do: load_resource(:bias_parse_code_dcb, [bytes, dcb_options(opts)])
  def parse_code_dcb_lossy(bytes, opts \\ []), do: load_lossy(:bias_parse_code_dcb_lossy, [bytes, dcb_options(opts)])

  def info(%Set{handle: handle}) do
    fields = NIF.bias_info(handle)

    %{
      records: fields.records,
      skipped_records: fields.skipped_records,
      mode: mode_atom(fields.mode),
      time_scale: fields.time_scale
    }
  end

  def records(%Set{handle: handle}) do
    handle
    |> NIF.bias_records()
    |> Enum.map(&record/1)
  end

  def code_osb(%Set{handle: handle}, satellite_id, obs, epoch, scale \\ "GPST") do
    with {:ok, epoch_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      NIF.bias_code_osb(handle, satellite_id, obs, epoch_s, scale_name(scale))
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def code_dsb(%Set{handle: handle}, satellite_id, obs1, obs2, epoch, scale \\ "GPST") do
    with {:ok, epoch_s} <- Time.epoch_to_j2000_seconds_fractional(epoch) do
      NIF.bias_code_dsb(handle, satellite_id, obs1, obs2, epoch_s, scale_name(scale))
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  def load_bias_sinex!(path), do: bang(load_bias_sinex(path))
  def parse_bias_sinex!(bytes), do: bang(parse_bias_sinex(bytes))
  def load_code_dcb!(path, opts \\ []), do: bang(load_code_dcb(path, opts))
  def parse_code_dcb!(bytes, opts \\ []), do: bang(parse_code_dcb(bytes, opts))

  def code_osb!(set, satellite_id, obs, epoch, scale \\ "GPST"),
    do: bang(code_osb(set, satellite_id, obs, epoch, scale))

  def code_dsb!(set, satellite_id, obs1, obs2, epoch, scale \\ "GPST"),
    do: bang(code_dsb(set, satellite_id, obs1, obs2, epoch, scale))

  defp load_resource(fun, args) do
    case apply(NIF, fun, args) do
      handle when is_reference(handle) ->
        set = %Set{handle: handle}
        {:ok, %{set | info: info(set)}}

      {:error, _} = err ->
        err

      other ->
        {:error, other}
    end
  rescue
    e in ErlangError -> {:error, Map.get(e, :original, e)}
    e in ArgumentError -> {:error, e.message}
  end

  defp load_lossy(fun, args) do
    case apply(NIF, fun, args) do
      {:ok, handle, skipped} ->
        set = %Set{handle: handle}
        {:ok, %{set | info: info(set)}, %{skipped_records: skipped}}

      {:error, _} = err ->
        err

      other ->
        {:error, other}
    end
  rescue
    e in ErlangError -> {:error, Map.get(e, :original, e)}
    e in ArgumentError -> {:error, e.message}
  end

  defp dcb_options(opts) do
    if opts != [] do
      {obs1, obs2} = Keyword.get(opts, :pair, {"C1C", "C2W"})

      %{
        obs1: obs1,
        obs2: obs2,
        year: Keyword.fetch!(opts, :year),
        month: Keyword.fetch!(opts, :month),
        time_scale: scale_name(Keyword.get(opts, :time_scale, "GPST")),
        receiver_system: system_letter(Keyword.get(opts, :receiver_system))
      }
    end
  end

  defp record(fields) do
    %Record{
      kind: kind_atom(fields.kind),
      target: fields.target,
      svn: fields.svn,
      obs1: fields.obs1,
      obs2: fields.obs2,
      valid_from: fields.valid_from,
      valid_until: fields.valid_until,
      value: fields.value,
      sigma: fields.sigma,
      slope: fields.slope,
      slope_sigma: fields.slope_sigma,
      is_phase: fields.is_phase
    }
  end

  defp bang({:ok, value}), do: value
  defp bang({:ok, value, _diagnostics}), do: value
  defp bang({:error, reason}), do: raise(ArgumentError, "bias operation failed: #{inspect(reason)}")

  defp kind_atom("osb"), do: :osb
  defp kind_atom("dsb"), do: :dsb
  defp kind_atom("isb"), do: :isb
  defp kind_atom(other), do: other

  defp mode_atom("absolute"), do: :absolute
  defp mode_atom("relative"), do: :relative
  defp mode_atom("mixed"), do: :mixed
  defp mode_atom(other), do: other

  defp scale_name(scale) when is_atom(scale), do: scale |> Atom.to_string() |> String.upcase()
  defp scale_name(scale) when is_binary(scale), do: String.upcase(scale)

  defp system_letter(nil), do: nil
  defp system_letter(:gps), do: "G"
  defp system_letter(:glonass), do: "R"
  defp system_letter(:galileo), do: "E"
  defp system_letter(:beidou), do: "C"
  defp system_letter(:qzss), do: "J"
  defp system_letter(:navic), do: "I"
  defp system_letter(:sbas), do: "S"
  defp system_letter(value) when is_binary(value), do: value
end
