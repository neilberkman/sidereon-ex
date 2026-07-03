defmodule Sidereon.SpaceWeatherTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.Data
  alias Sidereon.SpaceWeather

  @csv """
  DATE,BSRN,ND,KP1,KP2,KP3,KP4,KP5,KP6,KP7,KP8,KP_SUM,AP1,AP2,AP3,AP4,AP5,AP6,AP7,AP8,AP_AVG,CP,C9,ISN,F10.7_OBS,F10.7_ADJ,F10.7_DATA_TYPE,F10.7_OBS_CENTER81,F10.7_OBS_LAST81,F10.7_ADJ_CENTER81,F10.7_ADJ_LAST81
  2000-01-01,1,1,10,10,10,10,10,10,10,10,80,4,4,4,4,4,4,4,4,4,0.0,0,10,100.0,101.0,OBS,99.0,98.0,102.0,103.0
  2000-01-02,1,2,20,20,20,20,20,20,20,20,160,5,6,7,8,9,10,11,12,8,0.1,1,11,110.0,111.0,OBS,109.0,108.0,112.0,113.0
  2000-01-03,1,3,30,30,30,30,30,30,30,30,240,13,14,15,16,17,18,19,20,16,0.2,2,12,120.0,121.0,OBS,119.0,118.0,122.0,123.0
  """

  setup do
    root = Path.join(System.tmp_dir!(), "sidereon-space-weather-test-#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "parses and looks up NRLMSISE inputs" do
    assert {:ok, table} = SpaceWeather.parse(@csv)
    epoch = Sidereon.NIF.civil_j2000_seconds(2000, 1, 2, 12, 0, 0.0)

    assert {:ok, sample} = SpaceWeather.sample_at(table, epoch)
    assert sample.space_weather.f107 == 100.0
    assert sample.space_weather.f107a == 109.0
    assert sample.space_weather.ap == 8.0
    assert sample.class == :observed
    refute sample.ap_defaulted

    history_epoch = Sidereon.NIF.civil_j2000_seconds(2000, 1, 3, 12, 0, 0.0)
    assert {:ok, [16.0, 17.0, 16.0, 15.0, 14.0, 9.5, 4.125]} = SpaceWeather.ap_array_at(table, history_epoch)
    assert {:ok, coverage} = SpaceWeather.coverage(table)
    assert coverage.first_j2000_s < epoch
    assert coverage.end_j2000_s > epoch
  end

  test "fetch_space_weather is cache-first and offline-safe", %{root: root} do
    http_client = fn url, _opts ->
      assert String.ends_with?(url, "/SW-All.csv")
      {:ok, 200, @csv}
    end

    assert {:ok, table} = Data.fetch_space_weather(cache_dir: root, http_client: http_client)
    epoch = Sidereon.NIF.civil_j2000_seconds(2000, 1, 2, 12, 0, 0.0)
    assert {:ok, sw} = SpaceWeather.space_weather_at(table, epoch)
    assert sw.f107 == 100.0

    deny = fn _url, _opts -> flunk("fresh verified cache should avoid transport") end
    assert {:ok, cached} = Data.fetch_space_weather(cache_dir: root, offline: true, http_client: deny)
    assert {:ok, ^sw} = SpaceWeather.space_weather_at(cached, epoch)

    assert {:ok, relpath} = Data.space_weather_cache_relpath()
    path = Path.join(root, relpath)
    assert File.exists?(path <> ".provenance.json")
  end
end
