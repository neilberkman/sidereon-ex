defmodule Sidereon.GNSS.SP3ExactTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.SP3
  alias Sidereon.TestSupport.ExactSp3Fixture

  @date ~D[2020-01-01]

  test "accepts both official one-day five-minute boundary representations" do
    request = request!()

    half_open = ExactSp3Fixture.build(@date, count: 288, coverage: :half_open)
    assert {:ok, half_open_product, :half_open} = SP3.parse_exact(half_open, request)
    assert SP3.epoch_count(half_open_product) == 288
    assert SP3.declared_epoch_count(half_open_product) == 288

    inclusive = ExactSp3Fixture.build(@date, count: 289, coverage: :inclusive)
    assert {:ok, inclusive_product, :inclusive} = SP3.parse_exact(inclusive, request)
    assert SP3.epoch_count(inclusive_product) == 289
    assert SP3.declared_epoch_count(inclusive_product) == 289
  end

  test "declared header accessors remain distinct from the parsed grid" do
    bytes = ExactSp3Fixture.build(@date, count: 288, declared_count: 287)
    assert {:ok, product} = SP3.parse(bytes)
    assert SP3.epoch_count(product) == 288
    assert SP3.declared_epoch_count(product) == 287
    assert is_float(SP3.declared_start_j2000_seconds(product))
    assert SP3.declared_start_j2000_s(product) == SP3.declared_start_j2000_seconds(product)

    assert {:error, {:exact_sp3_validation_failed, message}} =
             SP3.validate_exact(product, request!())

    assert message =~ "header declares 287, parsed 288"
  end

  test "rejects shorter, longer, and irregular parsed grids" do
    request = request!()

    for count <- [287, 290] do
      bytes = ExactSp3Fixture.build(@date, count: count)

      assert {:error, {:exact_sp3_validation_failed, message}} =
               SP3.parse_exact(bytes, request)

      assert message =~ "span mismatch"
    end

    offsets = ExactSp3Fixture.regular_offsets(288, 300) |> List.replace_at(100, 30_001)
    irregular = ExactSp3Fixture.build(@date, offsets_s: offsets, count: 288)

    assert {:error, {:exact_sp3_validation_failed, message}} =
             SP3.parse_exact(irregular, request)

    assert message =~ "irregular"
  end

  test "rejects zero, non-finite, and mismatched header cadence" do
    request = request!()

    for {cadence, expected} <- [
          {"0.00000000", "positive"},
          {"NaN", "finite"},
          {"inf", "finite"},
          {"900.00000000", "cadence mismatch"}
        ] do
      bytes = ExactSp3Fixture.build(@date, header_cadence: cadence)

      assert {:error, {:exact_sp3_validation_failed, message}} =
               SP3.parse_exact(bytes, request)

      assert message =~ expected
    end
  end

  test "rejects unknown, zero, and noncanonical requested sample tokens" do
    for sample <- ["00M", "00U", "05X", "60M", "24H", "05m"] do
      assert {:error, {:exact_sp3_validation_failed, _message}} =
               SP3.ExactRequest.new(@date, "01D", sample, issue: "0000")
    end
  end

  test "an identity-derived agency mismatch is terminal" do
    {:ok, required} = SP3.ExactRequest.new(@date, "01D", "05M", expected_agency: "IGS")
    wrong = ExactSp3Fixture.build(@date, agency: "TST")

    assert {:error, {:exact_sp3_validation_failed, message}} =
             SP3.parse_exact(wrong, required)

    assert message =~ "agency mismatch"

    matching = ExactSp3Fixture.build(@date, agency: "IGS")
    assert {:ok, _product, :half_open} = SP3.parse_exact(matching, required)
  end

  defp request! do
    {:ok, request} = SP3.ExactRequest.new(@date, "01D", "05M", issue: "0000")
    request
  end
end
