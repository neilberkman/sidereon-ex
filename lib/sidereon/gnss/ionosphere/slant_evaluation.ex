defmodule Sidereon.GNSS.Ionosphere.SlantEvaluation do
  @moduledoc """
  An IONEX slant ionospheric group delay with the status of the value.

  `delay_m` is a group delay in positive meters: it increases the measured
  pseudorange. The carrier-phase advance is its negation. `status` is a
  `Sidereon.GNSS.Ionosphere.SlantStatus`, which names anything the value rests
  on beyond the product's stated grid.
  """

  alias Sidereon.GNSS.Ionosphere.SlantStatus

  @enforce_keys [:delay_m, :status]
  defstruct [:delay_m, :status]

  @type t :: %__MODULE__{delay_m: float(), status: SlantStatus.t()}

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(%{delay_m: delay_m, status: status}) do
    %__MODULE__{delay_m: delay_m, status: SlantStatus.from_nif_map(status)}
  end
end
