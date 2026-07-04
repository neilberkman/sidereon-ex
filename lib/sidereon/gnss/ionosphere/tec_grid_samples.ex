defmodule Sidereon.GNSS.Ionosphere.TecGridSamples do
  @moduledoc """
  Whole-grid IONEX vertical-TEC samples.

  Map epochs are split Julian dates with time-scale tags. Latitude and longitude
  axes are degrees, shell and base radii are kilometers, and TEC/RMS grids are
  TECU with indexing `[map][latitude][longitude]`.
  """

  alias Sidereon.GNSS.Ionosphere.TecSample

  @enforce_keys [
    :map_epochs,
    :lat_nodes_deg,
    :lon_nodes_deg,
    :dlat_deg,
    :dlon_deg,
    :shell_height_km,
    :base_radius_km,
    :exponent,
    :tec_maps,
    :rms_maps
  ]
  defstruct [
    :map_epochs,
    :lat_nodes_deg,
    :lon_nodes_deg,
    :dlat_deg,
    :dlon_deg,
    :shell_height_km,
    :base_radius_km,
    :exponent,
    :tec_maps,
    :rms_maps
  ]

  @typedoc "Epoch as `%{time_scale:, jd_whole:, jd_fraction:}`."
  @type epoch :: TecSample.epoch()

  @type t :: %__MODULE__{
          map_epochs: [epoch()],
          lat_nodes_deg: [float()],
          lon_nodes_deg: [float()],
          dlat_deg: float(),
          dlon_deg: float(),
          shell_height_km: float(),
          base_radius_km: float(),
          exponent: integer(),
          tec_maps: [[[float()]]],
          rms_maps: [[[float()]]]
        }

  @doc false
  @spec to_nif_map(t()) :: {:ok, map()} | {:error, term()}
  def to_nif_map(%__MODULE__{} = samples) do
    with {:ok, epochs} <- epochs(samples.map_epochs) do
      {:ok,
       %{
         map_epochs: epochs,
         lat_nodes_deg: floats(samples.lat_nodes_deg),
         lon_nodes_deg: floats(samples.lon_nodes_deg),
         dlat_deg: samples.dlat_deg / 1.0,
         dlon_deg: samples.dlon_deg / 1.0,
         shell_height_km: samples.shell_height_km / 1.0,
         base_radius_km: samples.base_radius_km / 1.0,
         exponent: samples.exponent,
         tec_maps: maps(samples.tec_maps),
         rms_maps: maps(samples.rms_maps)
       }}
    end
  rescue
    _ -> {:error, :bad_tec_grid_samples}
  end

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields) do
    fields = Map.update!(fields, :map_epochs, &Enum.map(&1, fn epoch -> epoch(epoch) end))
    struct!(__MODULE__, fields)
  end

  defp epochs(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      %{time_scale: time_scale, jd_whole: jd_whole, jd_fraction: jd_fraction}, {:ok, acc}
      when is_binary(time_scale) and is_number(jd_whole) and is_number(jd_fraction) ->
        {:cont, {:ok, [{time_scale, jd_whole / 1.0, jd_fraction / 1.0} | acc]}}

      {time_scale, jd_whole, jd_fraction}, {:ok, acc}
      when is_binary(time_scale) and is_number(jd_whole) and is_number(jd_fraction) ->
        {:cont, {:ok, [{time_scale, jd_whole / 1.0, jd_fraction / 1.0} | acc]}}

      _value, _acc ->
        {:halt, {:error, :bad_epoch}}
    end)
    |> case do
      {:ok, epochs} -> {:ok, Enum.reverse(epochs)}
      {:error, _} = err -> err
    end
  end

  defp epochs(_values), do: {:error, :bad_epoch}

  defp epoch({time_scale, jd_whole, jd_fraction}) do
    %{time_scale: time_scale, jd_whole: jd_whole, jd_fraction: jd_fraction}
  end

  defp epoch(%{time_scale: _time_scale, jd_whole: _jd_whole, jd_fraction: _jd_fraction} = epoch), do: epoch

  defp floats(values) when is_list(values), do: Enum.map(values, &(&1 / 1.0))
  defp maps(values) when is_list(values), do: Enum.map(values, &maps/1)
  defp maps(value) when is_number(value), do: value / 1.0
end
