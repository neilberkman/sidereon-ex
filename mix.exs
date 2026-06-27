defmodule Sidereon.MixProject do
  use Mix.Project

  @version "0.8.0"
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
      source_url: @source_url
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
      {:nx, "~> 0.7"},
      {:rustler, "~> 0.37"},
      {:rustler_precompiled, "~> 0.9"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:quokka, "~> 2.12", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    """
    Satellite toolkit for Elixir with SGP4 propagation, coordinate transforms,
    GNSS positioning, orbit determination, conjunction assessment, pass
    prediction, live TLE/OMM data, real-time tracking, and a Rust NIF backend.
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
      "mix.exs",
      "README.md",
      "CHANGELOG.md",
      "LICENSE"
    ] ++ Path.wildcard("checksum-*.exs")
  end

  defp docs do
    [
      main: "Sidereon",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/track_iss.md",
        "guides/pass_prediction.md",
        "guides/conjunction_screening.md",
        "guides/accuracy.md",
        "guides/batch_analysis.md",
        "guides/gnss_constellation_catalog.md",
        "examples/iss_tracker.livemd",
        "examples/gnss_positioning.livemd",
        "examples/conjunction_alert.livemd"
      ],
      groups_for_extras: [
        Guides: Path.wildcard("guides/*.md")
      ],
      groups_for_modules: [
        Core: [Sidereon, Sidereon.Elements, Sidereon.SGP4, Sidereon.TemeState],
        Coordinates: [Sidereon.Coordinates],
        "Ground Station": [Sidereon.Passes, Sidereon.Doppler, Sidereon.RF, Sidereon.Tracker],
        "Orbit Determination": [Sidereon.IOD, Sidereon.Lambert],
        "Space Environment": [
          Sidereon.Eclipse,
          Sidereon.Atmosphere,
          Sidereon.Ephemeris,
          Sidereon.Angles
        ],
        Conjunction: [Sidereon.Conjunction],
        "GNSS Positioning": [
          Sidereon.GNSS.Positioning,
          Sidereon.GNSS.PrecisePositioning,
          Sidereon.GNSS.SP3,
          Sidereon.GNSS.Broadcast,
          Sidereon.GNSS.RINEX.Observations,
          Sidereon.GNSS.ReducedOrbit,
          Sidereon.GNSS.ReducedOrbit.Piecewise,
          Sidereon.GNSS.Constellation,
          Sidereon.GNSS.Geometry,
          Sidereon.GNSS.Observables,
          Sidereon.GNSS.Velocity,
          Sidereon.GNSS.QC,
          Sidereon.GNSS.DGNSS,
          Sidereon.GNSS.RTK,
          Sidereon.GNSS.SolutionReport,
          Sidereon.GNSS.Frequencies,
          Sidereon.GNSS.CarrierPhase,
          Sidereon.GNSS.IonosphereFree,
          Sidereon.GNSS.Ionosphere,
          Sidereon.GNSS.Troposphere,
          Sidereon.GNSS.Time,
          Sidereon.GNSS.Signal.CA,
          Sidereon.GNSS.Signal.Correlator,
          Sidereon.GNSS.Navigation.LNAV,
          Sidereon.GNSS.Navigation.LNAV.Ephemeris
        ],
        "Data Sources": [
          Sidereon.CelesTrak,
          Sidereon.Constellation,
          Sidereon.GNSS.Data,
          Sidereon.GNSS.Data.Product,
          Sidereon.GNSS.Data.Catalog,
          Sidereon.GNSS.Data.Cache
        ],
        "Batch Analysis": [
          Sidereon.Nx,
          Sidereon.Nx.Geometry,
          Sidereon.Nx.Visibility,
          Sidereon.Nx.RF,
          Sidereon.Nx.Coverage
        ],
        Format: [Sidereon.Format.TLE, Sidereon.Format.OMM]
      ]
    ]
  end
end
