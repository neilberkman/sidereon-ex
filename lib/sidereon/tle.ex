defmodule Sidereon.TLE do
  @moduledoc """
  Backwards-compatible delegates for TLE/OMM parsing.

  Prefer `Sidereon.Format.TLE` and `Sidereon.Format.OMM` directly.
  """

  defdelegate parse(line1, line2), to: Sidereon.Format.TLE
  defdelegate from_omm(omm), to: Sidereon.Format.OMM, as: :parse
  defdelegate to_omm(elements), to: Sidereon.Format.OMM, as: :encode
end
