defmodule Sidereon.SunMoonErrorRegressionTest do
  use ExUnit.Case, async: true

  @valid_epoch_us DateTime.to_unix(~U[2026-05-13 00:00:00Z], :microsecond)

  test "public Sun/Moon batch helpers preserve native errors and successful pairs" do
    assert {:error, "empty epochs"} = Sidereon.sun_moon_eci([])
    assert {:error, "empty epochs"} = Sidereon.sun_moon_ecef([])

    # 1970 predates the embedded UT1 coverage. The native error tuple must not
    # be reinterpreted as a successful {sun, moon} pair.
    assert {:error, :invalid_input} = Sidereon.sun_moon_ecef([0])

    assert {:ok, %{sun: [sun], moon: [moon]}} =
             Sidereon.sun_moon_ecef([@valid_epoch_us])

    assert tuple_size(sun) == 3
    assert tuple_size(moon) == 3
  end
end
