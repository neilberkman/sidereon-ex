defmodule Sidereon.GNSS.RINEX.Observations.LeapSeconds do
  @moduledoc """
  The `LEAP SECONDS` header record of an observation file.

  `current` is the current leap-second count. `delta_future`, `week` and `day`
  are `nil` where the record leaves the field blank; a blank field before a
  written one keeps its place when the record is written back.

  `time_system` is the identifier in columns 25 to 27 exactly as written, or
  `nil` where the field is blank. A blank field and an explicit `"GPS"` are
  different statements and are both kept. RINEX 3.03 introduced `"BDS"` and
  `"GPS"`, RINEX 3.05 renamed `"BDS"` to `"BDT"`, and RINEX 4 permits only
  `"GPS"`; the writers refuse an identifier the target version does not
  support rather than rewriting it.
  """

  @enforce_keys [:current, :delta_future, :week, :day, :time_system]
  defstruct [:current, :delta_future, :week, :day, :time_system]

  @type t :: %__MODULE__{
          current: integer(),
          delta_future: integer() | nil,
          week: integer() | nil,
          day: integer() | nil,
          time_system: String.t() | nil
        }

  @doc false
  @spec from_nif_map(map()) :: t()
  def from_nif_map(fields) when is_map(fields), do: struct!(__MODULE__, fields)
end
