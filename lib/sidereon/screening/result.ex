defmodule Sidereon.Screening.Result do
  @moduledoc """
  Final result for a screened candidate pair.
  """

  @type t :: %__MODULE__{
          candidate: Sidereon.Screening.Candidate.t(),
          collision: Sidereon.Collision.Result.t() | nil,
          error: String.t() | nil
        }

  defstruct [
    :candidate,
    :collision,
    :error
  ]
end
