defmodule Sidereon.AnglesErrorContractTest do
  use ExUnit.Case, async: true

  alias Sidereon.Angles

  test "direct angle helpers expose their documented invalid-input result" do
    zero = {0.0, 0.0, 0.0}
    axis = {1.0, 0.0, 0.0}

    assert {:error, :invalid_input} = Angles.sun_angle(zero, axis)
    assert {:error, :invalid_input} = Angles.moon_angle(zero, axis)
    assert {:error, :invalid_input} = Angles.angular_separation(zero, axis)

    assert {:error, :invalid_input} = Sidereon.sun_angle(zero, axis)
    assert {:error, :invalid_input} = Sidereon.moon_angle(zero, axis)
  end
end
