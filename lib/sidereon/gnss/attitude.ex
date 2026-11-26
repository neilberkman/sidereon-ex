defmodule Sidereon.GNSS.Attitude do
  @moduledoc """
  GNSS spacecraft block identification, published yaw-law parameters,
  nominal yaw steering and Sun-fixed axes.
  """
  alias Sidereon.GNSS.Attitude
  alias Sidereon.GNSS.Attitude.OrbitAttitudeTrajectory
  alias Sidereon.NIF

  @typedoc "Cartesian components in x, y, z order."
  @type vector :: {number(), number(), number()}

  defmodule AttitudeMode do
    @moduledoc "The attitude regime applied at the requested epoch."
    @type t :: :nominal | :noon_turn | :midnight_turn | :shadow | :orbit_normal | :modified_yaw_steering
  end

  defmodule CosineTurnStartAngle do
    @moduledoc "The angle whose threshold starts a cosine turn."
    @type t :: :colinearity | :orbit_angle
  end

  defmodule BeidouManufacturer do
    @moduledoc "BeiDou spacecraft manufacturer."
    @type t :: :cast | :secm

    @doc "Compare two BeidouManufacturer values in declaration order."
    @spec compare(t(), t()) :: :lt | :eq | :gt
    def compare(first, second), do: NIF.attitude_manufacturer_compare(first, second)
  end

  defmodule BeidouOrbitClass do
    @moduledoc "BeiDou satellite orbit class."
    @type t :: :geo | :igso | :meo

    @doc "Compare two BeidouOrbitClass values in declaration order."
    @spec compare(t(), t()) :: :lt | :eq | :gt
    def compare(first, second), do: NIF.attitude_orbit_class_compare(first, second)
  end

  defmodule AttitudeSample do
    @moduledoc "One geocentric inertial satellite state and Sun position in SI units. This struct compares by value."
    @enforce_keys [:position_m, :velocity_m_s, :sun_position_m]
    defstruct [:position_m, :velocity_m_s, :sun_position_m]

    @type t :: %__MODULE__{
            position_m: Attitude.vector(),
            velocity_m_s: Attitude.vector(),
            sun_position_m: Attitude.vector()
          }
  end

  defmodule DybAxes do
    @moduledoc "Sun-fixed unit axes pointing toward the Sun, along the solar-panel axis and completing the frame. This struct compares by value."
    @enforce_keys [:d, :y, :b]
    defstruct [:d, :y, :b]
    @type t :: %__MODULE__{d: Attitude.vector(), y: Attitude.vector(), b: Attitude.vector()}
  end

  defmodule NominalYaw do
    @moduledoc "Nominal yaw and Sun elevation in radians and the corresponding body axes. This struct compares by value."
    @enforce_keys [:yaw_rad, :beta_rad, :body_x, :body_y, :body_z]
    defstruct [:yaw_rad, :beta_rad, :body_x, :body_y, :body_z]

    @type t :: %__MODULE__{
            yaw_rad: float(),
            beta_rad: float(),
            body_x: Attitude.vector(),
            body_y: Attitude.vector(),
            body_z: Attitude.vector()
          }
  end

  defmodule GnssAttitude do
    @moduledoc "Yaw and body axes at one instant, with the mode, orbit angle and Sun-fixed axes. This struct compares by value."
    @enforce_keys [:mode, :yaw_rad, :nominal_yaw_rad, :beta_rad, :orbit_angle_rad, :body_x, :body_y, :body_z, :dyb]
    defstruct [:mode, :yaw_rad, :nominal_yaw_rad, :beta_rad, :orbit_angle_rad, :body_x, :body_y, :body_z, :dyb]

    @type t :: %__MODULE__{
            mode: AttitudeMode.t(),
            yaw_rad: float(),
            nominal_yaw_rad: float(),
            beta_rad: float(),
            orbit_angle_rad: float(),
            body_x: Attitude.vector(),
            body_y: Attitude.vector(),
            body_z: Attitude.vector(),
            dyb: DybAxes.t() | nil
          }
  end

  defmodule CosineTurnParameters do
    @moduledoc "Start criteria and period of an attitude cosine turn. This struct compares by value."
    @enforce_keys [:beta_limit_rad, :beta_limit_inclusive, :start_angle, :start_angle_rad, :period_s]
    defstruct [:beta_limit_rad, :beta_limit_inclusive, :start_angle, :start_angle_rad, :period_s]

    @type t :: %__MODULE__{
            beta_limit_rad: float(),
            beta_limit_inclusive: boolean(),
            start_angle: CosineTurnStartAngle.t(),
            start_angle_rad: float(),
            period_s: float()
          }
  end

  defmodule GnssBlockError do
    @moduledoc "A GnssBlock refusal with its details."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}

    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  defmodule GnssAttitudeError do
    @moduledoc "A GnssAttitude refusal with its details."
    defstruct [:kind, :detail, :message]
    @type t :: %__MODULE__{kind: atom(), detail: map(), message: String.t()}

    defimpl String.Chars do
      def to_string(error), do: error.message
    end
  end

  defmodule GnssBlock do
    @moduledoc "A GNSS block with a published yaw law. Block values compare by value."
    alias Sidereon.GNSS.Attitude.BeidouManufacturer
    alias Sidereon.GNSS.Attitude.BeidouOrbitClass
    alias Sidereon.GNSS.Attitude.GnssBlockError
    alias Sidereon.GNSS.System

    @type t ::
            :gps_iia
            | :gps_iir
            | :gps_iirm
            | :gps_iif
            | :gps_iii
            | :glonass_m
            | :galileo_iov
            | :galileo_foc
            | :beidou2_geo
            | :beidou2_igso
            | :beidou2_meo
            | :beidou3_geo
            | :beidou3_igso
            | {:beidou3_meo, BeidouManufacturer.t() | nil}

    @doc "Parse an IGS or ANTEX spacecraft block name."
    @spec from_igs_name(String.t()) :: {:ok, t()} | {:error, GnssBlockError.t()}
    def from_igs_name(name), do: decode(NIF.attitude_block_from_igs_name(name))

    @doc "Parse a constellation block type and, for BeiDou, its orbit class."
    @spec from_constellation_block_type(atom() | String.t(), String.t(), BeidouOrbitClass.t() | nil) ::
            {:ok, t()} | {:error, GnssBlockError.t()}
    def from_constellation_block_type(system, block_type, orbit_class \\ nil) do
      case System.letter(system) do
        {:ok, letter} ->
          decode(NIF.attitude_block_from_constellation_block_type(letter, block_type, orbit_class))

        {:error, _} ->
          {:error, %GnssBlockError{kind: :invalid_system, detail: %{system: system}, message: "Invalid GNSS system"}}
      end
    end

    @doc "Return the canonical IGS block name."
    @spec igs_name(t()) :: String.t()
    def igs_name(block), do: NIF.attitude_block_igs_name(block)

    @doc "Return the constellation letter of the block."
    @spec system(t()) :: String.t()
    def system(block), do: NIF.attitude_block_system(block)

    defp decode({:ok, _value} = result), do: result
    defp decode({:error, detail}), do: {:error, struct!(GnssBlockError, detail)}

    @doc "Compare two GnssBlock values in declaration order."
    @spec compare(t(), t()) :: :lt | :eq | :gt
    def compare(first, second), do: NIF.attitude_block_compare(first, second)

    @doc "Return the display name of the GNSS block."
    @spec to_string(t()) :: String.t()
    def to_string(block), do: NIF.attitude_block_igs_name(block)
  end

  defmodule GnssAttitudeLaw do
    @moduledoc "The name and parameters of a GNSS yaw law. Law values compare by value."
    alias Sidereon.GNSS.Attitude.CosineTurnParameters
    alias Sidereon.GNSS.Attitude.GnssAttitudeError
    alias Sidereon.GNSS.Attitude.GnssBlock

    @type t :: :orbit_normal | {:cosine_turn, CosineTurnParameters.t()} | {atom(), map()}

    @doc "Return the published law and parameters for a block. GPS IIA requires a PRN."
    @spec for_block(GnssBlock.t(), byte() | nil) :: {:ok, t()} | {:error, GnssAttitudeError.t()}
    def for_block(block, prn \\ nil) do
      case NIF.attitude_law_for_block(block, prn) do
        {:ok, {:cosine_turn, parameters}} ->
          {:ok, {:cosine_turn, struct!(CosineTurnParameters, parameters)}}

        {:ok, {:beidou3_meo_unknown_manufacturer, detail}} ->
          {:ok, {:beidou3_meo_unknown_manufacturer, %{detail | cast: struct!(CosineTurnParameters, detail.cast)}}}

        {:ok, _value} = result ->
          result

        {:error, detail} ->
          {:error, struct!(GnssAttitudeError, detail)}
      end
    end

    @doc "Construct the gps iia attitude law."
    @spec gps_iia(number(), number(), number()) :: t()
    def gps_iia(yaw_rate_rad_s, yaw_bias_rad, shadow_limit_rad),
      do:
        {:gps_iia,
         %{
           yaw_rate_rad_s: yaw_rate_rad_s / 1.0,
           yaw_bias_rad: yaw_bias_rad / 1.0,
           shadow_limit_rad: shadow_limit_rad / 1.0
         }}

    @doc "Construct the gps iir attitude law."
    @spec gps_iir(number()) :: t()
    def gps_iir(yaw_rate_rad_s), do: {:gps_iir, %{yaw_rate_rad_s: yaw_rate_rad_s / 1.0}}

    @doc "Construct the gps iif attitude law."
    @spec gps_iif(number(), number(), number()) :: t()
    def gps_iif(yaw_rate_rad_s, yaw_bias_rad, shadow_limit_rad),
      do:
        {:gps_iif,
         %{
           yaw_rate_rad_s: yaw_rate_rad_s / 1.0,
           yaw_bias_rad: yaw_bias_rad / 1.0,
           shadow_limit_rad: shadow_limit_rad / 1.0
         }}

    @doc "Construct the glonass m attitude law."
    @spec glonass_m(number(), number()) :: t()
    def glonass_m(yaw_rate_rad_s, shadow_limit_rad),
      do: {:glonass_m, %{yaw_rate_rad_s: yaw_rate_rad_s / 1.0, shadow_limit_rad: shadow_limit_rad / 1.0}}

    @doc "Construct the galileo iov attitude law."
    @spec galileo_iov(number(), number()) :: t()
    def galileo_iov(beta_x_rad, beta_y_rad),
      do: {:galileo_iov, %{beta_x_rad: beta_x_rad / 1.0, beta_y_rad: beta_y_rad / 1.0}}

    @doc "Construct the cosine turn attitude law."
    @spec cosine_turn(CosineTurnParameters.t()) :: t()
    def cosine_turn(parameters), do: {:cosine_turn, parameters}

    @doc "Construct the beidou orbit normal switch attitude law."
    @spec beidou_orbit_normal_switch(number(), number()) :: t()
    def beidou_orbit_normal_switch(ys_to_on_beta_rad, on_to_ys_beta_rad),
      do:
        {:beidou_orbit_normal_switch,
         %{ys_to_on_beta_rad: ys_to_on_beta_rad / 1.0, on_to_ys_beta_rad: on_to_ys_beta_rad / 1.0}}

    @doc "Construct the fixed beta yaw steering attitude law."
    @spec fixed_beta_yaw_steering(number()) :: t()
    def fixed_beta_yaw_steering(beta0_rad), do: {:fixed_beta_yaw_steering, %{beta0_rad: beta0_rad / 1.0}}

    @doc "Construct the beidou3 meo unknown manufacturer attitude law."
    @spec beidou3_meo_unknown_manufacturer(CosineTurnParameters.t(), number()) :: t()
    def beidou3_meo_unknown_manufacturer(cast, secm_beta0_rad),
      do: {:beidou3_meo_unknown_manufacturer, %{cast: cast, secm_beta0_rad: secm_beta0_rad / 1.0}}

    @doc "Construct the orbit normal attitude law."
    @spec orbit_normal() :: t()
    def orbit_normal, do: :orbit_normal
  end

  @doc """
  Evaluate the yaw law along an orbit at TDB seconds past J2000.

  The body and Sun-fixed axes are in GCRF. The law can request samples at
  neighbouring times, which must also be inside the trajectory coverage.
  """
  @spec gnss_attitude(GnssAttitudeLaw.t(), OrbitAttitudeTrajectory.t(), number()) ::
          {:ok, GnssAttitude.t()} | {:error, GnssAttitudeError.t()}
  def gnss_attitude(law, %OrbitAttitudeTrajectory{} = trajectory, t_s) do
    case NIF.gnss_attitude(law, OrbitAttitudeTrajectory.native(trajectory), t_s / 1.0) do
      {:ok, %{dyb: dyb} = value} ->
        {:ok, struct!(GnssAttitude, %{value | dyb: if(dyb, do: struct!(DybAxes, dyb))})}

      {:error, details} ->
        {:error, struct!(GnssAttitudeError, details)}
    end
  end

  @doc "Evaluate nominal yaw steering from geocentric inertial coordinates in SI units."
  @spec nominal_yaw(vector(), vector(), vector()) :: {:ok, NominalYaw.t()} | {:error, GnssAttitudeError.t()}
  def nominal_yaw(position_m, velocity_m_s, sun_position_m) do
    NIF.attitude_nominal_yaw(vector(position_m), vector(velocity_m_s), vector(sun_position_m))
    |> decode(NominalYaw)
  end

  @doc "Evaluate Sun-fixed DYB axes from geocentric inertial positions in metres."
  @spec dyb_axes(vector(), vector()) :: {:ok, DybAxes.t()} | {:error, GnssAttitudeError.t()}
  def dyb_axes(position_m, sun_position_m) do
    NIF.attitude_dyb_axes(vector(position_m), vector(sun_position_m)) |> decode(DybAxes)
  end

  @doc "Return the published GPS IIA maximum yaw rate in radians per second, when known."
  @spec gps_iia_default_yaw_rate_rad_s(byte()) :: float() | nil
  def gps_iia_default_yaw_rate_rad_s(prn), do: NIF.attitude_gps_iia_default_yaw_rate_rad_s(prn)

  defp vector({x, y, z}), do: {x / 1.0, y / 1.0, z / 1.0}
  defp decode({:ok, value}, module), do: {:ok, struct!(module, value)}
  defp decode({:error, details}, _module), do: {:error, struct!(GnssAttitudeError, details)}

  @doc "Return the gps iia default yaw bias rad constant."
  @spec gps_iia_default_yaw_bias_rad() :: float()
  def gps_iia_default_yaw_bias_rad, do: NIF.attitude_gps_iia_default_yaw_bias_rad()

  @doc "Return the gps iir default yaw rate rad s constant."
  @spec gps_iir_default_yaw_rate_rad_s() :: float()
  def gps_iir_default_yaw_rate_rad_s, do: NIF.attitude_gps_iir_default_yaw_rate_rad_s()

  @doc "Return the gps iif default yaw rate rad s constant."
  @spec gps_iif_default_yaw_rate_rad_s() :: float()
  def gps_iif_default_yaw_rate_rad_s, do: NIF.attitude_gps_iif_default_yaw_rate_rad_s()

  @doc "Return the gps iif default yaw bias rad constant."
  @spec gps_iif_default_yaw_bias_rad() :: float()
  def gps_iif_default_yaw_bias_rad, do: NIF.attitude_gps_iif_default_yaw_bias_rad()

  @doc "Return the gps shadow limit rad constant."
  @spec gps_shadow_limit_rad() :: float()
  def gps_shadow_limit_rad, do: NIF.attitude_gps_shadow_limit_rad()

  @doc "Return the glonass m default yaw rate rad s constant."
  @spec glonass_m_default_yaw_rate_rad_s() :: float()
  def glonass_m_default_yaw_rate_rad_s, do: NIF.attitude_glonass_m_default_yaw_rate_rad_s()

  @doc "Return the glonass m shadow limit rad constant."
  @spec glonass_m_shadow_limit_rad() :: float()
  def glonass_m_shadow_limit_rad, do: NIF.attitude_glonass_m_shadow_limit_rad()

  @doc "Return the galileo iov beta x rad constant."
  @spec galileo_iov_beta_x_rad() :: float()
  def galileo_iov_beta_x_rad, do: NIF.attitude_galileo_iov_beta_x_rad()

  @doc "Return the galileo iov beta y rad constant."
  @spec galileo_iov_beta_y_rad() :: float()
  def galileo_iov_beta_y_rad, do: NIF.attitude_galileo_iov_beta_y_rad()

  @doc "Return the gps iii beta x rad constant."
  @spec gps_iii_beta_x_rad() :: float()
  def gps_iii_beta_x_rad, do: NIF.attitude_gps_iii_beta_x_rad()

  @doc "Return the gps iii beta y rad constant."
  @spec gps_iii_beta_y_rad() :: float()
  def gps_iii_beta_y_rad, do: NIF.attitude_gps_iii_beta_y_rad()

  @doc "Return the galileo foc turn constant."
  @spec galileo_foc_turn() :: CosineTurnParameters.t()
  def galileo_foc_turn, do: struct!(CosineTurnParameters, NIF.attitude_galileo_foc_turn())

  @doc "Return the beidou3 cast meo turn constant."
  @spec beidou3_cast_meo_turn() :: CosineTurnParameters.t()
  def beidou3_cast_meo_turn, do: struct!(CosineTurnParameters, NIF.attitude_beidou3_cast_meo_turn())

  @doc "Return the beidou3 cast igso turn constant."
  @spec beidou3_cast_igso_turn() :: CosineTurnParameters.t()
  def beidou3_cast_igso_turn, do: struct!(CosineTurnParameters, NIF.attitude_beidou3_cast_igso_turn())

  @doc "Return the beidou3 secm beta0 rad constant."
  @spec beidou3_secm_beta0_rad() :: float()
  def beidou3_secm_beta0_rad, do: NIF.attitude_beidou3_secm_beta0_rad()

  @doc "Return the beidou2 ys to on beta rad constant."
  @spec beidou2_ys_to_on_beta_rad() :: float()
  def beidou2_ys_to_on_beta_rad, do: NIF.attitude_beidou2_ys_to_on_beta_rad()

  @doc "Return the beidou2 on to ys beta rad constant."
  @spec beidou2_on_to_ys_beta_rad() :: float()
  def beidou2_on_to_ys_beta_rad, do: NIF.attitude_beidou2_on_to_ys_beta_rad()
end
