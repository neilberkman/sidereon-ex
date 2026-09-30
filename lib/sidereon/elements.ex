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

  `mean_motion_dot` and `mean_motion_double_dot` hold the TLE fields as
  written, ṅ/2 and n̈/6. They are `nil` when the source does not state them, as
  an OMM may not; SGP4 does not propagate with them, so `nil` propagates as a
  stated zero does, and a TLE cannot be written without them.
  `classification` is `nil` for an OMM that states no `CLASSIFICATION_TYPE`.
  `ephemeris_type`, `elset_number` and `rev_number` are `nil` for a blank TLE
  field or an unstated OMM keyword, and a blank TLE field is written back
  blank. `bstar_text` and `mean_motion_double_dot_text` hold the eight
  characters of the TLE B* and second-derivative fields as read, or `nil` for
  elements not read from a TLE; the TLE writer writes the text back while it
  decodes to exactly the stored value, so a spelling such as `" 00000+0"`
  survives a round trip.

  `catalog_number` is `nil` for elements whose source states none, as an OMM
  without `NORAD_CAT_ID` may; SGP4 propagates without it, and a TLE cannot be
  written without it. `epoch_jd` is the epoch as the split Julian date
  `%{jd_whole: whole, jd_fraction: fraction}` the core formed it with, set by
  `Sidereon.Format.OMM.to_elements/1`: it keeps the epoch's femtoseconds and a
  UTC leap second, which `epoch`, a `DateTime` to the microsecond, cannot, and
  propagation uses it in place of `epoch`. It is `nil` for elements read from a
  TLE, whose epoch `epoch` states. `omm_epoch_days` is the day count since
  1949-12-31 an OMM's epoch states, set by `Sidereon.Format.OMM.to_elements/1`
  for an epoch of whole microseconds, which python-sgp4 reads: SGP4 is then
  initialised as python-sgp4's `sgp4.omm.initialize` initialises the OMM
  (which Skyfield's `EarthSatellite.from_omm` uses), with `bstar` and
  `mean_motion_double_dot` as the OMM states them. It is `nil` otherwise.
  """

  @type t :: %__MODULE__{
          object_name: String.t() | nil,
          catalog_number: String.t() | nil,
          classification: String.t() | nil,
          international_designator: String.t(),
          epoch: DateTime.t(),
          epoch_jd: %{jd_whole: float(), jd_fraction: float()} | nil,
          omm_epoch_days: float() | nil,
          mean_motion_dot: float() | nil,
          mean_motion_double_dot: float() | nil,
          mean_motion_double_dot_text: String.t() | nil,
          bstar: float(),
          bstar_text: String.t() | nil,
          ephemeris_type: integer() | nil,
          elset_number: integer() | nil,
          inclination_deg: float(),
          raan_deg: float(),
          eccentricity: float(),
          arg_perigee_deg: float(),
          mean_anomaly_deg: float(),
          mean_motion: float(),
          rev_number: integer() | nil
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
    :rev_number,
    bstar_text: nil,
    mean_motion_double_dot_text: nil,
    epoch_jd: nil,
    omm_epoch_days: nil
  ]
end
