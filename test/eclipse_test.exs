defmodule Sidereon.EclipseTest do
  use ExUnit.Case, async: true

  alias Sidereon.Format.TLE

  # ISS TLE (epoch 2024-12-19)
  @iss_line1 "1 25544U 98067A   24354.52609954  .00020888  00000+0  37042-3 0  9992"
  @iss_line2 "2 25544  51.6393 213.2584 0006955  37.7614  87.9783 15.49970085486016"

  # Approximate Sun-Earth distance: ~1 AU in km
  @au_km 149_597_870.7

  describe "status/2" do
    test "satellite on the sunlit side returns :sunlit" do
      # Place satellite between Earth and Sun (sunward side).
      # Sun along +X axis, satellite at +X.
      sun_pos = {@au_km, 0.0, 0.0}
      sat_pos = {7000.0, 0.0, 0.0}

      assert Sidereon.Eclipse.status(sat_pos, sun_pos) == :sunlit
    end

    test "satellite off to the side returns :sunlit" do
      # Satellite perpendicular to the Earth-Sun line, well away from shadow.
      sun_pos = {@au_km, 0.0, 0.0}
      sat_pos = {0.0, 7000.0, 0.0}

      assert Sidereon.Eclipse.status(sat_pos, sun_pos) == :sunlit
    end

    test "satellite directly behind Earth returns :umbra" do
      # Sun along +X. Satellite on the -X side, right on the shadow axis.
      sun_pos = {@au_km, 0.0, 0.0}
      # Place satellite behind Earth, close to the axis (inside the umbra cone).
      # At ~7000 km behind Earth, umbra radius is still ~6300+ km, so a
      # satellite on the axis (rho = 0) is deep in umbra.
      sat_pos = {-7000.0, 0.0, 0.0}

      assert Sidereon.Eclipse.status(sat_pos, sun_pos) == :umbra
    end

    test "satellite behind Earth but offset to the edge returns :penumbra" do
      # Sun along +X. Satellite behind Earth, at the boundary region between
      # umbra and penumbra.
      sun_pos = {@au_km, 0.0, 0.0}
      # At 7000 km behind Earth:
      #   alpha_umbra ~ asin((696340 - 6371) / 149597870.7) ~ 0.00461 rad
      #   r_umbra ~ 6371 - 7000 * tan(0.00461) ~ 6371 - 32.3 ~ 6338.7 km
      #   alpha_penumbra ~ asin((696340 + 6371) / 149597870.7) ~ 0.00470 rad
      #   r_penumbra ~ 6371 + 7000 * tan(0.00470) ~ 6371 + 32.9 ~ 6403.9 km
      # Place satellite at a perpendicular distance between r_umbra and r_penumbra.
      sat_pos = {-7000.0, 6370.0, 0.0}

      assert Sidereon.Eclipse.status(sat_pos, sun_pos) == :penumbra
    end
  end

  describe "shadow_fraction/2" do
    test "returns 0.0 for satellite on the sunlit side" do
      sun_pos = {@au_km, 0.0, 0.0}
      sat_pos = {7000.0, 0.0, 0.0}

      assert Sidereon.Eclipse.shadow_fraction(sat_pos, sun_pos) == 0.0
    end

    test "returns 1.0 for satellite deep in umbra" do
      sun_pos = {@au_km, 0.0, 0.0}
      sat_pos = {-7000.0, 0.0, 0.0}

      assert Sidereon.Eclipse.shadow_fraction(sat_pos, sun_pos) == 1.0
    end

    test "returns value between 0 and 1 for penumbra" do
      sun_pos = {@au_km, 0.0, 0.0}
      sat_pos = {-7000.0, 6370.0, 0.0}

      fraction = Sidereon.Eclipse.shadow_fraction(sat_pos, sun_pos)
      assert fraction > 0.0
      assert fraction < 1.0
    end

    test "shadow fraction increases as satellite moves toward shadow axis" do
      sun_pos = {@au_km, 0.0, 0.0}

      # At 7000 km behind Earth:
      #   r_umbra  ~ 6339 km
      #   r_penumbra ~ 6404 km
      # Test points from outside penumbra -> penumbra -> umbra edge -> deep umbra

      # Outside penumbra: fully sunlit
      frac_outside = Sidereon.Eclipse.shadow_fraction({-7000.0, 6410.0, 0.0}, sun_pos)
      # In penumbra: partially shadowed
      frac_penumbra = Sidereon.Eclipse.shadow_fraction({-7000.0, 6370.0, 0.0}, sun_pos)
      # Inside umbra: fully shadowed
      frac_umbra = Sidereon.Eclipse.shadow_fraction({-7000.0, 6330.0, 0.0}, sun_pos)
      # On axis: fully shadowed
      frac_center = Sidereon.Eclipse.shadow_fraction({-7000.0, 0.0, 0.0}, sun_pos)

      assert frac_outside == 0.0
      assert frac_penumbra > 0.0
      assert frac_penumbra < 1.0
      assert frac_umbra == 1.0
      assert frac_center == 1.0
    end
  end

  describe "check/3" do
    @describetag :spk_file

    setup do
      paths = [
        Path.expand("~/.skyfield/de421.bsp"),
        Path.expand("~/de421.bsp"),
        "/tmp/de421.bsp",
        Path.join(File.cwd!(), "de421.bsp")
      ]

      path = Enum.find(paths, &File.exists?/1)

      if path do
        {:ok, tle} = TLE.parse(@iss_line1, @iss_line2)
        {:ok, eph} = Sidereon.Ephemeris.load(path)
        {:ok, tle: tle, eph: eph}
      else
        {:ok, skip: true}
      end
    end

    test "returns a valid status for ISS", %{} = ctx do
      if Map.get(ctx, :skip) do
        IO.puts("\n  [skipped] DE421 file not found")
      else
        dt = ~U[2024-12-19 12:00:00Z]
        {:ok, status} = Sidereon.Eclipse.check(ctx.tle, dt, ctx.eph)

        assert status in [:sunlit, :penumbra, :umbra]
      end
    end

    test "ISS spends roughly 35% of orbit in shadow (sanity check)", %{} = ctx do
      if Map.get(ctx, :skip) do
        IO.puts("\n  [skipped] DE421 file not found")
      else
        # Sample one full ISS orbit (~92 minutes) at 1-minute intervals.
        start = ~U[2024-12-19 00:00:00Z]
        samples = 92

        statuses =
          Enum.map(0..(samples - 1), fn i ->
            dt = DateTime.add(start, i * 60, :second)
            {:ok, status} = Sidereon.Eclipse.check(ctx.tle, dt, ctx.eph)
            status
          end)

        shadow_count = Enum.count(statuses, fn s -> s in [:umbra, :penumbra] end)
        shadow_fraction = shadow_count / samples

        # LEO satellites spend roughly 30-40% of each orbit in shadow.
        # Allow a wide margin for this sanity check.
        assert shadow_fraction >= 0.15,
               "Expected at least 15% shadow, got #{Float.round(shadow_fraction * 100, 1)}%"

        assert shadow_fraction <= 0.55,
               "Expected at most 55% shadow, got #{Float.round(shadow_fraction * 100, 1)}%"
      end
    end

    test "delegate Sidereon.eclipse/3 works", %{} = ctx do
      if Map.get(ctx, :skip) do
        IO.puts("\n  [skipped] DE421 file not found")
      else
        dt = ~U[2024-12-19 06:00:00Z]
        {:ok, status} = Sidereon.eclipse(ctx.tle, dt, ctx.eph)

        assert status in [:sunlit, :penumbra, :umbra]
      end
    end
  end
end
