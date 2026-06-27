defmodule Sidereon.GNSS.RINEX.ClockTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.RINEX.Clock

  @clk """
  3.00           C                                       RINEX VERSION / TYPE
       18                                                      LEAP SECONDS
                                                              END OF HEADER
  AR ONSA              2026 05 13 00 00  0.000000  2    1.000000000000e-06  0.0
  AS G05  2026 05 13 00 00  0.000000  2   -2.000000000000e-04  4.0e-11
  AS G05  2026 05 13 00 00 30.000000  2   -2.000000600000e-04  2.0e-11
  AS G05  2026 05 13 00 01  0.000000  2   -2.000001200000e-04  2.0e-11
  AS G24  2026 05 13 00 00  0.000000  1    5.000000000000e-05
  AS G24  2026 05 13 00 00 30.000000  1    5.000010000000e-05
  """

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "sidereon_clock_test_#{System.unique_integer([:positive])}.clk"
      )

    File.write!(path, @clk)
    on_exit(fn -> File.rm(path) end)
    {:ok, path: path}
  end

  describe "load!/1 and clock_s/3" do
    test "parses AS satellite records and ignores AR receiver records", ctx do
      clock = Clock.load!(ctx.path)
      assert Map.keys(clock.series) |> Enum.sort() == ["G05", "G24"]
    end

    test "returns the exact bias at a record epoch", ctx do
      clock = Clock.load!(ctx.path)
      assert {:ok, bias} = Clock.clock_s(clock, "G05", ~N[2026-05-13 00:00:30.000000])
      assert_in_delta bias, -2.0000006e-4, 1.0e-18
    end

    test "linearly interpolates between two records", ctx do
      clock = Clock.load!(ctx.path)
      # Halfway between 00:00:00 (-2.0e-4) and 00:00:30 (-2.0000006e-4).
      assert {:ok, bias} = Clock.clock_s(clock, "G24", ~N[2026-05-13 00:00:15.000000])
      assert_in_delta bias, (5.0e-5 + 5.00001e-5) / 2.0, 1.0e-18
    end

    test "parses records with no bias sigma column", ctx do
      clock = Clock.load!(ctx.path)
      assert {:ok, bias} = Clock.clock_s(clock, "G24", ~N[2026-05-13 00:00:00.000000])
      assert_in_delta bias, 5.0e-5, 1.0e-18
    end

    test "returns :no_clock for an unknown satellite", ctx do
      clock = Clock.load!(ctx.path)
      assert {:error, :no_clock} = Clock.clock_s(clock, "G99", ~N[2026-05-13 00:00:15.000000])
    end

    test "returns :no_clock outside the record span (no extrapolation)", ctx do
      clock = Clock.load!(ctx.path)
      assert {:error, :no_clock} = Clock.clock_s(clock, "G05", ~N[2026-05-12 23:59:00.000000])
      assert {:error, :no_clock} = Clock.clock_s(clock, "G05", ~N[2026-05-13 01:00:00.000000])
    end
  end

  describe "load/1" do
    test "returns an error tuple for a missing file" do
      assert {:error, _reason} = Clock.load("/nonexistent/sidereon_clock.clk")
    end
  end

  describe "parse_lossy/1 and load_lossy/1" do
    test "strict parsing reports malformed rows while lossy parsing skips them" do
      text = """
      AS G05  2026 05 13 00 00  0.000000  1   1.0e-04
      AS G06  2026 05 13 00 00  bad-second  1   2.0e-04
      """

      assert {:error, reason} = Clock.load(write_tmp_clock!(text))
      assert reason =~ "second=bad-second"

      assert {:ok, clock} = Clock.parse_lossy(text)
      assert Map.keys(clock.series) == ["G05"]

      assert {:ok, bias} = Clock.clock_s(clock, "G05", ~N[2026-05-13 00:00:00.000000])
      assert <<bias::float-64>> == <<1.0e-4::float-64>>
      assert {:error, :no_clock} = Clock.clock_s(clock, "G06", ~N[2026-05-13 00:00:00.000000])
    end

    test "load_lossy/1 returns an empty clock when every row is malformed" do
      path = write_tmp_clock!("AS G05  2026 05 13 00 00  0.000000  1\n")

      assert {:ok, %Clock{series: %{}}} = Clock.load_lossy(path)
    end
  end

  defp write_tmp_clock!(text) do
    path =
      Path.join(
        System.tmp_dir!(),
        "sidereon_clock_lossy_test_#{System.unique_integer([:positive])}.clk"
      )

    File.write!(path, text)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
