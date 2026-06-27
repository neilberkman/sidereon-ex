defmodule Sidereon.GNSS.CarrierPhase do
  @moduledoc """
  Dual-frequency carrier-phase linear combinations and the precise-positioning
  prep tooling built on them: geometry-free and wide-lane phase, the
  narrow-lane code, Melbourne-Wubbena, cycle-slip detection, and Hatch
  carrier-smoothed code.

  The numerical modeling lives in the Rust core. This module keeps the public
  Elixir API shape, validates options, normalizes arc maps for the NIF, and maps
  the core results back to the documented return maps.

  ## Arc shape

  `detect_cycle_slips/2` and `smooth_code/2` take an `arc`: a time-ordered list
  of per-epoch maps for **one** satellite. Each epoch map is a convenient subset
  of

      %{
        epoch: term(),        # opaque, passed through to the output
        phi1: float | nil,    # band-1 carrier phase, cycles
        phi2: float | nil,    # band-2 carrier phase, cycles
        p1:   float | nil,    # band-1 code, metres
        p2:   float | nil,    # band-2 code, metres
        lli1: integer | nil,  # band-1 LLI (bit 0 = loss of lock)
        lli2: integer | nil,  # band-2 LLI
        f1:   float | nil,    # band-1 carrier frequency, Hz (nil => skip)
        f2:   float | nil     # band-2 carrier frequency, Hz
      }

  An epoch with an unknown band frequency is skipped and reported with
  `skipped: true`. `epoch` is passed through unchanged. The data-gap detector
  can compare numeric-second epochs and `NaiveDateTime` epochs; other epoch
  terms remain opaque and do not trigger `:data_gap`.
  """

  alias Sidereon.NIF

  @default_gf_threshold_m 0.05
  @default_mw_threshold_cycles 4.0
  @default_min_arc_gap_s 300.0
  @default_hatch_window_cap 100
  @gap_reference ~N[2000-01-01 00:00:00]

  @type epoch_map :: %{optional(atom()) => term()}
  @type slip_reason :: :lli | :geometry_free | :melbourne_wubbena | :data_gap
  @type slip_result :: %{
          epoch: term(),
          slip: boolean(),
          reasons: [slip_reason()],
          gf: float() | nil,
          mw: float() | nil,
          skipped: boolean()
        }
  @type smooth_result :: %{
          epoch: term(),
          p_smooth: float() | nil,
          window: non_neg_integer(),
          reset: boolean()
        }
  @type iono_free_smooth_result :: %{
          epoch: term(),
          p_smooth: float() | nil,
          p_if: float() | nil,
          l_if: float() | nil,
          window: non_neg_integer(),
          reset: boolean()
        }

  @doc """
  Carrier phase in metres, `L = c / f * phi`.

  `phi_cyc` is carrier phase in cycles and `f_hz` is the carrier frequency in
  hertz. Returns `{:ok, l_m}` or `{:error, :invalid_frequency}` when the
  frequency is not positive. Never raises.
  """
  @spec phase_meters(number(), number()) :: {:ok, float()} | {:error, :invalid_frequency}
  def phase_meters(phi_cyc, f_hz) when is_number(phi_cyc) and is_number(f_hz) do
    NIF.carrier_phase_phase_meters(phi_cyc / 1.0, f_hz / 1.0)
  end

  def phase_meters(_phi_cyc, _f_hz), do: {:error, :invalid_frequency}

  @doc """
  Geometry-free phase combination `L_GF = l1_m - l2_m` (metres).
  """
  @spec geometry_free(number(), number()) :: float()
  def geometry_free(l1_m, l2_m) when is_number(l1_m) and is_number(l2_m) do
    NIF.carrier_phase_geometry_free(l1_m / 1.0, l2_m / 1.0)
  end

  @doc """
  Wide-lane wavelength `lambda_WL = c / (f1 - f2)` (metres).

  Returns `{:ok, lambda_WL}` or `{:error, :equal_frequencies}` when the two
  band frequencies are equal within the core epsilon.
  """
  @spec wide_lane_wavelength(number(), number()) ::
          {:ok, float()} | {:error, :equal_frequencies}
  def wide_lane_wavelength(f1, f2) when is_number(f1) and is_number(f2) do
    NIF.carrier_phase_wide_lane_wavelength(f1 / 1.0, f2 / 1.0)
  end

  def wide_lane_wavelength(_f1, _f2), do: {:error, :equal_frequencies}

  @doc """
  Narrow-lane code `P_NL = (f1*p1 + f2*p2) / (f1 + f2)` (metres).
  """
  @spec narrow_lane_code(number(), number(), number(), number()) ::
          {:ok, float()} | {:error, :equal_frequencies}
  def narrow_lane_code(p1_m, p2_m, f1, f2)
      when is_number(p1_m) and is_number(p2_m) and is_number(f1) and is_number(f2) do
    NIF.carrier_phase_narrow_lane_code(p1_m / 1.0, p2_m / 1.0, f1 / 1.0, f2 / 1.0)
  end

  def narrow_lane_code(_p1, _p2, _f1, _f2), do: {:error, :equal_frequencies}

  @doc """
  Melbourne-Wubbena combination (metres).

      MW = L_WL - P_NL
         = lambda_WL*(phi1 - phi2) - (f1*P1 + f2*P2)/(f1 + f2)

  Sign convention: wide-lane phase minus narrow-lane code.
  """
  @spec melbourne_wubbena(number(), number(), number(), number(), number(), number()) ::
          {:ok, float()} | {:error, :equal_frequencies}
  def melbourne_wubbena(phi1_cyc, phi2_cyc, p1_m, p2_m, f1, f2)
      when is_number(phi1_cyc) and is_number(phi2_cyc) and is_number(p1_m) and is_number(p2_m) and
             is_number(f1) and is_number(f2) do
    NIF.carrier_phase_melbourne_wubbena(
      phi1_cyc / 1.0,
      phi2_cyc / 1.0,
      p1_m / 1.0,
      p2_m / 1.0,
      f1 / 1.0,
      f2 / 1.0
    )
  end

  def melbourne_wubbena(_phi1, _phi2, _p1, _p2, _f1, _f2), do: {:error, :equal_frequencies}

  @doc """
  Melbourne-Wubbena wide-lane ambiguity estimate in wide-lane cycles.

  Computes `melbourne_wubbena/6` divided by the wide-lane wavelength. The
  result is cycle-normalized and uses the same sign convention and error
  behavior as `melbourne_wubbena/6`.
  """
  @spec wide_lane_cycles(number(), number(), number(), number(), number(), number()) ::
          {:ok, float()} | {:error, :equal_frequencies}
  def wide_lane_cycles(phi1_cyc, phi2_cyc, p1_m, p2_m, f1, f2)
      when is_number(phi1_cyc) and is_number(phi2_cyc) and is_number(p1_m) and is_number(p2_m) and
             is_number(f1) and is_number(f2) do
    NIF.carrier_phase_wide_lane_cycles(
      phi1_cyc / 1.0,
      phi2_cyc / 1.0,
      p1_m / 1.0,
      p2_m / 1.0,
      f1 / 1.0,
      f2 / 1.0
    )
  end

  def wide_lane_cycles(_phi1, _phi2, _p1, _p2, _f1, _f2), do: {:error, :equal_frequencies}

  @doc """
  Code-minus-carrier diagnostic `CMC = P - L` (metres).
  """
  @spec code_minus_carrier(number(), number(), number()) ::
          {:ok, float()} | {:error, :invalid_frequency}
  def code_minus_carrier(p_m, phi_cyc, f_hz)
      when is_number(p_m) and is_number(phi_cyc) and is_number(f_hz) do
    NIF.carrier_phase_code_minus_carrier(p_m / 1.0, phi_cyc / 1.0, f_hz / 1.0)
  end

  def code_minus_carrier(_p_m, _phi_cyc, _f_hz), do: {:error, :invalid_frequency}

  @doc """
  Detect cycle slips on a single-satellite arc.

  Returns one output map per input epoch:

      %{epoch: term(), slip: boolean(), reasons: [reason],
        gf: float | nil, mw: float | nil, skipped: boolean()}

  with `reason in [:lli, :geometry_free, :melbourne_wubbena, :data_gap]`.

  Options:

    * `:gf_threshold_m` (default `#{@default_gf_threshold_m}`)
    * `:mw_threshold_cycles` (default `#{@default_mw_threshold_cycles}`)
    * `:min_arc_gap_s` (default `#{@default_min_arc_gap_s}`)

  Thresholds must be non-negative numbers; invalid values raise
  `ArgumentError`.
  """
  @spec detect_cycle_slips([epoch_map()], keyword()) :: [slip_result()]
  def detect_cycle_slips(arc, opts \\ []) when is_list(arc) do
    {gf_threshold_m, mw_threshold_cycles, min_arc_gap_s} = validate_slip_opts!(opts)
    encoded = encode_arc(arc)

    encoded
    |> NIF.carrier_phase_detect_cycle_slips(gf_threshold_m, mw_threshold_cycles, min_arc_gap_s)
    |> Enum.zip(arc)
    |> Enum.map(fn {{slip, reasons, gf, mw, skipped}, ep} ->
      %{
        epoch: Map.get(ep, :epoch),
        slip: slip,
        reasons: reasons,
        gf: gf,
        mw: mw,
        skipped: skipped
      }
    end)
  end

  @doc """
  Single-frequency Hatch carrier-smoothed code on band 1.

  The filter resets on detected cycle slips, LLI loss of lock, data gaps, or
  missing band-1 code/phase/frequency. `:hatch_window_cap` defaults to
  `#{@default_hatch_window_cap}` and must be a positive integer.
  """
  @spec smooth_code([epoch_map()], keyword()) :: [smooth_result()]
  def smooth_code(arc, opts \\ []) when is_list(arc) do
    cap = validate_cap!(opts)
    {gf_threshold_m, mw_threshold_cycles, min_arc_gap_s} = validate_slip_opts!(opts)
    encoded = encode_arc(arc)

    encoded
    |> NIF.carrier_phase_smooth_code(
      gf_threshold_m,
      mw_threshold_cycles,
      min_arc_gap_s,
      effective_cap(cap, encoded)
    )
    |> Enum.zip(arc)
    |> Enum.map(fn {{p_smooth, window, reset}, ep} ->
      %{epoch: Map.get(ep, :epoch), p_smooth: p_smooth, window: window, reset: reset}
    end)
  end

  @doc """
  Dual-frequency ionosphere-free Hatch carrier-smoothed code.

  Forms ionosphere-free code and carrier phase at each epoch in the Rust core,
  then applies the same Hatch recursion and reset policy as `smooth_code/2`.
  """
  @spec smooth_iono_free_code([epoch_map()], keyword()) :: [iono_free_smooth_result()]
  def smooth_iono_free_code(arc, opts \\ []) when is_list(arc) do
    cap = validate_cap!(opts)
    {gf_threshold_m, mw_threshold_cycles, min_arc_gap_s} = validate_slip_opts!(opts)
    encoded = encode_arc(arc)

    encoded
    |> NIF.carrier_phase_smooth_iono_free_code(
      gf_threshold_m,
      mw_threshold_cycles,
      min_arc_gap_s,
      effective_cap(cap, encoded)
    )
    |> Enum.zip(arc)
    |> Enum.map(fn {{p_smooth, p_if, l_if, window, reset}, ep} ->
      %{
        epoch: Map.get(ep, :epoch),
        p_smooth: p_smooth,
        p_if: p_if,
        l_if: l_if,
        window: window,
        reset: reset
      }
    end)
  end

  defp validate_slip_opts!(opts) do
    gf = Keyword.get(opts, :gf_threshold_m, @default_gf_threshold_m)
    mw = Keyword.get(opts, :mw_threshold_cycles, @default_mw_threshold_cycles)
    gap = Keyword.get(opts, :min_arc_gap_s, @default_min_arc_gap_s)

    {non_negative!(:gf_threshold_m, gf), non_negative!(:mw_threshold_cycles, mw),
     non_negative!(:min_arc_gap_s, gap)}
  end

  defp non_negative!(_name, value) when is_number(value) and value >= 0.0, do: value / 1.0

  defp non_negative!(name, value) do
    raise ArgumentError, "#{inspect(name)} must be a non-negative number, got: #{inspect(value)}"
  end

  defp validate_cap!(opts) do
    cap = Keyword.get(opts, :hatch_window_cap, @default_hatch_window_cap)

    if is_integer(cap) and cap >= 1 do
      cap
    else
      raise ArgumentError, ":hatch_window_cap must be a positive integer, got: #{inspect(cap)}"
    end
  end

  defp encode_arc(arc), do: Enum.map(arc, &encode_epoch/1)

  defp encode_epoch(ep) do
    %{
      phi1: number_or_nil(Map.get(ep, :phi1)),
      phi2: number_or_nil(Map.get(ep, :phi2)),
      p1: number_or_nil(Map.get(ep, :p1)),
      p2: number_or_nil(Map.get(ep, :p2)),
      lli1: integer_or_nil(Map.get(ep, :lli1)),
      lli2: integer_or_nil(Map.get(ep, :lli2)),
      f1: number_or_nil(Map.get(ep, :f1)),
      f2: number_or_nil(Map.get(ep, :f2)),
      gap_time_s: epoch_time_s(Map.get(ep, :epoch))
    }
  end

  defp number_or_nil(value) when is_number(value), do: value / 1.0
  defp number_or_nil(_value), do: nil

  defp integer_or_nil(value) when is_integer(value), do: value
  defp integer_or_nil(_value), do: nil

  defp epoch_time_s(%NaiveDateTime{} = epoch) do
    NaiveDateTime.diff(epoch, @gap_reference, :microsecond) / 1_000_000.0
  end

  defp epoch_time_s(epoch) when is_number(epoch), do: epoch / 1.0
  defp epoch_time_s(_epoch), do: nil

  defp effective_cap(cap, encoded_arc) do
    min(cap, max(length(encoded_arc), 1))
  end
end
