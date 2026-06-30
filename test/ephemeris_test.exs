defmodule Sidereon.EphemerisTest do
  use ExUnit.Case

  @eros_kernel Path.join([__DIR__, "fixtures", "spk", "horizons_eros_type21.bsp"])

  describe "Sidereon.Ephemeris.load/1" do
    test "returns error on missing file" do
      assert {:error, {:file_error, :enoent}} =
               Sidereon.Ephemeris.load("/nonexistent/file.bsp")
    end

    test "returns a parse error on a non-SPK buffer" do
      assert {:error, {:parse_error, _reason}} =
               Sidereon.Ephemeris.load_bytes(<<"not a daf kernel">>)
    end

    test "load!/1 raises on missing file" do
      assert_raise ArgumentError, ~r/could not load SPK\/BSP/, fn ->
        Sidereon.Ephemeris.load!("/nonexistent/file.bsp")
      end
    end

    test "load/1 parses the kernel once into a handle" do
      assert {:ok, %Sidereon.Ephemeris{handle: handle}} = Sidereon.Ephemeris.load(@eros_kernel)
      assert is_reference(handle)
    end
  end

  describe "body name resolution" do
    setup do
      {:ok, eph} = Sidereon.Ephemeris.load(@eros_kernel)
      {:ok, eph: eph}
    end

    test "state returns error on invalid body atom", %{eph: eph} do
      assert {:error, {:invalid_body, :not_a_body}} =
               Sidereon.Ephemeris.state(eph, :not_a_body, :sun, 0.0)
    end

    test "position returns error on invalid body atom", %{eph: eph} do
      assert {:error, {:invalid_body, :not_a_body}} =
               Sidereon.Ephemeris.position(eph, :not_a_body, :sun, 2_451_545.0)
    end

    test "position!/4 raises on tagged errors", %{eph: eph} do
      assert_raise ArgumentError, ~r/could not compute ephemeris position/, fn ->
        Sidereon.Ephemeris.position!(eph, :not_a_body, :sun, 2_451_545.0)
      end
    end

    test "state!/4 raises on tagged errors", %{eph: eph} do
      assert_raise ArgumentError, ~r/could not compute ephemeris state/, fn ->
        Sidereon.Ephemeris.state!(eph, :not_a_body, :sun, 0.0)
      end
    end
  end

  describe "segment introspection" do
    setup do
      {:ok, eph} = Sidereon.Ephemeris.load(@eros_kernel)
      {:ok, eph: eph}
    end

    test "segments/1 lists the parsed descriptors", %{eph: eph} do
      segments = Sidereon.Ephemeris.segments(eph)
      assert is_list(segments)
      assert segments != []

      segment = hd(segments)

      assert %{
               name: name,
               target: target,
               center: center,
               frame: frame,
               data_type: data_type,
               start_et: start_et,
               stop_et: stop_et,
               start_address: start_address,
               end_address: end_address
             } = segment

      assert is_binary(name)
      assert is_integer(target)
      assert is_integer(center)
      assert is_integer(frame)
      assert is_integer(data_type)
      assert is_float(start_et)
      assert is_float(stop_et)
      assert is_integer(start_address)
      assert is_integer(end_address)

      # The kernel carries 433 Eros (NAIF 20000433) as a type-21 segment.
      assert Enum.any?(segments, &(&1.target == 20_000_433 and &1.data_type == 21))
    end

    test "internal_name/1 returns the DAF header name", %{eph: eph} do
      assert is_binary(Sidereon.Ephemeris.internal_name(eph))
    end
  end

  # Real type-21 (Extended Modified Difference Arrays) kernel: 433 Eros from JPL
  # Horizons. Reference vectors are CSPICE spkgeo(20000433, et, "J2000", 10).
  # This exercises the consolidated path: the Elixir reader delegates to
  # sidereon_core::astro::spk, which evaluates type 21, something the previous
  # hand-rolled type-2-only reader could not do at all.
  describe "type-21 kernel (433 Eros) via core reader" do
    @j2000_jd 2_451_545.0
    @seconds_per_day 86_400.0

    # {et seconds past J2000 TDB, {x, y, z} km}
    @references [
      {757_339_200.0, {198_083_634.33689928, 56_306_354.00566181, 67_761_020.0290685}},
      {767_879_989.4592, {-62_463_976.26374265, 142_278_295.29334122, 69_496_198.60194506}},
      {785_799_360.0, {-65_781_054.32577276, -197_470_134.64271438, -124_005_727.09542452}}
    ]

    setup do
      {:ok, eph} = Sidereon.Ephemeris.load(@eros_kernel)
      {:ok, eph: eph}
    end

    test "state/4 returns position and velocity matching the CSPICE reference", %{eph: eph} do
      for {et, {ex, ey, ez}} <- @references do
        assert {:ok, state} = Sidereon.Ephemeris.state(eph, 20_000_433, :sun, et)

        assert state.target == 20_000_433
        assert state.center == 10
        assert is_integer(state.frame)

        {x, y, z} = state.position_km
        assert_in_delta x, ex, 1.0e-3
        assert_in_delta y, ey, 1.0e-3
        assert_in_delta z, ez, 1.0e-3

        # Type 21 carries velocity directly, so the query returns it.
        assert {vx, vy, vz} = state.velocity_km_s
        assert is_float(vx) and is_float(vy) and is_float(vz)
      end
    end

    test "position/4 (JD convenience) matches the CSPICE reference", %{eph: eph} do
      for {et, {ex, ey, ez}} <- @references do
        jd_tdb = @j2000_jd + et / @seconds_per_day

        assert {:ok, {x, y, z}} =
                 Sidereon.Ephemeris.position(eph, 20_000_433, :sun, jd_tdb)

        assert_in_delta x, ex, 1.0e-3
        assert_in_delta y, ey, 1.0e-3
        assert_in_delta z, ez, 1.0e-3
      end
    end

    test "unknown body code in the kernel is reported as :unknown_body", %{eph: eph} do
      assert {:error, {:unknown_body, 9999}} =
               Sidereon.Ephemeris.state(eph, 9999, :sun, 0.0)
    end
  end

  # SPK file tests only run when a DE file is available.
  # Run with: mix test --include spk_file
  describe "with DE421 SPK file" do
    @describetag :spk_file

    setup do
      # Look for DE421 in common locations.
      paths = [
        Path.expand("~/.skyfield/de421.bsp"),
        Path.expand("~/de421.bsp"),
        "/tmp/de421.bsp",
        Path.join(File.cwd!(), "de421.bsp")
      ]

      path = Enum.find(paths, &File.exists?/1)

      if path do
        {:ok, eph} = Sidereon.Ephemeris.load(path)
        {:ok, eph: eph}
      else
        {:ok, skip: true}
      end
    end

    test "earth position relative to SSB at J2000", %{} = ctx do
      if Map.get(ctx, :skip) do
        IO.puts("\n  [skipped] DE421 file not found")
      else
        {:ok, {x, y, z}} = Sidereon.Ephemeris.position(ctx.eph, :earth, :ssb, 2_451_545.0)

        # Earth should be roughly 1 AU from SSB (within ~0.02 AU)
        distance_km = :math.sqrt(x * x + y * y + z * z)
        au_km = 149_597_870.7
        assert_in_delta distance_km / au_km, 1.0, 0.02
      end
    end

    test "moon position relative to earth at J2000", %{} = ctx do
      if Map.get(ctx, :skip) do
        IO.puts("\n  [skipped] DE421 file not found")
      else
        {:ok, {x, y, z}} = Sidereon.Ephemeris.position(ctx.eph, :moon, :earth, 2_451_545.0)

        # Moon should be roughly 384,400 km from Earth
        distance_km = :math.sqrt(x * x + y * y + z * z)
        assert_in_delta distance_km, 384_400.0, 20_000.0
      end
    end

    test "sun position relative to earth using DateTime", %{} = ctx do
      if Map.get(ctx, :skip) do
        IO.puts("\n  [skipped] DE421 file not found")
      else
        dt = ~U[2020-06-21 12:00:00Z]
        {:ok, {x, y, z}} = Sidereon.Ephemeris.position(ctx.eph, :sun, :earth, dt)

        # Sun should be roughly 1 AU from Earth
        distance_km = :math.sqrt(x * x + y * y + z * z)
        au_km = 149_597_870.7
        assert_in_delta distance_km / au_km, 1.0, 0.02
      end
    end
  end
end
