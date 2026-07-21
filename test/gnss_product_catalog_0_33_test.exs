defmodule Sidereon.GNSS.ProductCatalog033Test do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Distribution

  test "IGS final SP3 naming and CDDIS packaging follow the historical era" do
    assert {:error, {:unsupported_product, _reason}} = Data.mgex_sp3(:igs, ~D[1994-01-01])

    assert {:ok, first} = Data.mgex_sp3(:igs, ~D[1994-01-02])
    assert {:ok, "igs07300.sp3"} = Data.canonical_filename(first)

    assert {:ok, legacy} = Data.mgex_sp3(:igs, ~D[2022-11-26])
    assert {:ok, "igs22376.sp3"} = Data.canonical_filename(legacy)
    assert {:ok, legacy_identity} = Data.identity(legacy)

    assert {:ok,
            %{
              source: :nasa_cddis,
              compression: :unix_compress,
              archive_filename: "igs22376.sp3.Z",
              original_url: "https://cddis.nasa.gov/archive/gnss/products/2237/igs22376.sp3.Z"
            }} = Distribution.location(legacy_identity, :nasa_cddis)

    assert {:error, {:unsupported_product, _reason}} =
             Distribution.location(legacy_identity, :direct)

    assert {:ok, current} = Data.mgex_sp3(:igs, ~D[2022-11-27])
    assert {:ok, "IGS0OPSFIN_20223310000_01D_15M_ORB.SP3"} = Data.canonical_filename(current)
    assert {:ok, current_identity} = Data.identity(current)

    assert {:ok,
            %{
              source: :nasa_cddis,
              compression: :gzip,
              archive_filename: "IGS0OPSFIN_20223310000_01D_15M_ORB.SP3.gz"
            }} = Distribution.location(current_identity, :nasa_cddis)
  end

  test "IGS broadcast navigation remains broadcast and keeps its derivation" do
    assert {:ok, "final"} = Data.product_solution_class(:igs, :sp3)
    assert {:ok, "broadcast"} = Data.product_solution_class(:igs, :nav)

    assert {:ok, nav} = Data.mgex_nav(:igs, ~D[2022-11-26])
    assert {:ok, "BRDC00WRD_R_20223300000_01D_MN.rnx"} = Data.canonical_filename(nav)
    assert {:ok, identity} = Data.identity(nav)
    assert identity.solution_class == "broadcast"
    assert identity.campaign == "BRD"
    assert identity.format == "RINEX_NAV"
  end

  test "dated GFZ rapid defaults preserve the documented cadence transition" do
    assert {:ok, "05M"} = Data.default_sample(:gfz, :sp3)
    assert {:ok, "15M"} = Data.default_sample_for_date(:gfz, :sp3, ~D[2021-05-17])
    assert {:ok, "05M"} = Data.default_sample_for_date(:gfz, :sp3, ~D[2021-05-18])

    assert {:ok, before} = Data.mgex_sp3(:gfz, ~D[2021-05-17])
    assert {:ok, after_transition} = Data.mgex_sp3(:gfz, ~D[2021-05-18])
    assert before.sample == "15M"
    assert after_transition.sample == "05M"
    assert {:ok, before_identity} = Data.identity(before)
    assert {:ok, after_identity} = Data.identity(after_transition)
    assert before_identity.sample == "15M"
    assert after_identity.sample == "05M"
  end

  test "supported samples expose exact catalog lines and constructors enforce them" do
    assert {:ok, ["05M"]} = Data.supported_samples(:esa, :sp3, ~D[2026-06-15])

    assert {:error, {:unsupported_product, reason}} =
             Data.mgex_sp3(:esa, ~D[2026-06-15], sample: "15M")

    assert reason =~ "does not publish sample interval"

    assert {:ok, ["15M"]} = Data.supported_samples(:gfz, :sp3, ~D[2021-05-17])
    assert {:ok, ["05M"]} = Data.supported_samples(:gfz, :sp3, ~D[2021-05-18])

    assert {:error, {:unsupported_product, reason}} =
             Data.mgex_sp3(:gfz, ~D[2021-05-17], sample: "05M")

    assert reason =~ "does not publish sample interval"

    assert {:ok, ["15M"]} =
             Data.supported_samples(:esa_ult, :sp3, ~D[2025-02-02], "0600")

    assert {:ok, ["05M"]} =
             Data.supported_samples(:esa_ult, :sp3, ~D[2025-02-02], "1200")

    assert {:error, {:unsupported_product, reason}} =
             Data.ops_ultra_sp3(:esa_ult, ~D[2025-02-02], issue: "0600", sample: "05M")

    assert reason =~ "does not publish sample interval"

    assert {:ok, ["15M", "05M"]} =
             Data.supported_samples(:gfz_ult, :sp3, ~D[2021-05-15])

    assert {:ok, ["15M", "05M"]} =
             Data.supported_samples(:gfz_ult, :sp3, ~D[2021-05-15], "0000")

    assert {:ok, ["15M"]} =
             Data.supported_samples(:gfz_ult, :sp3, ~D[2021-05-15], "2100")

    assert {:error, {:unsupported_product, reason}} =
             Data.ops_ultra_sp3(:gfz_ult, ~D[2021-05-15], issue: "2100", sample: "05M")

    assert reason =~ "does not publish sample interval"
  end

  test "supported samples enforce issue rules" do
    assert {:error, {:unsupported_product, reason}} =
             Data.supported_samples(:esa_ult, :sp3, ~D[2025-02-02], "0130")

    assert reason =~ "does not publish issue"

    assert {:error, {:unsupported_product, reason}} =
             Data.supported_samples(:esa_ult, :sp3, ~D[2025-02-02], "2400")

    assert reason =~ "invalid issue time"

    assert {:error, {:unsupported_product, reason}} =
             Data.supported_samples(:esa, :sp3, ~D[2025-02-02], "0000")

    assert reason =~ "does not take an issue"
  end

  test "verified SP3 family floors reject invented earlier products and CDDIS paths" do
    for {center, day_before, first_day, expected_sample} <- [
          {:esa, ~D[2014-01-04], ~D[2014-01-05], "05M"},
          {:gfz, ~D[2020-05-12], ~D[2020-05-13], "15M"}
        ] do
      assert {:error, {:unsupported_product, _reason}} = Data.mgex_sp3(center, day_before)
      assert {:ok, product} = Data.mgex_sp3(center, first_day)
      assert product.sample == expected_sample
      assert {:ok, identity} = Data.identity(product)

      assert {:error, {:unsupported_product, _reason}} =
               Distribution.location(identity, :nasa_cddis)
    end

    assert {:error, {:unsupported_product, _reason}} =
             Data.ops_ultra_sp3(:igs_ult, ~D[2022-11-26], issue: "0000")

    assert {:ok, igs_ult} = Data.ops_ultra_sp3(:igs_ult, ~D[2022-11-27], issue: "0000")
    assert igs_ult.sample == "15M"

    assert {:ok, "IGS0OPSULT_20223310000_02D_15M_ORB.SP3"} =
             Data.canonical_filename(igs_ult)

    for {center, day_before, first_day} <- [
          {:esa_ult, ~D[2022-10-03], ~D[2022-10-04]},
          {:gfz_ult, ~D[2020-10-05], ~D[2020-10-06]}
        ] do
      assert {:error, {:unsupported_product, _reason}} =
               Data.ops_ultra_sp3(center, day_before, issue: "0000")

      assert {:ok, product} = Data.ops_ultra_sp3(center, first_day, issue: "0000")
      assert product.sample == "15M"
      assert {:ok, identity} = Data.identity(product)

      assert {:error, {:unsupported_product, _reason}} =
               Distribution.location(identity, :nasa_cddis)
    end
  end

  test "ultra-rapid defaults follow issue-aware ESA and dated GFZ cadence eras" do
    assert {:ok, "15M"} = Data.default_sample_for_date(:esa_ult, :sp3, ~D[2024-09-03])
    assert {:ok, "15M"} = Data.default_sample_for_date(:esa_ult, :sp3, ~D[2025-02-02])

    assert {:ok, esa_0600} =
             Data.ops_ultra_sp3(:esa_ult, ~D[2025-02-02], issue: "0600")

    assert {:ok, esa_1200} =
             Data.ops_ultra_sp3(:esa_ult, ~D[2025-02-02], issue: "1200")

    assert esa_0600.sample == "15M"
    assert esa_1200.sample == "05M"

    assert {:ok, generic_0600} = Data.product(:esa_ult, :sp3, ~D[2025-02-02], issue: "0600")
    assert {:ok, generic_1200} = Data.product(:esa_ult, :sp3, ~D[2025-02-02], issue: "1200")
    assert generic_0600.sample == esa_0600.sample
    assert generic_1200.sample == esa_1200.sample

    assert {:ok, esa_0600_name} = Data.canonical_filename(esa_0600)
    assert {:ok, esa_1200_name} = Data.canonical_filename(esa_1200)
    assert Data.canonical_filename(generic_0600) == {:ok, esa_0600_name}
    assert Data.canonical_filename(generic_1200) == {:ok, esa_1200_name}
    assert String.ends_with?(esa_0600_name, "_02D_15M_ORB.SP3")
    assert String.ends_with?(esa_1200_name, "_02D_05M_ORB.SP3")

    assert {:ok, "15M"} = Data.default_sample_for_date(:gfz_ult, :sp3, ~D[2021-05-15])
    assert {:ok, "05M"} = Data.default_sample_for_date(:gfz_ult, :sp3, ~D[2021-05-16])

    assert {:ok, gfz_before} =
             Data.ops_ultra_sp3(:gfz_ult, ~D[2021-05-15], issue: "2100")

    assert {:ok, gfz_after} =
             Data.ops_ultra_sp3(:gfz_ult, ~D[2021-05-16], issue: "0000")

    assert gfz_before.sample == "15M"
    assert gfz_after.sample == "05M"
  end

  test "GFZ ultra filename epochs map to cataloged content starts across the 2022 transition" do
    minus_one_day = %Data.Sp3ContentStartConvention{
      value: :filename_epoch_minus_one_day,
      content_start_offset_s: -86_400
    }

    aligned = %Data.Sp3ContentStartConvention{
      value: :filename_epoch,
      content_start_offset_s: 0
    }

    assert {:ok, ^minus_one_day} =
             Data.sp3_content_start_convention(:gfz_ult, ~D[2022-09-06], "2100")

    assert {:ok, ^aligned} =
             Data.sp3_content_start_convention(:gfz_ult, ~D[2022-09-07], "0000")

    assert {:ok, ^minus_one_day} =
             Data.sp3_content_start_convention(:gfz_ult, ~D[2022-09-07], "0300")

    assert {:ok, ^minus_one_day} =
             Data.sp3_content_start_convention(:gfz_ult, ~D[2022-09-08], "0600")

    assert {:ok, ^aligned} =
             Data.sp3_content_start_convention(:gfz_ult, ~D[2022-09-08], "0900")

    assert {:ok, ^aligned} =
             Data.sp3_content_start_convention(:gfz_ult, ~D[2022-09-09], "2100")
  end

  test "SP3 content-start queries enforce exact issue semantics" do
    assert {:error, {:unsupported_product, _reason}} =
             Data.sp3_content_start_convention(:gfz_ult, ~D[2022-09-08])

    assert {:error, {:unsupported_product, _reason}} =
             Data.sp3_content_start_convention(:gfz_ult, ~D[2022-09-08], "0130")

    assert {:error, {:unsupported_product, _reason}} =
             Data.sp3_content_start_convention(:gfz, ~D[2022-09-08], "0000")

    assert {:ok,
            %Data.Sp3ContentStartConvention{
              value: :filename_epoch,
              content_start_offset_s: 0
            }} = Data.sp3_content_start_convention(:gfz, ~D[2022-09-08])
  end

  test "CODE routes each current product family through its documented path" do
    date = ~D[2026-07-12]

    assert {:ok, sp3} = Data.mgex_sp3(:cod, date)

    assert {:ok,
            "https://www.aiub.unibe.ch/download/CODE_MGEX/CODE/2026/" <>
              "COD0MGXFIN_20261930000_01D_05M_ORB.SP3.gz"} = Data.archive_url(sp3)

    assert {:ok, clock} = Data.mgex_clk(:cod, date)

    assert {:ok,
            "https://www.aiub.unibe.ch/download/CODE_MGEX/CODE/2026/" <>
              "COD0MGXFIN_20261930000_01D_30S_CLK.CLK.gz"} = Data.archive_url(clock)

    assert {:ok, final_ionex} = Data.mgex_ionex(:cod, date)

    assert {:ok,
            "https://www.aiub.unibe.ch/download/CODE/2026/" <>
              "COD0OPSFIN_20261930000_01D_01H_GIM.INX.gz"} = Data.archive_url(final_ionex)

    assert {:ok, rapid_ionex} = Data.rapid_ionex(date)
    assert {:ok, rapid_url} = Data.archive_url(rapid_ionex)
    assert rapid_url =~ "https://www.aiub.unibe.ch/download/CODE/COD0OPSRAP_"

    assert {:ok, ultra} = Data.ops_ultra_sp3(:cod_ult, date, issue: "0000")
    assert {:ok, ultra_identity} = Data.identity(ultra)

    assert {:ok, %{original_url: ultra_url, compression: :none}} =
             Distribution.location(ultra_identity, :direct)

    assert ultra_url ==
             "https://www.aiub.unibe.ch/download/CODE/" <>
               "COD0OPSULT_20261930000_01D_05M_ORB.SP3"
  end

  test "unsupported known center/product combinations fail during derivation" do
    assert {:error, {:unsupported_product, "cod_prd1/sp3"}} =
             Data.product(:cod_prd1, :sp3, ~D[2026-07-12])

    assert {:error, {:unsupported_product, _reason}} =
             Data.product(:cod, :sp3, ~D[2022-11-26])

    assert {:error, {:unsupported_product, "cod_prd1/sp3"}} =
             Data.fetch_merged_sp3(~D[2026-07-12], [:cod_prd1],
               http_client: fn _url, _opts -> flunk("unsupported request reached transport") end
             )
  end
end
