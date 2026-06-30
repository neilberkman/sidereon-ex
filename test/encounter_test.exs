defmodule Sidereon.EncounterTest do
  use ExUnit.Case, async: true

  alias Sidereon.Encounter

  describe "frame/4" do
    test "builds a valid frame for head-on collision" do
      r1 = {7000.0, 0.0, 0.0}
      v1 = {0.0, 7.5, 0.0}
      r2 = {7000.1, 0.0, 0.0}
      v2 = {0.0, -7.5, 0.0}

      {:ok, frame} = Encounter.frame(r1, v1, r2, v2)
      assert_in_delta frame.miss_km, 0.1, 1.0e-9
      assert frame.relative_speed_km_s == 15.0
      # dv = v2 - v1 = {0, -15, 0}. y_hat = {0, -1.0, 0}
      assert frame.y_hat == {0.0, -1.0, 0.0}
      # dr = r2 - r1 = {0.1, 0, 0}. dv = {0, -15, 0}
      # dr_ortho = dr - (dr.y)y = {0.1, 0, 0} - 0 = {0.1, 0, 0}. x_hat = {1, 0, 0}
      assert frame.x_hat == {1.0, 0.0, 0.0}
      # z_hat = y_hat x x_hat = {0, -1, 0} x {1, 0, 0} = {0, 0, 1}
      assert frame.z_hat == {0.0, 0.0, 1.0}
    end

    test "handles collision course (parallel dv and dr)" do
      r1 = {7000.0, 0.0, 0.0}
      v1 = {0.0, 7.5, 0.0}
      r2 = {7000.0, 0.0, 0.0}
      v2 = {0.0, -7.5, 0.0}

      {:ok, frame} = Encounter.frame(r1, v1, r2, v2)
      assert frame.miss_km == 0.0
      assert frame.z_hat != {0.0, 0.0, 0.0}
    end

    test "returns error for zero relative velocity" do
      r1 = {7000.0, 0.0, 0.0}
      v1 = {0.0, 7.5, 0.0}
      r2 = {7000.1, 0.0, 0.0}
      v2 = {0.0, 7.5, 0.0}

      assert {:error, "zero relative velocity"} == Encounter.frame(r1, v1, r2, v2)
    end
  end

  describe "encounter_plane_covariance/2" do
    test "projects covariance into 2D plane" do
      r1 = {7000.0, 0.0, 0.0}
      v1 = {0.0, 7.5, 0.0}
      r2 = {7000.1, 0.0, 0.0}
      v2 = {0.0, -7.5, 0.0}

      {:ok, frame} = Encounter.frame(r1, v1, r2, v2)
      # x_hat={1,0,0}, z_hat={0,0,1}
      cov_eci = [
        [1.0, 0.0, 0.0],
        [0.0, 2.0, 0.0],
        [0.0, 0.0, 3.0]
      ]

      c_enc = Encounter.encounter_plane_covariance(frame, cov_eci)
      # R = [[1,0,0], [0,0,1]]
      # C_enc = [[1,0], [0,3]]
      assert c_enc == [
               [1.0, 0.0],
               [0.0, 3.0]
             ]
    end
  end
end
