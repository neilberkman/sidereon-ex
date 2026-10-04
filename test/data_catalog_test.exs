defmodule Sidereon.GNSS.Data.CatalogTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Data.Catalog
  alias Sidereon.GNSS.Data.Catalog.CatalogError

  test "the public detailed route retains fields from a legacy special-case tag" do
    assert {:error,
            %CatalogError{
              kind: :unknown_center,
              fields: %{value: "unknown_c"},
              message: "unknown analysis center \"unknown_c\""
            }} = Catalog.product_solution_class("unknown_c", :sp3)

    assert {:error, {:unknown_center, "unknown_c"}} =
             Data.product_solution_class("unknown_c", :sp3)
  end

  test "the public detailed route retains unknown type and unsupported-product fields" do
    assert {:error,
            %CatalogError{
              kind: :unknown_product_type,
              fields: %{value: "unknown_pt"},
              message: "unknown product type \"unknown_pt\""
            }} = Catalog.product_solution_class(:cod, "unknown_pt")

    assert {:error,
            %CatalogError{
              kind: :unsupported_product,
              fields: %{center: "cod", product_type: "nav"},
              message: "cod does not serve nav"
            }} = Catalog.product_solution_class(:cod, :nav)
  end

  test "date conversion rejects out-of-range numeric fields with a typed error" do
    assert {:error,
            %CatalogError{
              kind: :date_out_of_range,
              fields: %{},
              message: "product date is out of range"
            }} = Catalog.sp3_content_start_convention(:cod, {2026, 256, 1})

    assert {:ok, {"filename_epoch", 0}} =
             Catalog.sp3_content_start_convention(:cod, {2026, 1, 2})
  end

  test "the public detailed SP3 route retains variant fields and literal message" do
    assert {:error,
            %CatalogError{
              kind: :invalid_date,
              fields: %{year: 2026, month: 13, day: 40},
              message: "invalid product date 2026-13-40"
            }} = Catalog.sp3_content_start_convention(:cod, {2026, 13, 40})
  end

  test "the public identity route retains sample and issue failure fields" do
    assert {:error,
            %CatalogError{
              kind: :invalid_sample,
              fields: %{value: "99X"},
              message: "invalid sample code \"99X\""
            }} = Catalog.product_identity(:cod, :sp3, {2026, 1, 2}, "99X")

    assert {:error,
            %CatalogError{
              kind: :unsupported_sample,
              fields: %{center: "cod", product_type: "sp3", sample: "01D"},
              message: "cod/sp3 does not publish sample interval \"01D\""
            }} = Catalog.product_identity(:cod, :sp3, {2026, 1, 2}, "01D")

    assert {:error,
            %CatalogError{
              kind: :missing_issue,
              fields: %{center: "igs_ult"},
              message: "igs_ult requires an issue time"
            }} = Catalog.product_identity(:igs_ult, :sp3, {2026, 1, 2}, "02H")

    assert {:error,
            %CatalogError{
              kind: :unexpected_issue,
              fields: %{center: "cod"},
              message: "cod does not take an issue time"
            }} = Catalog.product_identity(:cod, :sp3, {2026, 1, 2}, "02H", "9999")

    assert {:error,
            %CatalogError{
              kind: :unsupported_issue,
              fields: %{center: "igs_ult", issue: "0130"},
              message: "igs_ult does not publish issue \"0130\""
            }} = Catalog.product_identity(:igs_ult, :sp3, {2026, 1, 2}, "02H", "0130")
  end

  test "the public identity and issue routes retain era and epoch diagnostics" do
    assert {:error,
            %CatalogError{
              kind: :unsupported_product_era,
              fields: %{center: "igs", product_type: "sp3", date: {1980, 1, 6}},
              message: "igs/sp3 has no cataloged naming convention for 1980-01-06"
            }} = Catalog.product_identity(:igs, :sp3, {1980, 1, 6}, "15M")

    assert {:error,
            %CatalogError{
              kind: :date_before_gps_epoch,
              fields: %{date: {1970, 1, 1}},
              message: "product date 1970-01-01 is before the GPS week epoch"
            }} = Catalog.ultra_issue_candidates(:igs_ult, {1970, 1, 1, 0, 0, 0})

    assert {:error,
            %CatalogError{
              kind: :invalid_issue,
              fields: %{value: "9999"},
              message: "invalid issue time \"9999\""
            }} = Catalog.product_identity(:igs_ult, :sp3, {2026, 1, 2}, "02H", "9999")
  end

  test "the public GPS date route retains day and representable-range errors" do
    assert {:error,
            %CatalogError{
              kind: :invalid_gps_day_of_week,
              fields: %{gps_day: 7},
              message: "invalid GPS day-of-week 7"
            }} = Catalog.date_from_gps_week_day(0, 7)

    assert {:error,
            %CatalogError{
              kind: :date_out_of_range,
              fields: %{},
              message: "product date is out of range"
            }} = Catalog.date_from_gps_week_day(4_294_967_295, 6)
  end

  test "DateTime catalog queries normalize equivalent instants to UTC" do
    utc = %DateTime{
      year: 2026,
      month: 1,
      day: 2,
      hour: 0,
      minute: 0,
      second: 0,
      microsecond: {0, 0},
      time_zone: "UTC",
      zone_abbr: "UTC",
      utc_offset: 0,
      std_offset: 0
    }

    offset = %DateTime{
      year: 2026,
      month: 1,
      day: 2,
      hour: 1,
      minute: 0,
      second: 0,
      microsecond: {0, 0},
      time_zone: "fixed +01:00",
      zone_abbr: "+01:00",
      utc_offset: 3_600,
      std_offset: 0
    }

    assert Catalog.next_issue_due(:igs_ult, :sp3, utc) ==
             Catalog.next_issue_due(:igs_ult, :sp3, offset)
  end

  test "the public issue route distinguishes no available catalog issue" do
    assert {:error,
            %CatalogError{
              kind: :no_available_ultra_issue,
              fields: %{},
              message: "no available ultra-rapid issue at or before target"
            }} =
             Catalog.latest_ultra_issue(:igs_ult, {2026, 1, 2, 12, 0, 0}, [])
  end

  test "the public issue routes retain date-time and schedule diagnostics" do
    assert {:error,
            %CatalogError{
              kind: :invalid_date_time,
              fields: %{hour: 25, minute: 61, second: 62},
              message: "invalid product time 25:61:62"
            }} = Catalog.ultra_issue_candidates(:igs_ult, {2026, 1, 2, 25, 61, 62})

    assert {:error,
            %CatalogError{
              kind: :unsupported_nominal_schedule,
              fields: %{center: "wum_nrt", product_type: "sp3"},
              message: "wum_nrt/sp3 has no nominal due-time schedule"
            }} = Catalog.next_issue_due(:wum_nrt, :sp3, {2026, 1, 2, 0, 0, 0})
  end

  test "the public identity validator retains span and filename diagnostics" do
    {:ok, product} = Data.mgex_sp3(:cod, ~D[2026-07-12])
    {:ok, identity} = Data.identity(product)

    assert {:error,
            %CatalogError{
              kind: :inconsistent_product_identity,
              fields: %{field: "span"},
              message: "product identity field \"span\" disagrees with its official filename"
            }} =
             Catalog.validate_product_identity(%{identity | span: "99D"})

    assert {:error,
            %CatalogError{
              kind: :inconsistent_product_identity,
              fields: %{field: "official_filename"},
              message: "product identity field \"official_filename\" disagrees with its official filename"
            }} =
             Catalog.validate_product_identity(%{
               identity
               | official_filename: String.replace(identity.official_filename, "COD0", "BAD0")
             })

    assert {:error,
            %CatalogError{
              kind: :invalid_official_filename,
              fields: %{value: "bad..name"},
              message: "invalid official product filename \"bad..name\""
            }} = Catalog.validate_product_identity(%{identity | official_filename: "bad..name"})
  end

  test "the public detailed listing route retains the parser diagnostic" do
    assert {:error,
            %CatalogError{
              kind: :unrecognized_archive_listing,
              fields: %{reason: "no known listing grammar"},
              message: "unrecognized archive listing: no known listing grammar"
            }} = Catalog.parse_archive_listing("bad grammar")
  end

  test "the public detailed terrain route retains invalid tile diagnostics" do
    assert {:error,
            %CatalogError{
              kind: :invalid_tile_index,
              fields: %{lat_index: -95, lon_index: 185},
              message: "invalid terrain tile index lat=-95 lon=185"
            }} = Catalog.skadi_tile_id(-95, 185)

    assert {:error,
            %CatalogError{
              kind: :invalid_tile_id,
              fields: %{value: "invalid_tile"},
              message: "invalid skadi tile id \"invalid_tile\""
            }} = Catalog.parse_skadi_tile_id("invalid_tile")
  end

  test "the public detailed terrain route retains invalid coordinate values" do
    assert {:error,
            %CatalogError{
              kind: :invalid_coordinate,
              fields: %{
                lat_deg_bits: "8000000000000000",
                lon_deg_bits: "4066a00000000000"
              },
              message: "invalid terrain coordinate lat=-0 lon=181"
            }} = Catalog.terrain_tile_index(-0.0, 181.0)

    assert {:error, {:invalid_coordinate, -0.0, 181.0}} =
             Data.terrain_tile_index(-0.0, 181.0)
  end

  test "the public exact-request route retains the empty-distributor diagnostic" do
    {:ok, product} = Data.mgex_sp3(:cod, ~D[2026-07-12])
    {:ok, identity} = Data.identity(product)

    assert {:error,
            %CatalogError{
              kind: :no_distribution_sources,
              fields: %{},
              message: "exact product request has no distributors"
            }} = Catalog.product_request(identity, [])
  end

  test "the public distribution and mirror routes retain their diagnostics" do
    assert {:ok, :ok} = Catalog.open_mirror(:cod, :sp3)

    {:ok, clk_product} = Data.mgex_clk(:cod, ~D[2026-07-12])
    {:ok, clk_identity} = Data.identity(clk_product)

    assert {:error,
            %CatalogError{
              kind: :unsupported_distribution,
              fields: %{source: "nasa_cddis", product_type: "clk"},
              message: "distributor nasa_cddis does not serve clk"
            }} = Catalog.distribution_location(clk_identity, :nasa_cddis)

    assert {:error,
            %CatalogError{
              kind: :no_open_mirror,
              fields: %{center: "grg", product_type: "sp3"},
              message: "grg/sp3 has no open mirror"
            }} = Catalog.open_mirror(:grg, :sp3)
  end

  test "the public distribution route retains era diagnostics" do
    {:ok, wum_product} = Data.mgex_sp3(:wum_nrt, ~D[2024-07-03], issue: "0300")
    {:ok, wum_identity} = Data.identity(wum_product)

    assert {:error,
            %CatalogError{
              kind: :unsupported_distribution_era,
              fields: %{source: "nasa_cddis", center: "wum_nrt", product_type: "sp3"},
              message: "distributor nasa_cddis has no cataloged wum_nrt/sp3 layout for 2024-07-03"
            }} = Catalog.distribution_location(wum_identity, :nasa_cddis)
  end

  test "caller-built identities retain invalid-span diagnostics" do
    {:ok, product} = Data.mgex_sp3(:cod, ~D[2026-07-12])
    {:ok, identity} = Data.identity(product)

    assert {:error,
            %CatalogError{
              kind: :invalid_span,
              fields: %{value: "bad"},
              message: "invalid coverage span \"bad\""
            }} = Catalog.validate_product_identity(%{identity | span: "bad"})
  end

  test "the public station route retains invalid station details" do
    assert {:error,
            %CatalogError{
              kind: :invalid_station,
              fields: %{value: "BADSTATION"},
              message: "invalid station code \"BADSTATION\""
            }} = Catalog.station_obs_filename("BADSTATION", ~D[2026-07-12], "30S")
  end

  test "the public publication route retains an unknown-center diagnostic" do
    assert {:error,
            %CatalogError{
              kind: :unknown_center,
              fields: %{value: "unknown_c"},
              message: "unknown analysis center \"unknown_c\""
            }} = Catalog.newest_published_product("unknown_c", :sp3, [])
  end
end
