defmodule Sidereon.Screening.Candidate do
  @moduledoc """
  A prefiltered conjunction candidate from catalog screening.
  """

  @type t :: %__MODULE__{
          i: non_neg_integer(),
          j: non_neg_integer(),
          id1: String.t() | nil,
          id2: String.t() | nil,
          miss_km: float() | nil,
          tca: DateTime.t() | nil
        }

  defstruct [
    :i,
    :j,
    :id1,
    :id2,
    :miss_km,
    :tca
  ]
end
