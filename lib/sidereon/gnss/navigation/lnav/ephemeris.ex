defmodule Sidereon.GNSS.Navigation.LNAV.Ephemeris do
  @moduledoc """
  GPS LNAV clock and ephemeris parameters in engineering units.

  Each field holds the natural engineering-unit value, i.e. the product of the
  integer transmitted in the LNAV message and that parameter's IS-GPS-200 scale
  factor (the value listed in IS-GPS-200 Tables 20-I, 20-II, and 20-III).
  Angular ephemeris terms are in *semicircles* (1 semicircle = pi radians);
  multiply by pi to obtain radians. The harmonic correction terms are already in
  radians.

  ## Subframe 1 - clock and health (IS-GPS-200 Table 20-I)

    * `:week_number` - GPS week number, 10-bit truncated (weeks, integer).
    * `:l2_code` - code(s) on L2 indicator (2-bit code, integer; default 0).
    * `:l2_p_data_flag` - L2-P data flag (0/1; default 0).
    * `:ura_index` - SV accuracy (URA) index, 0..15 (integer).
    * `:sv_health` - SV health, 6-bit (integer).
    * `:iodc` - issue of data, clock, 10-bit (integer).
    * `:tgd` - group delay differential (seconds).
    * `:toc` - clock data reference time (seconds).
    * `:af0` - SV clock bias (seconds).
    * `:af1` - SV clock drift (seconds/second).
    * `:af2` - SV clock drift rate (seconds/second^2).

  ## Subframe 2 - ephemeris part 1 (IS-GPS-200 Table 20-II)

    * `:iode` - issue of data, ephemeris, 8-bit (integer).
    * `:crs` - amplitude of the sine harmonic correction to orbit radius (meters).
    * `:delta_n` - mean motion difference from computed value (semicircles/second).
    * `:m0` - mean anomaly at reference time (semicircles).
    * `:cuc` - amplitude of the cosine harmonic correction to argument of latitude (radians).
    * `:eccentricity` - orbital eccentricity (dimensionless).
    * `:cus` - amplitude of the sine harmonic correction to argument of latitude (radians).
    * `:sqrt_a` - square root of the semi-major axis (sqrt(meters)).
    * `:toe` - ephemeris reference time (seconds).
    * `:fit_interval_flag` - fit-interval flag (0/1; default 0).
    * `:aodo` - age of data offset term, 5-bit integer 0..31 (the offset in
      seconds is the term times 900; default 0).

  ## Subframe 3 - ephemeris part 2 (IS-GPS-200 Table 20-III)

    * `:cic` - amplitude of the cosine harmonic correction to inclination (radians).
    * `:omega0` - longitude of ascending node at weekly epoch (semicircles).
    * `:cis` - amplitude of the sine harmonic correction to inclination (radians).
    * `:i0` - inclination at reference time (semicircles).
    * `:crc` - amplitude of the cosine harmonic correction to orbit radius (meters).
    * `:omega` - argument of perigee (semicircles).
    * `:omega_dot` - rate of right ascension (semicircles/second).
    * `:idot` - rate of inclination angle (semicircles/second).

  """

  @type t :: %__MODULE__{}

  defstruct [
    # Subframe 1
    :week_number,
    :l2_code,
    :l2_p_data_flag,
    :ura_index,
    :sv_health,
    :iodc,
    :tgd,
    :toc,
    :af0,
    :af1,
    :af2,
    # Subframe 2
    :iode,
    :crs,
    :delta_n,
    :m0,
    :cuc,
    :eccentricity,
    :cus,
    :sqrt_a,
    :toe,
    :fit_interval_flag,
    :aodo,
    # Subframe 3
    :cic,
    :omega0,
    :cis,
    :i0,
    :crc,
    :omega,
    :omega_dot,
    :idot
  ]

  @doc """
  A representative set of clock and ephemeris parameters for a MEO GPS SV.

  Useful for documentation and round-trip examples. Several signed fields carry
  negative values.
  """
  @spec example() :: t()
  def example do
    %__MODULE__{
      week_number: 290,
      l2_code: 1,
      l2_p_data_flag: 0,
      ura_index: 0,
      sv_health: 0,
      iodc: 0x2AB,
      tgd: -5.5879354476928711e-9,
      toc: 504_000,
      af0: -1.234e-4,
      af1: -3.5e-12,
      af2: 0.0,
      iode: 0xAB,
      crs: -55.625,
      delta_n: 1.56e-9,
      m0: -0.35,
      cuc: -1.2e-6,
      eccentricity: 0.012,
      cus: 8.3e-6,
      sqrt_a: 5153.65,
      toe: 504_000,
      fit_interval_flag: 0,
      aodo: 0,
      cic: 5.0e-8,
      omega0: -0.78,
      cis: -2.1e-7,
      i0: 0.305,
      crc: 250.625,
      omega: 0.95,
      omega_dot: -8.1e-9,
      idot: 1.5e-10
    }
  end
end
