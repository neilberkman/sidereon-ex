defmodule Sidereon.ConstellationTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

  alias Sidereon.Format.TLE

  @fixtures_dir Path.join(__DIR__, "fixtures/celestrak")

  setup do
    body = File.read!(Path.join(@fixtures_dir, "stations.tle"))

    tles =
      body
      |> String.trim()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce([], fn
        ["1 " <> _ = l1, "2 " <> _ = l2], acc ->
          case TLE.parse(l1, l2) do
            {:ok, tle} -> [tle | acc]
            _ -> acc
          end

        _, acc ->
          acc
      end)
      |> Enum.reverse()

    constellation = Sidereon.Constellation.from_tles("stations", tles)
    %{constellation: constellation, epoch: hd(tles).epoch}
  end

  test "from_tles creates constellation", %{constellation: c} do
    assert c.name == "stations"
    assert c.count > 10
  end

  test "propagate_all propagates all satellites", %{constellation: c, epoch: dt} do
    results = Sidereon.Constellation.propagate_all(c, dt)
    assert length(results) == c.count

    ok_count = Enum.count(results, fn {_, r} -> match?({:ok, _}, r) end)
    assert ok_count == c.count

    # All positions should be in valid orbit range
    for {_id, {:ok, teme}} <- results do
      {x, y, z} = teme.position
      radius = :math.sqrt(x * x + y * y + z * z)
      assert radius > 6300 and radius < 50_000
    end
  end

  test "propagate_all returns per-satellite errors for invalid elements", %{
    constellation: c,
    epoch: dt
  } do
    bad_tle = hd(c.satellites) |> Map.put(:mean_motion, nil)
    constellation = %{c | satellites: [bad_tle], count: 1}

    assert [
             {bad_tle.catalog_number, {:error, {:missing_field, :mean_motion}}}
           ] == Sidereon.Constellation.propagate_all(constellation, dt)
  end

  test "propagate_all returns per-satellite errors for task exits", %{constellation: c} do
    tle = hd(c.satellites)
    catalog_number = tle.catalog_number
    constellation = %{c | satellites: [tle], count: 1}

    {results, _log} =
      with_log(fn ->
        Sidereon.Constellation.propagate_all(constellation, :bad_datetime)
      end)

    assert [
             {^catalog_number, {:error, {:task_exit, _reason}}}
           ] = results
  end

  test "visible_from returns core-sorted visible rows", %{constellation: c, epoch: dt} do
    constellation = %{c | satellites: Enum.take(c.satellites, 10), count: 10}
    station = %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}

    {:ok, visible} =
      Sidereon.Constellation.visible_from(constellation, station, dt, min_elevation: -50.0)

    assert Enum.map(visible, & &1.catalog_number) == ["49271", "25544", "36086", "49044", "65586"]

    first = hd(visible)
    # Elevation/azimuth/range derive from look-angle geometry (atan2/asin/sqrt);
    # libm transcendentals differ by a few ULPs across CPU architectures
    # (arm64 vs x86_64), so compare to a tight tolerance rather than exact bits.
    # The raw SGP4 position below stays bit-exact across platforms.
    assert_in_delta first.elevation, -29.164801873796932, 1.0e-9
    assert_in_delta first.azimuth, 157.41771593250638, 1.0e-9
    assert_in_delta first.range_km, 8438.433948592748, 1.0e-9

    assert Tuple.to_list(first.position) |> Enum.map(&float_bits/1) == [
             0x40B0_1A88_998C_FB44,
             0x40B7_988C_0568_1811,
             0xC0A3_68D5_167E_3886
           ]
  end

  test "visible_from returns invalid satellite errors before calling the NIF", %{
    constellation: c,
    epoch: dt
  } do
    bad_tle = hd(c.satellites) |> Map.put(:mean_motion, nil)
    catalog_number = bad_tle.catalog_number
    constellation = %{c | satellites: [bad_tle], count: 1}
    station = %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}

    assert {:error,
            {:invalid_satellites,
             [
               {^catalog_number, {:error, {:missing_field, :mean_motion}}}
             ]}} =
             Sidereon.Constellation.visible_from(
               constellation,
               station,
               dt,
               min_elevation: -50.0
             )
  end

  describe "look_angle_arcs/4" do
    test "returns fleet-ordered arcs, bit-identical to per-satellite look angles", %{
      constellation: c,
      epoch: dt
    } do
      constellation = %{c | satellites: Enum.take(c.satellites, 5), count: 5}
      station = %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}
      times = for s <- 0..600//120, do: DateTime.add(dt, s, :second)

      {:ok, arcs} = Sidereon.Constellation.look_angle_arcs(constellation, station, times)

      # One arc per satellite, fleet order; one look angle per datetime.
      assert length(arcs) == 5
      assert Enum.all?(arcs, &(length(&1) == length(times)))

      # Each satellite's batched arc equals the per-satellite look angle at each
      # epoch, sample for sample (same core kernel -> bit-exact).
      for {tle, arc} <- Enum.zip(constellation.satellites, arcs) do
        for {datetime, look} <- Enum.zip(times, arc) do
          {:ok, single} = Sidereon.look_angle(tle, datetime, station, opsmode: :afspc)
          assert look == single
        end
      end
    end

    test "rejects a non-DateTime grid entry", %{constellation: c} do
      station = %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}

      assert {:error, {:invalid_field, :datetimes, :nope}} =
               Sidereon.Constellation.look_angle_arcs(c, station, [:nope])
    end

    test "rejects an invalid opsmode", %{constellation: c, epoch: dt} do
      station = %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}

      assert {:error, {:invalid_option, {:opsmode, :bogus}}} =
               Sidereon.Constellation.look_angle_arcs(c, station, [dt], opsmode: :bogus)
    end
  end

  describe "ground_tracks/3" do
    test "returns fleet-ordered tracks, bit-identical to per-satellite ground tracks", %{
      constellation: c,
      epoch: dt
    } do
      constellation = %{c | satellites: Enum.take(c.satellites, 5), count: 5}
      times = for s <- 0..600//120, do: DateTime.add(dt, s, :second)

      {:ok, tracks} = Sidereon.Constellation.ground_tracks(constellation, times)

      assert length(tracks) == 5
      assert Enum.all?(tracks, &(length(&1) == length(times)))

      for {tle, track} <- Enum.zip(constellation.satellites, tracks) do
        {:ok, single} = Sidereon.ground_track(tle, times, opsmode: :afspc)
        assert track == single
      end
    end

    test "honors the opsmode option", %{constellation: c, epoch: dt} do
      constellation = %{c | satellites: Enum.take(c.satellites, 1), count: 1}
      times = for s <- 0..120//60, do: DateTime.add(dt, s, :second)
      tle = hd(constellation.satellites)

      {:ok, [improved_track]} =
        Sidereon.Constellation.ground_tracks(constellation, times, opsmode: :improved)

      {:ok, single} = Sidereon.ground_track(tle, times, opsmode: :improved)
      assert improved_track == single
    end
  end

  describe "passes/5" do
    test "tags each pass with its fleet index and catalog number, parity with predict/5", %{
      constellation: c,
      epoch: dt
    } do
      constellation = %{c | satellites: Enum.take(c.satellites, 5), count: 5}
      station = %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}
      start_dt = dt
      end_dt = DateTime.add(dt, 86_400, :second)

      {:ok, passes} =
        Sidereon.Constellation.passes(constellation, station, start_dt, end_dt,
          min_elevation: 5.0,
          step_seconds: 60
        )

      # At least one LEO satellite passes over London within a day.
      assert passes != []

      # Indices stay inside the fleet and each row carries the matching catalog.
      for entry <- passes do
        assert entry.satellite_index in 0..4
        sat = Enum.at(constellation.satellites, entry.satellite_index)
        assert entry.catalog_number == sat.catalog_number
        assert %Sidereon.Pass{} = entry.pass
      end

      # Per satellite, the constellation passes equal the single-satellite
      # predictor over the same window/options (same core finder -> identical).
      for {tle, index} <- Enum.with_index(constellation.satellites) do
        {:ok, expected} =
          Sidereon.Passes.predict(tle, station, start_dt, end_dt,
            min_elevation: 5.0,
            step_seconds: 60,
            opsmode: :afspc
          )

        got =
          passes
          |> Enum.filter(&(&1.satellite_index == index))
          |> Enum.map(& &1.pass)

        assert got == expected
      end
    end

    test "rejects an invalid option", %{constellation: c, epoch: dt} do
      station = %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}
      end_dt = DateTime.add(dt, 3600, :second)

      assert {:error, {:invalid_option, :nonsense}} =
               Sidereon.Constellation.passes(c, station, dt, end_dt, nonsense: 1)
    end

    test "rejects a non-DateTime window bound", %{constellation: c, epoch: dt} do
      station = %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}

      assert {:error, {:invalid_field, :end_dt, :later}} =
               Sidereon.Constellation.passes(c, station, dt, :later)
    end
  end

  defp float_bits(float) do
    <<bits::unsigned-64>> = <<float::float-64>>
    bits
  end
end
