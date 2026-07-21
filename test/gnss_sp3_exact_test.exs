defmodule Sidereon.GNSS.SP3ExactTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.SP3
  alias Sidereon.TestSupport.ExactSp3Fixture

  @date ~D[2020-01-01]
  @terminal_record_corpus Path.join(__DIR__, "fixtures/sp3-terminal-record-v1.json")

  test "public exact parser obeys the shared terminal-record corpus" do
    corpus = @terminal_record_corpus |> File.read!() |> Jason.decode!()
    assert corpus["schema"] == "sidereon-sp3-terminal-record-v1"
    assert corpus["record_width"] == 80
    assert corpus["record_width_authority"] == "sidereon-interoperability-policy"

    {:ok, request} = SP3.ExactRequest.new(@date, "01H", "05M", issue: "0000")
    base = ExactSp3Fixture.build(@date, span_s: 3_600)

    for entry <- corpus["cases"] do
      result = base |> terminal_case_bytes(entry) |> SP3.parse_exact(request)

      assert terminal_result_class(result) == entry["expect"],
             "terminal-record corpus case #{entry["name"]}"
    end
  end

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

  test "identity-derived historical GFZ ultra request accepts its cataloged prior-day content start" do
    filename_date = ~D[2022-09-04]
    content_date = ~D[2022-09-03]

    {:ok, product} = Data.ops_ultra_sp3(:gfz_ult, filename_date, issue: "0000")
    {:ok, identity} = Data.identity(product)
    {:ok, request} = SP3.ExactRequest.from_identity(identity)

    bytes =
      ExactSp3Fixture.build(filename_date,
        content_date: content_date,
        issue: "0000",
        span_s: 2 * 86_400,
        agency: "GFZ"
      )

    assert request.date == filename_date
    assert {:ok, parsed, :half_open} = SP3.parse_exact(bytes, request)
    assert SP3.epoch_count(parsed) == 576

    {:ok, same_date_request} =
      SP3.ExactRequest.new(filename_date, "02D", "05M",
        issue: "0000",
        expected_agency: "GFZ"
      )

    assert {:error, {:exact_sp3_validation_failed, message}} =
             SP3.parse_exact(bytes, same_date_request)

    assert message =~ "declared start"
  end

  defp request! do
    {:ok, request} = SP3.ExactRequest.new(@date, "01D", "05M", issue: "0000")
    request
  end

  defp terminal_case_bytes(base, entry) do
    true = String.ends_with?(base, "EOF\n")
    prefix_size = byte_size(base) - byte_size("EOF\n")
    <<prefix::binary-size(^prefix_size), "EOF\n">> = base

    prefix <>
      decode_hex(entry["leading_hex"]) <>
      (entry["marker"] || "") <>
      String.duplicate(" ", entry["padding_spaces"]) <>
      decode_hex(entry["suffix_hex"]) <>
      decode_hex(entry["separator_hex"]) <>
      decode_hex(entry["trailing_hex"])
  end

  defp decode_hex(""), do: ""
  defp decode_hex(value), do: value |> String.upcase() |> Base.decode16!()

  defp terminal_result_class({:ok, %SP3{}, coverage}) when coverage in [:half_open, :inclusive], do: "accept"

  defp terminal_result_class({:error, {:exact_sp3_validation_failed, message}}) do
    cond do
      String.contains?(message, "malformed EOF record") -> "malformed_eof_record"
      String.contains?(message, "missing its EOF record") -> "missing_eof"
      String.contains?(message, "nonblank records after EOF") -> "trailing_content_after_eof"
      true -> flunk("terminal corpus reached unrelated exact error: #{inspect(message)}")
    end
  end

  defp terminal_result_class(other), do: flunk("terminal corpus returned an unexpected result: #{inspect(other)}")
end
