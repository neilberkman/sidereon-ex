defmodule Sidereon.CelestrakGpTest do
  use ExUnit.Case, async: true

  alias Sidereon.Format.OMM
  alias Sidereon.Format.TLE
  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.Data.Catalog.CatalogError
  alias Sidereon.GNSS.Data.CelestrakGpRecord
  alias Sidereon.SGP4.FitOmmHeader

  @line1 "1 25544U 98067A   26095.55331950  .00008543  00000+0  16420-3 0  9998"
  @line2 "2 25544  51.6328 299.5432 0006351 274.8255  85.2008 15.48786980560492"
  @root "https://celestrak.org/NORAD/elements/gp.php"

  test "source metadata and all GP format and selector URLs" do
    assert {:group, "active"} == {:group, "active"}
    refute {:group, "active"} == {:group, "stations"}
    assert Data.celestrak_gp_source_entry() == %{protocol: "https", host: "celestrak.org", root_url: @root}

    assert Data.navcen_source_entry() == %{
             protocol: "https",
             host: "www.navcen.uscg.gov",
             root_url: "https://www.navcen.uscg.gov/gps-constellation"
           }

    assert Data.navcen_constellation_url() == "https://www.navcen.uscg.gov/gps-constellation"
    assert "www.navcen.uscg.gov" in Data.allowed_hosts()

    for {format, wire} <- [
          tle: "TLE",
          three_line: "3LE",
          two_line: "2LE",
          xml: "XML",
          kvn: "KVN",
          json: "JSON",
          json_pretty: "JSON-PRETTY",
          csv: "CSV"
        ] do
      assert {:ok, @root <> "?GROUP=active&FORMAT=" <> ^wire} = Data.celestrak_gp_url({:group, "active"}, format)
      assert Data.CelestrakGpFormat.as_str(format) == wire
    end

    assert Data.CelestrakGpSpecial.as_str(:gpz) == "GPZ"
    assert Data.CelestrakGpSpecial.as_str(:gpz_plus) == "GPZ-PLUS"
    assert Data.CelestrakGpSpecial.as_str(:decaying) == "DECAYING"
    assert Data.CelestrakGpFormat.as_str(:unknown) == {:error, {:invalid_format, :unknown}}
    assert Data.CelestrakGpSpecial.as_str(:unknown) == {:error, {:invalid_selector, :special, :unknown}}
    assert Data.celestrak_gp_url({:group, "active"}, :unknown) == {:error, {:invalid_format, :unknown}}
    assert Data.celestrak_group(:unknown) == {:error, {:unsupported_system, :unknown}}

    for {query, part} <- [
          {{:catalog_number, 25_544}, "CATNR=25544"},
          {{:international_designator, "1998-067"}, "INTDES=1998-067"},
          {{:name, "ISS (ZARYA)"}, "NAME=ISS%20%28ZARYA%29"},
          {{:special, :gpz}, "SPECIAL=GPZ"},
          {{:special, :gpz_plus}, "SPECIAL=GPZ-PLUS"},
          {{:special, :decaying}, "SPECIAL=DECAYING"}
        ] do
      assert {:ok, @root <> "?" <> part <> "&FORMAT=JSON"} == Data.celestrak_gp_url(query, :json)
    end

    assert Data.celestrak_group("G") == "gps-ops"
    assert {:ok, @root <> "?GROUP=sbas&FORMAT=JSON"} = Data.celestrak_constellation_url("S", :json)

    for {system, group} <- [
          gps: "gps-ops",
          glonass: "glo-ops",
          galileo: "galileo",
          beidou: "beidou",
          qzss: "gnss",
          navic: "gnss",
          sbas: "sbas"
        ] do
      assert Data.celestrak_group(system) == group
      assert Data.celestrak_constellation_url(system, :json) == {:ok, @root <> "?GROUP=" <> group <> "&FORMAT=JSON"}
    end

    assert {:error,
            %CatalogError{
              kind: :invalid_celestrak_gp_selector,
              fields: %{selector: "CATNR", value: "999999999999999999999"}
            }} = Data.celestrak_gp_url({:catalog_number, 999_999_999_999_999_999_999}, :json)

    for {query, selector, value} <- [
          {{:group, "bad/group"}, "GROUP", "bad/group"},
          {{:catalog_number, -1}, "CATNR", "-1"},
          {{:international_designator, "98-067"}, "INTDES", "98-067"},
          {{:name, " "}, "NAME", " "},
          {{:special, :other}, "SPECIAL", "other"}
        ] do
      assert {:error,
              %CatalogError{kind: :invalid_celestrak_gp_selector, fields: %{selector: ^selector, value: ^value}}} =
               Data.celestrak_gp_url(query, :json)
    end
  end

  test "records retain bytes and native TLE fields and convert" do
    raw = "ISS (ZARYA)\r\n" <> @line1 <> "\r\n" <> @line2 <> "\r\n"
    assert {:ok, %{records: [record], rejected: []} = response} = Data.parse_celestrak_gp_response(raw, :tle)
    assert response == %Data.CelestrakGpResponse{records: [record], rejected: []}
    assert record.record_index == 1
    assert record.line_number == 1
    assert record.raw == raw
    assert record.object_name == "ISS (ZARYA)"

    assert {:tle, %{line1: @line1, line2: @line2, checksum_warnings: [], elements: %{catalog_number: "25544"}}} =
             record.payload

    assert {:ok, %{catalog_number: 25_544}} = CelestrakGpRecord.to_element_set(record)

    assert {:ok,
            %{
              object_name: "ISS (ZARYA)",
              object_id: "1998-067A",
              norad_cat_id: 25_544,
              center_name: "EARTH",
              ref_frame: "TEME",
              time_system: "UTC",
              mean_element_theory: "SGP4",
              ccsds_omm_vers: nil,
              epoch: %OMM.Epoch{year: 2026, month: 4, day: 5, hour: 13, minute: 16, second: 46, microsecond: 804_800}
            }} = CelestrakGpRecord.to_omm(record)

    assert {:ok, omm} = CelestrakGpRecord.to_omm(record)

    assert {:error, {:invalid_field, :creation_date, :invalid_civil_date}} =
             OMM.with_ccsds_header(omm, "2.0", "yesterday", "TEST")

    assert {:ok, headed} = OMM.with_ccsds_header(omm, "2.0", "2026-06-17T05:00:00", "TEST")
    assert {:error, {:missing_field, :bstar}} = OMM.encode_kvn(%{headed | bstar: nil})

    assert {:error, {:missing_one_of, [:mean_motion, :semi_major_axis]}} =
             OMM.encode_xml(%{headed | mean_motion: nil, semi_major_axis_km: nil})

    assert {:error, {:missing_field, :mean_motion}} =
             OMM.encode_kvn(%{headed | mean_motion: nil, semi_major_axis_km: 7000.0})

    assert {:error, {:missing_field, :mean_motion_dot}} =
             OMM.encode_kvn(%{headed | mean_element_theory: "SGP", mean_motion_dot: nil})

    assert {:error, {:missing_field, :mean_motion_ddot}} =
             OMM.encode_kvn(%{headed | mean_element_theory: "SGP", mean_motion_ddot: nil})

    assert {:error, {:missing_field, :bterm}} =
             OMM.encode_xml(%{headed | mean_element_theory: "SGP4-XP", bterm_m2_kg: nil})

    assert {:error, {:missing_field, :agom}} =
             OMM.encode_xml(%{headed | mean_element_theory: "SGP4-XP", bterm_m2_kg: 0.0, agom_m2_kg: nil})

    {:tle, tle} = record.payload
    assert record.payload == {:tle, tle}
    refute record.payload == {:omm, omm}
    assert tle == %Data.CelestrakTleRecord{elements: tle.elements, line1: @line1, line2: @line2, checksum_warnings: []}
    refute tle == %{tle | line1: "other"}

    assert tle.elements == %{
             catalog_number: "25544",
             classification: "U",
             international_designator: "98067A",
             epoch_year: 2026,
             epoch_day_of_year: 95.5533195,
             mean_motion_dot: 0.00008543,
             mean_motion_double_dot: 0.0,
             mean_motion_double_dot_text: " 00000+0",
             bstar: 0.0001642,
             bstar_text: " 16420-3",
             ephemeris_type: 0,
             elset_number: 999,
             inclination_deg: 51.6328,
             raan_deg: 299.5432,
             eccentricity: 0.0006351,
             arg_perigee_deg: 274.8255,
             mean_anomaly_deg: 85.2008,
             mean_motion: 15.4878698,
             rev_number: 56_049
           }

    bad_tle = %{tle | elements: %{tle.elements | epoch_day_of_year: 1000.0}}
    bad_record = %{record | payload: {:tle, bad_tle}}

    assert {:error, {:tle, {:invalid_field, :epoch_day_of_year, "out of range"}}} =
             CelestrakGpRecord.to_element_set(bad_record)

    assert {:error, {:tle, {:invalid_field, :epoch_day_of_year, "out of range"}}} =
             CelestrakGpRecord.to_omm(bad_record)

    bad_omm_record = %{record | payload: {:omm, %{omm | bstar: nil}}}
    assert {:error, {:omm, {:missing_field, :bstar}}} = CelestrakGpRecord.to_element_set(bad_omm_record)

    assert record == %CelestrakGpRecord{
             record_index: 1,
             line_number: 1,
             raw: raw,
             object_name: "ISS (ZARYA)",
             payload: record.payload
           }

    refute record == %{record | object_name: "OTHER"}
  end

  test "rejected TLE retains the offending line and checksum detail" do
    bad_line2 = binary_part(@line2, 0, 68) <> "3"
    raw = @line1 <> "\n" <> bad_line2 <> "\n"
    assert {:ok, %{records: [], rejected: [rejected]}} = Data.parse_celestrak_gp_response(raw, :two_line)
    assert rejected.record_index == 1
    assert rejected.line_number == 2
    assert rejected.raw == raw
    assert rejected.reason == {:tle, {:checksum_mismatch, "line 2", 3, 2}}

    assert rejected == %Data.CelestrakGpRejectedRecord{
             record_index: 1,
             line_number: 2,
             raw: raw,
             reason: {:tle, {:checksum_mismatch, "line 2", 3, 2}}
           }
  end

  test "accepted TLE lines retain missing-checksum warnings" do
    line1 = binary_part(@line1, 0, 68)
    line2 = binary_part(@line2, 0, 68)
    raw = line1 <> "\n" <> line2 <> "\n"

    assert {:ok, %{records: [%{raw: ^raw, payload: {:tle, tle}}], rejected: []}} =
             Data.parse_celestrak_gp_response(raw, :two_line)

    assert tle.checksum_warnings == [{"line 1", :missing, 8}, {"line 2", :missing, 2}]
  end

  test "OMM and structural rejections retain their native reasons and bytes" do
    assert {:ok,
            %{
              records: [],
              rejected: [
                %{record_index: 1, line_number: 1, raw: "OBJECT_NAME = X\n", reason: {:omm, {:missing_field, :epoch}}}
              ]
            }} =
             Data.parse_celestrak_gp_response("OBJECT_NAME = X\n", :kvn)

    body = "junk\n" <> @line1 <> "\n" <> @line2 <> "\n"

    assert {:ok,
            %{
              records: [%{record_index: 2, line_number: 2}],
              rejected: [%{record_index: 1, line_number: 1, raw: "junk\n", reason: {:structural, :unexpected_content}}]
            }} =
             Data.parse_celestrak_gp_response(body, :two_line)
  end

  test "framing and element-set rejections retain their exact kinds" do
    good = "ISS\n" <> @line1 <> "\n" <> @line2 <> "\n"

    assert {:ok, %{rejected: [%{line_number: 4, raw: "NEXT SAT", reason: {:structural, :incomplete_record}}]}} =
             Data.parse_celestrak_gp_response(good <> "NEXT SAT", :tle)

    bad_line = binary_part(@line2, 0, 68) <> "X"
    rejected = "STRAY\n" <> @line1 <> "\n" <> bad_line <> "\n\n"

    assert {:ok,
            %{
              records: [%{record_index: 2}],
              rejected: [%{raw: ^rejected, reason: {:structural, :invalid_tle_structure}}]
            }} =
             Data.parse_celestrak_gp_response(rejected <> @line1 <> "\n" <> @line2, :two_line)

    json = File.read!(Path.join(__DIR__, "fixtures/core/omm/24876.json"))
    json = String.replace(json, "\"MEAN_MOTION\":2.00563771", "\"MEAN_MOTION\":0.0")

    assert {:ok,
            %{
              records: [],
              rejected: [
                %{reason: {:structural, {:invalid_element_set, {:invalid_input, :mean_motion, :not_positive}}}}
              ]
            }} =
             Data.parse_celestrak_gp_response(json, :json)
  end

  test "response errors retain structured fields" do
    for {body, kind} <- [
          {"No GP data found", :celestrak_gp_data_not_found},
          {"<!DOCTYPE html><title>503</title>", :celestrak_gp_html_response}
        ] do
      assert {:error, %CatalogError{kind: ^kind}} = Data.parse_celestrak_gp_response(body, :json)
    end

    repeat = File.read!(Path.join(__DIR__, "fixtures/celestrak/repeat_download.txt"))

    assert {:error,
            %CatalogError{
              kind: :celestrak_gp_not_modified,
              fields: %{query: "GROUP=active", last_successful_download: "2026-03-26 08:10:22 UTC"}
            }} = Data.parse_celestrak_gp_response(repeat, :tle)

    assert {:error,
            %CatalogError{
              kind: :invalid_celestrak_gp_response,
              fields: %{
                line: 1,
                column: 2,
                reason: "malformed JSON: expected ident at line 1 column 2; response excerpt: \"not json\""
              }
            }} = Data.parse_celestrak_gp_response("not json", :json)

    assert {:error,
            %CatalogError{
              kind: :invalid_celestrak_gp_response,
              fields: %{line: nil, column: nil, reason: "invalid utf-8 sequence of 1 bytes from index 0"}
            }} = Data.parse_celestrak_gp_response(<<255>>, :json)
  end

  test "GP parser accepts every format and preserves record source positions" do
    fixture = fn ext -> File.read!(Path.join(__DIR__, "fixtures/core/omm/25544." <> ext)) end
    tle = @line1 <> "\n" <> @line2 <> "\n"

    csv =
      "OBJECT_NAME,EPOCH,MEAN_MOTION,ECCENTRICITY,INCLINATION,RA_OF_ASC_NODE,ARG_OF_PERICENTER,MEAN_ANOMALY,BSTAR,NORAD_CAT_ID\nISS,2026-06-17T04:32:52.099296,15.49273435,0.0004737,51.6332,300.0813,195.1146,164.9702,0.00017172,25544\n"

    for {format, body} <- [
          tle: "ISS\n" <> tle,
          three_line: "0 ISS\n" <> tle,
          two_line: tle,
          kvn: fixture.("kvn"),
          xml: fixture.("xml"),
          json: fixture.("json"),
          json_pretty: fixture.("json"),
          csv: csv
        ] do
      assert {:ok, %{records: [record], rejected: []}} = Data.parse_celestrak_gp_response(body, format)
      assert record.record_index == 1
      assert is_integer(record.line_number)
      assert record.raw == body
      assert {:ok, %{norad_cat_id: 25_544}} = CelestrakGpRecord.to_omm(record)
    end

    assert {:ok, [_], [], [%{index: 0, byte_start: 120, byte_end: 224, line: 2}]} =
             OMM.parse_csv_array_with_spans(csv)
  end

  test "invalid fit header reports the nested core error before solving" do
    header = %FitOmmHeader{creation_date: "yesterday", originator: "TEST"}
    assert header == %FitOmmHeader{creation_date: "yesterday", originator: "TEST"}
    refute header == %FitOmmHeader{creation_date: "yesterday", originator: "OTHER"}

    assert {:error, {:tle_fit_error, :omm_header, _, {:invalid_field, :creation_date, :invalid_civil_date}}} =
             Sidereon.SGP4.fit_tle([], omm_header: header)
  end

  test "fitted OMM carries the supplied CCSDS header" do
    assert {:ok, tle} = TLE.parse(@line1, @line2)

    samples =
      for seconds <- [-120, -60, 0, 60, 120] do
        dt = DateTime.add(tle.epoch, seconds, :second)
        assert {:ok, state} = Sidereon.SGP4.propagate(tle, dt)
        instant = {{dt.year, dt.month, dt.day}, {dt.hour, dt.minute, dt.second + elem(dt.microsecond, 0) / 1_000_000}}
        assert {:ok, jd} = Sidereon.GNSS.Time.utc_instant_split(instant)
        %{epoch: jd, position_teme_km: state.position, velocity_teme_km_s: state.velocity}
      end

    assert {:ok, fit} =
             Sidereon.SGP4.fit_tle(samples,
               epoch: {:sample, 2},
               max_nfev: 80,
               fit_bstar: false,
               metadata: [catalog_number: 25_544, international_designator: "98067A", object_name: "ISS"],
               omm_header: %FitOmmHeader{creation_date: "2026-06-17T05:00:00", originator: "TEST"}
             )

    assert fit.omm.creation_date == "2026-06-17T05:00:00"
    assert fit.omm.originator == "TEST"
    assert fit.omm_kvn =~ ~r/ORIGINATOR\s*= TEST/
  end

  test "GP status errors are classified without retries or cache writes" do
    root = Path.join([File.cwd!(), "tmp", "gp-test-#{System.unique_integer([:positive])}"])
    parent = self()

    client = fn _, _ ->
      send(parent, :request)
      {:ok, 503, "No GP data found"}
    end

    assert {:error,
            {:gp_response, 503, @root <> "?GROUP=active&FORMAT=TLE", %CatalogError{kind: :celestrak_gp_data_not_found}}} =
             Data.fetch_celestrak_gp({:group, "active"}, :tle, cache_dir: root, http_client: client)

    assert_receive :request
    refute_receive :request
    refute File.exists?(root)
  end

  test "a successful HTTP status does not cache a GP error document" do
    root = Path.join([File.cwd!(), "tmp", "gp-invalid-#{System.unique_integer([:positive])}"])
    parent = self()

    client = fn _, _ ->
      send(parent, :request)
      {:ok, 200, "<html>error</html>"}
    end

    assert {:error, %CatalogError{kind: :celestrak_gp_html_response}} =
             Data.fetch_celestrak_gp({:group, "active"}, :json, cache_dir: root, http_client: client)

    assert_receive :request
    refute_receive :request
    refute File.exists?(root)
  end

  test "non-success GP bodies retain the status for each response classification" do
    root = Path.join([File.cwd!(), "tmp", "gp-errors-#{System.unique_integer([:positive])}"])
    repeat = File.read!(Path.join(__DIR__, "fixtures/celestrak/repeat_download.txt"))
    parent = self()
    url = @root <> "?GROUP=active&FORMAT=JSON"

    for {body, kind} <- [
          {"No GP data found", :celestrak_gp_data_not_found},
          {repeat, :celestrak_gp_not_modified}
        ] do
      client = fn _, _ ->
        send(parent, :request)
        {:ok, 429, body}
      end

      assert {:error, {:gp_response, 429, ^url, %CatalogError{kind: ^kind}}} =
               Data.fetch_celestrak_gp({:group, "active"}, :json, cache_dir: root, http_client: client)

      assert_receive :request
      refute_receive :request
    end

    client = fn _, _ -> {:ok, 404, "not a GP response"} end

    assert {:error, {:http_status, 404, ^url}} =
             Data.fetch_celestrak_gp({:group, "active"}, :json, cache_dir: root, http_client: client)

    redirect = fn _, _ -> {:ok, 302, [{"location", "https://celestrak.org/other"}], "not a GP response"} end

    assert {:error, {:http_status, 302, ^url}} =
             Data.fetch_celestrak_gp({:group, "active"}, :json, cache_dir: root, http_client: redirect)

    refute File.exists?(root)
  end

  test "transient GP status pages retry and successful responses are cached" do
    for status <- [503, 429] do
      root = Path.join([File.cwd!(), "tmp", "gp-retry-#{System.unique_integer([:positive])}"])
      parent = self()
      body = @line1 <> "\n" <> @line2 <> "\n"
      key = make_ref()

      client = fn _, _ ->
        send(parent, {:request, status})
        count = Process.get(key, 0)
        Process.put(key, count + 1)
        if count == 0, do: {:ok, status, "<html>unavailable</html>"}, else: {:ok, 200, body}
      end

      assert {:ok, %{records: [_]}} =
               Data.fetch_celestrak_gp({:group, "active"}, :two_line,
                 cache_dir: root,
                 http_client: client,
                 retries: 2,
                 backoff_s: 0
               )

      assert_receive {:request, ^status}
      assert_receive {:request, ^status}
      refute_receive {:request, ^status}

      assert {:ok, %{records: [_]}} =
               Data.fetch_celestrak_gp({:group, "active"}, :two_line, cache_dir: root, offline: true)

      File.rm_rf!(root)
    end
  end

  test "empty server errors exhaust retries without caching" do
    root = Path.join([File.cwd!(), "tmp", "gp-empty-#{System.unique_integer([:positive])}"])
    parent = self()

    client = fn _, _ ->
      send(parent, :request)
      {:ok, 500, ""}
    end

    assert {:error, {:http_status, 500, @root <> "?GROUP=active&FORMAT=JSON"}} =
             Data.fetch_celestrak_gp({:group, "active"}, :json,
               cache_dir: root,
               http_client: client,
               retries: 3,
               backoff_s: 0
             )

    for _ <- 1..3, do: assert_receive(:request)
    refute_receive :request
    refute File.exists?(root)
  end

  test "repeat and no-data errors do not retry" do
    root = Path.join([File.cwd!(), "tmp", "gp-specific-#{System.unique_integer([:positive])}"])
    repeat = File.read!(Path.join(__DIR__, "fixtures/celestrak/repeat_download.txt"))
    parent = self()

    for {status, body, kind} <- [
          {429, repeat, :celestrak_gp_not_modified},
          {403, repeat, :celestrak_gp_not_modified},
          {404, "No GP data found", :celestrak_gp_data_not_found}
        ] do
      client = fn _, _ ->
        send(parent, :request)
        {:ok, status, body}
      end

      assert {:error, {:gp_response, ^status, @root <> "?GROUP=active&FORMAT=JSON", %CatalogError{kind: ^kind}}} =
               Data.fetch_celestrak_gp({:group, "active"}, :json,
                 cache_dir: root,
                 http_client: client,
                 retries: 3,
                 backoff_s: 0
               )

      assert_receive :request
      refute_receive :request
    end

    refute File.exists?(root)
  end

  test "repeat-download errors expose the verified expired cache" do
    root = Path.join([File.cwd!(), "tmp", "gp-repeat-cache-#{System.unique_integer([:positive])}"])
    body = @line1 <> "\n" <> @line2 <> "\n"
    client = fn _, _ -> {:ok, 200, body} end
    assert {:ok, _} = Data.fetch_celestrak_gp({:group, "active"}, :two_line, cache_dir: root, http_client: client)
    [sidecar] = Path.wildcard(Path.join([root, "celestrak-gp", "*.provenance.json"]))
    path = String.replace_suffix(sidecar, ".provenance.json", "")
    metadata = sidecar |> File.read!() |> Jason.decode!() |> Map.put("fetched_at", "2000-01-01T00:00:00Z")
    File.write!(sidecar, Jason.encode!(metadata))
    repeat = File.read!(Path.join(__DIR__, "fixtures/celestrak/repeat_download.txt"))

    assert {:error,
            {:gp_response, 429, _, %CatalogError{kind: :celestrak_gp_not_modified, fields: %{cache_path: ^path}}}} =
             Data.fetch_celestrak_gp({:group, "active"}, :two_line,
               cache_dir: root,
               http_client: fn _, _ -> {:ok, 429, repeat} end
             )

    assert File.read!(path) == body

    assert {:error, %CatalogError{kind: :celestrak_gp_not_modified, fields: %{cache_path: ^path}}} =
             Data.fetch_celestrak_gp({:group, "active"}, :two_line,
               cache_dir: root,
               http_client: fn _, _ -> {:ok, 200, repeat} end
             )

    File.rm_rf!(root)
  end

  test "unverified cache files are not exposed by repeat-download errors" do
    root = Path.join([File.cwd!(), "tmp", "gp-unverified-#{System.unique_integer([:positive])}"])
    body = @line1 <> "\n" <> @line2 <> "\n"

    assert {:ok, _} =
             Data.fetch_celestrak_gp({:group, "active"}, :two_line,
               cache_dir: root,
               http_client: fn _, _ -> {:ok, 200, body} end
             )

    [sidecar] = Path.wildcard(Path.join([root, "celestrak-gp", "*.provenance.json"]))
    File.rm!(sidecar)
    repeat = File.read!(Path.join(__DIR__, "fixtures/celestrak/repeat_download.txt"))

    assert {:error, {:gp_response, 429, _, %CatalogError{kind: :celestrak_gp_not_modified, fields: fields}}} =
             Data.fetch_celestrak_gp({:group, "active"}, :two_line,
               cache_dir: root,
               http_client: fn _, _ -> {:ok, 429, repeat} end
             )

    refute Map.has_key?(fields, :cache_path)
    File.rm_rf!(root)
  end

  test "GP HTTP errors containing valid or malformed data retain status" do
    root = Path.join([File.cwd!(), "tmp", "gp-status-body-#{System.unique_integer([:positive])}"])

    for body <- ["not a GP response", @line1 <> "\n" <> @line2 <> "\n"] do
      assert {:error, {:http_status, 403, @root <> "?GROUP=active&FORMAT=2LE"}} =
               Data.fetch_celestrak_gp({:group, "active"}, :two_line,
                 cache_dir: root,
                 http_client: fn _, _ -> {:ok, 403, body} end
               )
    end

    refute File.exists?(root)
  end

  test "catalog fetches retain transport error shapes" do
    root = Path.join([File.cwd!(), "tmp", "gp-transport-#{System.unique_integer([:positive])}"])
    url = @root <> "?GROUP=active&FORMAT=JSON"

    assert {:error, {:download_size_exceeded, 4}} =
             Data.fetch_celestrak_gp({:group, "active"}, :json,
               cache_dir: root,
               max_compressed_bytes: 4,
               http_client: fn _, _ -> {:ok, 200, "12345"} end
             )

    assert {:error, {:network, :closed}} =
             Data.fetch_celestrak_gp({:group, "active"}, :json,
               cache_dir: root,
               retries: 1,
               http_client: fn _, _ -> {:error, :closed} end
             )

    assert {:error, {:http_status, 302, ^url}} =
             Data.fetch_celestrak_gp({:group, "active"}, :json,
               cache_dir: root,
               http_client: fn _, _ -> {:ok, 302, ""} end
             )

    navcen = "https://www.navcen.uscg.gov/gps-constellation"

    assert {:error, {:redirect_not_allowed, 302, ^navcen}} =
             Data.fetch_navcen_constellation_status(cache_dir: root, http_client: fn _, _ -> {:ok, 302, ""} end)

    assert {:error, {:not_found_on_archive, ^navcen}} =
             Data.fetch_navcen_constellation_status(cache_dir: root, http_client: fn _, _ -> {:ok, 404, ""} end)

    refute File.exists?(root)
  end

  test "successful GP and NAVCEN downloads are cached after classification" do
    root = Path.join([File.cwd!(), "tmp", "gp-cache-#{System.unique_integer([:positive])}"])
    parent = self()
    body = @line1 <> "\n" <> @line2 <> "\n"

    client = fn url, _ ->
      send(parent, {:request, url})
      if String.contains?(url, "navcen"), do: {:ok, 200, "<html>GPS status</html>"}, else: {:ok, 200, body}
    end

    assert {:ok, %{records: [%{raw: ^body}]}} =
             Data.fetch_celestrak_gp({:catalog_number, 25_544}, :two_line, cache_dir: root, http_client: client)

    assert_receive {:request, @root <> "?CATNR=25544&FORMAT=2LE"}

    assert {:ok, %{records: [%{raw: ^body}]}} =
             Data.fetch_celestrak_gp({:catalog_number, 25_544}, :two_line, cache_dir: root, offline: true)

    assert {:ok, "<html>GPS status</html>"} =
             Data.fetch_navcen_constellation_status(cache_dir: root, http_client: client)

    assert_receive {:request, "https://www.navcen.uscg.gov/gps-constellation"}
    assert File.read!(Path.join([root, "navcen", "constellation.html"])) == "<html>GPS status</html>"
    assert {:ok, "<html>GPS status</html>"} = Data.fetch_navcen_constellation_status(cache_dir: root, offline: true)
    refute_receive {:request, _}
    File.rm_rf!(root)
  end

  test "GP fetches default to JSON when given cache options" do
    root = Path.join([File.cwd!(), "tmp", "gp-default-#{System.unique_integer([:positive])}"])
    body = File.read!(Path.join(__DIR__, "fixtures/core/omm/25544.json"))
    parent = self()

    client = fn url, _ ->
      send(parent, {:request, url})
      {:ok, 200, body}
    end

    assert {:ok, %{records: [_]}} = Data.fetch_celestrak_gp({:group, "active"}, cache_dir: root, http_client: client)
    assert_receive {:request, @root <> "?GROUP=active&FORMAT=JSON"}
    assert {:ok, %{records: [_]}} = Data.fetch_constellation(:gps, cache_dir: root, http_client: client)
    assert_receive {:request, @root <> "?GROUP=gps-ops&FORMAT=JSON"}
    File.rm_rf!(root)
  end

  test "constellation feeds use the two-hour default cache age" do
    root = Path.join([File.cwd!(), "tmp", "gp-constellation-#{System.unique_integer([:positive])}"])
    parent = self()
    body = @line1 <> "\n" <> @line2 <> "\n"

    client = fn url, _ ->
      send(parent, {:request, url})
      {:ok, 200, body}
    end

    url = @root <> "?GROUP=gps-ops&FORMAT=2LE"

    assert {:ok, %{records: [_]}} = Data.fetch_constellation(:gps, :two_line, cache_dir: root, http_client: client)
    assert_receive {:request, ^url}
    [provenance_path] = Path.wildcard(Path.join([root, "celestrak-gp", "*.provenance.json"]))
    provenance = provenance_path |> File.read!() |> Jason.decode!()
    assert provenance["source_url"] == url
    assert provenance["protocol"] == "https"
    assert provenance["compression"] == "none"
    assert provenance["size_data"] == byte_size(body)
    fresh = DateTime.utc_now() |> DateTime.add(-7100, :second) |> DateTime.to_iso8601()
    File.write!(provenance_path, Jason.encode!(Map.put(provenance, "fetched_at", fresh)))
    assert {:ok, %{records: [_]}} = Data.fetch_constellation(:gps, :two_line, cache_dir: root, http_client: client)
    refute_receive {:request, _}

    expired = DateTime.utc_now() |> DateTime.add(-7300, :second) |> DateTime.to_iso8601()
    File.write!(provenance_path, Jason.encode!(Map.put(provenance, "fetched_at", expired)))
    assert {:ok, %{records: [_]}} = Data.fetch_constellation(:gps, :two_line, cache_dir: root, http_client: client)
    assert_receive {:request, ^url}
    File.rm_rf!(root)
  end

  test "transport exceptions follow the configured retry policy" do
    root = Path.join([File.cwd!(), "tmp", "gp-retry-#{System.unique_integer([:positive])}"])
    parent = self()

    client = fn _, _ ->
      send(parent, :request)
      raise "transport failed"
    end

    assert {:error, {:network, "transport failed"}} =
             Data.fetch_celestrak_gp({:group, "active"}, :json,
               cache_dir: root,
               http_client: client,
               retries: 2,
               backoff_s: 0
             )

    assert_receive :request
    assert_receive :request
    refute_receive :request
    refute File.exists?(root)
  end
end
