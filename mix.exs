defmodule Sidereon.MixProject do
  use Mix.Project

  alias Sidereon.Format.OMM
  alias Sidereon.Format.TLE
  alias Sidereon.GNSS.Broadcast
  alias Sidereon.GNSS.CarrierPhase
  alias Sidereon.GNSS.Constellation
  alias Sidereon.GNSS.DGNSS
  alias Sidereon.GNSS.Frequencies
  alias Sidereon.GNSS.Geometry
  alias Sidereon.GNSS.Ionosphere
  alias Sidereon.GNSS.IonosphereFree
  alias Sidereon.GNSS.Navigation.LNAV
  alias Sidereon.GNSS.Navigation.LNAV.Ephemeris
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.Positioning
  alias Sidereon.GNSS.PrecisePositioning
  alias Sidereon.GNSS.QC
  alias Sidereon.GNSS.ReducedOrbit
  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.GNSS.RTK
  alias Sidereon.GNSS.Signal.CA
  alias Sidereon.GNSS.Signal.Correlator
  alias Sidereon.GNSS.SP3
  alias Sidereon.GNSS.Troposphere
  alias Sidereon.GNSS.Velocity

  @version "0.9.0"
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
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:rustler, "~> 0.37", optional: true},
      {:rustler_precompiled, "~> 0.9"},
      {:jason, "~> 1.4"},
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
      "mix.exs",
      "README.md",
      "CHANGELOG.md",
      "LICENSE"
    ] ++ Path.wildcard("checksum-*.exs")
  end

  defp docs do
    [
      main: "Sidereon",
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/pass_prediction.md",
        "guides/accuracy.md",
        "guides/gnss_constellation_catalog.md",
        "examples/gnss_positioning.livemd"
      ],
      groups_for_extras: [
        Guides: Path.wildcard("guides/*.md")
      ],
      groups_for_modules: [
        Core: [Sidereon, Sidereon.Elements, Sidereon.SGP4, Sidereon.TemeState],
        Coordinates: [Sidereon.Coordinates],
        "Ground Station": [Sidereon.Passes, Sidereon.Doppler, Sidereon.RF],
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
          PrecisePositioning,
          SP3,
          Broadcast,
          Observations,
          ReducedOrbit,
          Constellation,
          Geometry,
          Observables,
          Velocity,
          QC,
          DGNSS,
          RTK,
          Frequencies,
          CarrierPhase,
          IonosphereFree,
          Ionosphere,
          Troposphere,
          Sidereon.GNSS.Time,
          CA,
          Correlator,
          LNAV,
          Ephemeris
        ],
        "Data Sources": [Sidereon.Constellation],
        "Batch Analysis": [Sidereon.Coverage, Sidereon.RF],
        Format: [TLE, OMM]
      ]
    ]
  end
end
