defmodule Sidereon.GNSS.RINEX.ClockContractTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Ionosphere.Epoch, as: Instant
  alias Sidereon.GNSS.RINEX.Clock
  alias Sidereon.GNSS.RINEX.Clock.{CivilEpoch, HeaderRecord, Point, Record, Skip, WritePolicy}

  defp rec(content, label), do: String.pad_trailing(content, 60) <> label

  # A 3.00 `AS` record at the Table A16 columns: `A2,1X,A4,1X,I4,4I3,F10.6,I3,3X`
  # then the values in 19-column fields.
  defp as_line(satellite, {year, month, day, hour, minute}, second_text, count, values) do
    clock_fields = Enum.map_join([month, day, hour, minute], &String.pad_leading(Integer.to_string(&1), 3))
    value_fields = Enum.map_join(values, " ", &String.pad_leading(&1, 19))

    Enum.join([
      "AS ",
      String.pad_trailing(satellite, 4),
      " ",
      Integer.to_string(year),
      clock_fields,
      String.pad_leading(second_text, 10),
      String.pad_leading(Integer.to_string(count), 3),
      "   ",
      value_fields
    ])
  end

  # `F9.2,11X,A1,19X,A1`: version, file type `C` and satellite system `G`.
  @version_type "     3.00" <> String.duplicate(" ", 11) <> "C" <> String.duplicate(" ", 19) <> "G"

  defp header(system) do
    [
      rec(@version_type, "RINEX VERSION / TYPE"),
      rec("   " <> system, "TIME SYSTEM ID"),
      rec("", "END OF HEADER")
    ]
  end

  defp product(system, records), do: Enum.join(header(system) ++ records, "\n") <> "\n"

  # A UTC product across the leap second at the end of 2016-12-31.
  defp leap_second_text(system) do
    product(system, [
      as_line("G01", {2016, 12, 31, 23, 59}, "59.000000", 1, ["1.000000000000e-09"]),
      as_line("G01", {2017, 1, 1, 0, 0}, "0.000000", 1, ["3.000000000000e-09"])
    ])
  end

  @mixed """
  AR ONSA              2026 05 13 00 00  0.000000  2    1.000000000000e-06  0.0
  AS G05  2026 05 13 00 00  0.000000  2   -2.000000000000e-04  4.0e-11
  AS G05  2026 05 13 00 00 30.000000  2   -2.000000600000e-04  2.0e-11

  AS G24  2026 05 13 00 00  0.000000  1    5.000000000000e-05
  AS G24  2026 05 13 00 00 30.000000  1    5.000010000000e-05
  """

  describe "a product read from text" do
    setup do
      {:ok, clock} = Clock.parse(@mixed)
      %{clock: clock}
    end

    test "keeps every record of every type with how it was read", %{clock: clock} do
      assert Clock.record_count(clock) == 5
      [ar, g05 | _] = records = Clock.records(clock)

      assert %Record{
               record_type: :ar,
               name: "ONSA",
               satellite: nil,
               values: [1.0e-6, +0.0],
               line: 1,
               line_count: 1,
               reading: :whitespace
             } = ar

      assert ar.civil_epoch == %CivilEpoch{year: 2026, month: 5, day: 13, hour: 0, minute: 0, second: +0.0}
      assert %Instant{time_scale: "GPST"} = ar.epoch

      assert %Record{record_type: :as, satellite: "G05", values: [-2.0e-4, 4.0e-11], reading: {:columns, :v300}} = g05
      assert Enum.map(records, & &1.line) == [1, 2, 3, 5, 6]

      assert Clock.skipped_records(clock) == [%Skip{line: 1, record_type: "AR"}]
    end

    test "restates the text, blank line included, byte for byte", %{clock: clock} do
      assert Clock.to_rinex_string(clock) == {:ok, @mixed}
      assert Clock.source_line(clock, 4) == ""
      assert Clock.source_line(clock, 99) == nil
    end

    test "exposes and preserves suffix bytes and their source column through edits" do
      record_line =
        as_line("G01", {2026, 5, 13, 0, 0}, "0.000000", 1, ["1.000000000000e-09"])
        |> String.pad_trailing(80)
        |> Kernel.<>("X")

      {:ok, clock} = Clock.parse(product("GPS", [record_line]))
      assert [%Record{trailing_text_bytes: "X", trailing_text_column: 80}] = Clock.records(clock)

      assert {:ok, edited} = Clock.set_record_values(clock, 0, [2.0e-9])
      assert [%Record{trailing_text_bytes: "X", trailing_text_column: 80}] = Clock.records(edited)

      assert {:ok, written} = Clock.to_rinex_string(edited)
      edited_line = written |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "AS G01"))
      assert binary_part(edited_line, 80, 1) == "X"
    end

    test "defaults the time system with a notice", %{clock: clock} do
      assert Clock.time_system(clock) == :gps
      assert Clock.time_system_status(clock) == :defaulted
      assert Clock.time_scale(clock) == "GPST"
      assert Clock.version(clock) == nil
      assert Clock.header_records(clock) == []
      assert {:time_system_defaulted, %{system: :gps}} in Clock.notices(clock)
    end

    test "carries every declared value in the typed series", %{clock: clock} do
      series = Clock.series(clock)

      assert [%Point{bias_s: -2.0e-4, additional_values: [4.0e-11], epoch: %Instant{time_scale: "GPST"}} | _] =
               series["G05"]

      assert [%Point{additional_values: []} | _] = series["G24"]
      assert Map.keys(clock.series) == ["G05", "G24"]
    end

    test "edits return a new product and leave the old one as it was", %{clock: clock} do
      assert {:ok, edited} = Clock.set_record_values(clock, 1, [-3.0e-4, 4.0e-11])
      assert %Record{values: [-3.0e-4, 4.0e-11], reading: :edited} = Enum.at(Clock.records(edited), 1)
      assert %Record{values: [-2.0e-4, 4.0e-11]} = Enum.at(Clock.records(clock), 1)
      assert [{_seconds, -3.0e-4} | _] = edited.series["G05"]

      assert {:ok, {without_ar, %Record{record_type: :ar, name: "ONSA"}}} = Clock.remove_record(clock, 0)
      assert Clock.record_count(without_ar) == 4
      assert Clock.skipped_records(without_ar) == []

      assert {:ok, {satellites_only, 1}} = Clock.retain_records(clock, &(&1.record_type == :as))
      assert Enum.all?(Clock.records(satellites_only), &(&1.record_type == :as))

      assert {:ok, {rescaled, 2}} =
               Clock.edit_records(clock, fn record -> if record.name == "G24", do: [6.0e-5] end)

      assert Enum.map(rescaled.series["G24"], &elem(&1, 1)) == [6.0e-5, 6.0e-5]

      appended = %{record_type: :as, name: "G24", epoch: {{2026, 5, 13}, {0, 1, 0.0}}, values: [5.00002e-5]}
      assert {:ok, longer} = Clock.insert_record(clock, Clock.record_count(clock), appended)
      assert length(longer.series["G24"]) == 3
    end

    test "a refused edit changes nothing", %{clock: clock} do
      assert {:error, {:invalid_input, %{field: "index"}}} = Clock.set_record_values(clock, 99, [1.0e-9])
      assert {:error, {:invalid_argument, :index, -1}} = Clock.remove_record(clock, -1)
      assert {:error, {:invalid_argument, :values, :bias}} = Clock.set_record_values(clock, 1, [:bias])
      assert Clock.to_rinex_string(clock) == {:ok, @mixed}
    end
  end

  describe "time systems" do
    test "a UTC product answers a 23:59:60 query on a leap-second day by elapsed time" do
      {:ok, clock} = Clock.parse(leap_second_text("UTC"))

      assert Clock.time_system(clock) == :utc
      assert Clock.time_system_status(clock) == :declared
      assert Clock.time_scale(clock) == "UTC"

      # Halfway by elapsed time between 1e-9 at 23:59:59 and 3e-9 at 00:00:00.
      # Instants are held as split Julian dates, so the elapsed seconds carry
      # about 1e-11 s of rounding; the tolerance is the core's own relative
      # bound for this interpolation, far below the 1e-9 gap to a label-based
      # answer.
      assert {:ok, bias} = Clock.clock_s(clock, "G01", {{2016, 12, 31}, {23, 59, 60.0}})
      assert_in_delta bias, 2.0e-9, 1.0e-20

      civil = %CivilEpoch{year: 2016, month: 12, day: 31, hour: 23, minute: 59, second: 60.0}
      assert {:ok, ^bias} = Clock.clock_s(clock, "G01", civil)

      assert {:ok, %Instant{time_scale: "UTC"} = instant} = Clock.civil_to_instant("UTC", civil)
      assert {:ok, ^bias} = Clock.clock_s(clock, "G01", instant)
    end

    test "GLO is read as UTC" do
      {:ok, clock} = Clock.parse(leap_second_text("GLO"))

      assert Clock.time_system(clock) == :glo
      assert Clock.time_scale(clock) == "UTC"
      assert {:ok, _bias} = Clock.clock_s(clock, "G01", {{2016, 12, 31}, {23, 59, 60.0}})
    end

    test "a continuous scale refuses the leap-second label" do
      {:ok, clock} = Clock.parse(leap_second_text("GPS"))

      assert {:error, {:invalid_input, %{field: "epoch"}}} =
               Clock.clock_s(clock, "G01", {{2016, 12, 31}, {23, 59, 60.0}})

      assert Clock.civil_to_instant("GPST", {{2016, 12, 31}, {23, 59, 60.0}}) == {:error, :invalid_epoch}
    end

    test "IRN keeps civil epochs with no instant" do
      {:ok, clock} = Clock.parse(leap_second_text("IRN"))

      assert Clock.time_system(clock) == :irn
      assert Clock.time_scale(clock) == nil
      assert Clock.series(clock) == %{}
      assert Enum.all?(Clock.records(clock), &is_nil(&1.epoch))
      assert {:time_system_without_scale, %{system: :irn}} in Clock.notices(clock)

      assert {:error, {:invalid_input, %{field: "time_system"}}} =
               Clock.clock_s(clock, "G01", {{2016, 12, 31}, {23, 59, 59.0}})
    end

    test "the header records are kept with their typed readings" do
      {:ok, clock} = Clock.parse(leap_second_text("UTC"))

      assert [
               %HeaderRecord{line: 1, label: "RINEX VERSION / TYPE", field: {:version_type, version}},
               %HeaderRecord{line: 2, label: "TIME SYSTEM ID", field: {:time_system, %{label: "UTC"}}},
               %HeaderRecord{line: 3, field: :end_of_header}
             ] = Clock.header_records(clock)

      assert version.version == 3.0
      assert version.satellite_system == "G"
      assert Clock.version(clock) == 3.0
      assert Clock.layout(clock) == :v300
    end

    test "set_time_system restates the product in the new system" do
      {:ok, clock} = Clock.parse(leap_second_text("GPS"))

      assert {:ok, utc} = Clock.set_time_system(clock, :utc)
      assert Clock.time_scale(utc) == "UTC"
      assert {:ok, text} = Clock.to_rinex_string(utc)
      assert text =~ "UTC"
      assert Clock.time_system(clock) == :gps

      assert Clock.set_time_system(clock, :glonass_time) == {:error, {:invalid_argument, :time_system, :glonass_time}}
    end
  end

  describe "values beyond the declared count" do
    setup do
      # An `AS` record declaring one value while carrying a bias sigma.
      text = product("GPS", [as_line("G01", {2026, 5, 13, 0, 0}, "0.000000", 1, ["1.0e-09", "4.0e-11"])])
      {:ok, clock} = Clock.parse(text)
      %{clock: clock}
    end

    test "are kept as surplus values with a notice", %{clock: clock} do
      assert [%Record{values: [1.0e-9], surplus_values: [%{position: 1, value: 4.0e-11}]}] = Clock.records(clock)
      assert Enum.any?(Clock.notices(clock), &match?({:surplus_values, %{records: 1}}, &1))
    end

    test "an edit that would drop them is refused; one that restates them is not", %{clock: clock} do
      assert {:error, {:invalid_input, _fields}} = Clock.set_record_values(clock, 0, [2.0e-9])
      assert {:ok, edited} = Clock.set_record_values(clock, 0, [2.0e-9, 4.0e-11])
      assert [%Record{values: [2.0e-9, 4.0e-11], surplus_values: []}] = Clock.records(edited)
    end
  end

  describe "products built from rows" do
    test "are written with a header stating the time system and data types" do
      assert {:ok, clock} = Clock.from_series_rows(%{"G01" => [{1.0e9, 1.0e-9}, {1.0e9 + 30.0, 2.0e-9}]})
      assert Clock.time_system_status(clock) == :constructed
      assert {:ok, text} = Clock.to_rinex_string(clock)
      assert text =~ "TIME SYSTEM ID"
      assert text =~ "# / TYPES OF DATA"
      assert {:ok, reparsed} = Clock.parse(text)
      assert reparsed.series == clock.series

      assert {:error, {:invalid_input, %{field: "time_system"}}} = Clock.set_time_system(clock, :utc)
    end

    test "keep every declared value of each point in its time scale" do
      epoch = Instant.julian_date("BDT", 2_461_173.5, 0.0)
      point = %Point{epoch: epoch, bias_s: 1.0e-9, additional_values: [2.0e-11, 3.0e-15]}

      assert {:ok, clock} = Clock.from_clock_points("BDT", %{"C01" => [point]})
      assert Clock.time_scale(clock) == "BDT"
      assert %{"C01" => [%Point{bias_s: 1.0e-9, additional_values: [2.0e-11, 3.0e-15]}]} = Clock.series(clock)
      assert clock.series == %{"C01" => []}
    end

    test "a scale no RINEX clock time system names is refused" do
      epoch = Instant.julian_date("GLONASST", 2_461_173.5, 0.0)
      point = %Point{epoch: epoch, bias_s: 1.0e-9}

      assert {:ok, clock} = Clock.from_clock_points("GLONASST", %{"R01" => [point]})
      assert {:error, {:unsupported_time_scale, %{scale: "GLONASST"}}} = Clock.to_rinex_string(clock)
    end

    test "an epoch off the microsecond grid is refused, or written at the nearest microsecond by policy" do
      # 1.0e-12 day is 86.4 ns past midnight.
      epoch = Instant.julian_date("GPST", 2_461_173.5, 1.0e-12)
      {:ok, clock} = Clock.from_clock_points("GPST", %{"G01" => [%Point{epoch: epoch, bias_s: 1.0e-9}]})

      assert {:error, {:invalid_input, _fields}} = Clock.to_rinex_string(clock)
      assert {:error, {:invalid_input, _fields}} = Clock.to_rinex_string_with_policy(clock, %WritePolicy{})

      assert {:ok, %{text: text, departures: [departure]}} =
               Clock.to_rinex_string_with_policy(clock, %WritePolicy{nearest_microsecond_epochs: :allow})

      assert {:epoch_at_nearest_microsecond, %{record: 0, name: "G01", epoch: ^epoch, written: written}} = departure
      assert written =~ "2026"
      assert text =~ "AS G01"
    end
  end

  describe "arguments the boundary cannot carry" do
    setup do
      {:ok, clock} = Clock.parse(@mixed)
      %{clock: clock}
    end

    test "are named before the call", %{clock: clock} do
      assert Clock.clock_s(clock, "G05", {{2026, 5.0, 13}, {0, 0, 0}}) == {:error, {:invalid_epoch_field, :month, 5.0}}
      assert Clock.clock_s(clock, "G05", {{2026, 5, 13}, {256, 0, 0}}) == {:error, {:value_out_of_range, :hour, 256}}

      assert Clock.clock_s(clock, "G05", {{2_147_483_648, 5, 13}, {0, 0, 0}}) ==
               {:error, {:value_out_of_range, :year, 2_147_483_648}}

      assert Clock.clock_s(clock, "G05", {{2026, 5, 13}, {0, 0, "0"}}) == {:error, {:invalid_epoch_field, :second, "0"}}
      assert Clock.clock_s(clock, "G05", :noon) == {:error, {:invalid_argument, :epoch, :noon}}

      assert Clock.to_rinex_string_with_policy(clock, %WritePolicy{nearest_microsecond_epochs: :sometimes}) ==
               {:error, {:invalid_argument, :policy, %WritePolicy{nearest_microsecond_epochs: :sometimes}}}
    end
  end
end
