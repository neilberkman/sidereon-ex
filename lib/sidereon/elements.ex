defmodule Sidereon.Elements do
  @moduledoc """
  Canonical representation of satellite orbital elements.

  A pure data struct that knows nothing about serialization formats.
  Populated by format-specific parsers (`Sidereon.Format.TLE`, `Sidereon.Format.OMM`)
  and serialized by the same modules.

  All values are in standard astrodynamic units:
  - Angles: degrees
  - Mean motion: revolutions/day
  - Mean motion derivatives: rev/day², rev/day³
  - BSTAR drag: 1/earth-radii
  - Epoch: UTC DateTime
  """

  @type t :: %__MODULE__{
          object_name: String.t() | nil,
          catalog_number: String.t(),
          classification: String.t(),
          international_designator: String.t(),
          epoch: DateTime.t(),
          mean_motion_dot: float(),
          mean_motion_double_dot: float(),
          bstar: float(),
          ephemeris_type: integer(),
          elset_number: integer(),
          inclination_deg: float(),
          raan_deg: float(),
          eccentricity: float(),
          arg_perigee_deg: float(),
          mean_anomaly_deg: float(),
          mean_motion: float(),
          rev_number: integer()
        }

  @enforce_keys [
    :catalog_number,
    :classification,
    :international_designator,
    :epoch,
    :mean_motion_dot,
    :mean_motion_double_dot,
    :bstar,
    :ephemeris_type,
    :elset_number,
    :inclination_deg,
    :raan_deg,
    :eccentricity,
    :arg_perigee_deg,
    :mean_anomaly_deg,
    :mean_motion,
    :rev_number
  ]
  @derive Jason.Encoder
  @derive JSON.Encoder
  defstruct [
    :object_name,
    :catalog_number,
    :classification,
    :international_designator,
    :epoch,
    :mean_motion_dot,
    :mean_motion_double_dot,
    :bstar,
    :ephemeris_type,
    :elset_number,
    :inclination_deg,
    :raan_deg,
    :eccentricity,
    :arg_perigee_deg,
    :mean_anomaly_deg,
    :mean_motion,
    :rev_number
  ]
end
