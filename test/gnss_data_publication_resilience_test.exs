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
  end
end
