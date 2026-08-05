defmodule Sidereon.GNSS.DataPublicationResilienceTest do
  @moduledoc """
  Publication-lag resilience surface (core 0.36.0) through the NIF.

  The cross-line predicted-IONEX walk, the closed-dialect listing parsers,
  and newest-published-issue selection are pure and deterministic in
  `sidereon-core`; these tests check faithful marshaling against the archive
  listings recorded live during the 2026-08-04 publication lag (the same
  fixtures the core pins).
  """
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Data.Product

  @fixtures Path.join(__DIR__, "fixtures/listings")

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  test "predicted_ionex_line_candidates share the map date and name their line" do
    map_date = ~D[2026-08-05]

    assert {:ok, [one_day, two_day]} = Data.predicted_ionex_line_candidates(map_date)
    assert %Product{center: "cod_prd1", date: ^map_date} = one_day
    assert %Product{center: "cod_prd2", date: ^map_date} = two_day
    # Same official filename, distinct archive lines.
    assert one_day.filename == two_day.filename
    assert one_day.url =~ "/IONO/P1/2026/"
    assert two_day.url =~ "/IONO/P2/2026/"
  end

  test "the walk stays whole across the civil year boundary" do
    assert {:ok, candidates} = Data.predicted_ionex_line_candidates(~D[2027-01-01])
    assert Enum.all?(candidates, &(&1.date == ~D[2027-01-01]))
  end

  test "the recorded P1 gap resolves to P2 with the line named" do
    assert {:ok, objects} =
             Data.parse_archive_listing(fixture("aiub-iono-p1p2-20260804.csv"))

    assert {:ok, gap} = Data.predicted_ionex_line_candidates(~D[2026-08-05])
    assert {:ok, 1} = Data.resolve_first_published(gap, objects)
    assert Enum.at(gap, 1).center == "cod_prd2"

    assert {:ok, both} = Data.predicted_ionex_line_candidates(~D[2026-08-04])
    assert {:ok, 0} = Data.resolve_first_published(both, objects)
  end

  test "newest_published_product reports the recorded GFZ lag" do
    assert {:ok, objects} =
             Data.parse_archive_listing(fixture("gfz-ultra-w2430-20260804.html"))

    assert {:ok, newest} = Data.newest_published_product(:gfz_ult, :sp3, objects)

    assert newest == %{
             date: ~D[2026-08-03],
             issue: "0300",
             filename: "GFZ0OPSULT_20262150300_02D_05M_ORB.SP3",
             observed_at: "2026-08-04 08:20"
           }

    assert {:ok, minutes} =
             Data.published_issue_age_minutes(newest, ~U[2026-08-04 07:08:00Z])

    assert minutes == 28 * 60 + 8
  end

  test "an unrecognizable listing body is a typed error, never an empty parse" do
    for body <- ["", "This mirror has moved.", "<html><h1>503</h1></html>"] do
      assert {:error, {:unrecognized_archive_listing, _reason}} =
               Data.parse_archive_listing(body)
    end
  end

  test "publication listing URLs are bounded" do
    assert {:ok, urls} = Data.publication_listing_urls(:gfz_ult, :sp3, ~D[2026-08-04])

    assert urls == [
             "https://isdc-data.gfz.de/gnss/products/ultra/w2430/",
             "https://isdc-data.gfz.de/gnss/products/ultra/w2429/"
           ]

    assert {:ok, ["https://www.aiub.unibe.ch/download/full_listing.csv"]} =
             Data.publication_listing_urls(:cod_prd1, :ionex, ~D[2026-08-04])
  end

  test "the WUM near-real-time line is cataloged with its verified conventions" do
    assert "wum_nrt" in Data.centers()

    assert {:ok, product} =
             Data.ops_ultra_sp3(:wum_nrt, ~D[2026-08-03], issue: "0500")

    assert {:ok, "WUM0MGXNRT_20262150500_02D_05M_ORB.SP3"} = Data.canonical_filename(product)
    assert {:ok, "near_real_time"} = Data.product_solution_class(:wum_nrt, :sp3)

    # The era gate refuses dates before the archive-verified NRT start.
    assert {:error, _} = Data.ops_ultra_sp3(:wum_nrt, ~D[2024-07-02], issue: "0000")
  end

  describe "publication_status/3" do
    test "answers the recorded GFZ lag scenario in one bounded query" do
      fetcher = fn url, _opts ->
        assert url == "https://isdc-data.gfz.de/gnss/products/ultra/w2430/"
        {:ok, fixture("gfz-ultra-w2430-20260804.html")}
      end

      assert {:published, published} =
               Data.publication_status(:gfz_ult, :sp3,
                 now: ~U[2026-08-04 07:08:00Z],
                 listing_fetcher: fetcher
               )

      assert published.date == ~D[2026-08-03]
      assert published.issue == "0300"
      assert published.observed_at == "2026-08-04 08:20"
      assert published.behind_nominal_minutes == 28 * 60 + 8
    end

    test "an authoritative 404 walks back one directory; nothing published is distinct" do
      fetcher = fn _url, _opts -> {:not_posted, 404} end

      assert {:nothing_published, urls} =
               Data.publication_status(:gfz_ult, :sp3,
                 now: ~U[2026-08-04 07:08:00Z],
                 listing_fetcher: fetcher
               )

      assert length(urls) == 2
    end

    test "a transport failure is unreachable and never walks back" do
      parent = self()

      fetcher = fn url, _opts ->
        send(parent, {:fetched, url})
        {:error, {:network, :econnrefused}}
      end

      assert {:unreachable, url, {:network, :econnrefused}} =
               Data.publication_status(:gfz_ult, :sp3,
                 now: ~U[2026-08-04 07:08:00Z],
                 listing_fetcher: fetcher
               )

      assert url == "https://isdc-data.gfz.de/gnss/products/ultra/w2430/"
      assert_received {:fetched, _}
      refute_received {:fetched, _}
    end

    test "an unrecognizable listing from a reachable archive is unreachable" do
      fetcher = fn _url, _opts -> {:ok, "<html><h1>503</h1></html>"} end

      assert {:unreachable, _url, {:unrecognized_archive_listing, _}} =
               Data.publication_status(:gfz_ult, :sp3,
                 now: ~U[2026-08-04 07:08:00Z],
                 listing_fetcher: fetcher
               )
    end

    test "the built-in fetch follows AIUB's bounded 302 to the object store" do
      parent = self()

      http_client = fn url, _opts ->
        send(parent, {:http, url})

        case url do
          "https://www.aiub.unibe.ch/download/full_listing.csv" ->
            {:ok, 302, [{"location", "https://download.aiub.unibe.ch/full_listing.csv"}], ""}

          "https://download.aiub.unibe.ch/full_listing.csv" ->
            {:ok, 200, [],
             "CODE/IONO/P2/2026/COD0OPSPRD_20262170000_01D_01H_GIM.INX.gz;1;" <>
               "2026-08-04T06:51:15Z;00\n"}
        end
      end

      assert {:published, published} =
               Data.publication_status(:cod_prd2, :ionex,
                 now: ~U[2026-08-04 07:08:00Z],
                 http_client: http_client
               )

      assert published.date == ~D[2026-08-05]
      assert published.observed_at == "2026-08-04T06:51:15Z"
      assert_received {:http, "https://www.aiub.unibe.ch/download/full_listing.csv"}
      assert_received {:http, "https://download.aiub.unibe.ch/full_listing.csv"}
    end

    test "a redirect off the cataloged allowlist stays unreachable" do
      http_client = fn _url, _opts ->
        {:ok, 302, [{"location", "https://evil.example.com/full_listing.csv"}], ""}
      end

      assert {:unreachable, _url, {:redirect_not_allowed, 302, _}} =
               Data.publication_status(:cod_prd2, :ionex,
                 now: ~U[2026-08-04 07:08:00Z],
                 http_client: http_client
               )
    end

    test "wum_nrt identities cross the caller-built NIF boundary (0.36.0 carries the token arms)" do
      {:ok, product} = Data.ops_ultra_sp3(:wum_nrt, ~D[2026-08-03], issue: "0500")
      # `identity/1` marshals the WUM publisher and near_real_time solution
      # tokens through the same NIF string parsing that rejects unknown
      # tokens for caller-supplied identities; 0.36.0 accepts them.
      assert {:ok, identity} = Data.identity(product)
      assert identity.publisher == "WUM"
      assert identity.solution_class == "near_real_time"
      assert identity.official_filename == "WUM0MGXNRT_20262150500_02D_05M_ORB.SP3"
    end

    test "wum_nrt publication status routes ftp:// listings through the FTP transport" do
      parent = self()

      ftp_client = fn url, _opts ->
        send(parent, {:ftp, url})

        case url do
          "ftp://igs.gnsswhu.cn/pub/gps/products/mgex/2430/" ->
            {:ok, fixture("whu-mgex-2430-20260804.txt")}
        end
      end

      assert {:published, published} =
               Data.publication_status(:wum_nrt, :sp3,
                 now: ~U[2026-08-04 07:08:00Z],
                 ftp_client: ftp_client
               )

      assert published.date == ~D[2026-08-03]
      assert published.issue == "0500"
      assert published.filename == "WUM0MGXNRT_20262150500_02D_05M_ORB.SP3"
      assert published.observed_at == "Aug 04 06:30"
      assert_received {:ftp, "ftp://igs.gnsswhu.cn/pub/gps/products/mgex/2430/"}
    end

    test "an FTP absence walks back like an authoritative 404" do
      ftp_client = fn url, _opts ->
        case url do
          "ftp://igs.gnsswhu.cn/pub/gps/products/mgex/2430/" ->
            {:error, {:not_found_on_archive, url}}

          "ftp://igs.gnsswhu.cn/pub/gps/products/mgex/2429/" ->
            {:ok, fixture("whu-mgex-2430-20260804.txt")}
        end
      end

      assert {:published, published} =
               Data.publication_status(:wum_nrt, :sp3,
                 now: ~U[2026-08-04 07:08:00Z],
                 ftp_client: ftp_client
               )

      assert published.issue == "0500"
      assert published.listing_url == "ftp://igs.gnsswhu.cn/pub/gps/products/mgex/2429/"
    end

    @tag :network
    test "live: WHU publication status over real anonymous FTP" do
      assert {:published, published} = Data.publication_status(:wum_nrt, :sp3)
      assert %Date{} = published.date
      assert published.filename =~ ~r/^WUM0MGXNRT_\d{11}_02D_05M_ORB\.SP3$/
    end

    test "filename-bearing wum_nrt candidates derive identity from the core catalog" do
      # Ultra candidates carry filenames; identity/1 must derive fields from
      # the one core catalog and only VERIFY the declared filename - the
      # removed interface-side filename grammar silently dropped every WHU
      # NRT candidate before download.
      {:ok, bare} = Data.ops_ultra_sp3(:wum_nrt, ~D[2026-08-03], issue: "0500")
      {:ok, canonical} = Data.canonical_filename(bare)
      product = %{bare | filename: canonical}

      assert {:ok, identity} = Data.identity(product)
      assert identity.solution_class == "near_real_time"
      assert identity.official_filename == canonical

      # A candidate lying about its filename fails closed.
      lying = %{product | filename: "WUM0MGXNRT_20262150500_02D_15M_ORB.SP3"}

      assert {:error, {:product_validation_failed, :official_filename}} =
               Data.identity(lying)
    end
  end
end
