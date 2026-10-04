defmodule Sidereon.NmeaTypedDiagnosticsTest do
  use ExUnit.Case, async: true

  alias Sidereon.GNSS.NMEA

  test "malformed public NMEA parse retains typed nested field error details" do
    text = "$GPGGA,123519,bad,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,"
    assert {:ok, parsed} = NMEA.parse(text)
    assert parsed.sentences == []
    assert [skip] = parsed.diagnostics.skips
    assert skip.reason == "malformed_field"
    assert skip.detail == "latitude: invalid float"
    assert skip.reason_kind == "malformed_field"
    assert skip.cause.kind == "float_parse"
    assert skip.cause.field == "latitude"
    assert skip.cause.value == "bad"
    assert skip.cause.min == nil
    assert skip.cause.max == nil
    assert skip.at.line == 1
  end
end
