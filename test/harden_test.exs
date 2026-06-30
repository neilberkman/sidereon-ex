defmodule Sidereon.HardenTest do
  use ExUnit.Case, async: true

  alias Sidereon.CCSDS.CDM
  alias Sidereon.Collision
  alias Sidereon.Covariance

  describe "Collision covariance validation" do
    test "rejects non-3x3 matrices" do
      params = %{
        r1: {7000, 0, 0},
        v1: {0, 7.5, 0},
        cov1: [[1, 0], [0, 1]],
        r2: {7000.1, 0, 0},
        v2: {0, -7.5, 0},
        cov2: [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
        hard_body_radius_km: 0.015
      }

      assert {:error, "cov1 is not a 3x3 numeric matrix"} == Collision.probability(params)
    end

    test "rejects non-numeric matrices without crashing" do
      params = %{
        r1: {7000, 0, 0},
        v1: {0, 7.5, 0},
        cov1: [["x", "x", "x"], ["x", "x", "x"], ["x", "x", "x"]],
        r2: {7000.1, 0, 0},
        v2: {0, -7.5, 0},
        cov2: [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
        hard_body_radius_km: 0.015
      }

      assert {:error, "cov1 is not a 3x3 numeric matrix"} == Collision.probability(params)
    end

    test "rejects non-PSD matrices" do
      # Indefinite matrix: eigenvalues are 3, -1, 1. Not PSD.
      indefinite = [[1.0, 2.0, 0.0], [2.0, 1.0, 0.0], [0.0, 0.0, 1.0]]

      params = %{
        r1: {7000, 0, 0},
        v1: {0, 7.5, 0},
        cov1: indefinite,
        r2: {7000.1, 0, 0},
        v2: {0, -7.5, 0},
        cov2: [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
        hard_body_radius_km: 0.015
      }

      assert {:error, "cov1 is not positive semidefinite"} == Collision.probability(params)
    end
  end

  describe "CDM datetime offset parsing" do
    test "correctly handles +05:00 offset" do
      # Minimal but complete CDM (the core requires the full state vector and the
      # six RTN covariance components per object); enough to test parse_datetime.
      kvn = """
      TCA = 2024-01-01T12:00:00.000+05:00
      CREATION_DATE = 2024-01-01T10:00:00.000Z
      MESSAGE_ID = TEST
      OBJECT = OBJECT1
      X = 7000.0
      Y = 0.0
      Z = 0.0
      X_DOT = 0.0
      Y_DOT = 7.5
      Z_DOT = 0.0
      CR_R = 1.0
      CT_R = 0.0
      CT_T = 1.0
      CN_R = 0.0
      CN_T = 0.0
      CN_N = 1.0
      OBJECT = OBJECT2
      X = 7000.1
      Y = 0.0
      Z = 0.0
      X_DOT = 0.0
      Y_DOT = -7.5
      Z_DOT = 0.0
      CR_R = 1.0
      CT_R = 0.0
      CT_T = 1.0
      CN_R = 0.0
      CN_T = 0.0
      CN_N = 1.0
      """

      {:ok, cdm} = CDM.parse(kvn)
      # 12:00 +05:00 is 07:00 UTC
      assert cdm.tca == ~U[2024-01-01 07:00:00.000Z]
    end
  end

  describe "Covariance PSD check" do
    test "returns false for indefinite matrix [[1,2,0],[2,1,0],[0,0,1]]" do
      m = [[1.0, 2.0, 0.0], [2.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
      refute Covariance.positive_semidefinite?(m)
    end

    test "returns true for identity" do
      assert Covariance.positive_semidefinite?([
               [1.0, 0.0, 0.0],
               [0.0, 1.0, 0.0],
               [0.0, 0.0, 1.0]
             ])
    end

    test "returns true for a real covariance-like PSD matrix" do
      # Case where det=0 but still PSD
      m = [[1.0, 1.0, 0.0], [1.0, 1.0, 0.0], [0.0, 0.0, 1.0]]
      assert Covariance.positive_semidefinite?(m)
    end
  end

  describe "Covariance.rtn_to_eci validation" do
    test "rejects malformed matrices" do
      r = {7000, 0, 0}
      v = {0, 7.5, 0}
      assert {:error, _} = Covariance.rtn_to_eci([[1.0]], r, v)
    end

    test "rejects non-numeric matrices" do
      r = {7000, 0, 0}
      v = {0, 7.5, 0}

      assert {:error, _} =
               Covariance.rtn_to_eci([["x", "x", "x"], ["x", "x", "x"], ["x", "x", "x"]], r, v)
    end
  end
end
