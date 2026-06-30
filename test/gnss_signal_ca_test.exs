defmodule Sidereon.GNSS.Signal.CATest do
  use ExUnit.Case

  alias Sidereon.GNSS.Signal.CA

  @three_valued MapSet.new([-65, -1, 63])

  # IS-GPS-200 Table 3-I, "first 10 chips (octal)" column. The first 10 raw
  # binary chips read MSB-first as a 10-bit number, expressed in octal.
  @octal_reference %{
    1 => "1440",
    2 => "1620",
    3 => "1710",
    4 => "1744",
    5 => "1133",
    6 => "1455",
    7 => "1131",
    8 => "1454",
    9 => "1626",
    10 => "1504",
    11 => "1642",
    12 => "1750",
    13 => "1764",
    14 => "1772",
    15 => "1775",
    16 => "1776",
    17 => "1156",
    18 => "1467",
    19 => "1633",
    20 => "1715",
    21 => "1746",
    22 => "1763",
    23 => "1063",
    24 => "1706",
    25 => "1743",
    26 => "1761",
    27 => "1770",
    28 => "1774",
    29 => "1127",
    30 => "1453",
    31 => "1625",
    32 => "1712"
  }

  describe "constants" do
    test "code_length/0 is 1023" do
      assert CA.code_length() == 1023
    end

    test "chip_rate_hz/0 is 1.023 Mcps" do
      assert CA.chip_rate_hz() == 1_023_000
    end
  end

  describe "code/1" do
    test "returns 1023 chips for several PRNs" do
      for prn <- [1, 2, 19, 24, 32] do
        assert {:ok, chips} = CA.code(prn)
        assert length(chips) == 1023
      end
    end

    test "chips are bipolar ±1" do
      assert {:ok, chips} = CA.code(1)
      assert Enum.all?(chips, &(&1 in [-1, 1]))
    end

    test "invalid PRN returns a tagged error without raising" do
      for prn <- [0, 33, -1, 99] do
        assert CA.code(prn) == {:error, {:unsupported_prn, prn}}
      end
    end
  end

  describe "IS-GPS-200 Table 3-I first-10-chip octal reference" do
    test "matches the published octal for representative PRNs" do
      for {prn, expected_octal} <- @octal_reference do
        assert {:ok, chips} = CA.code(prn)

        # Map bipolar back to raw bits (+1 -> 0, -1 -> 1), MSB-first.
        value =
          chips
          |> Enum.take(10)
          |> Enum.reduce(0, fn chip, acc ->
            bit = if chip == 1, do: 0, else: 1
            acc * 2 + bit
          end)

        octal = Integer.to_string(value, 8)

        assert octal == expected_octal,
               "PRN #{prn}: expected octal #{expected_octal}, got #{octal}"
      end
    end
  end

  describe "balance" do
    test "512 chips of -1, 511 of +1, sum -1 for every supported PRN" do
      for prn <- 1..32 do
        assert {:ok, chips} = CA.code(prn)
        assert length(chips) == 1023
        assert Enum.count(chips, &(&1 == -1)) == 512
        assert Enum.count(chips, &(&1 == 1)) == 511
        assert Enum.sum(chips) == -1
      end
    end
  end

  describe "chip/2" do
    test "chip 0 equals first element of code" do
      assert {:ok, [first | _]} = CA.code(1)
      assert CA.chip(1, 0) == {:ok, first}
    end

    test "index wraps modulo the code length" do
      assert {:ok, c0} = CA.chip(1, 0)
      assert CA.chip(1, 1023) == {:ok, c0}
      assert CA.chip(1, 2046) == {:ok, c0}

      assert {:ok, c1022} = CA.chip(1, 1022)
      assert CA.chip(1, -1) == {:ok, c1022}
    end

    test "invalid PRN returns a tagged error" do
      assert CA.chip(33, 0) == {:error, {:unsupported_prn, 33}}
    end
  end

  describe "autocorrelation" do
    test "peak 1023 at zero lag and three-valued off-peak" do
      assert {:ok, code} = CA.code(1)
      [peak | rest] = CA.autocorrelation(code)

      assert peak == 1023
      refute 1023 in rest
      # All three Gold-code off-peak values must actually occur, not merely a
      # subset; a degenerate code with fewer distinct values must fail.
      assert MapSet.equal?(MapSet.new(rest), @three_valued)
    end
  end

  describe "cross_correlation" do
    test "is exactly three-valued for distinct PRNs" do
      for {a, b} <- [{1, 2}, {19, 24}] do
        assert {:ok, code_a} = CA.code(a)
        assert {:ok, code_b} = CA.code(b)

        values = CA.cross_correlation(code_a, code_b)
        assert length(values) == 1023
        # Set-equality (not subset): all three canonical values must appear.
        assert MapSet.equal?(MapSet.new(values), @three_valued)
      end
    end
  end

  describe "correlation_at/3" do
    test "zero-lag autocorrelation equals the code length" do
      assert {:ok, code} = CA.code(1)
      assert CA.correlation_at(code, code, 0) == 1023
    end

    test "matches the full sequence at a representative lag" do
      assert {:ok, code} = CA.code(1)
      full = CA.autocorrelation(code)
      assert CA.correlation_at(code, code, 7) == Enum.at(full, 7)
    end
  end
end
