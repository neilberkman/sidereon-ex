defmodule Sidereon.GNSS.RINEX.Observations.ScaleFactor do
  @moduledoc """
  One `SYS / SCALE FACTOR` header record.

  `factor` is what the stored observations were divided by; the values the
  observation accessors return are already physical. An empty `codes` list
  means every code of the system.
  """

  @enforce_keys [:system, :factor, :codes]
  defstruct [:system, :factor, :codes]

  @type t :: %__MODULE__{system: String.t(), factor: float(), codes: [String.t()]}

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end
