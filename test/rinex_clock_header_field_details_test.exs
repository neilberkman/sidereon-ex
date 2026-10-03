defmodule Sidereon.GNSS.RINEX.ClockHeaderFieldDetailsTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.RINEX.Clock
  alias Sidereon.GNSS.RINEX.Clock.CivilEpoch

  defp fixture(name), do: Path.join([__DIR__, "fixtures", "clk", "lossless", name])

  test "public header records expose every RINEX 3.04 clock header field payload" do
    source = File.read!(fixture("rinex_clock304_table_a17.clk"))
    {:ok, clock} = Clock.parse(source)
    {:ok, reparsed} = Clock.parse(source)
    assert Clock.header_records(clock) === Clock.header_records(reparsed)

    assert Enum.map(Clock.header_records(clock), & &1.field) === [
             {:version_type, %{version: 3.04, file_type: "C", satellite_system: "G"}},
             {:program_run_by_date, %{program: "TORINEXC V9.9", run_by: "USNO", date: "19960403  001000 UTC"}},
             {:comment, "EXAMPLE OF A CLOCK DATA ANALYSIS FILE"},
             {:comment, "IN THIS CASE ANALYSIS RESULTS FROM GPS ONLY ARE INCLUDED"},
             {:comment, "No re-alignment of the clocks has been applied."},
             {:observation_types, %{system: "G", count: 4, descriptors: ["C1W", "L1W", "C2W", "L2W"]}},
             {:time_system, %{label: "GPS"}},
             {:leap_seconds, 10},
             {:dcbs_applied, %{system: "G", program: "CC2NONCC", source: "p1c1bias.hist @ goby.nrl.navy.mil"}},
             {:pcvs_applied, %{system: "G", program: "PAGES", source: "igs05.atx @ igscb.jpl.nasa.gov"}},
             {:types_of_data, %{count: 2, types: ["AS", "AR"]}},
             {:analysis_center, %{designator: "USN", name: "USNO USING GIPSY/OASIS-II"}},
             {:clock_ref_count,
              %{
                count: 1,
                start: %CivilEpoch{year: 1994, month: 7, day: 14, hour: 0, minute: 0, second: 0.0},
                stop: %CivilEpoch{year: 1994, month: 7, day: 14, hour: 20, minute: 59, second: 0.0}
              }},
             {:analysis_clock_ref, %{name: "USNO", identifier: "40451S003", constraint_s: -0.123456789012}},
             {:clock_ref_count,
              %{
                count: 1,
                start: %CivilEpoch{year: 1994, month: 7, day: 14, hour: 21, minute: 0, second: 0.0},
                stop: %CivilEpoch{year: 1994, month: 7, day: 14, hour: 21, minute: 59, second: 0.0}
              }},
             {:analysis_clock_ref, %{name: "TIDB", identifier: "50103M108", constraint_s: -0.123456789012}},
             {:solution_station_count, %{count: 4, frame: "ITRF96"}},
             {:solution_station,
              %{name: "GOLD", identifier: "40405S031", xyz_mm: {1_234_567_890, -1_234_567_890, -1_234_567_890}}},
             {:solution_station,
              %{name: "AREQ", identifier: "42202M005", xyz_mm: {-1_234_567_890, 1_234_567_890, -1_234_567_890}}},
             {:solution_station,
              %{name: "TIDB", identifier: "50103M108", xyz_mm: {1_234_567_890, -1_234_567_890, 1_234_567_890}}},
             {:solution_station,
              %{name: "HARK", identifier: "30302M007", xyz_mm: {-1_234_567_890, 1_234_567_890, -1_234_567_890}}},
             {:solution_station,
              %{name: "USNO", identifier: "40451S003", xyz_mm: {1_234_567_890, -1_234_567_890, -1_234_567_890}}},
             {:solution_satellite_count, 27},
             {:prn_list,
              [
                "G01",
                "G02",
                "G03",
                "G04",
                "G05",
                "G06",
                "G07",
                "G08",
                "G09",
                "G10",
                "G13",
                "G14",
                "G15",
                "G16",
                "G17",
                "G18"
              ]},
             {:prn_list, ["G19", "G21", "G22", "G23", "G24", "G25", "G26", "G27", "G29", "G30", "G31"]},
             :end_of_header
           ]
  end

  test "public header records expose 3.04 GNSS leap seconds and station fields" do
    {:ok, clock} = Clock.parse(File.read!(fixture("rinex_clock304_table_a18.clk")))
    fields = Enum.map(Clock.header_records(clock), & &1.field)
    assert {:leap_seconds_gnss, 10} in fields
    assert {:station_name_num, %{name: "USNO", identifier: "40451S003"}} in fields
    assert {:station_clock_ref, "UTC(USNO) MASTER CLOCK VIA CONTINUOUS CABLE MONITOR"} in fields
  end

  test "public header records preserve empty optional values and continuation lines" do
    source = File.read!(fixture("rinex_clock304_table_a17.clk"))
    lines = String.split(source, "\n", trim: true)
    end_line = Enum.find(lines, &String.contains?(&1, "END OF HEADER"))
    continuation = String.pad_trailing("        L5Q", 65) <> "SYS / # / OBS TYPES"
    continued_text = String.replace(source, end_line, continuation <> "\n" <> end_line, global: false)
    {:ok, continued} = Clock.parse(continued_text)

    assert Enum.map(Clock.header_records(continued), & &1.field)
           |> Enum.filter(&match?({:observation_types, _}, &1))
           |> List.last() ==
             {:observation_types, %{system: nil, count: nil, descriptors: ["L5Q"]}}

    clock_ref = Enum.find(lines, &String.contains?(&1, "# OF CLK REF"))
    blank_clock_ref = String.pad_trailing("     1", 65) <> "# OF CLK REF"
    {:ok, blank_epoch} = Clock.parse(String.replace(source, clock_ref, blank_clock_ref, global: false))

    assert Enum.find_value(Clock.header_records(blank_epoch), fn
             %{field: {:clock_ref_count, value}} -> value
             _ -> nil
           end) === %{count: 1, start: nil, stop: nil}

    analysis_ref = Enum.find(lines, &String.contains?(&1, "ANALYSIS CLK REF"))
    blank_constraint = String.pad_trailing("USNO      40451S003", 65) <> "ANALYSIS CLK REF"
    {:ok, no_constraint} = Clock.parse(String.replace(source, analysis_ref, blank_constraint, global: false))

    assert Enum.find_value(Clock.header_records(no_constraint), fn
             %{field: {:analysis_clock_ref, value}} -> value
             _ -> nil
           end) === %{name: "USNO", identifier: "40451S003", constraint_s: nil}
  end
end
