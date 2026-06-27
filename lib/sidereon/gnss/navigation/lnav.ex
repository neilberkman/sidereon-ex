defmodule Sidereon.GNSS.Navigation.LNAV do
  @moduledoc """
  GPS L1 C/A LNAV navigation message synthesis and decoding (subframes 1-3).

  The legacy navigation (LNAV) message is the data stream modulated onto the
  GPS L1 C/A signal at 50 bits per second. Its structure is defined in
  IS-GPS-200 (Section 20.3): the message is organized into 1500-bit *frames*,
  each frame being five 300-bit *subframes*, and each subframe being ten 30-bit
  *words*. Every word carries 24 source data bits (most significant first)
  followed by 6 parity bits.

  This module covers the clock and ephemeris subframes:

    * Subframe 1 - SV clock correction and health (IS-GPS-200 Table 20-I).
    * Subframe 2 - first half of the ephemeris (IS-GPS-200 Table 20-II).
    * Subframe 3 - second half of the ephemeris (IS-GPS-200 Table 20-III).

  The first word of every subframe is the telemetry (TLM) word; the second is
  the hand-over word (HOW). Both are described in IS-GPS-200 Section 20.3.3.

  ## Words and bits

  A subframe is represented as a flat list of 300 bits (`0`/`1`), most
  significant bit first, with the ten words concatenated in transmission
  order. `word_length/0` is 30 and `subframe_length/0` is 300.

  ## Parameters and units

  `encode/2` and `decode/1` exchange an `Sidereon.GNSS.Navigation.LNAV.Ephemeris` struct
  whose fields hold the natural engineering-unit values (the products of the
  transmitted integers and their IS-GPS-200 scale factors). See that struct's
  documentation for the per-field units. Angular ephemeris quantities use
  *semicircles* (and semicircles/second), the harmonic correction terms use
  radians, distances use meters, and clock/time quantities use seconds, exactly
  as tabulated in IS-GPS-200.

  ## Parity

  The 6 parity bits of each word are produced by the (32, 26) Hamming code of
  IS-GPS-200 Section 20.3.5.2 and Table 20-XIV, including the rule that the two
  trailing parity bits of the previous word (`D29*`, `D30*`) feed the current
  word and that `D30*` complements the 24 transmitted data bits. The last two
  data bits of the HOW and of word 10 are solved so that those words'
  `D29`/`D30` parity bits are zero, per IS-GPS-200 Section 20.3.3.2. At the
  start of each subframe the previous parity bits are seeded to zero, producing
  self-consistent stand-alone subframes.

  The bit packing, parity, scaling, and range validation are implemented in the
  Rust core (`astrodynamics_gnss::navigation::lnav`); this module marshals the
  parameter struct across the NIF and maps the result back to the public shapes.

  ## Examples

      iex> Sidereon.GNSS.Navigation.LNAV.word_length()
      30

      iex> Sidereon.GNSS.Navigation.LNAV.subframe_length()
      300

      iex> Sidereon.GNSS.Navigation.LNAV.preamble()
      139

  """

  alias Sidereon.GNSS.Navigation.LNAV.Ephemeris

  @doc """
  Bit length of a single LNAV word (IS-GPS-200 Section 20.3.2).

  ## Examples

      iex> Sidereon.GNSS.Navigation.LNAV.word_length()
      30

  """
  @spec word_length() :: 30
  def word_length, do: Sidereon.NIF.lnav_word_length()

  @doc """
  Bit length of a single LNAV subframe (IS-GPS-200 Section 20.3.2).

  ## Examples

      iex> Sidereon.GNSS.Navigation.LNAV.subframe_length()
      300

  """
  @spec subframe_length() :: 300
  def subframe_length, do: Sidereon.NIF.lnav_subframe_length()

  @doc """
  The 8-bit TLM preamble `1000 1011` as an integer (IS-GPS-200 Section 20.3.3.1).

  ## Examples

      iex> Sidereon.GNSS.Navigation.LNAV.preamble()
      139

  """
  @spec preamble() :: 139
  def preamble, do: Sidereon.NIF.lnav_preamble()

  @doc """
  Extracts the 17-bit time-of-week count from a hand-over word.

  Accepts either a 30-bit HOW word or a full 300-bit subframe (whose word 2 is
  the HOW). The returned value is the truncated Z-count carried in the HOW
  (units of 6 seconds), per IS-GPS-200 Section 20.3.3.2.

  ## Examples

      iex> {:ok, sfs} = Sidereon.GNSS.Navigation.LNAV.encode(Sidereon.GNSS.Navigation.LNAV.Ephemeris.example(), tow: 12345)
      iex> Sidereon.GNSS.Navigation.LNAV.tow(sfs[1])
      {:ok, 12345}

  """
  @spec tow([0 | 1]) :: {:ok, non_neg_integer()} | {:error, :bad_length}
  def tow(bits) when is_list(bits) do
    case Sidereon.NIF.lnav_tow(bits) do
      {:ok, value} -> {:ok, value}
      {:error, :bad_length} -> {:error, :bad_length}
    end
  end

  @doc """
  Like `tow/1` but raises on malformed input length.
  """
  @spec tow!([0 | 1]) :: non_neg_integer()
  def tow!(bits) when is_list(bits) do
    case tow(bits) do
      {:ok, value} -> value
      {:error, :bad_length} -> raise ArgumentError, "expected a 30-bit word or 300-bit subframe"
    end
  end

  @doc """
  Extracts the 3-bit subframe ID from a hand-over word.

  Accepts a 30-bit HOW word or a full 300-bit subframe. Returns the subframe
  identifier carried in HOW bits 20-22 (IS-GPS-200 Section 20.3.3.2).

  ## Examples

      iex> {:ok, sfs} = Sidereon.GNSS.Navigation.LNAV.encode(Sidereon.GNSS.Navigation.LNAV.Ephemeris.example(), tow: 0)
      iex> Sidereon.GNSS.Navigation.LNAV.subframe_id(sfs[2])
      {:ok, 2}

  """
  @spec subframe_id([0 | 1]) :: {:ok, 1..5} | {:error, :bad_length}
  def subframe_id(bits) when is_list(bits) do
    case Sidereon.NIF.lnav_subframe_id(bits) do
      {:ok, value} -> {:ok, value}
      {:error, :bad_length} -> {:error, :bad_length}
    end
  end

  @doc """
  Like `subframe_id/1` but raises on malformed input length.
  """
  @spec subframe_id!([0 | 1]) :: 1..5
  def subframe_id!(bits) when is_list(bits) do
    case subframe_id(bits) do
      {:ok, value} -> value
      {:error, :bad_length} -> raise ArgumentError, "expected a 30-bit word or 300-bit subframe"
    end
  end

  @doc """
  Computes the 6 parity bits of a word (IS-GPS-200 Table 20-XIV).

  `data24` is the list of 24 *source* data bits (most significant first, before
  the `D30*` complementation). `d29_prev` and `d30_prev` are the two trailing
  parity bits of the previous word. Returns `[D25, D26, D27, D28, D29, D30]`.
  """
  @spec parity([0 | 1], 0 | 1, 0 | 1) :: [0 | 1]
  def parity(data24, d29_prev, d30_prev) when is_list(data24) and length(data24) == 24 do
    Sidereon.NIF.lnav_parity(data24, d29_prev, d30_prev)
  end

  @doc """
  Verifies the parity of a single 30-bit word.

  `word30` is the 30-bit word as transmitted (data bits possibly complemented
  by `D30*`, followed by 6 received parity bits). `d29_prev`/`d30_prev` are the
  previous word's trailing parity bits. Returns `true` when the recomputed
  parity matches the received parity.
  """
  @spec parity_valid?([0 | 1], 0 | 1, 0 | 1) :: boolean()
  def parity_valid?(word30, d29_prev, d30_prev) when is_list(word30) and length(word30) == 30 do
    Sidereon.NIF.lnav_parity_valid(word30, d29_prev, d30_prev)
  end

  @doc """
  Encodes clock and ephemeris parameters into LNAV subframes 1-3.

  Returns `{:ok, %{1 => bits, 2 => bits, 3 => bits}}` where each value is a flat
  list of 300 bits (most significant first). Out-of-range parameters yield
  `{:error, {:out_of_range, field, value}}`; this function never raises on bad
  input.

  ## Options

    * `:tow` - the 17-bit time-of-week count placed in each HOW (0..131071,
      default 0).
    * `:alert` - HOW alert flag (`0`/`1`, default 0).
    * `:anti_spoof` - HOW anti-spoof flag (`0`/`1`, default 0).
    * `:integrity` - TLM integrity status flag (`0`/`1`, default 0).
    * `:tlm_message` - 14-bit TLM message field (default 0).

  """
  @spec encode(Ephemeris.t(), keyword()) ::
          {:ok, %{1 => [0 | 1], 2 => [0 | 1], 3 => [0 | 1]}} | {:error, term()}
  def encode(%Ephemeris{} = params, opts \\ []) do
    # Field order mirrors the Rust `LnavParams` decode order; `nil`-defaults match
    # the historical clock/ephemeris optional-field semantics.
    param_values = [
      week_number: params.week_number,
      l2_code: params.l2_code || 0,
      l2_p_data_flag: params.l2_p_data_flag || 0,
      ura_index: params.ura_index,
      sv_health: params.sv_health,
      iodc: params.iodc || 0,
      tgd: params.tgd,
      toc: params.toc,
      af0: params.af0,
      af1: params.af1,
      af2: params.af2,
      iode: params.iode,
      crs: params.crs,
      delta_n: params.delta_n,
      m0: params.m0,
      cuc: params.cuc,
      eccentricity: params.eccentricity,
      cus: params.cus,
      sqrt_a: params.sqrt_a,
      toe: params.toe,
      fit_interval_flag: params.fit_interval_flag || 0,
      aodo: params.aodo || 0,
      cic: params.cic,
      omega0: params.omega0,
      cis: params.cis,
      i0: params.i0,
      crc: params.crc,
      omega: params.omega,
      omega_dot: params.omega_dot,
      idot: params.idot
    ]

    opt_values = [
      tow: Keyword.get(opts, :tow, 0),
      alert: Keyword.get(opts, :alert, 0),
      anti_spoof: Keyword.get(opts, :anti_spoof, 0),
      integrity: Keyword.get(opts, :integrity, 0),
      tlm_message: Keyword.get(opts, :tlm_message, 0)
    ]

    encoded =
      Sidereon.NIF.lnav_encode(
        Enum.map(param_values, &elem(&1, 1)),
        Enum.map(opt_values, &elem(&1, 1))
      )

    case encoded do
      {:ok, {sf1, sf2, sf3}} ->
        {:ok, %{1 => sf1, 2 => sf2, 3 => sf3}}

      {:error, {:out_of_range, field}} ->
        value = Keyword.fetch!(param_values ++ opt_values, field)
        {:error, {:out_of_range, field, value}}
    end
  end

  @doc """
  Decodes LNAV subframes 1-3 back into the engineering-unit parameter struct.

  Accepts `%{1 => bits, 2 => bits, 3 => bits}` of 300-bit subframes. Parity is
  verified on all 30 words first; a failure returns
  `{:error, {:parity_failed, subframe, word}}` (word is 1-based). On success
  returns `{:ok, %Sidereon.GNSS.Navigation.LNAV.Ephemeris{}}`.
  """
  @spec decode(%{1 => [0 | 1], 2 => [0 | 1], 3 => [0 | 1]}) ::
          {:ok, Ephemeris.t()} | {:error, term()}
  def decode(%{1 => sf1, 2 => sf2, 3 => sf3}) do
    case Sidereon.NIF.lnav_decode(sf1, sf2, sf3) do
      {:ok, {ints, floats}} ->
        [
          week_number,
          l2_code,
          ura_index,
          sv_health,
          iodc,
          toc,
          iode,
          toe,
          fit_interval_flag,
          aodo
        ] =
          ints

        [
          tgd,
          af0,
          af1,
          af2,
          crs,
          delta_n,
          m0,
          cuc,
          eccentricity,
          cus,
          sqrt_a,
          cic,
          omega0,
          cis,
          i0,
          crc,
          omega,
          omega_dot,
          idot
        ] = floats

        {:ok,
         %Ephemeris{
           week_number: week_number,
           l2_code: l2_code,
           ura_index: ura_index,
           sv_health: sv_health,
           iodc: iodc,
           tgd: tgd,
           toc: toc,
           af0: af0,
           af1: af1,
           af2: af2,
           iode: iode,
           crs: crs,
           delta_n: delta_n,
           m0: m0,
           cuc: cuc,
           eccentricity: eccentricity,
           cus: cus,
           sqrt_a: sqrt_a,
           toe: toe,
           fit_interval_flag: fit_interval_flag,
           aodo: aodo,
           cic: cic,
           omega0: omega0,
           cis: cis,
           i0: i0,
           crc: crc,
           omega: omega,
           omega_dot: omega_dot,
           idot: idot
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
