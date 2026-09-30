defmodule Sidereon.GNSS.Ionosphere.TecGridSamples do
  @moduledoc """
  Whole-grid IONEX vertical-TEC samples.

  This is the intermediate representation an IONEX product is built from and
  read back as, with no text in the loop:
  `from_samples/1` followed by `tec_grid_samples/1` reproduces every stored
  float and epoch.

  `map_epochs` are `Sidereon.GNSS.Ionosphere.Epoch` values, strictly increasing.
  The node axes are degrees and run in the direction their signed step gives.
  Shell height and base radius are kilometers. TEC and RMS grids are TECU and
  height grids are kilometers, each indexed `[map][latitude][longitude]`.

  ## Absence

    * A node without a value is `nil`; a node holding `0.0` has a value of zero.
    * `rms_maps` or `height_maps` is `nil` where the product carries no such
      maps at all. That is not the same as maps present with every node
      non-available, which is a list of the same shape as `tec_maps` filled with
      `nil`.

  RMS and height maps both hold that distinction, through the handle, the writer
  and a reparse: a stack present with every node `nil` is written out with every
  node at the file's missing value and read back as a stack, where `nil` writes
  no such records at all.

  This whole-grid form is the only one that can state it.
  `Sidereon.GNSS.Ionosphere.from_node_samples/5` builds from flat node samples,
  which carry no map-presence field: samples whose `rms_tecu` is `nil` at every
  node give a product with no RMS maps, because nothing in that input says the
  maps are declared. Build such a product from these samples instead.

  ## What is refused

    * `{:invalid_grid_field, field, value}` - a field whose value is not of the
      field's type, with the value that is not.
    * `{:value_out_of_range, field, value}` - a number past the range the
      boundary carries that field in, with the value that is past it. An axis
      entry, a step, a radius and a node value are each past it when they are an
      integer larger in magnitude than the largest finite double, which has no
      double to be read onto; `EXPONENT` is past it outside the signed 32-bit
      range it crosses in.
    * the epoch refusals of `Sidereon.GNSS.Ionosphere.Epoch`.
  """

  alias Sidereon.GNSS.Ionosphere.Epoch
  alias Sidereon.GNSS.Ionosphere.Header
  alias Sidereon.GNSS.Ionosphere.Numeric

  @enforce_keys [
    :map_epochs,
    :lat_nodes_deg,
    :lon_nodes_deg,
    :dlat_deg,
    :dlon_deg,
    :shell_height_km,
    :base_radius_km,
    :exponent,
    :tec_maps
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
    :rms_maps,
    :height_maps,
    header: %Header{}
  ]

  @type grid :: [[[float() | nil]]]

  @type t :: %__MODULE__{
          map_epochs: [Epoch.t()],
          lat_nodes_deg: [float()],
          lon_nodes_deg: [float()],
          dlat_deg: float(),
          dlon_deg: float(),
          shell_height_km: float(),
          base_radius_km: float(),
          exponent: integer(),
          tec_maps: grid(),
          rms_maps: grid() | nil,
          height_maps: grid() | nil,
          header: Header.t()
        }

  @doc false
  @spec to_nif_map(t()) :: {:ok, map()} | {:error, term()}
  def to_nif_map(%__MODULE__{} = samples) do
    with {:ok, map_epochs} <- epochs(samples.map_epochs),
         {:ok, header} <- Header.to_nif_map(samples.header || %Header{}),
         {:ok, lat_nodes_deg} <- axis(samples.lat_nodes_deg, :lat_nodes_deg),
         {:ok, lon_nodes_deg} <- axis(samples.lon_nodes_deg, :lon_nodes_deg),
         {:ok, dlat_deg} <- scalar(samples.dlat_deg, :dlat_deg),
         {:ok, dlon_deg} <- scalar(samples.dlon_deg, :dlon_deg),
         {:ok, shell_height_km} <- scalar(samples.shell_height_km, :shell_height_km),
         {:ok, base_radius_km} <- scalar(samples.base_radius_km, :base_radius_km),
         {:ok, exponent} <- integer(samples.exponent, :exponent),
         {:ok, tec_maps} <- maps(samples.tec_maps, :tec_maps),
         {:ok, rms_maps} <- optional_maps(samples.rms_maps, :rms_maps),
         {:ok, height_maps} <- optional_maps(samples.height_maps, :height_maps) do
      {:ok,
       %{
         map_epochs: map_epochs,
         lat_nodes_deg: lat_nodes_deg,
         lon_nodes_deg: lon_nodes_deg,
         dlat_deg: dlat_deg,
         dlon_deg: dlon_deg,
         shell_height_km: shell_height_km,
         base_radius_km: base_radius_km,
         exponent: exponent,
         tec_maps: tec_maps,
         rms_maps: rms_maps,
         height_maps: height_maps,
         header: header
       }}
    end
  end

  def to_nif_map(_other), do: {:error, :bad_tec_grid_samples}

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields) do
    fields
    |> Map.update!(:map_epochs, fn epochs -> Enum.map(epochs, &Epoch.from_nif_term/1) end)
    |> Map.update!(:header, &Header.from_nif_map/1)
    |> then(&struct!(__MODULE__, &1))
  end

  defp epochs(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case Epoch.to_nif_term(value) do
        {:ok, term} -> {:cont, {:ok, [term | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, terms} -> {:ok, Enum.reverse(terms)}
      {:error, _reason} = error -> error
    end
  end

  defp epochs(_values), do: {:error, :bad_epoch}

  # An axis entry that is not a number names the axis and the whole list it sits
  # in, as it always has; one no double holds names the axis and that entry,
  # because the entry is what is past the range.
  defp axis(values, field) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case Numeric.float(value) do
        {:ok, float} -> {:cont, {:ok, [float | acc]}}
        {:out_of_range, value} -> {:halt, {:error, {:value_out_of_range, field, value}}}
        :not_a_number -> {:halt, {:error, {:invalid_grid_field, field, values}}}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, _reason} = error -> error
    end
  end

  defp axis(values, field), do: {:error, {:invalid_grid_field, field, values}}

  defp scalar(value, field) do
    case Numeric.float(value) do
      {:ok, float} -> {:ok, float}
      {:out_of_range, value} -> {:error, {:value_out_of_range, field, value}}
      :not_a_number -> {:error, {:invalid_grid_field, field, value}}
    end
  end

  # `EXPONENT` crosses as an `i32`; a value outside that range is named here
  # rather than reaching the boundary as an opaque decode error.
  defp integer(value, field) do
    cond do
      Numeric.i32?(value) -> {:ok, value}
      is_integer(value) -> {:error, {:value_out_of_range, field, value}}
      true -> {:error, {:invalid_grid_field, field, value}}
    end
  end

  # `nil` and `[]` both say the product carries no such maps. A list of maps
  # whose nodes are all `nil` says the maps are present and every node is
  # non-available, and is passed through as such.
  defp optional_maps(nil, _field), do: {:ok, nil}
  defp optional_maps([], _field), do: {:ok, nil}
  defp optional_maps(value, field), do: maps(value, field)

  defp maps(value, field) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn map, {:ok, acc} ->
      case rows(map, field) do
        {:ok, rows} -> {:cont, {:ok, [rows | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, _reason} = error -> error
    end
  end

  defp maps(value, field), do: {:error, {:invalid_grid_field, field, value}}

  defp rows(map, field) when is_list(map) do
    Enum.reduce_while(map, {:ok, []}, fn row, {:ok, acc} ->
      case nodes(row, field) do
        {:ok, nodes} -> {:cont, {:ok, [nodes | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, _reason} = error -> error
    end
  end

  defp rows(map, field), do: {:error, {:invalid_grid_field, field, map}}

  defp nodes(row, field) when is_list(row) do
    Enum.reduce_while(row, {:ok, []}, fn
      nil, {:ok, acc} ->
        {:cont, {:ok, [nil | acc]}}

      value, {:ok, acc} ->
        case Numeric.float(value) do
          {:ok, float} -> {:cont, {:ok, [float | acc]}}
          {:out_of_range, value} -> {:halt, {:error, {:value_out_of_range, field, value}}}
          :not_a_number -> {:halt, {:error, {:invalid_grid_field, field, value}}}
        end
    end)
    |> case do
      {:ok, converted} -> {:ok, Enum.reverse(converted)}
      {:error, _reason} = error -> error
    end
  end

  defp nodes(row, field), do: {:error, {:invalid_grid_field, field, row}}
end
