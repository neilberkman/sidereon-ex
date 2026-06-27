defmodule Sidereon.GNSS.SP3WriterTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.SP3

  # Single-epoch SP3-c from `{satellite, [x,y,z] km, clock_us | nil}` records.
  defp sp3_bytes(records) do
    n = length(records)

    sats =
      Enum.map_join(records, "", fn {sat, _, _} -> sat end) <>
        String.duplicate("  0", 17 - n)

    header = [
      "#cP2020  6 24  0  0  0.00000000       1 ORBIT IGS14 FIT  TST",
      "## 2111 432000.00000000   900.00000000 59024 0.0000000000000",
      "+   #{String.pad_leading(Integer.to_string(n), 2)}   #{sats}",
      "++         0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0  0",
      "%c M  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
      "%f  1.2500000  1.025000000  0.00000000000  0.000000000000000",
      "%f  0.0000000  0.000000000  0.00000000000  0.000000000000000",
      "%i    0    0    0    0      0      0      0      0         0",
      "%i    0    0    0    0      0      0      0      0         0",
      "/* TEST SP3-c FIXTURE",
      "*  2020  6 24  0  0  0.00000000"
    ]

    recs =
      Enum.map(records, fn {sat, [x, y, z], clk} ->
        c = clk || 999_999.999999
        "P" <> sat <> fmt(x) <> fmt(y) <> fmt(z) <> fmt(c)
      end)

    Enum.join(header ++ recs ++ ["EOF", ""], "\n")
  end

  defp fmt(v), do: :io_lib.format(~c"~14.6f", [v]) |> IO.iodata_to_binary()

  defp parse!(records), do: SP3.parse(sp3_bytes(records))

  describe "SP3.to_iodata/2" do
    test "round-trips the satellite set through parse -> to_iodata -> parse" do
      {:ok, sp3} =
        parse!([
          {"G01", [15000.0, -20000.0, 5000.0], 100.0},
          {"G02", [16000.0, -21000.0, 6000.0], 200.0},
          {"E11", [17000.0, -22000.0, 7000.0], 300.0}
        ])

      text = sp3 |> SP3.to_iodata() |> IO.iodata_to_binary()
      assert {:ok, reparsed} = SP3.parse(text)

      assert Enum.sort(SP3.satellite_ids(reparsed)) == ["E11", "G01", "G02"]
      assert SP3.satellite_ids(reparsed) == SP3.satellite_ids(sp3)
    end

    test "is deterministic (same product -> identical bytes)" do
      {:ok, sp3} = parse!([{"G01", [15000.0, -20000.0, 5000.0], 100.0}])

      a = IO.iodata_to_binary(SP3.to_iodata(sp3))
      b = IO.iodata_to_binary(SP3.to_iodata(sp3))
      assert a == b
    end
  end

  describe "Data.write_sp3/3" do
    setup do
      base =
        Path.join(System.tmp_dir!(), "sidereon_sp3_write_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm("#{base}.sp3") && File.rm("#{base}.sp3.gz") end)
      {:ok, base: base}
    end

    test "writes a file that loads back with the same satellites", %{base: base} do
      path = "#{base}.sp3"

      {:ok, sp3} =
        parse!([
          {"G01", [15000.0, -20000.0, 5000.0], 100.0},
          {"G02", [16000.0, -21000.0, 6000.0], 200.0}
        ])

      assert {:ok, ^path} = Data.write_sp3(sp3, path)
      assert {:ok, loaded} = SP3.load(path)
      assert Enum.sort(SP3.satellite_ids(loaded)) == ["G01", "G02"]
    end

    test "gzip: true writes a gzipped product that decompresses to valid SP3", %{base: base} do
      path = "#{base}.sp3.gz"
      {:ok, sp3} = parse!([{"G01", [15000.0, -20000.0, 5000.0], 100.0}])

      assert {:ok, ^path} = Data.write_sp3(sp3, path, gzip: true)
      assert <<0x1F, 0x8B, _rest::binary>> = File.read!(path)

      {:ok, reparsed} = path |> File.read!() |> :zlib.gunzip() |> SP3.parse()
      assert SP3.satellite_ids(reparsed) == ["G01"]
    end
  end

  describe "merge -> write -> re-read" do
    test "the written merged product covers the union of two centers", %{} do
      {:ok, a} =
        parse!([
          {"G01", [15000.0, -20000.0, 5000.0], 100.0},
          {"G02", [16000.0, -21000.0, 6000.0], 200.0},
          {"G03", [17000.0, -22000.0, 7000.0], 300.0}
        ])

      {:ok, b} =
        parse!([
          {"G01", [15000.0, -20000.0, 5000.0], 100.0},
          {"G02", [16000.0, -21000.0, 6000.0], 200.0}
        ])

      {:ok, merged, _report} = SP3.merge([a, b])

      path =
        Path.join(System.tmp_dir!(), "sidereon_merged_#{System.unique_integer([:positive])}.sp3")

      on_exit(fn -> File.rm(path) end)

      assert {:ok, ^path} = Data.write_sp3(merged, path)
      assert {:ok, loaded} = SP3.load(path)

      # Union coverage survives the round trip to a single standard file: G03,
      # which only center A had, is present in the written product.
      assert "G03" in SP3.satellite_ids(loaded)
      assert Enum.sort(SP3.satellite_ids(loaded)) == ["G01", "G02", "G03"]
    end
  end
end
