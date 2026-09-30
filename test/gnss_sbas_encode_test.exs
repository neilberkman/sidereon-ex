defmodule Sidereon.GNSS.SBASEncodeTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.SBAS

  test "strict raw encoding reports an unrecognized preamble with typed fields" do
    assert {:error, {:sbas_encode_error, %{variant: "unrecognized_preamble", preamble: 0}}} =
             SBAS.encode_unsupported(63, 0, :binary.copy(<<0>>, 27))
  end
end
