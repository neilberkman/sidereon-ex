defmodule Sidereon.Astro.RelativeErrorContractTest do
  use ExUnit.Case, async: true

  alias Sidereon.Astro.Relative

  @error_message "relative-frame calculation failed: :invalid_input"

  test "direct relative helpers return flat errors and bang helpers raise" do
    zero = %Relative.State{
      epoch_tdb_seconds: 0.0,
      position_km: {0.0, 0.0, 0.0},
      velocity_km_s: {0.0, 1.0, 0.0}
    }

    calls = [
      {fn -> Relative.rotation(:rsw, zero) end, fn -> Relative.rotation!(:rsw, zero) end},
      {fn -> Relative.cw_stm(0.0, 1.0) end, fn -> Relative.cw_stm!(0.0, 1.0) end},
      {fn -> Relative.mean_motion_circular(0.0) end, fn -> Relative.mean_motion_circular!(0.0) end},
      {fn -> Relative.mean_motion_from_state(zero) end, fn -> Relative.mean_motion_from_state!(zero) end}
    ]

    for {call, bang_call} <- calls do
      assert {:error, :invalid_input} = call.()
      assert_raise ArgumentError, @error_message, bang_call
    end
  end
end
