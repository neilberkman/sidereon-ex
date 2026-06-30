defmodule Sidereon.GNSS.SP3Test do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.{SP3, Time}

  # Minimal but standards-shaped SP3-c position+clock file with two GPS sats and
  # two epochs (mirrors the astrodynamics-gnss parser fixture). G01 has a clock
  # estimate at both epochs; G02's second epoch is a missing-orbit (all-zero)
  # record.
  @sp3c """
  #cP2020  6 24  0  0  0.00000000       2 ORBIT IGS14 FIT  TST
  ## 2111 432000.00000000   900.00000000 59024 0.0000000000000
  +    2   G01G02  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
  ++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0
  %c G  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc
  %c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc
  %f  1.2500000  1.025000000  0.00000000000  0.000000000000000
  %f  0.0000000  0.000000000  0.00000000000  0.000000000000000
  %i    0    0    0    0      0      0      0      0         0
  %i    0    0    0    0      0      0      0      0         0
  /* TEST SP3-c FIXTURE
  *  2020  6 24  0  0  0.00000000
  PG01  15000.000000 -20000.000000   5000.000000    123.456789
  PG02  -1234.567890   2345.678901  -3456.789012 999999.999999
  *  2020  6 24  0 15  0.00000000
  PG01  15100.000000 -20100.000000   5100.000000   -987.654321
  PG02      0.000000      0.000000      0.000000    100.000000
  EOF
  """

  defp sp3d_velocity_fixture do
    header = [
      "#dV2020  6 24  0  0  0.00000000       1 ORBIT IGS14 FIT  TST",
      "## 2111 432000.00000000   900.00000000 59024 0.0000000000000",
      "+    1   G05  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
      "++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
      "%c M  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%f  1.2500000  1.025000000  0.00000000000  0.000000000000000",
      "%f  0.0000000  0.000000000  0.00000000000  0.000000000000000",
      "%i    0    0    0    0      0      0      0      0         0",
      "%i    0    0    0    0      0      0      0      0         0",
      "/* TEST SP3-d VELOCITY FIXTURE",
      "*  2020  6 24  0  0  0.00000000"
    ]

    records = [
      "PG05" <> fmt(10_000.0) <> fmt(-20_000.0) <> fmt(5_000.0) <> fmt(10.0) <> all_flags(),
      "VG05" <> fmt(10_000.0) <> fmt(-20_000.0) <> fmt(30_000.0) <> fmt(1.0)
    ]

    Enum.join(header ++ records ++ ["EOF", ""], "\n")
  end

  defp fmt(v), do: :io_lib.format(~c"~14.6f", [v]) |> IO.iodata_to_binary()
  defp all_flags, do: String.duplicate(" ", 14) <> "EP  MP"

  describe "parse/1" do
    test "parses an in-memory SP3-c buffer into a handle" do
      assert {:ok, %SP3{} = sp3} = SP3.parse(@sp3c)
      assert is_reference(sp3.handle)
      # Header time scale comes from the %c descriptor (GPS -> GPST).
      assert sp3.time_scale == "GPST"
    end

    test "returns an error tuple on a malformed buffer" do
      assert {:error, _reason} = SP3.parse("not an sp3 file\n")
    end
  end

  describe "load/1 and load!/1" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "sidereon_sp3_test_#{System.unique_integer([:positive])}.sp3"
        )

      File.write!(path, @sp3c)
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "load/1 returns {:ok, handle} for a real file", %{path: path} do
      assert {:ok, %SP3{}} = SP3.load(path)
    end

    test "load/1 returns {:error, _} for a missing path" do
      assert {:error, :enoent} = SP3.load("/no/such/sp3/file.sp3")
    end

    test "load!/1 returns the handle", %{path: path} do
      assert %SP3{} = SP3.load!(path)
    end

    test "load!/1 raises on a missing path" do
      assert_raise ArgumentError, fn -> SP3.load!("/no/such/sp3/file.sp3") end
    end
  end

  describe "position/3" do
    setup do
      {:ok, sp3} = SP3.parse(@sp3c)
      {:ok, sp3: sp3}
    end

    test "evaluates at a node epoch, returning ITRF meters + clock seconds", %{sp3: sp3} do
      # First epoch is a spline node, so the value equals the parsed record,
      # converted km -> m and clock us -> s.
      assert {:ok, state} = SP3.position(sp3, "G01", ~N[2020-06-24 00:00:00])
      assert_in_delta state.x_m, 15_000_000.0, 1.0e-3
      assert_in_delta state.y_m, -20_000_000.0, 1.0e-3
      assert_in_delta state.z_m, 5_000_000.0, 1.0e-3
      assert_in_delta state.clock_s, 123.456789e-6, 1.0e-15
    end

    test "exposes the parsed SP3 node coverage", %{sp3: sp3} do
      {:ok, start_s} = Time.epoch_to_j2000_seconds(~N[2020-06-24 00:00:00])
      {:ok, end_s} = Time.epoch_to_j2000_seconds(~N[2020-06-24 00:15:00])

      assert SP3.coverage(sp3) == %{
               start_j2000_s: start_s / 1.0,
               end_j2000_s: end_s / 1.0,
               time_scale: "GPST"
             }
    end

    test "accepts an erlang datetime tuple", %{sp3: sp3} do
      assert {:ok, state} = SP3.position(sp3, "G01", {{2020, 6, 24}, {0, 0, 0}})
      assert_in_delta state.x_m, 15_000_000.0, 1.0e-3
    end

    test "errors for an unknown satellite", %{sp3: sp3} do
      assert {:error, _reason} = SP3.position(sp3, "G31", ~N[2020-06-24 00:00:00])
    end

    test "errors for a malformed satellite token", %{sp3: sp3} do
      assert {:error, {:bad_sat_id, _}} = SP3.position(sp3, "GXX", ~N[2020-06-24 00:00:00])
    end

    test "rejects out-of-coverage epochs unless extrapolation is explicit", %{sp3: sp3} do
      epoch = ~N[2020-06-24 00:20:00]

      assert {:error, :outside_coverage} = SP3.position(sp3, "G01", epoch)
      assert {:ok, %SP3.State{}} = SP3.position(sp3, "G01", epoch, extrapolate: true)
    end
  end

  describe "exact parsed node accessors" do
    setup do
      {:ok, sp3} = SP3.parse(@sp3c)
      {:ok, sp3: sp3}
    end

    test "exposes the parsed epoch count and J2000 node axis", %{sp3: sp3} do
      {:ok, start_s} = Time.epoch_to_j2000_seconds(~N[2020-06-24 00:00:00])

      assert SP3.epoch_count(sp3) == 2
      assert SP3.epochs_j2000_seconds(sp3) == [start_s / 1.0, start_s / 1.0 + 900.0]
    end

    test "returns an exact parsed state without interpolation", %{sp3: sp3} do
      assert {:ok, state} = SP3.state(sp3, "G02", 0)

      assert %SP3.State{} = state
      assert_in_delta state.x_m, -1_234_567.89, 1.0e-6
      assert_in_delta state.y_m, 2_345_678.901, 1.0e-6
      assert_in_delta state.z_m, -3_456_789.012, 1.0e-6
      assert state.clock_s == nil
      assert state.velocity_m_s == nil
      assert state.clock_rate_s_s == nil
      refute state.clock_event
      refute state.clock_predicted
      refute state.maneuver
      refute state.orbit_predicted
    end

    test "returns all exact records present at one epoch", %{sp3: sp3} do
      assert {:ok, [{"G01", state}]} = SP3.states_at(sp3, 1)
      assert_in_delta state.x_m, 15_100_000.0, 1.0e-6
      assert_in_delta state.clock_s, -987.654321e-6, 1.0e-15
    end

    test "does not fabricate missing SP3 orbit sentinel records", %{sp3: sp3} do
      assert {:error, {:unknown_satellite, "G02"}} = SP3.state(sp3, "G02", 1)
      assert {:error, :epoch_out_of_range} = SP3.state(sp3, "G01", 99)
      assert {:error, :epoch_out_of_range} = SP3.states_at(sp3, 99)
    end

    test "decodes velocity records and SP3 status flags" do
      {:ok, sp3} = SP3.parse(sp3d_velocity_fixture())

      assert SP3.epoch_count(sp3) == 1
      assert {:ok, state} = SP3.state(sp3, "G05", 0)

      assert_in_delta state.x_m, 10_000_000.0, 1.0e-6
      assert_in_delta state.clock_s, 10.0e-6, 1.0e-15
      assert state.velocity_m_s == {1_000.0, -2_000.0, 3_000.0}
      assert state.clock_rate_s_s == 1.0e-10
      assert state.clock_event
      assert state.clock_predicted
      assert state.maneuver
      assert state.orbit_predicted
    end
  end
end
