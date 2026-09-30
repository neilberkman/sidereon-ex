defmodule Sidereon.GNSS.Ionosphere.HeightNode do
  @moduledoc """
  The height-map node that stopped a slant delay from finding one shell height.

  A slant delay needs the single-layer height the product's maps put the pierce
  point on. IONEX 1 gives that height as `HGT1` plus the node's height value, so
  a product whose height maps give no value at a node, or give two different
  values, has no one height to ride on. This names the node the scan stopped at,
  in `[map][latitude][longitude]` order:

    * `{:height_not_available, %HeightNode{}}` - the node holds no height value.
    * `{:varying_heights, %HeightNode{}}` - the node holds a height value
      different from the one every earlier node gave.

  `map_number` counts from 1 as a file numbers its maps; `lat_index` and
  `lon_index` are positions in the node axes, which count from 0.

  A product with no height maps has the single height `HGT1` and reaches neither
  refusal.
  """

  @enforce_keys [:map_number, :lat_index, :lon_index]
  defstruct [:map_number, :lat_index, :lon_index]

  @type t :: %__MODULE__{
          map_number: pos_integer(),
          lat_index: non_neg_integer(),
          lon_index: non_neg_integer()
        }

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end
