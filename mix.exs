defmodule Sidereon.MixProject do
  use Mix.Project

  alias Sidereon.CCSDS.CDM
  alias Sidereon.CCSDS.OEM
  alias Sidereon.CCSDS.OPM
  alias Sidereon.CCSDS.TDM
  alias Sidereon.Estimation
  alias Sidereon.Estimation.AlphaBetaGains
  alias Sidereon.Estimation.AlphaBetaState
  alias Sidereon.Estimation.AlphaBetaStep
  alias Sidereon.Estimation.NisGate
  alias Sidereon.Estimation.ScalarKalmanGains
  alias Sidereon.Estimation.SmoothedTrack
  alias Sidereon.Estimation.SmoothedTrackEpoch
  alias Sidereon.Estimation.TrackFilter
  alias Sidereon.Estimation.TrackFilterConfig
  alias Sidereon.Estimation.TrackGatedUpdate
  alias Sidereon.Estimation.TrackInnovation
  alias Sidereon.Estimation.TrackPrediction
  alias Sidereon.Estimation.TrackRtsEpoch
  alias Sidereon.Estimation.TrackRtsHistory
  alias Sidereon.Estimation.TrackRtsHistoryBuilder
  alias Sidereon.Estimation.TrackState
  alias Sidereon.Estimation.TrackUpdate
  alias Sidereon.Format.OMM
  alias Sidereon.Format.TLE
  alias Sidereon.Geofence
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.CarrierPhase
  alias Sidereon.GNSS.Constellation
  alias Sidereon.GNSS.Data
  alias Sidereon.GNSS.DGNSS
  alias Sidereon.GNSS.Frequencies
  alias Sidereon.GNSS.Fusion
  alias Sidereon.GNSS.Geometry
  alias Sidereon.GNSS.Ionosphere
  alias Sidereon.GNSS.IonosphereFree
  alias Sidereon.GNSS.Navigation.LNAV
  alias Sidereon.GNSS.Navigation.LNAV.Ephemeris
  alias Sidereon.GNSS.NTRIP
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.PreciseEphemeris
  alias Sidereon.GNSS.PreciseEphemeris.Interpolant
  alias Sidereon.GNSS.PreciseEphemeris.InterpolantArtifact
  alias Sidereon.GNSS.PreciseEphemeris.PreciseInterpolantArtifact
  alias Sidereon.GNSS.PreciseEphemeris.StateBatch
  alias Sidereon.GNSS.PrecisePositioning
  alias Sidereon.GNSS.QC
  alias Sidereon.GNSS.ReducedOrbit
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.RTK
  alias Sidereon.GNSS.Scenario
  alias Sidereon.GNSS.Signal.Analysis
  alias Sidereon.GNSS.Signal.CA
  alias Sidereon.GNSS.Signal.Correlator
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.SPP
  alias Sidereon.GNSS.StaticPositioning
  alias Sidereon.GNSS.Troposphere
  alias Sidereon.GNSS.Velocity
  alias Sidereon.SourceLocalization
  alias Sidereon.SourceLocalization.Covariance
  alias Sidereon.SourceLocalization.Crlb
  alias Sidereon.SourceLocalization.GeometryQuality
  alias Sidereon.SourceLocalization.InitialGuess
  alias Sidereon.SourceLocalization.Options
  alias Sidereon.SourceLocalization.Residual
  alias Sidereon.SourceLocalization.Sensor
  alias Sidereon.SourceLocalization.SensorInfluence
  alias Sidereon.SourceLocalization.Solution
  alias Sidereon.Terrain.MmapTerrain

  @version "0.27.1"
  @source_url "https://github.com/neilberkman/sidereon-ex"

  def project do
    [
      app: :sidereon,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Sidereon",
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")]
    ]
  end

  def application do
    [
      mod: {Sidereon.Application, []},
      extra_applications: [:logger, :ssl]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:rustler, "~> 0.37", optional: true},
      {:rustler_precompiled, "~> 0.9"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:quokka, "~> 2.13", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Satellite toolkit for Elixir with SGP4 propagation, coordinate transforms,
    GNSS positioning, orbit determination, conjunction assessment, pass
    prediction, and a Rust NIF backend.
    """
  end

  defp package do
    [
      files: package_files(),
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp package_files do
    [
      "lib",
      "native/sidereon_nif/src",
      "native/sidereon_nif/Cargo*",
      "Cargo.toml",
      "Cargo.lock",
      "mix.exs",
      "README.md",
      "sidereon.livemd",
      "examples",
      "CHANGELOG.md",
      "LICENSE"
    ] ++ Path.wildcard("checksum-*.exs")
  end

  defp docs do
    [
      main: "sidereon",
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      extras: [
        "README.md",
        "sidereon.livemd",
        "CHANGELOG.md",
        "guides/pass_prediction.md",
        "guides/accuracy.md",
        "guides/data_acquisition.md",
        "guides/gnss_constellation_catalog.md",
        "examples/gnss_positioning.livemd"
      ],
      groups_for_extras: [
        Guides: Path.wildcard("guides/*.md")
      ],
      groups_for_modules: [
        Core: [Sidereon, Sidereon.Elements, Sidereon.SGP4, Sidereon.TemeState],
        Coordinates: [Sidereon.Coordinates, Sidereon.FrameCatalog, Sidereon.Geodesic],
        "Ground Station": [Sidereon.Passes, Sidereon.Doppler, Sidereon.RF, Geofence],
        "Orbit Determination": [Sidereon.IOD, Sidereon.Lambert],
        "Space Environment": [
          Sidereon.Eclipse,
          Sidereon.Atmosphere,
          Sidereon.Ephemeris,
          Sidereon.Angles
        ],
        Conjunction: [Sidereon.Conjunction],
        "GNSS Positioning": [
          Positioning,
          PreciseEphemeris,
          Interpolant,
          InterpolantArtifact,
          PreciseInterpolantArtifact,
          StateBatch,
          PrecisePositioning,
          SP3,
          SPP,
          Broadcast,
          Observations,
          ReducedOrbit,
          Constellation,
          Geometry,
          Observables,
          Velocity,
          StaticPositioning,
          QC,
          DGNSS,
          RTK,
          Fusion,
          Scenario,
          Frequencies,
          CarrierPhase,
          IonosphereFree,
          Ionosphere,
          Troposphere,
          Data,
          Sidereon.GNSS.Time,
          CA,
          Analysis,
          Correlator,
          LNAV,
          Ephemeris,
          NTRIP
        ],
        "Data Sources": [Data, Sidereon.Constellation, Sidereon.Terrain, MmapTerrain],
        Estimation: [
          Estimation,
          AlphaBetaGains,
          AlphaBetaState,
          AlphaBetaStep,
          NisGate,
          ScalarKalmanGains,
          TrackFilterConfig,
          TrackFilter,
          TrackState,
          TrackPrediction,
          TrackInnovation,
          TrackUpdate,
          TrackGatedUpdate,
          TrackRtsHistoryBuilder,
          TrackRtsHistory,
          TrackRtsEpoch,
          SmoothedTrack,
          SmoothedTrackEpoch,
          SourceLocalization,
          Sensor,
          Options,
          Solution,
          Covariance,
          Residual,
          SensorInfluence,
          GeometryQuality,
          InitialGuess,
          Crlb
        ],
        "Batch Analysis": [Sidereon.Coverage, Sidereon.RF],
        Format: [TLE, OMM, CDM, OEM, OPM, TDM]
      ]
    ]
  end
end
