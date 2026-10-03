defmodule Sidereon.TLEFileTest do
  use ExUnit.Case, async: true

  alias Sidereon.Elements
  alias Sidereon.Format.TLE
  alias Sidereon.SGP4

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

      assert {:ok, %{rejected: [rejected]}} = Sidereon.parse_tle_file(text)
      assert rejected.line_number == 4
      assert rejected.name == "BAD ONE"
      assert {:invalid, reason} = rejected.issue

      assert match?({:invalid_tle, text} when is_binary(text), reason) or
               match?({:invalid_input, field, kind} when is_atom(field) and is_atom(kind), reason) or
               match?({:sgp4, code} when is_integer(code), reason)

      [named, bare] = satellites
      assert named.line_number == 2
      assert bare.line_number == 7
      assert named.checksum_warnings == []

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

  describe "parse_tle_file/2 rejections and checksum policy" do
    test "reports stray lines and orphan names with their line numbers" do
      text = """
      #{@iss_l2}
      LONELY NAME
      #{@iss_l1}
      TRAILING NAME
      """

      assert {:ok, %{satellites: [], rejected: rejected, skipped: 3}} =
               Sidereon.parse_tle_file(text)

      assert [
               %{line_number: 1, name: "", issue: :orphan_line_2},
               %{line_number: 2, name: "LONELY NAME", issue: :missing_line_2},
               %{line_number: 4, name: "TRAILING NAME", issue: :orphan_name}
             ] = rejected
    end

    test "a checksum mismatch is rejected under :strict and reported under :lenient" do
      bad_l1 = String.slice(@iss_l1, 0, 68) <> "4"
      text = "#{bad_l1}\n#{@iss_l2}\n"

      assert {:ok, %{satellites: [], rejected: [%{issue: {:invalid, _}}]}} =
               Sidereon.parse_tle_file(text)

      assert {:ok, %{satellites: [sat], rejected: []}} =
               Sidereon.parse_tle_file(text, policy: :lenient)

      assert sat.checksum_warnings == [{"line 1", {:mismatch, 4}, 3}]
    end

    test "an unknown policy is refused" do
      assert {:error, {:invalid_field, :policy, :loose}} =
               Sidereon.parse_tle_file("", policy: :loose)
    end
  end

  describe "Sidereon.Format.TLE.parse/3 checksum policy" do
    test "refuses a mismatching checksum digit by default and reads it leniently" do
      bad_l1 = String.slice(@iss_l1, 0, 68) <> "4"

      assert {:error, {:checksum_mismatch, "line 1", 4, 3}} = TLE.parse(bad_l1, @iss_l2)

      assert {:ok, %Elements{catalog_number: "25544"}, [{"line 1", {:mismatch, 4}, 3}]} =
               TLE.parse_with_warnings(bad_l1, @iss_l2, policy: :lenient)
    end

    test "a leniently parsed pair propagates like the valid-line reference" do
      bad_l1 = String.slice(@iss_l1, 0, 68) <> "4"

      assert {:ok, lenient, [{"line 1", {:mismatch, 4}, 3}]} =
               TLE.parse_with_warnings(bad_l1, @iss_l2, policy: :lenient)

      assert {:ok, reference, []} = TLE.parse_with_warnings(@iss_l1, @iss_l2)

      datetime = ~U[2018-07-04 00:00:00Z]
      assert {:ok, lenient_state} = SGP4.propagate(lenient, datetime)
      assert {:ok, reference_state} = SGP4.propagate(reference, datetime)

      assert lenient_state.position == reference_state.position
      assert lenient_state.velocity == reference_state.velocity
    end

    test "a line without column 69 is read and reported under both policies" do
      short_l1 = String.slice(@iss_l1, 0, 68)

      for policy <- [:strict, :lenient] do
        assert {:ok, _elements, [{"line 1", :missing, 3}]} =
                 TLE.parse_with_warnings(short_l1, @iss_l2, policy: policy)
      end
    end

    test "keeps the assumed-decimal field text and writes it back" do
      l1 = "1 25544U 98067A   18184.80969102  .00001614  00000+0  31745-4 0  9993"
      l1 = String.slice(l1, 0, 68) <> Integer.to_string(checksum(l1))

      assert {:ok, el, []} = TLE.parse_with_warnings(l1, @iss_l2)
      assert el.mean_motion_double_dot_text == " 00000+0"
      assert el.bstar_text == " 31745-4"
      assert {:ok, {^l1, @iss_l2}} = TLE.encode(el)
    end

    test "blank bookkeeping fields read as nil and are written blank" do
      l1 = String.slice(@iss_l1, 0, 62) <> "      "
      l1 = l1 <> Integer.to_string(checksum(l1))
      l2 = String.slice(@iss_l2, 0, 63) <> "     "
      l2 = l2 <> Integer.to_string(checksum(l2))

      assert {:ok, el, []} = TLE.parse_with_warnings(l1, l2)
      assert el.ephemeris_type == nil
      assert el.elset_number == nil
      assert el.rev_number == nil
      assert {:ok, {^l1, ^l2}} = TLE.encode(el)
    end

    defp checksum(line) do
      line
      |> String.slice(0, 68)
      |> String.graphemes()
      |> Enum.reduce(0, fn
        "-", acc -> acc + 1
        c, acc when c in ~w(0 1 2 3 4 5 6 7 8 9) -> acc + String.to_integer(c)
        _, acc -> acc
      end)
      |> rem(10)
    end
  end
end
