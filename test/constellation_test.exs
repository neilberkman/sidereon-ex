defmodule Sidereon.ConstellationTest do
  use ExUnit.Case

  import ExUnit.CaptureLog

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
          case Sidereon.Format.TLE.parse(l1, l2) do
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
    assert float_bits(first.elevation) == 0xC03D_2A30_74A2_4700
    assert float_bits(first.azimuth) == 0x4063_AD5D_EDCD_A442
    assert float_bits(first.range_km) == 0x40C0_7B37_8BA0_A300

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

  defp float_bits(float) do
    <<bits::unsigned-64>> = <<float::float-64>>
    bits
  end
end
