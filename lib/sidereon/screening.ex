defmodule Sidereon.Screening do
  @moduledoc """
  Catalog-scale conjunction screening.

  Generates candidate pairs from many objects, applies coarse filters,
  and evaluates collision probability on surviving encounters.

  ## Where catalog management lives

  Sidereon treats "catalog" as a responsibility split across three modules
  rather than a single `Catalog` facade:

    * `Sidereon.CelesTrak` - fetches TLE / OMM data from public endpoints.
    * `Sidereon.Constellation` - holds a named set of propagated satellites
      and drives bulk operations like `propagate_all/2`.
    * `Sidereon.Screening` (this module) - consumes a materialized list of
      objects at a common epoch and produces conjunction results.

  A typical workflow pipes CelesTrak -> Constellation -> Screening. There
  is no separate `Sidereon.Catalog` module because that layer would only
  re-export these three with no additional behavior.
  """

  alias Sidereon.Collision
  alias Sidereon.Screening.Candidate
  alias Sidereon.Screening.Result

  @type object :: %{
          optional(:id) => String.t(),
          r: {float(), float(), float()},
          v: {float(), float(), float()},
          cov: [[float()]],
          hard_body_radius_km: float()
        }

  @doc """
  Screen a list of objects at a common epoch for potential conjunctions.

  ## Options
    * `:miss_threshold_km` - Coarse distance filter (default: 50.0)
    * `:pc_threshold` - Filter final results by risk (default: 0.0)
    * `:method` - Collision probability method (default: :equal_area)

  Returns a list of `%Result{}` sorted by decreasing Pc.
  """
  @spec screen_catalog([object()], keyword()) :: [Result.t()]
  def screen_catalog(objects, opts \\ []) do
    threshold = Keyword.get(opts, :miss_threshold_km, 50.0)
    pc_min = Keyword.get(opts, :pc_threshold, 0.0)
    method = Keyword.get(opts, :method, :equal_area)

    objects_with_index = Enum.with_index(objects)

    # Generate candidate pairs using a coarse distance filter
    candidates =
      for {obj1, i} <- objects_with_index,
          {obj2, j} <- objects_with_index,
          i < j,
          dist = distance(obj1.r, obj2.r),
          dist <= threshold do
        %Candidate{
          i: i,
          j: j,
          id1: obj1[:id],
          id2: obj2[:id],
          miss_km: dist
        }
      end

    # Evaluate Pc for candidates
    candidates
    |> Enum.map(fn cand ->
      obj1 = Enum.at(objects, cand.i)
      obj2 = Enum.at(objects, cand.j)

      params = %{
        r1: obj1.r,
        v1: obj1.v,
        cov1: obj1.cov,
        r2: obj2.r,
        v2: obj2.v,
        cov2: obj2.cov,
        hard_body_radius_km: obj1.hard_body_radius_km + obj2.hard_body_radius_km
      }

      case Collision.probability(params, method: method) do
        {:ok, col_res} ->
          %Result{candidate: cand, collision: col_res}

        {:error, reason} ->
          %Result{candidate: cand, error: reason}
      end
    end)
    |> Enum.filter(fn res ->
      case res.collision do
        # Keep errors for visibility
        nil -> true
        col -> col.pc >= pc_min
      end
    end)
    |> Enum.sort_by(fn res -> (res.collision && res.collision.pc) || 0.0 end, :desc)
  end

  defp distance({x1, y1, z1}, {x2, y2, z2}) do
    :math.sqrt(:math.pow(x1 - x2, 2) + :math.pow(y1 - y2, 2) + :math.pow(z1 - z2, 2))
  end
end
