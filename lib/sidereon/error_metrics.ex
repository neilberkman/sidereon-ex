defmodule Sidereon.ErrorMetrics do
  @moduledoc """
  Position error metrics derived from supplied covariance matrices.

  Covariances are in square metres. ENU axes are east, north, up. ECEF
  covariances are rotated at the supplied WGS84 geodetic reference before
  metrics are computed.
  """

  alias __MODULE__.ErrorEllipse
  alias __MODULE__.PercentileRadius
  alias __MODULE__.PositionErrorMetrics
  alias Sidereon.NIF

  defmodule ErrorEllipse do
    @moduledoc """
    Horizontal one-sigma error ellipse.
    """

    @enforce_keys [:semi_major_m, :semi_minor_m, :orientation_rad]
    defstruct [:semi_major_m, :semi_minor_m, :orientation_rad]

    @type t :: %__MODULE__{
            semi_major_m: float(),
            semi_minor_m: float(),
            orientation_rad: float()
          }
  end

  defmodule PercentileRadius do
    @moduledoc """
    Exact percentile circle or sphere radius plus the named approximation.
    """

    @enforce_keys [:probability, :radius_m, :approx_m, :approx_valid]
    defstruct [:probability, :radius_m, :approx_m, :approx_valid]

    @type t :: %__MODULE__{
            probability: float(),
            radius_m: float(),
            approx_m: float(),
            approx_valid: boolean()
          }
  end

  defmodule PositionErrorMetrics do
    @moduledoc """
    Standard horizontal, vertical, and three-dimensional position error metrics.
    """

    @enforce_keys [
      :ellipse,
      :sigma_e_m,
      :sigma_n_m,
      :sigma_u_m,
      :cep_m,
      :r95_m,
      :r99_m,
      :drms_m,
      :two_drms_m,
      :vep_m,
      :sep_m,
      :mrse_m
    ]
    defstruct [
      :ellipse,
      :sigma_e_m,
      :sigma_n_m,
      :sigma_u_m,
      :cep_m,
      :r95_m,
      :r99_m,
      :drms_m,
      :two_drms_m,
      :vep_m,
      :sep_m,
      :mrse_m
    ]

    @type t :: %__MODULE__{
            ellipse: ErrorEllipse.t(),
            sigma_e_m: float(),
            sigma_n_m: float(),
            sigma_u_m: float(),
            cep_m: PercentileRadius.t(),
            r95_m: PercentileRadius.t(),
            r99_m: PercentileRadius.t(),
            drms_m: float(),
            two_drms_m: float(),
            vep_m: float(),
            sep_m: PercentileRadius.t(),
            mrse_m: float()
          }
  end

  @type covariance3 :: [[number()]]
  @type geodetic_radians_m :: {number(), number(), number()}
  @type error_reason ::
          :non_finite
          | :not_positive_semidefinite
          | :invalid_probability
          | :rotation
          | term()

  @doc """
  Compute position error metrics from an ENU covariance matrix in square metres.
  """
  @spec from_enu_covariance(covariance3()) :: {:ok, PositionErrorMetrics.t()} | {:error, error_reason()}
  def from_enu_covariance(covariance_enu_m2) do
    case NIF.position_error_metrics_from_enu_covariance(rows(covariance_enu_m2)) do
      {:ok, metrics} -> {:ok, metrics(metrics)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Compute position error metrics from an ECEF covariance matrix in square metres.

  The receiver is `{lat_rad, lon_rad, height_m}`.
  """
  @spec from_ecef_covariance(covariance3(), geodetic_radians_m()) ::
          {:ok, PositionErrorMetrics.t()} | {:error, error_reason()}
  def from_ecef_covariance(covariance_ecef_m2, receiver_llh_rad_m) do
    case NIF.position_error_metrics_from_ecef_covariance(rows(covariance_ecef_m2), vec3(receiver_llh_rad_m)) do
      {:ok, metrics} -> {:ok, metrics(metrics)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @doc """
  Compute position error metrics from a kinematic solution-like map or struct.

  The value must provide `:position_m` and `:position_covariance_m2`.
  """
  @spec from_kinematic_solution(map()) :: {:ok, PositionErrorMetrics.t()} | {:error, error_reason()}
  def from_kinematic_solution(solution) when is_map(solution) do
    position_m = Map.fetch!(solution, :position_m)
    covariance_m2 = Map.fetch!(solution, :position_covariance_m2)

    case NIF.position_error_metrics_from_kinematic_solution(vec3(position_m), rows(covariance_m2)) do
      {:ok, metrics} -> {:ok, metrics(metrics)}
      {:error, _} = err -> err
      other -> {:error, other}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  defp metrics(value) do
    %PositionErrorMetrics{
      ellipse: ellipse(value.ellipse),
      sigma_e_m: value.sigma_e_m,
      sigma_n_m: value.sigma_n_m,
      sigma_u_m: value.sigma_u_m,
      cep_m: percentile(value.cep_m),
      r95_m: percentile(value.r95_m),
      r99_m: percentile(value.r99_m),
      drms_m: value.drms_m,
      two_drms_m: value.two_drms_m,
      vep_m: value.vep_m,
      sep_m: percentile(value.sep_m),
      mrse_m: value.mrse_m
    }
  end

  defp ellipse(value) do
    %ErrorEllipse{
      semi_major_m: value.semi_major_m,
      semi_minor_m: value.semi_minor_m,
      orientation_rad: value.orientation_rad
    }
  end

  defp percentile(value) do
    %PercentileRadius{
      probability: value.probability,
      radius_m: value.radius_m,
      approx_m: value.approx_m,
      approx_valid: value.approx_valid
    }
  end

  defp rows(matrix), do: Enum.map(matrix, fn row -> Enum.map(row, &(&1 / 1.0)) end)
  defp vec3({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}
  defp vec3([x, y, z]), do: {x / 1.0, y / 1.0, z / 1.0}
end
