defmodule Sidereon.GNSS.IonosphereFree do
  @moduledoc """
  The dual-frequency ionosphere-free linear combination for code and phase.

  The first-order ionospheric group delay on a GNSS pseudorange is dispersive: to
  first order it scales as `1 / f^2`, so a signal at carrier `f` is delayed by
  `I(f) = K / f^2` for a slant-path constant `K` proportional to the total
  electron content (TEC). Measuring the same range on two carriers `f1` and `f2`
  therefore gives two observations that share the geometry but carry different
  ionospheric delays, and a fixed linear combination of the two cancels the
  `1 / f^2` term exactly:

      PR_IF = (f1^2 * PR1 - f2^2 * PR2) / (f1^2 - f2^2)

  Writing `gamma = f1^2 / (f1^2 - f2^2)` this is the affine combination

      PR_IF = gamma * PR1 - (gamma - 1) * PR2

  Substituting `PR_i = R + K / f_i^2` (a true range `R` plus the first-order
  ionospheric delay on band `i`) the `K` terms cancel and `PR_IF = R`. A position
  solve fed these combined pseudoranges therefore needs no ionosphere model; call
  `Sidereon.GNSS.Positioning.solve/4` with `ionosphere: false` (the troposphere term,
  which is non-dispersive and does not cancel, still applies).

  ## Frequency table

  The ionosphere-free carrier-pair frequencies used here, in hertz:

  | System  | Band  | Frequency (MHz) |
  |---------|-------|-----------------|
  | GPS     | L1    | 1575.42         |
  | GPS     | L2    | 1227.60         |
  | Galileo | E1    | 1575.42         |
  | Galileo | E5a   | 1176.45         |
  | BeiDou  | B1I   | 1561.098        |
  | BeiDou  | B3I   | 1268.52         |

  The default combination pair per system is GPS `{:l1, :l2}`, Galileo
  `{:e1, :e5a}`, BeiDou `{:b1i, :b3i}`.

  Carrier phase uses the same first-order cancellation coefficients, but the
  carrier ionosphere term has the opposite sign and the combined ambiguity
  remains. If `L_i = lambda_i * phi_i` is carrier phase in metres,

      L_IF = gamma * L1 - (gamma - 1) * L2

  cancels the first-order ionosphere while preserving a combined float
  ambiguity. This is a PPP/RTK input primitive, not ambiguity resolution.

  ## Noise amplification

  The combination is not free: because it is a weighted difference of two noisy
  observations, uncorrelated band noise of equal standard deviation `sigma` is
  amplified to `sigma * sqrt(gamma^2 + (gamma - 1)^2)`. For GPS L1/L2 this factor
  is about `2.978`; for Galileo E1/E5a about `2.588`. See `noise_amplification/2`.

  ## Non-goals

  This module builds only the first-order ionosphere-free code and carrier-phase
  combinations. It deliberately does not implement the Melbourne-Wubbena /
  wide-lane / geometry-free combinations, ambiguity resolution, the second-order
  ionospheric term, or triple-frequency combinations.
  """

  alias Sidereon.GNSS.RINEX.Observations
  alias Sidereon.NIF

  @typedoc "A pseudorange observation `{satellite_id, range_m}`."
  @type observation :: {String.t(), float()}

  @typedoc "A reason a satellite was dropped from the paired set."
  @type drop_reason ::
          :missing_band1 | :missing_band2 | :duplicate_observation | :unknown_system

  @typedoc "A reason a carrier-phase combination could not be formed."
  @type phase_error :: :equal_frequencies | :invalid_frequency

  @doc """
  The ionosphere-free carrier-pair table as `%{system => %{band => f_hz}}`.

  For the full fixed-frequency carrier table and GLONASS RINEX band lookups,
  use `Sidereon.GNSS.Frequencies`.
  """
  @spec frequencies() :: %{String.t() => %{atom() => float()}}
  def frequencies do
    NIF.iono_free_frequencies()
    |> Map.new(fn {system, bands} ->
      {system, Map.new(bands, fn {band, frequency_hz} -> {String.to_atom(band), frequency_hz} end)}
    end)
  end

  @doc """
  The carrier frequency in hertz for `system` (`"G"`, `"E"`, `"C"`) and `band`.

  Returns `{:ok, f_hz}` or `{:error, {:unknown_band, system, band}}`.
  """
  @spec frequency(String.t(), atom()) ::
          {:ok, float()} | {:error, {:unknown_band, String.t(), atom()}}
  def frequency(system, band) when is_binary(system) and is_atom(band) do
    case NIF.iono_free_frequency(system, Atom.to_string(band)) do
      {:ok, frequency_hz} -> {:ok, frequency_hz}
      {:error, :unknown_band} -> {:error, {:unknown_band, system, band}}
    end
  end

  @doc """
  The standard combination band pair for `system`.

  Returns `{:ok, {band1, band2}}` or `{:error, {:unknown_system, system}}`.
  """
  @spec default_pair(String.t()) ::
          {:ok, {atom(), atom()}} | {:error, {:unknown_system, String.t()}}
  def default_pair(system) when is_binary(system) do
    case NIF.iono_free_default_pair(system) do
      {:ok, {band1, band2}} -> {:ok, {String.to_atom(band1), String.to_atom(band2)}}
      {:error, :unknown_system} -> {:error, {:unknown_system, system}}
    end
  end

  @doc """
  The ionosphere-free combination coefficient `gamma = f1^2 / (f1^2 - f2^2)`.

  Returns `{:error, :equal_frequencies}` when `f1 == f2` (the combination is
  undefined; the denominator vanishes). Never raises.
  """
  @spec gamma(float(), float()) :: {:ok, float()} | {:error, :equal_frequencies}
  def gamma(f1, f2) when is_number(f1) and is_number(f2) do
    NIF.iono_free_gamma(f1 / 1.0, f2 / 1.0)
  end

  @doc """
  The noise-amplification factor `sqrt(gamma^2 + (gamma - 1)^2)`.

  This is the factor by which uncorrelated equal-variance band noise is amplified
  into the combined pseudorange. About `2.978` for GPS L1/L2 and `2.588` for
  Galileo E1/E5a. Returns `{:error, :equal_frequencies}` when `f1 == f2`. Never
  raises.
  """
  @spec noise_amplification(float(), float()) :: {:ok, float()} | {:error, :equal_frequencies}
  def noise_amplification(f1, f2) when is_number(f1) and is_number(f2) do
    NIF.iono_free_noise_amplification(f1 / 1.0, f2 / 1.0)
  end

  @doc """
  The ionosphere-free pseudorange from two carrier-band pseudoranges.

      PR_IF = (f1^2 * pr1 - f2^2 * pr2) / (f1^2 - f2^2)
            = gamma * pr1 - (gamma - 1) * pr2

  `pr1`/`pr2` are in metres on carriers `f1`/`f2` (hertz). Returns `{:ok, pr_if}`,
  or `{:error, :equal_frequencies}` when `f1 == f2`. Never raises.
  """
  @spec iono_free(float(), float(), float(), float()) ::
          {:ok, float()} | {:error, :equal_frequencies}
  def iono_free(pr1, pr2, f1, f2) when is_number(pr1) and is_number(pr2) and is_number(f1) and is_number(f2) do
    NIF.iono_free_code(pr1 / 1.0, pr2 / 1.0, f1 / 1.0, f2 / 1.0)
  end

  @doc """
  The ionosphere-free carrier-phase combination from phase measurements in metres.

      L_IF = gamma * L1 - (gamma - 1) * L2

  `l1_m`/`l2_m` are carrier phase already expressed in metres (`lambda_i *
  phi_i`). The first-order ionosphere cancels; the float ambiguity remains in
  the combined phase. Returns `{:ok, l_if_m}` or `{:error, :equal_frequencies}`.
  Never raises.
  """
  @spec iono_free_phase(number(), number(), number(), number()) ::
          {:ok, float()} | {:error, :equal_frequencies}
  def iono_free_phase(l1_m, l2_m, f1, f2)
      when is_number(l1_m) and is_number(l2_m) and is_number(f1) and is_number(f2) do
    NIF.iono_free_phase(l1_m / 1.0, l2_m / 1.0, f1 / 1.0, f2 / 1.0)
  end

  @doc """
  The ionosphere-free carrier-phase combination from phase measurements in cycles.

  The two phase inputs are converted to metres with `L_i = c / f_i * phi_i`, then
  combined with `iono_free_phase/4`. Returns:

    * `{:ok, l_if_m}` for a valid frequency pair;
    * `{:error, :equal_frequencies}` when `f1 == f2`;
    * `{:error, :invalid_frequency}` when either frequency is not positive.

  Never raises.
  """
  @spec iono_free_phase_cycles(number(), number(), number(), number()) ::
          {:ok, float()} | {:error, phase_error()}
  def iono_free_phase_cycles(phi1_cyc, phi2_cyc, f1, f2)
      when is_number(phi1_cyc) and is_number(phi2_cyc) and is_number(f1) and is_number(f2) do
    NIF.iono_free_phase_cycles(phi1_cyc / 1.0, phi2_cyc / 1.0, f1 / 1.0, f2 / 1.0)
  end

  def iono_free_phase_cycles(_phi1_cyc, _phi2_cyc, _f1, _f2), do: {:error, :invalid_frequency}

  @doc """
  Combine two per-satellite pseudorange bands into ionosphere-free pseudoranges.

  `band1` and `band2` are `[{satellite_id, range_m}]` lists for the two carriers.
  Satellites are paired by id, and each pair is combined with the frequency pair
  for that satellite's system (the leading letter of the id), so a mixed
  GPS+Galileo+BeiDou set uses each system's own carriers.

  Returns `{combined, dropped}` where `combined` is the ascending-by-id list of
  `{satellite_id, pr_if}` and `dropped` reports every satellite that could not be
  combined as `{satellite_id, reason}`:

    * `:missing_band2`: present in `band1` only;
    * `:missing_band1`: present in `band2` only;
    * `:duplicate_observation`: the satellite appears more than once in a band,
      so which pseudorange to use is ambiguous; it is dropped rather than
      silently collapsed to whichever entry comes last;
    * `:unknown_system`: the system letter has no known frequency pair.

  Empty input yields `{[], []}`. Never raises.

  ## Options

    * `:pairs`: override the band pair per system, e.g.
      `pairs: %{"G" => {:l1, :l2}}`. A system without an override uses its
      standard default pair.
  """
  @spec iono_free_pseudoranges([observation()], [observation()], keyword()) ::
          {[observation()], [{String.t(), drop_reason()}]}
  def iono_free_pseudoranges(band1, band2, opts \\ []) when is_list(band1) and is_list(band2) do
    overrides = opts |> Keyword.get(:pairs, %{}) |> encode_pair_overrides()
    NIF.iono_free_pseudoranges(band1, band2, overrides)
  end

  @doc """
  Convenience: pull two carrier bands from a parsed observation handle and combine
  them into ionosphere-free pseudoranges for one epoch.

  Calls `Sidereon.GNSS.RINEX.Observations.pseudoranges/3` twice, once for each band's code
  preference, then `iono_free_pseudoranges/3`. `epoch` is an epoch index or
  `{{y, mo, d}, {h, mi, s}}` tuple, exactly as `Observations.pseudoranges/3` accepts.

  Returns `{:ok, {combined, dropped}}` or `{:error, reason}` (propagated from
  either extraction).

  ## Options

    * `:codes`: a map `%{system => {band1_codes, band2_codes}}` of the
      observation codes to extract for each band, e.g.
      `%{"G" => {["C1C"], ["C2W", "C2L"]}, "E" => {["C1C"], ["C5Q"]}}`. When
      omitted, the standard band-1/band-2 codes for the systems present in the
      file's `observation_codes/1` are used (GPS C1C/C2W, Galileo C1C/C5Q,
      BeiDou C2I/C6I), restricted to those whose codes the file actually carries.
    * `:pairs`: forwarded to `iono_free_pseudoranges/3`.
  """
  @spec iono_free_from_obs(Observations.t(), non_neg_integer() | tuple(), keyword()) ::
          {:ok, {[observation()], [{String.t(), drop_reason()}]}} | {:error, term()}
  def iono_free_from_obs(%Observations{} = obs, epoch, opts \\ []) do
    code_map = Keyword.get(opts, :codes) || default_obs_codes(obs)

    band1_codes = Map.new(code_map, fn {sys, {b1, _b2}} -> {sys, b1} end)
    band2_codes = Map.new(code_map, fn {sys, {_b1, b2}} -> {sys, b2} end)

    with {:ok, band1} <- Observations.pseudoranges(obs, epoch, codes: band1_codes),
         {:ok, band2} <- Observations.pseudoranges(obs, epoch, codes: band2_codes) do
      {:ok, iono_free_pseudoranges(band1, band2, Keyword.take(opts, [:pairs]))}
    end
  end

  # --- helpers -------------------------------------------------------------

  defp encode_pair_overrides(pairs) when is_map(pairs) do
    Enum.map(pairs, fn {system, {band1, band2}} ->
      {system, encode_band(band1), encode_band(band2)}
    end)
  end

  defp encode_pair_overrides(_pairs), do: []

  defp encode_band(band) when is_atom(band), do: Atom.to_string(band)
  defp encode_band(_band), do: "__invalid__"

  # The standard band-1/band-2 codes per system, kept only for systems whose
  # codes the file actually carries.
  @standard_obs_codes %{
    "G" => {["C1C"], ["C2W", "C2L"]},
    "E" => {["C1C"], ["C5Q"]},
    "C" => {["C2I"], ["C6I"]}
  }

  defp default_obs_codes(%Observations{} = obs) do
    available = Observations.observation_codes(obs)

    @standard_obs_codes
    |> Enum.filter(fn {sys, {b1, b2}} ->
      file_codes = Map.get(available, sys, [])
      Enum.any?(b1, &(&1 in file_codes)) and Enum.any?(b2, &(&1 in file_codes))
    end)
    |> Map.new()
  end
end
