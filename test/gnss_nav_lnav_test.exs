defmodule Sidereon.GNSS.Navigation.LNAVTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Navigation.LNAV
  alias Sidereon.GNSS.Navigation.LNAV.Ephemeris

  # Per-field LSB scale factors (IS-GPS-200 Tables 20-I/II/III). Quantize the
  # input by these before comparing, so the test proves the bit packing rather
  # than float exactness.
  @lsb %{
    tgd: :math.pow(2, -31),
    toc: 16,
    af0: :math.pow(2, -31),
    af1: :math.pow(2, -43),
    af2: :math.pow(2, -55),
    crs: :math.pow(2, -5),
    delta_n: :math.pow(2, -43),
    m0: :math.pow(2, -31),
    cuc: :math.pow(2, -29),
    eccentricity: :math.pow(2, -33),
    cus: :math.pow(2, -29),
    sqrt_a: :math.pow(2, -19),
    toe: 16,
    cic: :math.pow(2, -29),
    omega0: :math.pow(2, -31),
    cis: :math.pow(2, -29),
    i0: :math.pow(2, -31),
    crc: :math.pow(2, -5),
    omega: :math.pow(2, -31),
    omega_dot: :math.pow(2, -43),
    idot: :math.pow(2, -43)
  }

  @integer_fields [
    :week_number,
    :l2_code,
    :ura_index,
    :sv_health,
    :iodc,
    :iode,
    :fit_interval_flag,
    :aodo
  ]

  defp quantize(value, lsb), do: round(value / lsb) * lsb

  defp params, do: Ephemeris.example()

  describe "round-trip encode/decode" do
    test "recovers every scaled field within its LSB" do
      p = params()
      {:ok, sfs} = LNAV.encode(p, tow: 12_345)
      {:ok, d} = LNAV.decode(sfs)

      for {field, lsb} <- @lsb do
        input = Map.fetch!(p, field)
        decoded = Map.fetch!(d, field)
        expected = quantize(input, lsb)

        assert_in_delta decoded,
                        expected,
                        lsb / 2,
                        "field #{field}: decoded=#{decoded} expected=#{expected} lsb=#{lsb}"
      end
    end

    test "recovers every integer field exactly" do
      p = params()
      {:ok, sfs} = LNAV.encode(p)
      {:ok, d} = LNAV.decode(sfs)

      for field <- @integer_fields do
        assert Map.fetch!(d, field) == Map.fetch!(p, field), "integer field #{field}"
      end
    end

    test "negative signed values keep their sign" do
      p = params()
      {:ok, sfs} = LNAV.encode(p)
      {:ok, d} = LNAV.decode(sfs)

      assert d.tgd < 0
      assert d.af0 < 0
      assert d.af1 < 0
      assert d.crs < 0
      assert d.m0 < 0
      assert d.cuc < 0
      assert d.cis < 0
      assert d.omega0 < 0
      assert d.omega_dot < 0
    end

    test "near-full-scale signed values round-trip" do
      # M0 spans the full 32-bit signed range; near -1 semicircle is large.
      p = %{params() | m0: -0.9999999, omega0: 0.9999999, idot: -3.0e-10}
      {:ok, sfs} = LNAV.encode(p)
      {:ok, d} = LNAV.decode(sfs)

      assert_in_delta d.m0, quantize(p.m0, @lsb.m0), @lsb.m0 / 2
      assert_in_delta d.omega0, quantize(p.omega0, @lsb.omega0), @lsb.omega0 / 2
      assert_in_delta d.idot, quantize(p.idot, @lsb.idot), @lsb.idot / 2
    end

    test "IODC split across words 3 and 8 recovers exactly" do
      # 0x2AB sets both the 2 MSBs (word 3) and 8 LSBs (word 8).
      p = %{params() | iodc: 0x2AB}
      {:ok, sfs} = LNAV.encode(p)
      {:ok, d} = LNAV.decode(sfs)
      assert d.iodc == 0x2AB
    end
  end

  describe "parity" do
    test "matches IS-GPS-200 Table 20-XIV for a known word with nonzero prior parity" do
      # Asymmetric 24-bit source word; the two trailing parity bits of the
      # previous word (D29*, D30*) feed the result. These expected vectors are
      # the (32, 26) Hamming parity of IS-GPS-200 Table 20-XIV; a nonzero prior
      # pair exercises the D29*/D30* wiring that an all-zero seed would mask.
      data = [1, 0, 1, 1, 0, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 1]

      assert LNAV.parity(data, 1, 0) == [0, 1, 1, 0, 1, 1]
      assert LNAV.parity(data, 0, 1) == [1, 0, 0, 1, 0, 0]
    end

    test "all 30 words satisfy parity with chained D29*/D30*" do
      {:ok, sfs} = LNAV.encode(params(), tow: 777)

      for sf <- [1, 2, 3] do
        words = Enum.chunk_every(sfs[sf], 30)

        {:ok, _} =
          Enum.reduce(words, {0, 0}, fn word, {d29p, d30p} ->
            assert LNAV.parity_valid?(word, d29p, d30p), "subframe #{sf} word parity"
            [d29, d30] = Enum.slice(word, 28, 2)
            {d29, d30}
          end)
          |> then(&{:ok, &1})
      end
    end

    test "flipping a single data bit makes parity fail" do
      {:ok, sfs} = LNAV.encode(params())

      # Flip bit in word 3 (index 60..83) of subframe 2; word 3 follows the
      # HOW whose trailing parity feeds it.
      sf2 = sfs[2]
      words = Enum.chunk_every(sf2, 30)
      [_w1, w2, w3 | _] = words
      [d29p, d30p] = Enum.slice(w2, 28, 2)

      for flip_pos <- [0, 5, 12, 23] do
        corrupted = List.update_at(w3, flip_pos, fn b -> Bitwise.bxor(b, 1) end)
        refute LNAV.parity_valid?(corrupted, d29p, d30p), "flip at #{flip_pos} should fail"
      end
    end

    test "decode reports parity_failed on a corrupted subframe" do
      {:ok, sfs} = LNAV.encode(params())
      # Corrupt a data bit in subframe 1 word 3 (bit index 60).
      corrupted = List.update_at(sfs[1], 60, fn b -> Bitwise.bxor(b, 1) end)
      assert {:error, {:parity_failed, 1, 3}} = LNAV.decode(%{sfs | 1 => corrupted})
    end

    test "HOW (word 2) trailing parity bits are zero" do
      {:ok, sfs} = LNAV.encode(params())

      for sf <- [1, 2, 3] do
        how = Enum.slice(sfs[sf], 30, 30)
        assert Enum.slice(how, 28, 2) == [0, 0], "subframe #{sf} HOW t-bits"
      end
    end

    test "word 10 trailing parity bits are zero" do
      {:ok, sfs} = LNAV.encode(params())

      for sf <- [1, 2, 3] do
        word10 = Enum.slice(sfs[sf], 270, 30)
        assert Enum.slice(word10, 28, 2) == [0, 0], "subframe #{sf} word10 t-bits"
      end
    end
  end

  describe "structure" do
    test "preamble constant is 0x8B" do
      assert LNAV.preamble() == 0x8B
    end

    test "word 1 preamble is 0x8B in each subframe" do
      {:ok, sfs} = LNAV.encode(params())

      for sf <- [1, 2, 3] do
        preamble_bits = Enum.slice(sfs[sf], 0, 8)
        value = Enum.reduce(preamble_bits, 0, fn b, acc -> acc * 2 + b end)
        assert value == 0x8B
      end
    end

    test "HOW carries the supplied TOW and correct subframe ID" do
      {:ok, sfs} = LNAV.encode(params(), tow: 54_321)

      for sf <- [1, 2, 3] do
        assert LNAV.tow(sfs[sf]) == {:ok, 54_321}
        assert LNAV.subframe_id(sfs[sf]) == {:ok, sf}
        assert LNAV.tow!(sfs[sf]) == 54_321
        assert LNAV.subframe_id!(sfs[sf]) == sf
      end
    end

    test "each subframe is 300 bits, each word 30 bits" do
      {:ok, sfs} = LNAV.encode(params())

      for sf <- [1, 2, 3] do
        assert length(sfs[sf]) == 300
        assert Enum.all?(Enum.chunk_every(sfs[sf], 30), &(length(&1) == 30))
      end
    end

    test "length constants" do
      assert LNAV.word_length() == 30
      assert LNAV.subframe_length() == 300
    end
  end

  describe "error path (no raise)" do
    test "out-of-range week number returns a tagged error" do
      p = %{params() | week_number: 2000}
      assert {:error, {:out_of_range, :week_number, 2000}} = LNAV.encode(p)
    end

    test "out-of-range URA index returns a tagged error" do
      p = %{params() | ura_index: 99}
      assert {:error, {:out_of_range, :ura_index, 99}} = LNAV.encode(p)
    end

    test "signed field beyond two's-complement range returns a tagged error" do
      # toc has a 16-bit range with LSB 16 -> max 65535*16; far beyond it errors.
      p = %{params() | m0: 5.0}
      assert {:error, {:out_of_range, :m0, 5.0}} = LNAV.encode(p)
    end

    test "an out-of-range 1-bit flag is rejected, not silently truncated" do
      # alert/anti_spoof/integrity are single-bit HOW/TLM fields; a value that
      # does not fit one bit must error rather than have its high bits dropped.
      assert {:error, {:out_of_range, :alert, 2}} = LNAV.encode(params(), alert: 2)
      assert {:error, {:out_of_range, :anti_spoof, 2}} = LNAV.encode(params(), anti_spoof: 2)
      assert {:error, {:out_of_range, :integrity, 5}} = LNAV.encode(params(), integrity: 5)
    end

    test "HOW field helpers return tagged bad_length errors" do
      bits = List.duplicate(0, 29)

      assert LNAV.tow(bits) == {:error, :bad_length}
      assert LNAV.subframe_id(bits) == {:error, :bad_length}

      assert_raise ArgumentError, fn -> LNAV.tow!(bits) end
      assert_raise ArgumentError, fn -> LNAV.subframe_id!(bits) end
    end
  end
end
