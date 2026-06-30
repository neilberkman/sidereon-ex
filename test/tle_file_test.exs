defmodule Sidereon.TLEFileTest do
  use ExUnit.Case, async: true

  alias Sidereon.Elements

  @iss_l1 "1 25544U 98067A   18184.80969102  .00001614  00000-0  31745-4 0  9993"
  @iss_l2 "2 25544  51.6414 295.8524 0003435 262.6267 204.2868 15.54005638121106"

  describe "parse_tle_file/1" do
    test "parses a mixed file: 3-line named, bare 2-line, and a malformed record" do
      text = """
      ISS (ZARYA)
      #{@iss_l1}
      #{@iss_l2}
      BAD ONE
      1 not a real line
      2 not a real line
      #{@iss_l1}
      #{@iss_l2}
      """

      assert {:ok, %{satellites: satellites, skipped: skipped}} =
               Sidereon.parse_tle_file(text)

      # The malformed record is skipped and counted; the two good ones survive.
      assert length(satellites) == 2
      assert skipped == 1

      [named, bare] = satellites

      # Name from the 3-line set is captured; the bare 2-line set has an empty name.
      assert named.name == "ISS (ZARYA)"
      assert bare.name == ""

      # The malformed record's name ("BAD ONE") must not leak onto the next record.
      refute bare.name == "BAD ONE"

      # Each `tle` is a fully populated Elements struct usable downstream.
      assert %Elements{} = named.tle
      assert named.tle.catalog_number == "25544"
      assert named.tle.object_name == "ISS (ZARYA)"
      # A bare record carries no object name.
      assert bare.tle.object_name == nil
    end

    test "a returned satellite propagates and yields a look angle" do
      text = "ISS (ZARYA)\n#{@iss_l1}\n#{@iss_l2}\n"

      assert {:ok, %{satellites: [sat], skipped: 0}} = Sidereon.parse_tle_file(text)

      datetime = ~U[2018-07-04 00:00:00Z]

      assert {:ok, teme} = Sidereon.propagate(sat.tle, datetime)
      {x, _y, _z} = teme.position
      assert x > 3000 and x < 4000

      station = %{latitude: 40.0, longitude: -74.0, altitude_m: 0.0}
      assert {:ok, look} = Sidereon.look_angle(sat.tle, datetime, station)
      assert is_float(look.azimuth)
      assert is_float(look.elevation)
      assert look.range_km > 0.0
    end

    test "an empty file yields no satellites and zero skipped" do
      assert {:ok, %{satellites: [], skipped: 0}} = Sidereon.parse_tle_file("\n\n  \n")
    end

    test "tolerates CRLF, blank lines, and surrounding whitespace" do
      text = "\r\n  ISS (ZARYA)  \r\n#{@iss_l1}\r\n\r\n#{@iss_l2}\r\n\r\n"

      assert {:ok, %{satellites: [sat], skipped: 0}} = Sidereon.parse_tle_file(text)
      assert sat.name == "ISS (ZARYA)"
      assert sat.tle.catalog_number == "25544"
    end
  end
end
