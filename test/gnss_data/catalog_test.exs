defmodule Sidereon.GNSS.Data.CatalogTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data.Catalog

  doctest Sidereon.GNSS.Data.Catalog

  describe "GPS-week and day-of-year arithmetic" do
    test "worked example: 2020-06-24 is GPS week 2111, day 3, doy 176" do
      d = ~D[2020-06-24]
      assert Catalog.gps_week(d) == 2111
      assert Catalog.gps_day_of_week(d) == 3
      assert Catalog.day_of_year(d) == 176
    end

    test "GPS epoch day itself is week 0, day 0" do
      d = ~D[1980-01-06]
      assert Catalog.gps_week(d) == 0
      assert Catalog.gps_day_of_week(d) == 0
    end

    test "the day before the next GPS week rolls the day-of-week to 6" do
      assert Catalog.gps_day_of_week(~D[1980-01-12]) == 6
      assert Catalog.gps_week(~D[1980-01-12]) == 0
      assert Catalog.gps_week(~D[1980-01-13]) == 1
    end

    test "day-of-year handles the leap day and year boundaries" do
      assert Catalog.day_of_year(~D[2020-01-01]) == 1
      # 2020 is a leap year: Dec 31 is the 366th day.
      assert Catalog.day_of_year(~D[2020-12-31]) == 366
      # 2021 is not a leap year: Dec 31 is the 365th day.
      assert Catalog.day_of_year(~D[2021-12-31]) == 365
    end
  end

  describe "canonical_filename/4" do
    test "encodes the IGS long-name for catalog centers and content types" do
      assert {:ok, "GFZ0OPSRAP_20201760000_01D_15M_ORB.SP3"} =
               Catalog.canonical_filename(:gfz, :sp3, ~D[2020-06-24], "15M")

      assert {:ok, "COD0MGXFIN_20241760000_01D_05M_ORB.SP3"} =
               Catalog.canonical_filename(:cod, :sp3, ~D[2024-06-24], "05M")

      assert {:ok, "COD0MGXFIN_20241760000_01D_30S_CLK.CLK"} =
               Catalog.canonical_filename(:cod, :clk, ~D[2024-06-24], "30S")

      assert {:ok, "ESA0MGNFIN_20201760000_01D_05M_ORB.SP3"} =
               Catalog.canonical_filename(:esa, :sp3, ~D[2020-06-24], "05M")

      assert {:ok, "ESA0MGNFIN_20201760000_01D_30S_CLK.CLK"} =
               Catalog.canonical_filename(:esa, :clk, ~D[2020-06-24], "30S")
    end

    test "navigation uses the no-sample RINEX long-name from the BKG IGS tree" do
      assert {:ok, "BRDC00WRD_R_20201770000_01D_MN.rnx"} =
               Catalog.canonical_filename(:igs, :nav, ~D[2020-06-25], "01D")
    end

    test "IONEX uses the ESA GIM content code" do
      assert {:ok, "COD0OPSFIN_20241760000_01D_01H_GIM.INX"} =
               Catalog.canonical_filename(:cod, :ionex, ~D[2024-06-24], "01H")

      assert {:ok, "ESA0OPSFIN_20241760000_01D_02H_GIM.INX"} =
               Catalog.canonical_filename(:esa, :ionex, ~D[2024-06-24], "02H")
    end

    test "removed products return a no-open-mirror error" do
      assert {:error, {:no_open_mirror, {:wum, :clk}}} =
               Catalog.canonical_filename(:wum, :clk, ~D[2020-06-24], "30S")

      assert {:error, {:no_open_mirror, {:grg_ult, :sp3}}} =
               Catalog.canonical_filename(:grg_ult, :sp3, ~D[2024-09-03], "05M", "0600")

      assert {:error, {:no_open_mirror, {:igs, :ionex}}} =
               Catalog.canonical_filename(:igs, :ionex, ~D[2024-06-24], "01H")
    end

    test "a center that does not publish a content type is rejected" do
      # GFZ operational serves SP3/CLK but not broadcast nav or IONEX.
      assert {:error, {:unsupported_product, {:content_not_served, :nav}}} =
               Catalog.canonical_filename(:gfz, :nav, ~D[2020-06-25], "01D")

      # IGS serves broadcast nav but not precise orbits here.
      assert {:error, {:unsupported_product, {:content_not_served, :sp3}}} =
               Catalog.canonical_filename(:igs, :sp3, ~D[2020-06-24], "05M")
    end

    test "zero-pads the day-of-year to three digits" do
      assert {:ok, name} = Catalog.canonical_filename(:esa, :sp3, ~D[2020-01-01], "05M")
      assert name =~ "_20200010000_"
    end

    test "rejects an unknown center" do
      assert {:error, {:unsupported_product, {:center, :nope}}} =
               Catalog.canonical_filename(:nope, :sp3, ~D[2020-06-24], "05M")
    end

    test "rejects an unknown content type" do
      assert {:error, {:unsupported_product, {:content, :bogus}}} =
               Catalog.canonical_filename(:esa, :bogus, ~D[2020-06-24], "05M")
    end

    test "rejects a malformed sampling code" do
      assert {:error, {:unsupported_product, {:sample, "5M"}}} =
               Catalog.canonical_filename(:esa, :sp3, ~D[2020-06-24], "5M")
    end
  end

  describe "ultra-rapid precise products" do
    test "encodes the OPSULT SP3 filenames with issue time, 02D span, and native sample" do
      date = ~D[2024-09-03]

      assert {:ok, "IGS0OPSULT_20242470600_02D_15M_ORB.SP3"} =
               Catalog.canonical_filename(:igs_ult, :sp3, date, "15M", "0600")

      assert {:ok, "COD0OPSULT_20242470000_01D_05M_ORB.SP3"} =
               Catalog.canonical_filename(:cod_ult, :sp3, date, "05M", "0000")

      assert {:ok, "ESA0OPSULT_20242470600_02D_15M_ORB.SP3"} =
               Catalog.canonical_filename(:esa_ult, :sp3, date, "15M", "0600")

      assert {:ok, "GFZ0OPSULT_20242470600_02D_05M_ORB.SP3"} =
               Catalog.canonical_filename(:gfz_ult, :sp3, date, "05M", "0600")
    end

    test "rejects ultra-rapid clock products" do
      assert {:error, {:unsupported_product, {:content_not_served, :clk}}} =
               Catalog.canonical_filename(:igs_ult, :clk, ~D[2024-09-03], "05M", "0600")

      assert {:error, {:no_open_mirror, {:grg_ult, :clk}}} =
               Catalog.canonical_filename(:grg_ult, :clk, ~D[2024-09-03], "05M", "0600")
    end

    test "builds archive URLs for ultra-rapid products" do
      assert {:ok,
              "https://igs.bkg.bund.de/root_ftp/IGS/products/2330/IGS0OPSULT_20242470600_02D_15M_ORB.SP3.gz"} =
               Catalog.archive_url(:igs_ult, :sp3, ~D[2024-09-03], "15M", "0600")

      assert {:ok, "http://ftp.aiub.unibe.ch/CODE/COD0OPSULT_20261620000_01D_05M_ORB.SP3"} =
               Catalog.archive_url(:cod_ult, :sp3, ~D[2026-06-11], "05M", "0000")

      assert {:ok,
              "https://navigation-office.esa.int/products/gnss-products/2330/ESA0OPSULT_20242470600_02D_15M_ORB.SP3.gz"} =
               Catalog.archive_url(:esa_ult, :sp3, ~D[2024-09-03], "15M", "0600")

      assert {:ok,
              "https://isdc-data.gfz.de/gnss/products/ultra/w2330/GFZ0OPSULT_20242470600_02D_05M_ORB.SP3.gz"} =
               Catalog.archive_url(:gfz_ult, :sp3, ~D[2024-09-03], "05M", "0600")
    end

    test "resolves the latest available issue at or before a target time" do
      target = ~N[2024-09-03 13:00:00]

      assert {:ok, %{date: ~D[2024-09-03], issue: "1200"}} =
               Catalog.latest_ultra_issue(:igs_ult, target)

      available = [{~D[2024-09-03], "0000"}, {~D[2024-09-03], "0600"}]

      assert {:ok, %{date: ~D[2024-09-03], issue: "0600"}} =
               Catalog.latest_ultra_issue(:igs_ult, target, available)
    end

    test "falls back to a previous-day issue when current-day issue is absent" do
      target = ~N[2024-09-03 01:00:00]
      available = [{~D[2024-09-02], "1800"}]

      assert {:ok, %{date: ~D[2024-09-02], issue: "1800"}} =
               Catalog.latest_ultra_issue(:igs_ult, target, available)
    end

    test "rejects unsupported issue times" do
      assert {:error, {:unsupported_product, {:issue, "0300"}}} =
               Catalog.canonical_filename(:igs_ult, :sp3, ~D[2024-09-03], "15M", "0300")

      assert {:error, {:unsupported_product, {:issue, "0600"}}} =
               Catalog.canonical_filename(:cod_ult, :sp3, ~D[2024-09-03], "05M", "0600")
    end

    test "requires an explicit issue for low-level ultra-rapid filenames" do
      assert {:error, {:unsupported_product, :missing_issue}} =
               Catalog.canonical_filename(:igs_ult, :sp3, ~D[2024-09-03], "15M")
    end
  end

  describe "archive_url/4" do
    test "builds the GFZ HTTPS URL with the rapid/week directory and .gz suffix" do
      assert {:ok,
              "https://isdc-data.gfz.de/gnss/products/rapid/w2111/GFZ0OPSRAP_20201760000_01D_15M_ORB.SP3.gz"} =
               Catalog.archive_url(:gfz, :sp3, ~D[2020-06-24], "15M")
    end

    test "builds an ESA Navigation Office URL for a final precise product" do
      assert {:ok, url} = Catalog.archive_url(:esa, :sp3, ~D[2020-06-24], "05M")

      assert url ==
               "https://navigation-office.esa.int/products/gnss-products/2111/ESA0MGNFIN_20201760000_01D_05M_ORB.SP3.gz"
    end

    test "builds AIUB HTTP URLs for restored CODE final products" do
      assert {:ok,
              "http://ftp.aiub.unibe.ch/CODE_MGEX/CODE/2024/COD0MGXFIN_20241760000_01D_05M_ORB.SP3.gz"} =
               Catalog.archive_url(:cod, :sp3, ~D[2024-06-24], "05M")

      assert {:ok,
              "http://ftp.aiub.unibe.ch/CODE_MGEX/CODE/2024/COD0MGXFIN_20241760000_01D_30S_CLK.CLK.gz"} =
               Catalog.archive_url(:cod, :clk, ~D[2024-06-24], "30S")
    end

    test "builds the BKG IGS URL for broadcast navigation" do
      assert {:ok,
              "https://igs.bkg.bund.de/root_ftp/IGS/BRDC/2020/177/BRDC00WRD_R_20201770000_01D_MN.rnx.gz"} =
               Catalog.archive_url(:igs, :nav, ~D[2020-06-25], "01D")
    end

    test "builds the ESA URL for a global ionosphere map" do
      assert {:ok, "http://ftp.aiub.unibe.ch/CODE/2024/COD0OPSFIN_20241760000_01D_01H_GIM.INX.gz"} =
               Catalog.archive_url(:cod, :ionex, ~D[2024-06-24], "01H")

      assert {:ok,
              "https://navigation-office.esa.int/products/gnss-products/2320/ESA0OPSFIN_20241760000_01D_02H_GIM.INX.gz"} =
               Catalog.archive_url(:esa, :ionex, ~D[2024-06-24], "02H")
    end

    test "builds the BKG IGS URL for station observations" do
      assert {:ok,
              "https://igs.bkg.bund.de/root_ftp/IGS/obs/2020/177/WTZR00DEU_R_20201770000_01D_30S_MO.crx.gz"} =
               Catalog.station_obs_url("WTZR00DEU", ~D[2020-06-25], "30S")
    end

    test "propagates unsupported and no-open-mirror errors" do
      assert {:error, {:unsupported_product, _}} =
               Catalog.archive_url(:nope, :sp3, ~D[2020-06-24], "05M")

      assert {:error, {:no_open_mirror, {:grg, :sp3}}} =
               Catalog.archive_url(:grg, :sp3, ~D[2020-06-24], "05M")
    end
  end

  describe "CODE rapid and predicted IONEX" do
    test "rapid GIM uses the COD0OPSRAP token on the AIUB CODE root" do
      assert {:ok, "COD0OPSRAP_20261640000_01D_01H_GIM.INX"} =
               Catalog.canonical_filename(:cod_rap, :ionex, ~D[2026-06-13], "01H")

      assert {:ok, "http://ftp.aiub.unibe.ch/CODE/COD0OPSRAP_20261640000_01D_01H_GIM.INX.gz"} =
               Catalog.archive_url(:cod_rap, :ionex, ~D[2026-06-13], "01H")
    end

    test "predicted GIMs share the COD0OPSPRD token and CODE root" do
      # The two predicted aliases differ only in the day they target; both serve
      # the single COD0OPSPRD product (horizon is in the file header, not name).
      assert {:ok, "COD0OPSPRD_20261650000_01D_01H_GIM.INX"} =
               Catalog.canonical_filename(:cod_prd1, :ionex, ~D[2026-06-14], "01H")

      assert {:ok, "http://ftp.aiub.unibe.ch/CODE/COD0OPSPRD_20261650000_01D_01H_GIM.INX.gz"} =
               Catalog.archive_url(:cod_prd1, :ionex, ~D[2026-06-14], "01H")

      # The low-level catalog call encodes the date verbatim; the predicted-day
      # offset is applied by the convenience builder / candidate walk, not here.
      # So the same date yields the same filename for both predicted aliases.
      assert {:ok, "http://ftp.aiub.unibe.ch/CODE/COD0OPSPRD_20261660000_01D_01H_GIM.INX.gz"} =
               Catalog.archive_url(:cod_prd2, :ionex, ~D[2026-06-15], "01H")

      assert {:ok, "http://ftp.aiub.unibe.ch/CODE/COD0OPSPRD_20261660000_01D_01H_GIM.INX.gz"} =
               Catalog.archive_url(:cod_prd1, :ionex, ~D[2026-06-15], "01H")
    end

    test "rapid and predicted GIMs compress as .gz and default to 01H" do
      assert {:ok, :gzip} = Catalog.compression(:cod_rap, :ionex)
      assert {:ok, :gzip} = Catalog.compression(:cod_prd1, :ionex)
      assert {:ok, "01H"} = Catalog.default_sample(:cod_rap, :ionex)
      assert {:ok, "01H"} = Catalog.default_sample(:cod_prd2, :ionex)
    end

    test "predicted_day_offset distinguishes 1-day from 2-day horizon" do
      assert Catalog.predicted_day_offset(:cod_prd1) == 0
      assert Catalog.predicted_day_offset(:cod_prd2) == 1
      assert Catalog.predicted_day_offset(:cod_rap) == 0
    end

    test "gim_date_candidates walks the calendar day backward, newest first" do
      assert [~D[2026-06-14], ~D[2026-06-13], ~D[2026-06-12]] =
               Catalog.gim_date_candidates(:cod_rap, ~D[2026-06-14])

      # The predicted offset is applied to the target before fallback expansion.
      assert [~D[2026-06-14], ~D[2026-06-13]] =
               Catalog.gim_date_candidates(:cod_prd1, ~D[2026-06-14], 1)

      assert [~D[2026-06-15], ~D[2026-06-14]] =
               Catalog.gim_date_candidates(:cod_prd2, ~D[2026-06-14], 1)
    end

    test "the IGS combined rapid IONEX has no open mirror" do
      assert {:error, {:no_open_mirror, {:igs, :ionex}}} =
               Catalog.canonical_filename(:igs, :ionex, ~D[2026-06-14], "01H")
    end

    test "AIUB is the only host introduced by the new IONEX aliases" do
      hosts = Catalog.allowed_hosts()
      assert MapSet.member?(hosts, "ftp.aiub.unibe.ch")
      assert :cod_rap in Catalog.centers()
      assert :cod_prd1 in Catalog.centers()
      assert :cod_prd2 in Catalog.centers()
    end
  end

  describe "protocol/1, compression/2, and allowed_hosts/0" do
    test "maps centers to catalog protocols" do
      assert {:ok, :https} = Catalog.protocol(:gfz)
      assert {:ok, :http} = Catalog.protocol(:cod)
      assert {:ok, :https} = Catalog.protocol(:esa)
      assert {:ok, :https} = Catalog.protocol(:igs)
      assert {:error, {:unsupported_product, _}} = Catalog.protocol(:nope)
    end

    test "maps center products to archive compression" do
      assert {:ok, :gzip} = Catalog.compression(:cod, :sp3)
      assert {:ok, :gzip} = Catalog.compression(:cod, :ionex)
      assert {:ok, :none} = Catalog.compression(:cod_ult, :sp3)
      assert {:error, {:no_open_mirror, {:grg, :sp3}}} = Catalog.compression(:grg, :sp3)
    end

    test "allowed hosts contain every catalog host and nothing else slips in" do
      hosts = Catalog.allowed_hosts()
      assert MapSet.member?(hosts, "isdc-data.gfz.de")
      assert MapSet.member?(hosts, "ftp.aiub.unibe.ch")
      assert MapSet.member?(hosts, "navigation-office.esa.int")
      assert MapSet.member?(hosts, "igs.bkg.bund.de")
      refute MapSet.member?(hosts, "gssc.esa.int")
      refute MapSet.member?(hosts, "evil.example.com")
    end
  end
end
