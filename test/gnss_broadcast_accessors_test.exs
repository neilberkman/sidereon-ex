defmodule Sidereon.GNSS.BroadcastAccessorsTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Broadcast

  alias Sidereon.GNSS.Broadcast.{
    ClockPolynomial,
    GlonassRecord,
    IonoCorrections,
    KeplerianElements,
    KlobucharAlphaBeta,
    Record
  }

  @nav_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_MN.rnx")
  @glonass_nav_path Path.join(__DIR__, "fixtures/nav/ESBC00DNK_R_20201770000_01D_RN.rnx")
  @beidou_iono_path Path.join(__DIR__, "fixtures/nav/BRDC00WRD_R_20261200800_06H_MN.rnx")
  @broadcast_golden_path Path.join(__DIR__, "fixtures/core/broadcast_golden.json")

  describe "RINEX NAV record accessors" do
    test "exposes default broadcast records and matches the core golden bits" do
      nav = Broadcast.load!(@nav_path)

      records = Broadcast.records(nav)
      assert Broadcast.record_count(nav) == 1395
      assert length(records) == 1395

      assert Enum.frequencies_by(records, &String.first(&1.satellite_id)) == %{
               "G" => 257,
               "E" => 781,
               "C" => 357
             }

      assert Enum.all?(records, &match?(%Record{}, &1))
      assert Enum.all?(records, &(&1.sv_health == 0.0))
      refute Enum.any?(records, &(&1.message == :galileo_fnav))

      case_data = golden_case("gps_at_toe")
      record = matching_record(records, case_data)

      assert %Record{
               satellite_id: "G01",
               message: :gps_lnav,
               week: 2111,
               elements: %KeplerianElements{},
               clock: %ClockPolynomial{},
               fit_interval_s: 14_400.0
             } = record

      assert_struct_bits(record.elements, case_data["elements_hex"])
      assert_struct_bits(record.clock, case_data["clock_hex"])
      assert_float_bits(record.group_delay_s, case_data["tgd_s_hex"], "group_delay_s")
    end

    test "exposes leap seconds and GPS ionosphere coefficients from the header" do
      nav = Broadcast.load!(@nav_path)

      assert Broadcast.leap_seconds(nav) == 18.0

      assert %IonoCorrections{
               gps: %KlobucharAlphaBeta{
                 alpha: {4.6566e-09, 1.4901e-08, -5.9605e-08, -1.1921e-07},
                 beta: {81_920.0, 98_304.0, -65_536.0, -524_290.0}
               },
               beidou: nil
             } = Broadcast.iono_corrections(nav)
    end

    test "exposes BeiDou ionosphere coefficients when the header carries BDSA and BDSB" do
      nav = Broadcast.load!(@beidou_iono_path)

      assert %IonoCorrections{
               gps: %KlobucharAlphaBeta{},
               beidou: %KlobucharAlphaBeta{
                 alpha: {3.6322e-08, 4.4703e-08, -8.9407e-07, 1.4901e-06},
                 beta: {118_780.0, -294_910.0, 3_014_700.0, -2_752_500.0}
               }
             } = Broadcast.iono_corrections(nav)
    end
  end

  describe "GLONASS record accessors" do
    test "exposes healthy GLONASS state-vector records in SI units" do
      nav = Broadcast.load!(@glonass_nav_path)

      assert Broadcast.record_count(nav) == 0
      assert Broadcast.glonass_record_count(nav) == 510
      assert Broadcast.leap_seconds(nav) == 18.0

      records = Broadcast.glonass_records(nav)
      assert length(records) == 510
      assert Enum.all?(records, &match?(%GlonassRecord{}, &1))

      [first | _] = records

      assert %GlonassRecord{
               satellite_id: "R01",
               clock_bias_s: 6.355904042721e-05,
               freq_channel: 1
             } = first

      assert first.gamma_n == 0.0
      assert first.sv_health == 0.0

      assert_vec3_in_delta(
        first.position_m,
        {10_908_942.38281, -2_885_726.074219, 22_883_539.55078},
        1.0e-6
      )

      assert_vec3_in_delta(
        first.velocity_m_s,
        {1_407.806396484, 2_795.855522156, -316.9984817505},
        1.0e-9
      )

      assert_vec3_in_delta(
        first.acceleration_m_s2,
        {-1.862645149231e-06, -0.0, -2.793967723846e-06},
        1.0e-18
      )
    end
  end

  defp golden_case(name) do
    @broadcast_golden_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("cases")
    |> Enum.find(&(&1["name"] == name))
  end

  defp matching_record(records, case_data) do
    matches =
      Enum.filter(records, fn record ->
        record.satellite_id == case_data["sat"] and
          record.message == message_atom(case_data["message"]) and
          float_bits(record.elements.toe_sow) == int_bits(case_data["elements_hex"]["toe_sow"]) and
          float_bits(record.elements.sqrt_a) == int_bits(case_data["elements_hex"]["sqrt_a"]) and
          float_bits(record.elements.e) == int_bits(case_data["elements_hex"]["e"])
      end)

    assert length(matches) == 1
    hd(matches)
  end

  defp assert_struct_bits(struct, expected_hex) do
    values = Map.from_struct(struct)

    for {field, hex} <- expected_hex do
      key = String.to_existing_atom(field)
      assert_float_bits(Map.fetch!(values, key), hex, field)
    end
  end

  defp assert_float_bits(actual, hex, label) do
    assert float_bits(actual) == int_bits(hex), "#{label} bit pattern differs"
  end

  defp assert_vec3_in_delta({ax, ay, az}, {ex, ey, ez}, delta) do
    assert_in_delta ax, ex, delta
    assert_in_delta ay, ey, delta
    assert_in_delta az, ez, delta
  end

  defp message_atom("GPS_LNAV"), do: :gps_lnav
  defp message_atom("GAL_INAV"), do: :galileo_inav
  defp message_atom("GAL_FNAV"), do: :galileo_fnav
  defp message_atom("BDS_D1"), do: :beidou_d1
  defp message_atom("BDS_D2"), do: :beidou_d2

  defp int_bits("0x" <> hex), do: String.to_integer(hex, 16)

  defp float_bits(value) do
    <<bits::unsigned-64>> = <<value::float-64>>
    bits
  end
end
