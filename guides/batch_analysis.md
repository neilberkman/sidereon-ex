# Batch Analysis: Coverage, Visibility, and Link Budgets at Scale

When you need to answer questions like "which ground stations can see
this constellation right now?" or "what's the coverage probability
across a region over 24 hours?", propagating one satellite at a time
is too slow. The `Sidereon.Nx` module handles these batch workloads using
tensor operations that scale to thousands of satellites and grid points.

These functions automatically use GPU acceleration (Metal, CUDA) if
you add a backend like EXLA or Torchx to your project. No code changes
needed; just add the dependency and set the backend.

## Which Satellites Can a Ground Station See?

Given a constellation and a set of ground stations, compute visibility
in one call:

```elixir
# Satellite positions in ITRS (Earth-fixed) coordinates, [n, 3] tensor
# (You'd get these by propagating a constellation and converting to ITRS)
sat_positions = Nx.tensor([
  [4000.0, 3000.0, 4500.0],   # satellite 1
  [-2000.0, 5000.0, 3000.0],  # satellite 2
  [6000.0, -1000.0, 2000.0],  # satellite 3
], type: :f64)

# Ground stations as [m, 3]: lat, lon, altitude_m
stations = Nx.tensor([
  [40.7128, -74.006, 10.0],    # New York
  [51.5074, -0.1278, 11.0],   # London
  [35.6762, 139.6503, 40.0],  # Tokyo
], type: :f64)

# Get look angles for all satellite/station pairs
look = Sidereon.Nx.look_angles(sat_positions, stations)
# look.elevation is [3, 3]: elevation of each satellite from each station

# Which pairs are above 10° elevation?
visible = Sidereon.Nx.visible_mask(sat_positions, stations, min_elevation: 10.0)
# [3, 3] boolean tensor
```

## Coverage Over Time

Track how many satellites are visible from each ground station across
a time series:

```elixir
# elevation_series is [t, s, g]: t time steps, s satellites, g ground stations
# For example, 24 hours × 28 satellites × 50 ground stations at 5-min steps:
# shape [288, 28, 50]

# Count how many time steps each satellite-station pair has coverage
counts = Sidereon.Nx.access_counts(elevation_series, min_elevation: 10.0)
# shape [28, 50]: access count per satellite per station
```

## Batch Link Budget

Compute path loss and link margin for every visible satellite-station
pair simultaneously:

```elixir
# Path loss from range (any shape tensor)
fspl = Sidereon.Nx.fspl(look.range_km, 1616.0)

# Link margin for the entire visibility matrix
margin = Sidereon.Nx.link_margin(%{
  eirp_dbw: Nx.tensor(0.0),
  fspl_db: fspl,
  receiver_gt_dbk: Nx.tensor(-12.0),
  other_losses_db: Nx.tensor(3.0),
  required_cn0_dbhz: Nx.tensor(35.0)
})
# margin is [n, m]: link margin for each satellite from each station
```

## GPU Acceleration

By default, everything runs on CPU. To use GPU acceleration, add a
backend to your project's `mix.exs`:

```elixir
# For Apple Silicon (Metal)
{:torchx, "~> 0.7"}

# For NVIDIA GPUs or fast CPU (XLA)
{:exla, "~> 0.7"}
```

Then configure the backend:

```elixir
# In your application startup or config
Nx.global_default_backend(EXLA.Backend)
# or
Nx.global_default_backend({Torchx.Backend, device: :mps})
```

No changes to your Sidereon code needed; the same `Sidereon.Nx.look_angles/2`
call now runs on the GPU.
