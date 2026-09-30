defmodule Sidereon.GNSS.Ionosphere.ParseResult do
  @moduledoc """
  A parsed IONEX product together with what the reader reported about the file
  it came from.

  `warnings` is in reader order and holds every finding with all of its fields;
  none is dropped or collapsed into a message alone. An empty list means the
  reader found nothing to report, not that warnings were discarded.

  `skipped_records` counts the records a forgiving parse passed over: a block
  the reader does not support, such as `START OF AUX DATA`, or a header record
  whose field it could not read. A skip is not a warning and is not counted as
  one, so a product with no warnings can still have skipped records. It is the
  same count `Sidereon.GNSS.Ionosphere.skipped_records/1` reads from a handle,
  taken at parse time.
  """

  alias Sidereon.GNSS.Ionosphere.Warning

  @enforce_keys [:handle, :warnings, :skipped_records]
  defstruct [:handle, :warnings, :skipped_records]

  @type t :: %__MODULE__{
          handle: reference(),
          warnings: [Warning.t()],
          skipped_records: non_neg_integer()
        }
end
