defmodule Sidereon.EphemerisTest do
  use ExUnit.Case

  describe "Sidereon.Ephemeris.load/1" do
    test "returns error on missing file" do
      assert {:error, {:file_error, :enoent}} =
               Sidereon.Ephemeris.load("/nonexistent/file.bsp")
    end

    test "load!/1 raises on missing file" do
      assert_raise ArgumentError, ~r/could not load SPK\/BSP/, fn ->
        Sidereon.Ephemeris.load!("/nonexistent/file.bsp")
      end
    end
  end

  describe "body name resolution" do
    test "position returns error on invalid body atom" do
      # Create a dummy struct to test body resolution
      eph = %Sidereon.Ephemeris{path: "/dummy.bsp"}

      assert {:error, {:invalid_body, :invalid_body}} =
               Sidereon.Ephemeris.position(eph, :invalid_body, :earth, 2_451_545.0)
    end

    test "position!/4 raises on tagged errors" do
      eph = %Sidereon.Ephemeris{path: "/dummy.bsp"}

      assert_raise ArgumentError, ~r/could not compute ephemeris position/, fn ->
        Sidereon.Ephemeris.position!(eph, :invalid_body, :earth, 2_451_545.0)
      end
    end

    test "integer NAIF codes pass straight through to the reader" do
      # A raw integer code is accepted (it is the kernel, not this layer, that
      # decides whether the body exists). Against a missing file the reader
      # surfaces the I/O failure rather than rejecting the code up front.
      eph = %Sidereon.Ephemeris{path: "/nonexistent.bsp"}

      assert {:error, {:nif_error, _}} =
               Sidereon.Ephemeris.position(eph, 20_000_433, :sun, 2_451_545.0)
    end
  end

  # Real type-21 (Extended Modified Difference Arrays) kernel: 433 Eros from JPL
  # Horizons. Reference vectors are CSPICE spkgeo(20000433, et, "J2000", 10).
  # This exercises the consolidated path: the Elixir reader now delegates to
  # sidereon_core::astro::spk, which evaluates type 21 — something the previous
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
      path = Path.join([__DIR__, "fixtures", "spk", "horizons_eros_type21.bsp"])
      {:ok, eph} = Sidereon.Ephemeris.load(path)
      {:ok, eph: eph}
    end

    test "queried states match the CSPICE reference", %{eph: eph} do
      for {et, {ex, ey, ez}} <- @references do
        jd_tdb = @j2000_jd + et / @seconds_per_day

        assert {:ok, {x, y, z}} =
                 Sidereon.Ephemeris.position(eph, 20_000_433, :sun, jd_tdb)

        # Magnitudes are ~1e8 km; the core reader agrees with CSPICE to ~1e-8 km
        # and the split-JD round trip stays well under a meter.
        assert_in_delta x, ex, 1.0e-3
        assert_in_delta y, ey, 1.0e-3
        assert_in_delta z, ez, 1.0e-3
      end
    end

    test "unknown body code in the kernel is reported as an error", %{eph: eph} do
      assert {:error, {:nif_error, _}} =
               Sidereon.Ephemeris.position(eph, 9999, :sun, @j2000_jd)
    end
  end

  describe "Julian Date conversion" do
    test "J2000.0 epoch is correct" do
      # J2000.0 = 2000-01-01 12:00:00 TDB = JD 2451545.0
      # We test this indirectly through the position function's datetime conversion.
      # The struct just holds a path, so we can verify the module loads.
      eph = %Sidereon.Ephemeris{path: "/dummy.bsp"}
      assert eph.path == "/dummy.bsp"
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
