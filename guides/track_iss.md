# Track the ISS from a Ground Station

This guide walks through fetching the ISS TLE, propagating its orbit,
computing look angles, and setting up real-time tracking, all in about
20 lines of Elixir.

## Fetch the TLE

```elixir
{:ok, [iss]} = Sidereon.CelesTrak.fetch_tle(25544)
```

## Propagate to Now

```elixir
{:ok, teme} = Sidereon.propagate(iss, DateTime.utc_now())
IO.inspect(teme.position, label: "TEME position (km)")
```

## Get Geodetic Coordinates

```elixir
{:ok, geo} = Sidereon.geodetic(iss, DateTime.utc_now())
IO.puts("ISS is at #{Float.round(geo.latitude, 2)}°N, #{Float.round(geo.longitude, 2)}°E")
IO.puts("Altitude: #{Float.round(geo.altitude_km, 1)} km")
```

## Look Angles from Your Location

```elixir
# New York City
station = %{latitude: 40.7128, longitude: -74.006, altitude_m: 10.0}

{:ok, look} = Sidereon.look_angle(iss, DateTime.utc_now(), station)
IO.puts("Azimuth: #{Float.round(look.azimuth, 1)}°")
IO.puts("Elevation: #{Float.round(look.elevation, 1)}°")
IO.puts("Range: #{Float.round(look.range_km, 1)} km")

if look.elevation > 0 do
  IO.puts("ISS is above the horizon!")
else
  IO.puts("ISS is below the horizon.")
end
```

## Real-Time Tracking

Start a tracker that updates every second:

```elixir
{:ok, tracker} = Sidereon.Tracker.start_link(iss, interval_ms: 1000)
Sidereon.Tracker.subscribe(tracker)

# Receive 5 updates
for _ <- 1..5 do
  receive do
    {:sidereon_tracker, _pid, state} ->
      geo = state.geodetic
      IO.puts("#{state.time} | #{Float.round(geo.latitude, 2)}°N, #{Float.round(geo.longitude, 2)}°E | #{Float.round(geo.altitude_km, 1)} km")
  end
end

Sidereon.Tracker.stop(tracker)
```

## Predict Passes

Find when the ISS will be visible from your location:

```elixir
now = DateTime.utc_now()
tomorrow = DateTime.add(now, 86400, :second)

passes = Sidereon.Passes.predict(iss, station, now, tomorrow, min_elevation: 10.0)

for pass <- passes do
  duration = DateTime.diff(pass.set, pass.rise)
  IO.puts("Rise: #{pass.rise} | Max el: #{Float.round(pass.max_elevation, 1)}° | Duration: #{duration}s")
end
```

## RF Link Budget

Compute path loss for a UHF amateur radio link (437 MHz):

```elixir
{:ok, look} = Sidereon.look_angle(iss, DateTime.utc_now(), station)

if look.elevation > 0 do
  fspl = Sidereon.RF.fspl(look.range_km, 437.0)
  IO.puts("Free-space path loss: #{Float.round(fspl, 1)} dB")

  margin = Sidereon.RF.link_margin(%{
    eirp_dbw: Sidereon.RF.eirp(30.0, 10.0),  # 1W + 10 dBi Yagi
    fspl_db: fspl,
    receiver_gt_dbk: -20.0,
    other_losses_db: 3.0,
    required_cn0_dbhz: 30.0
  })
  IO.puts("Link margin: #{Float.round(margin, 1)} dB")
end
```
