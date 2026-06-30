defmodule Sidereon.Collision do
  @moduledoc """
  Collision probability calculation for close approaches.

  Computes `Pc` from relative state, covariance, and hard-body radius
  using encounter-plane methods such as Foster 2D.

  This module is intended for operational conjunction screening and
  standards-based workflows such as CCSDS CDM ingestion.

  The encounter geometry and `Pc` integration are implemented in the
  `sidereon-core` core; this module validates the covariance inputs, selects
  the method, marshals across the NIF, and packages the `%Result{}`.
  """

  alias Sidereon.Collision.Result
  alias Sidereon.Covariance
  alias Sidereon.NIF

  @type params :: %{
          r1: {float(), float(), float()},
          v1: {float(), float(), float()},
          cov1: [[float()]],
          r2: {float(), float(), float()},
          v2: {float(), float(), float()},
          cov2: [[float()]],
          hard_body_radius_km: float()
        }

  # Maps the public method option to the core method atom and the method tag
  # reported on the result.
  @methods %{
    equal_area: {:equal_area, :foster_2d_equal_area},
    numerical: {:numerical, :foster_2d_numerical},
    alfano_2005: {:alfano_2005, :alfano_2005}
  }

  @doc """
  Compute collision probability from two objects' states and covariances.

  All positions in km, velocities in km/s, covariances in km².

  ## Options
    * `:method` - one of:
      * `:equal_area` (default) - Foster 2D equal-area-square approximation
      * `:numerical` - Foster 2D with polar-grid numerical integration
      * `:alfano_2005` - Alfano (2005) 1D Simpson's rule with analytical
        cross-axis integration. Independent cross-check against the Foster
        methods.

  Returns `{:ok, %Result{}}` or `{:error, reason}`.
  """
  @spec probability(params(), keyword()) :: {:ok, Result.t()} | {:error, String.t()}
  def probability(params, opts \\ []) do
    %{cov1: cov1, cov2: cov2} = params

    cond do
      not Covariance.valid_matrix?(cov1) ->
        {:error, "cov1 is not a 3x3 numeric matrix"}

      not Covariance.valid_matrix?(cov2) ->
        {:error, "cov2 is not a 3x3 numeric matrix"}

      not Covariance.positive_semidefinite?(cov1) ->
        {:error, "cov1 is not positive semidefinite"}

      not Covariance.positive_semidefinite?(cov2) ->
        {:error, "cov2 is not positive semidefinite"}

      true ->
        method = Keyword.get(opts, :method, :equal_area)

        case Map.fetch(@methods, method) do
          {:ok, {core_method, _}} -> run(params, core_method)
          :error -> {:error, "unsupported method: #{method}"}
        end
    end
  end

  @doc """
  Compute Pc using the 2D Foster method with equal-area square approximation.
  """
  @spec probability_equal_area(params()) :: {:ok, Result.t()} | {:error, String.t()}
  def probability_equal_area(params), do: run(params, :equal_area)

  @doc """
  Compute Pc using the 2D Foster method with numerical integration over the circle.
  """
  @spec probability_numerical(params()) :: {:ok, Result.t()} | {:error, String.t()}
  def probability_numerical(params), do: run(params, :numerical)

  @doc """
  Compute Pc using the Alfano (2005) method.

  Uses 1D Simpson's composite rule along the principal x axis of the
  encounter-plane covariance, with the cross-axis integration evaluated
  analytically as the difference of two error functions. This uses a 1D
  scan in place of the 2D quadrature grid used by `probability_numerical/1`
  for elongated covariance cases.

  Reference: Alfano, S., "A Numerical Implementation of Spherical Object
  Collision Probability," Journal of the Astronautical Sciences, Vol. 53,
  No. 1, Jan-Mar 2005, pp. 103-109.
  """
  @spec probability_alfano_2005(params()) :: {:ok, Result.t()} | {:error, String.t()}
  def probability_alfano_2005(params), do: run(params, :alfano_2005)

  defp run(params, core_method) do
    %{r1: r1, v1: v1, cov1: cov1, r2: r2, v2: v2, cov2: cov2, hard_body_radius_km: hbr} = params
    {_, result_method} = Map.fetch!(@methods, core_method)

    case NIF.collision_probability(r1, v1, cov1, r2, v2, cov2, hbr, core_method) do
      {:ok, {pc, miss_km, relative_speed_km_s, sigma_x_km, sigma_z_km}} ->
        {:ok,
         %Result{
           pc: pc,
           miss_km: miss_km,
           relative_speed_km_s: relative_speed_km_s,
           sigma_x_km: sigma_x_km,
           sigma_z_km: sigma_z_km,
           method: result_method
         }}

      {:error, reason} ->
        {:error, conjunction_reason(reason)}
    end
  end

  # The core returns the zero-relative-velocity case as the `:undefined_frame`
  # atom; surface it as this module's documented string reason.
  defp conjunction_reason(:undefined_frame), do: "zero relative velocity"
  defp conjunction_reason(reason), do: reason
end
