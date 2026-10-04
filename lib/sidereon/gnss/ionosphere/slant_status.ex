defmodule Sidereon.GNSS.Ionosphere.SlantStatus do
  @moduledoc """
  What a slant-delay value rests on beyond the product's stated grid.

  The three fields are independent and can all be set on one value:

    * `held` - the coverage miss a `:hold` coverage policy held the value
      through: `:epoch_before_first_map`, `:epoch_after_last_map`,
      `:latitude_out_of_range` or `:longitude_out_of_range`. `nil` inside
      coverage.

    * `degraded` - a `Sidereon.GNSS.Ionosphere.NodeGap` naming every
      non-available node a `:renormalize` missing-node policy interpolated
      around. `nil` where every weighted node held a value.

    * `assumed_mapping` - what the product declares, where the single-layer
      factor mapped a product declaring anything but `COSZ`: `:no_mapping`,
      `:q_factor`, `:absent`, or `{:other, code}` carrying the declared code's
      own text. `nil` where the product declares `COSZ`, which is the factor
      applied.

  `valid?` is true when the value was neither held through a coverage miss nor
  degraded by a non-available node. An assumed mapping does not clear it: most
  published global products declare something other than `COSZ`, so a nominal
  result from the CODE, ESA, JPL or UPC grids would otherwise read as invalid.
  A caller that cares which factor was applied reads `assumed_mapping`.
  """

  alias Sidereon.GNSS.Ionosphere.NodeGap

  @enforce_keys [:valid?]
  defstruct [:held, :degraded, :assumed_mapping, :valid?]

  @type coverage_error ::
          :epoch_before_first_map
          | :epoch_after_last_map
          | :latitude_out_of_range
          | :longitude_out_of_range

  @type assumed_mapping :: :no_mapping | :q_factor | :absent | {:other, String.t() | nil}

  @type t :: %__MODULE__{
          held: coverage_error() | nil,
          degraded: NodeGap.t() | nil,
          assumed_mapping: assumed_mapping() | nil,
          valid?: boolean()
        }

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(%{held: held, degraded: degraded, assumed_mapping: assumed_mapping, valid: valid}) do
    %__MODULE__{
      held: held,
      degraded: if(degraded, do: NodeGap.from_nif_map(degraded)),
      assumed_mapping: assumed_mapping,
      valid?: valid
    }
  end
end
