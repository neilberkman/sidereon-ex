# Predict Passes with Doppler

Complete pass prediction with look angles and Doppler shift at each
moment of the pass. Useful for ground station automation, antenna
pointing, and frequency compensation.

## Setup

```elixir
# Fetch a satellite
{:ok, [sat]} = Sidereon.CelesTrak.fetch_tle(25544)

# Define your ground station
station = %{latitude: 51.5074, longitude: -0.1278, altitude_m: 11.0}  # London
```

## Find Passes

```elixir
start = DateTime.utc_now()
stop = DateTime.add(start, 86400, :second)

passes = Sidereon.Passes.predict(sat, station, start, stop, min_elevation: 5.0)
IO.puts("Found #{length(passes)} passes above 5°")
```

## Detailed Pass Report

For each pass, sample the trajectory at 10-second intervals:

```elixir
for pass <- Enum.take(passes, 3) do
  IO.puts("\n--- Pass: #{pass.rise} to #{pass.set} (max el: #{Float.round(pass.max_elevation, 1)}°) ---")
  IO.puts("Time                     | Az     | El    | Range km | Doppler Hz")
  IO.puts(String.duplicate("-", 75))

  duration = DateTime.diff(pass.set, pass.rise)
  steps = div(duration, 10)

  for i <- 0..steps do
    dt = DateTime.add(pass.rise, i * 10, :second)

    case Sidereon.look_angle(sat, dt, station) do
      {:ok, look} when look.elevation > 0 ->
        # Doppler at 437 MHz (UHF amateur)
        {:ok, doppler} = Sidereon.doppler(sat, dt, station, 437.0e6)

        IO.puts(
          "#{dt} | #{String.pad_leading(Float.to_string(Float.round(look.azimuth, 1)), 6)} " <>
          "| #{String.pad_leading(Float.to_string(Float.round(look.elevation, 1)), 5)} " <>
          "| #{String.pad_leading(Float.to_string(Float.round(look.range_km, 0)), 8)} " <>
          "| #{Float.round(doppler.doppler_shift_hz, 0)}"
        )

      _ ->
        :skip
    end
  end
end
```

## Eclipse-Aware Passes

Check whether the satellite is sunlit during a pass (important for
optical observations):

```elixir
# Requires a JPL ephemeris file for Sun position
# Download de421.bsp from https://naif.jpl.nasa.gov/pub/naif/generic_kernels/spk/planets/
eph = Sidereon.Ephemeris.load("/path/to/de421.bsp")

for pass <- passes do
  {:ok, status} = Sidereon.Eclipse.check(sat, pass.max_elevation_time, eph)

  case status do
    :sunlit -> IO.puts("#{pass.rise}: VISIBLE (sunlit, max el #{Float.round(pass.max_elevation, 1)}°)")
    :penumbra -> IO.puts("#{pass.rise}: partial shadow")
    :umbra -> IO.puts("#{pass.rise}: in Earth's shadow")
  end
end
```
