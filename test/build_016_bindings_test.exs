defmodule Sidereon.Build016BindingsTest do
  use ExUnit.Case, async: true

  alias Sidereon.CCSDS.TDM
  alias Sidereon.Format.TLE
  alias Sidereon.FrameCatalog
  alias Sidereon.Geodesic
  alias Sidereon.Geoid
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Troposphere
  alias Sidereon.OrbitDetermination
  alias Sidereon.Propagator
  alias Sidereon.Reliability
  alias Sidereon.SGP4

  @geodtest_row Path.join(__DIR__, "fixtures/geodesic/geodtest_one.dat")
  @egm2008_crop Path.join(__DIR__, "fixtures/geoid/egm2008_25_norcal_crop.bin")
  @tdm_annex Path.join(__DIR__, "fixtures/tdm/annex_e_06.kvn")
  @sp3_two_epoch Path.join(__DIR__, "fixtures/sp3/gbm_c08_c21_two_epoch.sp3")

  @decay_l1 "1 28872U 05037B   05333.02012661  .25992681  00000-0  24476-3 0  1534"
  @decay_l2 "2 28872  96.4736 157.9986 0303955 244.0492 110.6523 16.46015938 10708"

  test "geodesic inverse and direct match one GeodTest row" do
    [lat1, lon1, azi1, lat2, lon2, azi2, s12 | _] = geodtest_values()

    assert {:ok, inverse} = Sidereon.geodesic_inverse(lat1, lon1, lat2, lon2)
    assert_in_delta inverse.s12_m, s12, 5.0e-7
    assert_in_delta inverse.azi1_deg, azi1, 5.0e-13
    assert_in_delta inverse.azi2_deg, azi2, 5.0e-13

    assert {:ok, direct} = Geodesic.direct(lat1, lon1, azi1, s12)
    assert_in_delta direct.lat2_deg, lat2, 5.0e-13
    assert_in_delta direct.lon2_deg, lon2, 5.0e-13
    assert_in_delta direct.azi2_deg, azi2, 5.0e-13
  end

  test "frame catalog Helmert transform matches core reference bits" do
    position = {4_027_893.6750, 307_045.9069, 4_919_475.1721}
    velocity = {-0.01361, 0.01686, 0.01024}

    assert {:ok, state} = FrameCatalog.transform(position, velocity, :itrf2020, :etrf2020, 2010.0)

    assert_bits(state.position_m, [
      0x414EBAFAFAAF96AB,
      0x4112BD96385ABA5F,
      0x4152C42CBD90AC4E
    ])

    assert_bits(state.velocity_m_per_year, [
      0xBF1D0A95D661CF80,
      0x3F1B61FFF5A13200,
      0x3F2E8D9B41C88C40
    ])
  end

  test "EGM2008 crop loader exposes the standard loaded-grid query surface" do
    bytes = File.read!(@egm2008_crop)
    assert {:ok, grid} = Geoid.load_egm2008_raster_window(bytes, :two_point_five_minute, 37.0, -123.0, 25, 25)

    assert_in_delta Geoid.grid_undulation_deg(grid, 37.7749, -122.4194), -32.163558372373, 0.005
    assert float_bits(Geoid.grid_undulation_deg(grid, 37.0, -123.0)) == 0xC0423FEB60000000
  end

  test "TDM Annex E KVN round-trips through canonical structs" do
    text = File.read!(@tdm_annex)

    assert {:ok, tdm} = TDM.parse(text)
    assert [%TDM.Segment{} = segment | _] = tdm.segments
    assert [%TDM.Participant{} | _] = segment.metadata.participants
    assert [%TDM.DataRecord{} = record | _] = segment.data.records
    assert %TDM.Scalar{text: text_value, value: value} = record.value
    assert is_binary(text_value)
    assert is_float(value)

    assert {:ok, encoded} = TDM.encode(tdm)
    assert {:ok, reparsed} = TDM.parse(encoded)
    assert {:ok, encoded_again} = TDM.encode(reparsed)
    assert encoded_again == encoded
  end

  test "ECEF SP3 precise-orbit fit preserves unbounded covariance and low-sample flags" do
    sp3 = SP3.load!(@sp3_two_epoch)

    assert {:ok, report} =
             OrbitDetermination.fit_sp3_ecef_precise_orbit(sp3, "C21",
               forces: [:twobody],
               min_ledger_samples: 3
             )

    assert [%{covariance: %{kind: :unbounded, matrix: nil}}] = report.fits
    assert report.ledger.per_sat["C21"].n == 2
    assert report.ledger.per_sat["C21"].low_sample_count
    assert report.ledger.per_constellation["C"].low_sample_count
  end

  test "SGP4 decay latch prevents raw post-decay recovery inside one latch" do
    assert {:ok, elements} = TLE.parse(@decay_l1, @decay_l2)
    assert {:ok, [{:ok, [_raw_later]}]} = SGP4.propagate_batch([elements], [1450.0])

    assert {:ok, [first, later]} = SGP4.propagate_with_decay_latch(elements, [1440.0, 1450.0])
    assert {:error, {:decayed, 1440.0, 1440.0}} = first
    assert {:error, {:decayed, 1440.0, 1450.0}} = later
  end

  test "W-test returns core delta0 and lambda0 components" do
    assert {:ok, %{delta0: delta0, lambda0: lambda0}} = Reliability.wtest_noncentrality(0.001, 0.80)

    assert float_bits(delta0) == 0x40108751CBD0BEC7
    assert float_bits(lambda0) == 0x4031131C0D9309E7
  end

  test "small wave-2 options are marshaled through the public surfaces" do
    assert {:error, :below_mapping_elevation} =
             Troposphere.mapping(1.0, 45.0, 100.0, ~N[2020-01-01 00:00:00])

    sat_pos = {-7000.0, 6370.0, 0.0}
    sun_pos = {149_597_870.7, 0.0, 0.0}
    assert is_float(Sidereon.Eclipse.shadow_fraction_with_model(sat_pos, sun_pos, :wgs84_oblate))
    assert Sidereon.Eclipse.status_with_model(sat_pos, sun_pos, :wgs84_oblate) in [:sunlit, :penumbra, :umbra]

    state = {{7000.0, 0.0, 1300.0}, {0.0, 7.4, 1.0}}

    assert {:ok, {{_x, _y, _z}, {_vx, _vy, _vz}}} =
             Propagator.propagate(state, 10.0,
               forces: [:composite, {:geopotential, 4, 0}],
               tolerance: 1.0e-10
             )
  end

  defp geodtest_values do
    @geodtest_row
    |> File.read!()
    |> String.split()
    |> Enum.map(&parse_number/1)
  end

  defp parse_number(value) do
    if String.contains?(value, [".", "e", "E"]) do
      String.to_float(value)
    else
      String.to_integer(value) / 1.0
    end
  end

  defp assert_bits(values, expected_bits) do
    values
    |> Tuple.to_list()
    |> Enum.zip(expected_bits)
    |> Enum.each(fn {value, expected} ->
      assert float_bits(value) == expected
    end)
  end

  defp float_bits(value) do
    <<bits::unsigned-64>> = <<value::float-64>>
    bits
  end
end
