defmodule Sidereon.GNSS.Data.Catalog do
  @moduledoc """
  Static, pure catalog of GNSS analysis centers and the rules that turn a
  product specification into a canonical filename and a full archive URL.

  Everything here is deterministic and network-free: GPS-week and day-of-year
  arithmetic, the IGS long-name filename convention, and the per-center archive
  layout. The fetch pipeline derives **all** network hosts and cache filenames
  from this module, which is what keeps the layer safe against SSRF (only known
  hosts are ever contacted) and path traversal (cache names come only from a
  validated canonical filename).

  ## Analysis centers

  Each center maps to the archive protocol, host, product token it publishes,
  and directory layout for each content type. Only centers and paths that
  resolve against a live, anonymous HTTP(S) archive are listed; every entry
  below has been checked against its server.

  | Code       | Center                               | Protocol | Host                         |
  |------------|--------------------------------------|----------|------------------------------|
  | `:gfz`     | GFZ Potsdam operational rapid        | HTTPS    | `isdc-data.gfz.de`           |
  | `:cod`     | CODE / University of Bern            | HTTP     | `ftp.aiub.unibe.ch`          |
  | `:esa`     | ESA Navigation Office final products | HTTPS    | `navigation-office.esa.int`  |
  | `:igs`     | IGS combined broadcast navigation    | HTTPS    | `igs.bkg.bund.de`            |
  | `:igs_ult` | IGS combined ultra-rapid             | HTTPS    | `igs.bkg.bund.de`            |
  | `:cod_ult` | CODE ultra-rapid                     | HTTP     | `ftp.aiub.unibe.ch`          |
  | `:esa_ult` | ESA ultra-rapid                      | HTTPS    | `navigation-office.esa.int`  |
  | `:gfz_ult` | GFZ ultra-rapid                      | HTTPS    | `isdc-data.gfz.de`           |
  | `:cod_rap` | CODE rapid global ionosphere map     | HTTP     | `ftp.aiub.unibe.ch`          |
  | `:cod_prd1`| CODE 1-day predicted ionosphere map  | HTTP     | `ftp.aiub.unibe.ch`          |
  | `:cod_prd2`| CODE 2-day predicted ionosphere map  | HTTP     | `ftp.aiub.unibe.ch`          |

  AIUB's public CODE archive does not offer HTTPS. CODE products are public
  data, but fresh products do not have published checksums; transport integrity
  therefore relies on the plain-HTTP channel.

  Products that were only reachable through the deprecated ESA GSSC anonymous
  archive and have no verified open HTTP(S) mirror are intentionally not
  listed. Requests for those former products return
  `{:error, {:no_open_mirror, {center, content}}}`.

  ## Content types and what each center serves

    * `:sp3`, `:clk`: precise orbits and clocks. `:gfz` (operational rapid),
      `:cod` and `:esa` (final products), and the ultra-rapid center aliases
      `:igs_ult`, `:cod_ult`, `:esa_ult`, and `:gfz_ult`. The GFZ rapid token
      is `GFZ0OPSRAP`; the CODE MGEX final token is `COD0MGXFIN`; the ESA final
      token is `ESA0MGNFIN`; the ultra-rapid tokens are `IGS0OPSULT`,
      `COD0OPSULT`, `ESA0OPSULT`, and `GFZ0OPSULT`.
    * `:nav`: the IGS merged multi-GNSS broadcast navigation file
      (`BRDC00WRD_R_..._MN.rnx`). Only `:igs` publishes it.
    * `:ionex`: the global ionosphere TEC map (`..._GIM.INX`). `:cod` serves
      the final `COD0OPSFIN` over HTTP and `:esa` serves `ESA0OPSFIN` over
      HTTPS. Lower-latency CODE GIMs live in the AIUB `/CODE` root: `:cod_rap`
      serves the rapid map `COD0OPSRAP` (short name `CORG<ddd>0.<yy>I`), and the
      predicted aliases `:cod_prd1` (1-day-ahead) and `:cod_prd2` (2-day-ahead)
      both serve `COD0OPSPRD` (short name `COPG<ddd>0.<yy>I`). The predicted
      product is published in real time: the 1-day map for a UTC day exists
      before that day starts, so `:cod_prd1` resolves for the current/near-future
      UTC day and `:cod_prd2` for the day after. AIUB encodes the prediction
      horizon only in the file's `COMMENT` header, not the filename; the catalog
      distinguishes the horizons by the target date the convenience builders
      offset to. The IGS combined rapid map `IGS0OPSRAP` has no verified open
      HTTP(S) mirror and stays in `@no_open_mirrors`. IONEX cadence is sub-daily,
      so the default sampling is `01H`/`02H`, not `01D`.

  ## Filename conventions

  Precise products and IONEX follow the IGS long-name convention
  `AAAVPPPTTT_YYYYDDDHHMM_LEN_SMP_CNT.EXT` (e.g.
  `GFZ0OPSRAP_20201760000_01D_15M_ORB.SP3`). Ultra-rapid SP3 uses the same
  form with a sub-daily issue time and a two-day span, e.g.
  `IGS0OPSULT_20242470600_02D_15M_ORB.SP3`. CODE ultra-rapid SP3 on AIUB is
  published as a daily, uncompressed `01D` file. Broadcast navigation uses the
  RINEX long-name `SSSSMRCCC_R_YYYYDDDHHMM_LEN_CNT.fmt` with **no** sampling
  field and a lowercase extension (e.g. `BRDC00WRD_R_20201770000_01D_MN.rnx`).
  """

  @gps_epoch_jdn 2_444_245
  @seconds_per_day 86_400
  @opsult_issues ~w(0000 0600 1200 1800)

  # Each center definition:
  #   :name      human-readable name
  #   :protocol  :https | :http
  #   :host      archive host (the SSRF allow-list source)
  #   :root      archive root URL (no trailing slash)
  #   :tokens    %{content => token_prefix} where the token already includes the
  #              solution code (e.g. "GFZ0OPSRAP", "ESA0MGNFIN", "BRDC00WRD").
  #   :layouts   %{content => layout} describing the directory tree per content.
  #   :spans     optional %{content => span}; defaults to "01D".
  #   :samples   optional default samples per content for convenience builders.
  #   :issues    optional valid issue-time list for sub-daily products.
  @centers %{
    gfz: %{
      name: "GFZ (Deutsches GeoForschungsZentrum Potsdam) operational AC",
      protocol: :https,
      host: "isdc-data.gfz.de",
      root: "https://isdc-data.gfz.de/gnss/products",
      tokens: %{sp3: "GFZ0OPSRAP", clk: "GFZ0OPSRAP"},
      layouts: %{sp3: :gfz_rapid_week, clk: :gfz_rapid_week},
      samples: %{sp3: "15M", clk: "30S"}
    },
    esa: %{
      name: "ESA Navigation Office GNSS products",
      protocol: :https,
      host: "navigation-office.esa.int",
      root: "https://navigation-office.esa.int/products/gnss-products",
      tokens: %{sp3: "ESA0MGNFIN", clk: "ESA0MGNFIN", ionex: "ESA0OPSFIN"},
      layouts: %{sp3: :gps_week, clk: :gps_week, ionex: :gps_week},
      samples: %{sp3: "05M", clk: "30S", ionex: "02H"}
    },
    cod: %{
      name: "Center for Orbit Determination in Europe (CODE), University of Bern",
      protocol: :http,
      host: "ftp.aiub.unibe.ch",
      root: "http://ftp.aiub.unibe.ch",
      tokens: %{sp3: "COD0MGXFIN", clk: "COD0MGXFIN", ionex: "COD0OPSFIN"},
      layouts: %{
        sp3: :aiub_code_mgex_year,
        clk: :aiub_code_mgex_year,
        ionex: :aiub_code_year
      },
      samples: %{sp3: "05M", clk: "30S", ionex: "01H"}
    },
    igs_ult: %{
      name: "IGS combined ultra-rapid precise products",
      protocol: :https,
      host: "igs.bkg.bund.de",
      root: "https://igs.bkg.bund.de/root_ftp/IGS",
      tokens: %{sp3: "IGS0OPSULT"},
      layouts: %{sp3: :bkg_products_week},
      spans: %{sp3: "02D"},
      samples: %{sp3: "15M"},
      issues: @opsult_issues
    },
    cod_ult: %{
      name: "CODE ultra-rapid precise products",
      protocol: :http,
      host: "ftp.aiub.unibe.ch",
      root: "http://ftp.aiub.unibe.ch",
      tokens: %{sp3: "COD0OPSULT"},
      layouts: %{sp3: :aiub_code_root},
      spans: %{sp3: "01D"},
      samples: %{sp3: "05M"},
      issues: ~w(0000),
      compression: %{sp3: :none}
    },
    esa_ult: %{
      name: "ESA ultra-rapid precise products",
      protocol: :https,
      host: "navigation-office.esa.int",
      root: "https://navigation-office.esa.int/products/gnss-products",
      tokens: %{sp3: "ESA0OPSULT"},
      layouts: %{sp3: :gps_week},
      spans: %{sp3: "02D"},
      samples: %{sp3: "15M"},
      issues: @opsult_issues
    },
    gfz_ult: %{
      name: "GFZ ultra-rapid precise products",
      protocol: :https,
      host: "isdc-data.gfz.de",
      root: "https://isdc-data.gfz.de/gnss/products",
      tokens: %{sp3: "GFZ0OPSULT"},
      layouts: %{sp3: :gfz_ultra_week},
      spans: %{sp3: "02D"},
      samples: %{sp3: "05M"},
      issues: @opsult_issues
    },
    cod_rap: %{
      name: "CODE rapid global ionosphere map",
      protocol: :http,
      host: "ftp.aiub.unibe.ch",
      root: "http://ftp.aiub.unibe.ch",
      tokens: %{ionex: "COD0OPSRAP"},
      layouts: %{ionex: :aiub_code_root},
      spans: %{ionex: "01D"},
      samples: %{ionex: "01H"}
    },
    cod_prd1: %{
      name: "CODE 1-day predicted global ionosphere map",
      protocol: :http,
      host: "ftp.aiub.unibe.ch",
      root: "http://ftp.aiub.unibe.ch",
      tokens: %{ionex: "COD0OPSPRD"},
      layouts: %{ionex: :aiub_code_root},
      spans: %{ionex: "01D"},
      samples: %{ionex: "01H"}
    },
    cod_prd2: %{
      name: "CODE 2-day predicted global ionosphere map",
      protocol: :http,
      host: "ftp.aiub.unibe.ch",
      root: "http://ftp.aiub.unibe.ch",
      tokens: %{ionex: "COD0OPSPRD"},
      layouts: %{ionex: :aiub_code_root},
      spans: %{ionex: "01D"},
      samples: %{ionex: "01H"}
    },
    igs: %{
      name: "IGS Combined Analysis Center",
      protocol: :https,
      host: "igs.bkg.bund.de",
      root: "https://igs.bkg.bund.de/root_ftp/IGS",
      tokens: %{nav: "BRDC00WRD"},
      layouts: %{nav: :bkg_brdc_year_doy},
      samples: %{nav: "01D"}
    }
  }

  @no_open_mirrors MapSet.new([
                     {:grg, :sp3},
                     {:grg, :clk},
                     {:wum, :sp3},
                     {:wum, :clk},
                     {:grg_ult, :sp3},
                     {:grg_ult, :clk},
                     {:igs, :ionex}
                   ])

  # Content type -> filename form.
  #   :code   the 2- or 3-letter content code
  #   :ext    the file extension (case as published)
  #   :kind   :sampled (AAAVPPPTTT_DATE_LEN_SMP_CNT.EXT) or
  #           :nav (SSSSMRCCC_R_DATE_LEN_CNT.ext, no SMP field)
  @content %{
    sp3: %{code: "ORB", ext: "SP3", kind: :sampled},
    clk: %{code: "CLK", ext: "CLK", kind: :sampled},
    nav: %{code: "MN", ext: "rnx", kind: :nav},
    ionex: %{code: "GIM", ext: "INX", kind: :sampled},
    obs: %{code: "MO", ext: "crx", kind: :obs_station}
  }

  @type error ::
          {:error, {:unsupported_product, term()}}
          | {:error, {:no_open_mirror, {atom(), atom()}}}
  @type compression :: :gzip | :none

  @doc """
  All supported analysis-center codes.
  """
  @spec centers() :: [atom()]
  def centers, do: Map.keys(@centers)

  @doc """
  All supported content-type codes.
  """
  @spec content_types() :: [atom()]
  def content_types, do: Map.keys(@content)

  @doc """
  Look up a center's static definition.

  Returns `{:ok, map}` or `{:error, {:unsupported_product, {:center, code}}}`.
  """
  @spec center(atom()) :: {:ok, map()} | {:error, {:unsupported_product, term()}}
  def center(code) when is_atom(code) do
    case Map.fetch(@centers, code) do
      {:ok, def} -> {:ok, def}
      :error -> {:error, {:unsupported_product, {:center, code}}}
    end
  end

  def center(code), do: {:error, {:unsupported_product, {:center, code}}}

  @doc """
  Human-readable center name, or `nil` if the code is unknown.
  """
  @spec center_name(atom()) :: String.t() | nil
  def center_name(code) do
    case center(code) do
      {:ok, def} -> def.name
      _ -> nil
    end
  end

  @doc """
  The catalog default sampling code for a center/content pair, when one is known.

  Ultra-rapid centers publish different native orbit cadences (`IGS`/`ESA` at
  15 minutes, several analysis-center products at 5 minutes), so callers should
  prefer this over a global default when building live-latency products.

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.default_sample(:igs_ult, :sp3)
      {:ok, "15M"}

      iex> Sidereon.GNSS.Data.Catalog.default_sample(:gfz_ult, :sp3)
      {:ok, "05M"}
  """
  @spec default_sample(atom(), atom()) :: {:ok, String.t()} | error()
  def default_sample(center, content) do
    with {:ok, _descriptor} <- content(content),
         :ok <- open_mirror(center, content),
         {:ok, cdef} <- center(center),
         {:ok, samples} <- Map.fetch(cdef, :samples),
         {:ok, sample} <- Map.fetch(samples, content) do
      {:ok, sample}
    else
      :error -> {:error, {:unsupported_product, {:default_sample, {center, content}}}}
      {:error, _} = err -> err
    end
  end

  @doc """
  The content-type descriptor (`%{code:, ext:, kind:}`) for a content type.

  Returns `{:ok, map}` or `{:error, {:unsupported_product, {:content, type}}}`.
  """
  @spec content(atom()) :: {:ok, map()} | {:error, {:unsupported_product, term()}}
  def content(type) when is_atom(type) do
    case Map.fetch(@content, type) do
      {:ok, descriptor} -> {:ok, descriptor}
      :error -> {:error, {:unsupported_product, {:content, type}}}
    end
  end

  def content(type), do: {:error, {:unsupported_product, {:content, type}}}

  @doc """
  The GPS week number for a calendar date.

  GPS week 0 began on 1980-01-06. Uses exact integer day arithmetic, so it is
  leap-second-agnostic (week numbering is a calendar count, not a clock count).

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.gps_week(~D[2020-06-24])
      2111
  """
  @spec gps_week(Date.t()) :: non_neg_integer()
  def gps_week(%Date{} = date) do
    div(days_since_gps_epoch(date), 7)
  end

  @doc """
  The GPS day-of-week for a calendar date (`0` = Sunday … `6` = Saturday).

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.gps_day_of_week(~D[2020-06-24])
      3
  """
  @spec gps_day_of_week(Date.t()) :: 0..6
  def gps_day_of_week(%Date{} = date) do
    rem(days_since_gps_epoch(date), 7)
  end

  @doc """
  The day-of-year (`001`-`366`) for a calendar date.

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.day_of_year(~D[2020-06-24])
      176
  """
  @spec day_of_year(Date.t()) :: 1..366
  def day_of_year(%Date{} = date) do
    jdn(date.year, date.month, date.day) - jdn(date.year, 1, 1) + 1
  end

  @doc """
  Build the canonical IGS long-name filename for a product.

  Precise products and IONEX use `AAAVPPPTTT_YYYYDDDHHMM_LEN_SMP_CNT.EXT`;
  broadcast navigation uses the no-sampling RINEX form
  `SSSSMRCCC_R_YYYYDDDHHMM_LEN_CNT.ext`. The center must actually publish the
  requested content type.

  Returns `{:ok, filename}` or a tagged error tuple.

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.canonical_filename(:gfz, :sp3, ~D[2020-06-24], "15M")
      {:ok, "GFZ0OPSRAP_20201760000_01D_15M_ORB.SP3"}

      iex> Sidereon.GNSS.Data.Catalog.canonical_filename(:igs, :nav, ~D[2020-06-25], "01D")
      {:ok, "BRDC00WRD_R_20201770000_01D_MN.rnx"}
  """
  @spec canonical_filename(atom(), atom(), Date.t(), String.t()) ::
          {:ok, String.t()} | error()
  def canonical_filename(center, content, %Date{} = date, sample)
      when is_atom(center) and is_atom(content) and is_binary(sample) do
    canonical_filename(center, content, date, sample, nil)
  end

  def canonical_filename(_center, _content, _date, _sample),
    do: {:error, {:unsupported_product, :bad_arguments}}

  @doc """
  Build the canonical filename for a product with an optional sub-daily issue.

  `issue` is `nil` for daily products and an `HHMM` string for ultra-rapid
  products. Ultra-rapid centers reject unsupported issue times instead of
  silently rounding.

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.canonical_filename(:igs_ult, :sp3, ~D[2024-09-03], "15M", "0600")
      {:ok, "IGS0OPSULT_20242470600_02D_15M_ORB.SP3"}
  """
  @spec canonical_filename(atom(), atom(), Date.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | error()
  def canonical_filename(center, content, %Date{} = date, sample, issue)
      when is_atom(center) and is_atom(content) and is_binary(sample) do
    with {:ok, descriptor} <- content(content),
         :ok <- open_mirror(center, content),
         {:ok, cdef} <- center(center),
         {:ok, token} <- token_for(cdef, content),
         :ok <- validate_sample(sample),
         {:ok, issue} <- issue_for(cdef, issue),
         {:ok, span} <- span_for(cdef, content) do
      {:ok, build_filename(descriptor, token, date, sample, issue, span)}
    end
  end

  def canonical_filename(_center, _content, _date, _sample, _issue),
    do: {:error, {:unsupported_product, :bad_arguments}}

  @doc """
  Return candidate ultra-rapid issues at or before a target epoch, newest first.

  The returned entries are maps with `:date` and `:issue` keys. A previous-day
  issue is included when it is the newest product not after the target; this is
  required for early UTC hours when the current-day file has not landed yet.

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.ultra_issue_candidates(:igs_ult, ~N[2024-09-03 13:15:00]) |> Enum.take(3)
      [%{date: ~D[2024-09-03], issue: "1200"}, %{date: ~D[2024-09-03], issue: "0600"}, %{date: ~D[2024-09-03], issue: "0000"}]
  """
  @spec ultra_issue_candidates(atom(), NaiveDateTime.t() | DateTime.t()) ::
          [%{date: Date.t(), issue: String.t()}] | error()
  def ultra_issue_candidates(center, target) do
    with :ok <- open_mirror(center, :sp3),
         {:ok, cdef} <- center(center),
         {:ok, issues} <- issues_for(cdef),
         {:ok, target_ndt} <- normalize_target(target) do
      target_date = NaiveDateTime.to_date(target_ndt)

      [target_date, Date.add(target_date, -1)]
      |> Enum.flat_map(fn date ->
        Enum.map(issues, fn issue ->
          %{date: date, issue: issue, epoch: issue_epoch(date, issue)}
        end)
      end)
      |> Enum.filter(&(NaiveDateTime.compare(&1.epoch, target_ndt) != :gt))
      |> Enum.sort_by(& &1.epoch, {:desc, NaiveDateTime})
      |> Enum.map(&Map.take(&1, [:date, :issue]))
    end
  end

  @doc """
  Resolve the latest available ultra-rapid issue at or before `target`.

  `available` is optional. When provided, it is a list of `%{date:, issue:}` maps
  or `{date, issue}` tuples representing archive entries known to exist; the
  resolver picks the newest candidate present in that set. This keeps network
  probing outside the pure catalog while letting the fetch layer fall back from
  a missing latest issue to an older one.

  ## Examples

      iex> available = [{~D[2024-09-03], "0000"}, {~D[2024-09-03], "0600"}]
      iex> Sidereon.GNSS.Data.Catalog.latest_ultra_issue(:igs_ult, ~N[2024-09-03 13:00:00], available)
      {:ok, %{date: ~D[2024-09-03], issue: "0600"}}
  """
  @spec latest_ultra_issue(
          atom(),
          NaiveDateTime.t() | DateTime.t(),
          nil | [%{date: Date.t(), issue: String.t()} | {Date.t(), String.t()}]
        ) ::
          {:ok, %{date: Date.t(), issue: String.t()}}
          | error()
  def latest_ultra_issue(center, target, available \\ nil) do
    with candidates when is_list(candidates) <- ultra_issue_candidates(center, target),
         {:ok, available_set} <- available_issue_set(available) do
      case Enum.find(candidates, &available?(&1, available_set)) do
        nil -> {:error, {:unsupported_product, :no_available_issue}}
        issue -> {:ok, issue}
      end
    end
  end

  @doc """
  Day offset, relative to a target UTC date, that a predicted IONEX alias maps to.

  CODE publishes a single predicted product (`COD0OPSPRD`); the prediction
  horizon ("1-DAY", "2-DAY", ... PREDICTED) appears only in the file's COMMENT
  header, never the filename. The catalog therefore distinguishes the horizons by
  the calendar day each alias targets: `:cod_prd1` is the current/near-future day
  (offset `0`) and `:cod_prd2` is the day after (offset `+1`). Non-predicted
  centers return `0`.

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.predicted_day_offset(:cod_prd1)
      0

      iex> Sidereon.GNSS.Data.Catalog.predicted_day_offset(:cod_prd2)
      1

      iex> Sidereon.GNSS.Data.Catalog.predicted_day_offset(:cod_rap)
      0
  """
  @spec predicted_day_offset(atom()) :: integer()
  def predicted_day_offset(:cod_prd1), do: 0
  def predicted_day_offset(:cod_prd2), do: 1
  def predicted_day_offset(_center), do: 0

  @doc """
  Candidate UTC dates for a daily GIM (rapid or predicted) at or before `target`,
  newest first.

  Unlike ultra-rapid SP3, the CODE rapid and predicted GIMs are daily files with
  no sub-daily issue time, so the latest-available fallback walks the calendar day
  backward instead of the issue clock. The rapid map lands a day or two late and
  the predicted map is published ahead of its target day; in both cases the
  freshest file present may be for a slightly earlier day than first requested, so
  the fetch layer tries these candidates newest first.

  Returns a list of `Date` values (at most `lookback + 1` entries, default
  lookback `2`), or a tagged error for an unsupported center/content.

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.gim_date_candidates(:cod_rap, ~D[2026-06-14])
      [~D[2026-06-14], ~D[2026-06-13], ~D[2026-06-12]]

      iex> Sidereon.GNSS.Data.Catalog.gim_date_candidates(:cod_prd1, ~D[2026-06-14], 1)
      [~D[2026-06-14], ~D[2026-06-13]]
  """
  @spec gim_date_candidates(
          atom(),
          Date.t() | NaiveDateTime.t() | DateTime.t(),
          non_neg_integer()
        ) ::
          [Date.t()] | error()
  def gim_date_candidates(center, target, lookback \\ 2) do
    with :ok <- open_mirror(center, :ionex),
         {:ok, _cdef} <- center(center),
         {:ok, base} <- gim_target_date(center, target) do
      for back <- 0..lookback, do: Date.add(base, -back)
    end
  end

  defp gim_target_date(center, %Date{} = date),
    do: {:ok, Date.add(date, predicted_day_offset(center))}

  defp gim_target_date(center, %DateTime{} = target),
    do: gim_target_date(center, DateTime.to_date(target))

  defp gim_target_date(center, %NaiveDateTime{} = target),
    do: gim_target_date(center, NaiveDateTime.to_date(target))

  defp gim_target_date(_center, _target), do: {:error, {:unsupported_product, :bad_target}}

  @doc """
  Build the canonical IGS long-name filename for a daily station observation
  product (RINEX 3 CRINEX), e.g.
  `ESBC00DNK_R_20201770000_01D_30S_MO.crx`.

  Station observation files are keyed by a 9-character site id, not an
  analysis-center token, so they have their own builder.

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.station_obs_filename("ESBC00DNK", ~D[2020-06-25], "30S")
      {:ok, "ESBC00DNK_R_20201770000_01D_30S_MO.crx"}
  """
  @spec station_obs_filename(String.t(), Date.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:unsupported_product, term()}}
  def station_obs_filename(station, %Date{} = date, sample)
      when is_binary(station) and is_binary(sample) do
    with :ok <- validate_station(station),
         :ok <- validate_sample(sample),
         {:ok, descriptor} <- content(:obs) do
      {:ok, "#{station}_R_#{date_block(date)}_01D_#{sample}_#{descriptor.code}.#{descriptor.ext}"}
    end
  end

  def station_obs_filename(_station, _date, _sample),
    do: {:error, {:unsupported_product, :bad_arguments}}

  @doc """
  Build the full, compressed (`.gz`) archive URL for a daily station observation
  product on the public BKG IGS observation tree.

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.station_obs_url("WTZR00DEU", ~D[2020-06-25], "30S")
      {:ok, "https://igs.bkg.bund.de/root_ftp/IGS/obs/2020/177/WTZR00DEU_R_20201770000_01D_30S_MO.crx.gz"}
  """
  @spec station_obs_url(String.t(), Date.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:unsupported_product, term()}}
  def station_obs_url(station, %Date{} = date, sample) do
    with {:ok, filename} <- station_obs_filename(station, date, sample) do
      root = "https://igs.bkg.bund.de/root_ftp/IGS"
      {:ok, "#{root}/#{dir_path(:bkg_obs_year_doy, date)}/#{filename}.gz"}
    end
  end

  @doc """
  Build the full, compressed (`.gz`) archive URL for a product.

  The directory follows the center/content layout; the filename is the canonical
  long-name plus a `.gz` suffix. The host is always one of the catalog hosts,
  never caller-supplied input.

  Returns `{:ok, url}` or a tagged error tuple.

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.archive_url(:gfz, :sp3, ~D[2020-06-24], "15M")
      {:ok, "https://isdc-data.gfz.de/gnss/products/rapid/w2111/GFZ0OPSRAP_20201760000_01D_15M_ORB.SP3.gz"}

      iex> Sidereon.GNSS.Data.Catalog.archive_url(:igs, :nav, ~D[2020-06-25], "01D")
      {:ok, "https://igs.bkg.bund.de/root_ftp/IGS/BRDC/2020/177/BRDC00WRD_R_20201770000_01D_MN.rnx.gz"}
  """
  @spec archive_url(atom(), atom(), Date.t(), String.t()) ::
          {:ok, String.t()} | error()
  def archive_url(center, content, %Date{} = date, sample) do
    archive_url(center, content, date, sample, nil)
  end

  def archive_url(_center, _content, _date, _sample),
    do: {:error, {:unsupported_product, :bad_arguments}}

  @doc """
  Build the full, compressed (`.gz`) archive URL for a product with an optional
  issue time.

  ## Examples

      iex> Sidereon.GNSS.Data.Catalog.archive_url(:cod_ult, :sp3, ~D[2026-06-11], "05M", "0000")
      {:ok, "http://ftp.aiub.unibe.ch/CODE/COD0OPSULT_20261620000_01D_05M_ORB.SP3"}
  """
  @spec archive_url(atom(), atom(), Date.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | error()
  def archive_url(center, content, %Date{} = date, sample, issue) do
    with {:ok, filename} <- canonical_filename(center, content, date, sample, issue),
         {:ok, cdef} <- center(center),
         {:ok, layout} <- layout_for(cdef, content),
         {:ok, suffix} <- archive_suffix_for(cdef, content) do
      {:ok, "#{cdef.root}/#{dir_path(layout, date)}/#{filename}#{suffix}"}
    end
  end

  def archive_url(_center, _content, _date, _sample, _issue),
    do: {:error, {:unsupported_product, :bad_arguments}}

  @doc """
  The transfer protocol (`:https` or `:http`) for a center.
  """
  @spec protocol(atom()) :: {:ok, :https | :http} | {:error, {:unsupported_product, term()}}
  def protocol(center) do
    with {:ok, cdef} <- center(center), do: {:ok, cdef.protocol}
  end

  @doc """
  The archive compression used for a center/content pair.
  """
  @spec compression(atom(), atom()) :: {:ok, compression()} | error()
  def compression(center, content) do
    with {:ok, _descriptor} <- content(content),
         :ok <- open_mirror(center, content),
         {:ok, cdef} <- center(center),
         {:ok, _token} <- token_for(cdef, content),
         {:ok, _layout} <- layout_for(cdef, content) do
      compression_for(cdef, content)
    end
  end

  @doc """
  The set of hosts the layer is permitted to contact.

  Used by the download path as an allow-list so a malformed or unexpected URL
  can never cause a request to an off-catalog host.
  """
  @spec allowed_hosts() :: MapSet.t(String.t())
  def allowed_hosts do
    @centers |> Map.values() |> MapSet.new(& &1.host)
  end

  # --- filename construction -----------------------------------------------

  defp build_filename(%{kind: :sampled, code: code, ext: ext}, token, date, sample, issue, span) do
    "#{token}_#{date_block(date, issue)}_#{span}_#{sample}_#{code}.#{ext}"
  end

  defp build_filename(%{kind: :nav, code: code, ext: ext}, token, date, _sample, _issue, span) do
    "#{token}_R_#{date_block(date, nil)}_#{span}_#{code}.#{ext}"
  end

  defp date_block(%Date{} = date), do: date_block(date, nil)
  defp date_block(%Date{} = date, nil), do: date_block(date, "0000")
  defp date_block(%Date{} = date, issue), do: "#{date.year}#{pad3(day_of_year(date))}#{issue}"

  defp token_for(%{tokens: tokens}, content) do
    case Map.fetch(tokens, content) do
      {:ok, token} -> {:ok, token}
      :error -> {:error, {:unsupported_product, {:content_not_served, content}}}
    end
  end

  defp layout_for(%{layouts: layouts}, content) do
    case Map.fetch(layouts, content) do
      {:ok, layout} -> {:ok, layout}
      :error -> {:error, {:unsupported_product, {:content_not_served, content}}}
    end
  end

  defp span_for(cdef, content) do
    {:ok, get_in(cdef, [:spans, content]) || "01D"}
  end

  defp archive_suffix_for(cdef, content) do
    case compression_for(cdef, content) do
      {:ok, :gzip} -> {:ok, ".gz"}
      {:ok, :none} -> {:ok, ""}
      {:ok, other} -> {:error, {:unsupported_product, {:compression, other}}}
    end
  end

  defp compression_for(cdef, content) do
    {:ok, get_in(cdef, [:compression, content]) || :gzip}
  end

  defp issue_for(%{issues: issues}, issue) when is_binary(issue) do
    with :ok <- validate_issue(issue) do
      if issue in issues do
        {:ok, issue}
      else
        {:error, {:unsupported_product, {:issue, issue}}}
      end
    end
  end

  defp issue_for(%{issues: _issues}, nil), do: {:error, {:unsupported_product, :missing_issue}}

  defp issue_for(_cdef, nil), do: {:ok, nil}

  defp issue_for(_cdef, issue), do: {:error, {:unsupported_product, {:issue, issue}}}

  defp issues_for(%{issues: issues}), do: {:ok, issues}
  defp issues_for(_cdef), do: {:error, {:unsupported_product, :not_ultra_rapid}}

  defp normalize_target(%DateTime{} = target), do: {:ok, DateTime.to_naive(target)}
  defp normalize_target(%NaiveDateTime{} = target), do: {:ok, target}
  defp normalize_target(_target), do: {:error, {:unsupported_product, :bad_target}}

  defp issue_epoch(date, issue) do
    {hour, minute} = parse_issue!(issue)
    NaiveDateTime.new!(date, Time.new!(hour, minute, 0))
  end

  defp available_issue_set(nil), do: {:ok, nil}

  defp available_issue_set(available) when is_list(available) do
    available
    |> Enum.reduce_while({:ok, MapSet.new()}, fn entry, {:ok, acc} ->
      case normalize_available_issue(entry) do
        {:ok, key} -> {:cont, {:ok, MapSet.put(acc, key)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp available_issue_set(_available),
    do: {:error, {:unsupported_product, :bad_available_issues}}

  defp normalize_available_issue({%Date{} = date, issue}) when is_binary(issue) do
    with :ok <- validate_issue(issue), do: {:ok, {date, issue}}
  end

  defp normalize_available_issue(%{date: %Date{} = date, issue: issue}) when is_binary(issue) do
    with :ok <- validate_issue(issue), do: {:ok, {date, issue}}
  end

  defp normalize_available_issue(_entry),
    do: {:error, {:unsupported_product, :bad_available_issue}}

  defp available?(_candidate, nil), do: true
  defp available?(%{date: date, issue: issue}, set), do: MapSet.member?(set, {date, issue})

  defp open_mirror(center, content) do
    if MapSet.member?(@no_open_mirrors, {center, content}) do
      {:error, {:no_open_mirror, {center, content}}}
    else
      :ok
    end
  end

  # --- directory layouts ---------------------------------------------------

  # GFZ HTTPS operational tree: <root>/rapid/w<gpsweek>/<file>.
  defp dir_path(:gfz_rapid_week, date), do: "rapid/w#{gps_week(date)}"

  # GFZ HTTPS ultra-rapid tree: <root>/ultra/w<gpsweek>/<file>.
  defp dir_path(:gfz_ultra_week, date), do: "ultra/w#{gps_week(date)}"

  # ESA Navigation Office tree: <root>/<gpsweek>/<file>.
  defp dir_path(:gps_week, date), do: "#{gps_week(date)}"

  # BKG IGS products tree: <root>/products/<gpsweek>/<file>.
  defp dir_path(:bkg_products_week, date), do: "products/#{gps_week(date)}"

  # BKG IGS broadcast navigation tree: <root>/BRDC/<year>/<doy>/<file>.
  defp dir_path(:bkg_brdc_year_doy, date), do: "BRDC/#{date.year}/#{pad3(day_of_year(date))}"

  # BKG IGS station observation tree: <root>/obs/<year>/<doy>/<file>.
  defp dir_path(:bkg_obs_year_doy, date), do: "obs/#{date.year}/#{pad3(day_of_year(date))}"

  # AIUB CODE MGEX final tree: <root>/CODE_MGEX/CODE/<year>/<file>.
  defp dir_path(:aiub_code_mgex_year, date), do: "CODE_MGEX/CODE/#{date.year}"

  # AIUB CODE operational/final tree: <root>/CODE/<year>/<file>.
  defp dir_path(:aiub_code_year, date), do: "CODE/#{date.year}"

  # AIUB CODE recent-products root: <root>/CODE/<file>.
  defp dir_path(:aiub_code_root, _date), do: "CODE"

  # --- validation ----------------------------------------------------------

  defp validate_sample(<<_::binary-size(3)>> = s) do
    if String.match?(s, ~r/\A[0-9]{2}[A-Z]\z/), do: :ok, else: bad_sample(s)
  end

  defp validate_sample(s), do: bad_sample(s)

  defp bad_sample(s), do: {:error, {:unsupported_product, {:sample, s}}}

  defp validate_issue(<<_::binary-size(4)>> = issue) do
    if String.match?(issue, ~r/\A[0-9]{4}\z/) do
      {hour, minute} = parse_issue!(issue)

      if hour in 0..23 and minute in 0..59 do
        :ok
      else
        bad_issue(issue)
      end
    else
      bad_issue(issue)
    end
  end

  defp validate_issue(issue), do: bad_issue(issue)

  defp bad_issue(issue), do: {:error, {:unsupported_product, {:issue, issue}}}

  defp parse_issue!(issue) do
    <<hh::binary-size(2), mm::binary-size(2)>> = issue
    {String.to_integer(hh), String.to_integer(mm)}
  end

  # A RINEX 3 site id is a 9-character SSSSMRCCC token (4-char monument, marker,
  # receiver, 3-char ISO country), upper-case alphanumeric. Validating it keeps
  # the cache filename path-safe and the archive URL on the known host.
  defp validate_station(<<_::binary-size(9)>> = s) do
    if String.match?(s, ~r/\A[A-Z0-9]{9}\z/), do: :ok, else: bad_station(s)
  end

  defp validate_station(s), do: bad_station(s)

  defp bad_station(s), do: {:error, {:unsupported_product, {:station, s}}}

  @doc """
  The transfer protocol for the daily station observation archive.
  """
  @spec station_obs_protocol() :: :https
  def station_obs_protocol, do: :https

  # --- date arithmetic -----------------------------------------------------

  defp days_since_gps_epoch(%Date{} = date) do
    jdn(date.year, date.month, date.day) - @gps_epoch_jdn
  end

  defp pad3(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")

  defp jdn(year, month, day) do
    a = div(14 - month, 12)
    y = year + 4800 - a
    m = month + 12 * a - 3
    day + div(153 * m + 2, 5) + 365 * y + div(y, 4) - div(y, 100) + div(y, 400) - 32_045
  end

  @doc false
  def seconds_per_day, do: @seconds_per_day
end
