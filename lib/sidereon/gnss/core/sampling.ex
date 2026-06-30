defmodule Sidereon.GNSS.Core.Sampling do
  @moduledoc false

  alias Sidereon.{Coordinates, Elements, SGP4}
  alias Sidereon.GNSS.Core.Epoch
  alias Sidereon.GNSS.SP3

  def sample_sp3(%SP3{} = sp3, sat_id, t0, t1, cadence_s) do
    steps = Epoch.steps(t0, t1, cadence_s)

    samples =
      steps
      |> Enum.reduce([], fn ep, acc ->
        case SP3.position(sp3, sat_id, ep) do
          {:ok, %{x_m: x, y_m: y, z_m: z}} -> [{ep, {x, y, z}} | acc]
          {:error, _} -> acc
        end
      end)
      |> Enum.reverse()

    {:ok, samples, length(steps)}
  end

  def sample_sgp4(%Elements{} = tle, t0, t1, cadence_s) do
    steps = Epoch.steps(t0, t1, cadence_s)

    samples =
      steps
      |> Enum.reduce([], fn ep, acc ->
        dt = DateTime.from_naive!(Epoch.to_naive!(ep), "Etc/UTC")

        case SGP4.propagate(tle, dt) do
          {:ok, teme} ->
            gcrs = Coordinates.teme_to_gcrs(teme, dt)
            {x_km, y_km, z_km} = Coordinates.gcrs_to_itrs(gcrs, dt)
            [{ep, {x_km * 1000.0, y_km * 1000.0, z_km * 1000.0}} | acc]

          _ ->
            acc
        end
      end)
      |> Enum.reverse()

    {:ok, samples, length(steps)}
  end
end
