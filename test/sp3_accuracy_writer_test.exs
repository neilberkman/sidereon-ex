defmodule Sidereon.GNSS.SP3AccuracyWriterTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.{Data, SP3}

  @fixtures Path.join(__DIR__, "fixtures/sp3/accuracy_merge")
  @sigma_x 0.018189894035458565
  @options [
    combine: :precedence,
    precedence_scope: :cell,
    min_agree: 1,
    clock_min_common: 1,
    position_tolerance_m: 5.0,
    clock_tolerance_s: 50.0e-9,
    outlier_reject: [position_m: 5.0, clock_ns: 50.0],
    systems: [:gps],
    epoch_interval_s: 300.0
  ]

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp parse!(text) do
    assert {:ok, product} = SP3.parse(text)
    product
  end

  defp merge!(sources) do
    assert {:ok, merged, _report} = SP3.merge(sources, @options)
    merged
  end

  defp accuracy(product, satellite, epoch) do
    assert {:ok, value} = SP3.record_accuracy(product, satellite, epoch)
    value
  end

  defp assert_same_accuracy(left, right, satellite) do
    for epoch <- 0..1 do
      assert accuracy(left, satellite, epoch) == accuracy(right, satellite, epoch)
    end
  end

  defp assert_source_round_trips(product, satellite) do
    assert {:ok, strict} = SP3.to_sp3_string(product)
    assert {:ok, rounded, _report} = SP3.to_sp3_string_with_rounding(product)

    for text <- [strict, rounded] do
      assert_same_accuracy(product, parse!(text), satellite)
    end
  end

  defp assert_zero_report(report) do
    assert map_size(report.record_values) == 8
    assert map_size(report.accuracy_sigmas) == 8
    assert Enum.all?(Map.values(report.record_values), &(&1 == 0.0))
    assert Enum.all?(Map.values(report.accuracy_sigmas), &(&1 == 0.0))
  end

  defp fixed(value, decimals, width) do
    value |> :erlang.float_to_binary(decimals: decimals) |> String.pad_leading(width)
  end

  defp code(nil, width), do: String.duplicate(" ", width)
  defp code(value, width), do: value |> Integer.to_string() |> String.pad_leading(width)

  # Change only synthetic header bases and the chosen satellite's accuracy
  # columns. Numeric orbit/clock columns and the shared G02 datum anchor stay fixed.
  defp with_accuracy(name, satellite, position_base, clock_base, x_exponent, clock_exponent) do
    text = fixture(name)
    first_bases = text |> String.split("\n") |> Enum.find(&String.starts_with?(&1, "%f"))

    bases =
      "%f " <>
        fixed(position_base, 7, 10) <>
        " " <>
        fixed(clock_base, 9, 12) <>
        "  0.00000000000  0.000000000000000"

    text
    |> String.replace(first_bases, bases, global: false)
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      if String.starts_with?(line, "P" <> satellite) do
        binary_part(line, 0, 60) <>
          " " <>
          code(x_exponent, 2) <>
          " " <>
          code(nil, 2) <> " " <> code(nil, 2) <> " " <> code(clock_exponent, 3) <> " "
      else
        line
      end
    end)
    |> parse!()
  end

  test "unspecified first bases preserve known and unknown accuracy in either merge order" do
    a = parse!(fixture("A.sp3"))
    b = parse!(fixture("B.sp3"))
    assert_source_round_trips(a, "G01")
    assert_source_round_trips(b, "G12")

    for sources <- [[a, b], [b, a]] do
      merged = merge!(sources)
      assert {:ok, strict} = SP3.to_sp3_string(merged)
      assert {:ok, rounded, _old_report} = SP3.to_sp3_string_with_rounding(merged)

      assert {:ok, detailed, report} =
               SP3.to_sp3_string_with_accuracy_rounding(merged, :conservative)

      assert_zero_report(report)

      for product <- [merged, parse!(strict), parse!(rounded), parse!(detailed)] do
        assert_same_accuracy(a, product, "G01")
        assert_same_accuracy(b, product, "G12")

        for epoch <- 0..1 do
          assert accuracy(product, "G01", epoch).p.position_sigma_m ==
                   {:unknown, :unknown, :unknown}

          assert accuracy(product, "G12", epoch).p.position_sigma_m ==
                   {{:known, @sigma_x}, :unknown, :unknown}
        end
      end
    end
  end

  test "shared clock anchor retains clock accuracy when position and clock bases are reconciled" do
    a = parse!(fixture("A-anchor.sp3"))
    b = parse!(fixture("B-anchor.sp3"))
    assert_source_round_trips(a, "G01")
    assert_source_round_trips(b, "G12")
    assert {:known, clock_sigma} = accuracy(b, "G12", 0).p.clock_sigma_m
    assert clock_sigma > 0.0

    for sources <- [[a, b], [b, a]] do
      merged = merge!(sources)
      assert {:ok, text} = SP3.to_sp3_string(merged)
      assert {:ok, rounded, _} = SP3.to_sp3_string_with_rounding(merged)

      assert {:ok, detailed, report} =
               SP3.to_sp3_string_with_accuracy_rounding(merged, :conservative)

      assert_zero_report(report)

      for output <- [text, rounded, detailed] do
        assert_same_accuracy(b, parse!(output), "G12")
        assert_same_accuracy(a, parse!(output), "G01")
      end
    end
  end

  test "different exactly compatible bases round-trip without changing standard deviations" do
    a = with_accuracy("A-anchor.sp3", "G01", 2.0, 2.0, 2, 2)
    b = with_accuracy("B-anchor.sp3", "G12", 4.0, 4.0, 1, 1)
    assert_source_round_trips(a, "G01")
    assert_source_round_trips(b, "G12")

    for sources <- [[a, b], [b, a]] do
      merged = merge!(sources)
      assert {:ok, strict} = SP3.to_sp3_string(merged)

      assert {:ok, text, report} =
               SP3.to_sp3_string_with_accuracy_rounding(merged, :conservative)

      assert_zero_report(report)

      for output <- [strict, text] do
        reread = parse!(output)
        assert_same_accuracy(a, reread, "G01")
        assert_same_accuracy(b, reread, "G12")
        assert elem(accuracy(reread, "G12", 0).p.position_sigma_m, 0) == {:known, 0.004}
      end
    end
  end

  test "explicit conservative conversion reports position and clock sigma changes without mutating input" do
    a = with_accuracy("A-anchor.sp3", "G01", 2.0, 2.0, 1, 1)
    b = parse!(fixture("B-anchor.sp3"))
    merged = merge!([a, b])
    before = for epoch <- 0..1, do: accuracy(merged, "G12", epoch)
    assert {:error, {:accuracy_not_representable, _}} = SP3.to_sp3_string(merged)
    assert {:error, {:accuracy_not_representable, _}} = SP3.to_sp3_string_with_rounding(merged)

    assert {:ok, text, report} =
             SP3.to_sp3_string_with_accuracy_rounding(merged, :conservative)

    reread = parse!(text)

    for epoch <- 0..1 do
      assert {:known, source_clock} = accuracy(b, "G12", epoch).p.clock_sigma_m
      assert elem(accuracy(reread, "G12", epoch).p.position_sigma_m, 0) == {:known, 0.032}
      assert {:known, output_clock} = accuracy(reread, "G12", epoch).p.clock_sigma_m
      assert output_clock == 2.0 * 299_792_458.0 * 1.0e-12
      assert output_clock >= source_clock
      assert report.accuracy_sigmas.position_sigma_x_m == 0.032 - @sigma_x
      assert report.accuracy_sigmas.clock_sigma_m == output_clock - source_clock
      assert accuracy(merged, "G12", epoch) == Enum.at(before, epoch)
    end

    assert Enum.all?(Map.values(report.record_values), &(&1 == 0.0))

    assert {:ok, ^text, second_report} =
             SP3.to_sp3_string_with_accuracy_rounding(reread, :conservative)

    assert_zero_report(second_report)

    reverse = merge!([b, a])
    assert {:error, {:accuracy_not_representable, _}} = SP3.to_sp3_string(reverse)

    assert {:ok, reverse_text, reverse_report} =
             SP3.to_sp3_string_with_accuracy_rounding(reverse, :conservative)

    reverse_output = parse!(reverse_text)
    assert_same_accuracy(b, reverse_output, "G12")

    for epoch <- 0..1 do
      assert {:ok, %{p: %{axis_exponents: {4, nil, nil}, clock_exponent: 29}}} =
               SP3.record_accuracy_codes(reverse_output, "G01", epoch)

      assert elem(accuracy(reverse_output, "G01", epoch).p.position_sigma_m, 0) ==
               {:known, 0.00244140625}

      assert {:known, original_clock} = accuracy(a, "G01", epoch).p.clock_sigma_m
      assert {:known, converted_clock} = accuracy(reverse_output, "G01", epoch).p.clock_sigma_m
      assert converted_clock >= original_clock
      assert reverse_report.accuracy_sigmas.position_sigma_x_m == 0.00244140625 - 0.002
      assert reverse_report.accuracy_sigmas.clock_sigma_m == converted_clock - original_clock
    end
  end

  test "the lower exponent boundary rounds up but exceeding the largest finite exponent is refused" do
    low_a = with_accuracy("A-anchor.sp3", "G01", 2.0, 1.025, -9, nil)
    low_b = with_accuracy("B-anchor.sp3", "G12", 4.0, 1.025, -5, nil)
    low = merge!([low_a, low_b])
    assert {:error, {:accuracy_not_representable, _}} = SP3.to_sp3_string(low)
    assert {:ok, text, report} = SP3.to_sp3_string_with_accuracy_rounding(low, :conservative)

    assert elem(accuracy(parse!(text), "G12", 0).p.position_sigma_m, 0) ==
             {:known, 1.0 / 512.0 * 1.0e-3}

    assert report.accuracy_sigmas.position_sigma_x_m == 1.0 / 1024.0 * 1.0e-3

    high_a = with_accuracy("A-anchor.sp3", "G01", 1.25, 1.025, 1, nil)
    high_b = with_accuracy("B-anchor.sp3", "G12", 2.0, 1.025, 98, nil)
    assert_source_round_trips(high_a, "G01")
    assert_source_round_trips(high_b, "G12")
    high = merge!([high_a, high_b])
    assert {:error, {:accuracy_not_representable, _}} = SP3.to_sp3_string(high)

    assert {:error, {:accuracy_not_representable, _}} =
             SP3.to_sp3_string_with_accuracy_rounding(high, :conservative)
  end

  test "velocity products preserve all eight sigmas and merged reports follow retained fields" do
    a = parse!(fixture("A-velocity.sp3"))
    b = parse!(fixture("B-velocity.sp3"))
    assert_source_round_trips(a, "G01")
    assert_source_round_trips(b, "G12")

    for {source, satellite} <- [{a, "G01"}, {b, "G12"}] do
      assert {:ok, direct, direct_report} = SP3.to_sp3_string_with_accuracy_rounding(source, :conservative)
      assert_zero_report(direct_report)
      assert_same_accuracy(source, parse!(direct), satellite)
    end

    merged = merge!([a, b])
    assert {:error, {:accuracy_not_representable, _}} = SP3.to_sp3_string(merged)
    assert {:ok, text, report} = SP3.to_sp3_string_with_accuracy_rounding(merged, :conservative)
    reread = parse!(text)
    expected_position = 32.0 * 1.0e-3
    expected_clock = 2.0 * (299_792_458.0 * 1.0e-12)

    for epoch <- 0..1 do
      before = accuracy(b, "G12", epoch)
      after_write = accuracy(reread, "G12", epoch)

      assert after_write.p.position_sigma_m ==
               {{:known, expected_position}, {:known, expected_position}, {:known, expected_position}}

      # Merge deliberately emits position/clock products; it drops V records.
      assert after_write.v == nil

      assert after_write.p.clock_sigma_m == {:known, expected_clock}
      assert {:known, source_position} = elem(before.p.position_sigma_m, 0)
      assert {:known, source_velocity} = elem(before.v.velocity_sigma_m_s, 0)
      assert {:known, source_clock} = before.p.clock_sigma_m
      assert {:known, source_clock_rate} = before.v.clock_rate_sigma_m_s
      assert source_clock_rate > 0.0
      assert source_position == @sigma_x
      assert source_velocity == 1_220_703_125.0 / 67_108_864.0 * 1.0e-7

      assert report.accuracy_sigmas == %{
               position_sigma_x_m: expected_position - source_position,
               position_sigma_y_m: expected_position - source_position,
               position_sigma_z_m: expected_position - source_position,
               velocity_sigma_x_m_s: 0.0,
               velocity_sigma_y_m_s: 0.0,
               velocity_sigma_z_m_s: 0.0,
               clock_sigma_m: expected_clock - source_clock,
               clock_rate_sigma_m_s: 0.0
             }

      assert accuracy(merged, "G12", epoch).p == before.p
      assert accuracy(merged, "G12", epoch).v == nil
    end

    assert Enum.all?(Map.values(report.record_values), &(&1 == 0.0))
    assert {:ok, ^text, second_report} = SP3.to_sp3_string_with_accuracy_rounding(reread, :conservative)
    assert_zero_report(second_report)
  end

  test "clock accuracy obeys the three-column finite exponent boundaries" do
    a = with_accuracy("A-anchor.sp3", "G01", 1.25, 2.0, nil, -99)
    b = with_accuracy("B-anchor.sp3", "G12", 1.25, 4.0, nil, -50)
    assert_source_round_trips(a, "G01")
    assert_source_round_trips(b, "G12")
    merged = merge!([a, b])
    assert {:error, {:accuracy_not_representable, %{component: "clock"}}} = SP3.to_sp3_string(merged)
    assert {:ok, text, report} = SP3.to_sp3_string_with_accuracy_rounding(merged, :conservative)
    reread = parse!(text)
    scale = 299_792_458.0 * 1.0e-12
    source_sigma = 1.0 / Integer.pow(2, 100) * scale
    output_sigma = 1.0 / Integer.pow(2, 99) * scale

    for epoch <- 0..1 do
      assert accuracy(b, "G12", epoch).p.clock_sigma_m == {:known, source_sigma}
      assert accuracy(reread, "G12", epoch).p.clock_sigma_m == {:known, output_sigma}
      assert accuracy(merged, "G12", epoch).p.clock_sigma_m == {:known, source_sigma}
      assert {:ok, %{p: %{clock_exponent: -99}}} = SP3.record_accuracy_codes(reread, "G12", epoch)
    end

    assert report.accuracy_sigmas.clock_sigma_m == output_sigma - source_sigma
    high_a = with_accuracy("A-anchor.sp3", "G01", 1.25, 1.025, nil, 1)
    high_b = with_accuracy("B-anchor.sp3", "G12", 1.25, 2.0, nil, 998)
    assert_source_round_trips(high_a, "G01")
    assert_source_round_trips(high_b, "G12")
    high = merge!([high_a, high_b])

    assert {:error, {:accuracy_not_representable, %{component: "clock", exponent: 998}}} =
             SP3.to_sp3_string(high)

    assert {:error, {:accuracy_not_representable, %{component: "clock", exponent: 998}}} =
             SP3.to_sp3_string_with_accuracy_rounding(high, :conservative)

    assert_same_accuracy(high_b, high, "G12")
  end

  test "strict base conversion also preserves the actual decoded floating-point uncertainty" do
    a = with_accuracy("A-anchor.sp3", "G01", 3.375, 1.025, 17, nil)
    b = with_accuracy("B-anchor.sp3", "G12", 1.5, 1.025, 51, nil)
    assert_source_round_trips(a, "G01")
    assert_source_round_trips(b, "G12")

    for sources <- [[a, b], [b, a]] do
      merged = merge!(sources)
      assert_same_accuracy(a, merged, "G01")
      assert_same_accuracy(b, merged, "G12")

      # Equivalent rational powers can decode one floating-point step apart.
      # A strict success must preserve the actual decoded values on this target.
      case SP3.to_sp3_string(merged) do
        {:ok, text} ->
          output = parse!(text)
          assert_same_accuracy(a, output, "G01")
          assert_same_accuracy(b, output, "G12")

        {:error, {:accuracy_not_representable, %{component: "position x"}}} ->
          assert elem(accuracy(a, "G01", 0).p.position_sigma_m, 0) !=
                   elem(accuracy(b, "G12", 0).p.position_sigma_m, 0)
      end
    end
  end

  test "missing and unknown policies never enable accuracy conversion" do
    product = parse!(fixture("B.sp3"))
    refute function_exported?(SP3, :to_sp3_string_with_accuracy_rounding, 1)

    for policy <- [nil, :nearest, :unknown, "conservative", 0, %{}] do
      assert {:error, :invalid_accuracy_rounding_policy} =
               SP3.to_sp3_string_with_accuracy_rounding(product, policy)
    end
  end

  test "accuracy sentinels retain their meaning and invalid-base codes are never silently dropped" do
    a = parse!(fixture("A-anchor.sp3"))
    sentinel_b = with_accuracy("B-anchor.sp3", "G12", 1.25, 1.025, 99, 999)
    assert_source_round_trips(sentinel_b, "G12")

    for sources <- [[a, sentinel_b], [sentinel_b, a]] do
      merged = merge!(sources)

      assert {:ok, text, report} =
               SP3.to_sp3_string_with_accuracy_rounding(merged, :conservative)

      assert_zero_report(report)
      reread = parse!(text)
      assert_same_accuracy(sentinel_b, reread, "G12")

      for epoch <- 0..1 do
        assert elem(accuracy(reread, "G12", epoch).p.position_sigma_m, 0) == :too_large
        assert accuracy(reread, "G12", epoch).p.clock_sigma_m == :too_large
        assert {:ok, %{p: codes}} = SP3.record_accuracy_codes(reread, "G12", epoch)
        assert elem(codes.axis_exponents, 0) == 99
        assert codes.clock_exponent == 999
      end
    end

    invalid_a = with_accuracy("A-anchor.sp3", "G01", 0.0, 0.0, 13, 13)
    b = parse!(fixture("B-anchor.sp3"))
    assert_source_round_trips(invalid_a, "G01")

    assert {:ok, invalid_text, invalid_report} =
             SP3.to_sp3_string_with_accuracy_rounding(invalid_a, :conservative)

    assert_zero_report(invalid_report)
    assert_same_accuracy(invalid_a, parse!(invalid_text), "G01")

    for sources <- [[invalid_a, b], [b, invalid_a]] do
      merged = merge!(sources)
      assert_same_accuracy(invalid_a, merged, "G01")
      assert {:error, {:accuracy_not_representable, _}} = SP3.to_sp3_string(merged)

      assert {:error, {:accuracy_not_representable, _}} =
               SP3.to_sp3_string_with_accuracy_rounding(merged, :conservative)
    end
  end

  test "atomic gzip output returns the detailed report and refusal preserves an existing file" do
    dir = Path.join(System.tmp_dir!(), "sidereon-accuracy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "product.sp3.gz")
    merged = merge!([parse!(fixture("A-anchor.sp3")), parse!(fixture("B-anchor.sp3"))])
    assert {:ok, ^path, report} = Data.write_sp3_with_accuracy_rounding(merged, path, :conservative, gzip: true)
    assert_zero_report(report)
    assert_same_accuracy(merged, parse!(:zlib.gunzip(File.read!(path))), "G12")

    high_a = with_accuracy("A-anchor.sp3", "G01", 1.25, 1.025, 1, nil)
    high_b = with_accuracy("B-anchor.sp3", "G12", 2.0, 1.025, 98, nil)
    previous = File.read!(path)

    assert {:error, {:accuracy_not_representable, _}} =
             Data.write_sp3_with_accuracy_rounding(merge!([high_a, high_b]), path, :conservative)

    assert File.read!(path) == previous
  end
end
