defmodule Sidereon.GNSS.Constellation do
  @moduledoc """
  GNSS constellation identity catalogs and validation helpers.

  This module is a data/catalog layer: it builds normalized satellite identity
  records from public sources and compares those records with GNSS products. It
  does not alter positioning solves or infer application-specific health rules.

  The identity, parsing, validation, and diff logic lives in the `sidereon_core`
  `constellation` module (the shared Rust core), reached through the NIF. The
  core covers all five GNSS constellations — **GPS, Galileo, GLONASS, BeiDou, and
  QZSS** — so this module is multi-system: `from_celestrak_omm/2` dispatches on
  the constellation atom (`:gps`, `:galileo`, `:glonass`, `:beidou`, `:qzss`) to
  the per-system identity adapter in the core.

  OMM/JSON source records are parsed from `OBJECT_NAME` and rendered as the
  SP3/RINEX id (`"G13"`, `"E07"`, `"R13"`, `"C19"`, `"J02"`). GPS constellation
  status HTML can be parsed and merged as an optional SVN/usability overlay.

  ## Examples

      iex> omms = [
      ...>   %{"OBJECT_NAME" => "GPS BIIF-8  (PRN 03)", "NORAD_CAT_ID" => 40294}
      ...> ]
      iex> {:ok, [record]} = Sidereon.GNSS.Constellation.from_celestrak_omm(:gps, omms)
      iex> {record.system, record.prn, record.norad_id, record.sp3_id}
      {:gps, 3, 40294, "G03"}

      iex> record = %Sidereon.GNSS.Constellation.Record{
      ...>   system: :gps,
      ...>   prn: 3,
      ...>   svn: nil,
      ...>   norad_id: 40294,
      ...>   sp3_id: "G03",
      ...>   active?: true,
      ...>   usable?: true,
      ...>   source: %{}
      ...> }
      iex> Sidereon.GNSS.Constellation.to_csv([record])
      "prn,norad_cat_id,active,sp3_id\\n3,40294,true,G03\\n"

  Use `from_celestrak_omm/2`, `from_celestrak_omm_lenient/2`,
  `parse_navcen_html/1`, and `merge_navcen/2` with caller-provided text or
  decoded maps.
  """

  alias Sidereon.GNSS.Constellation
  alias Sidereon.GNSS.SP3
  alias Sidereon.NIF

  # The five constellations the catalog resolves identities for. (The core's
  # `GnssSystem` also has NavIC/SBAS, but there is no OMM identity adapter for
  # them, so they are out of scope for this module.)
  @system_letters %{gps: "G", glonass: "R", galileo: "E", beidou: "C", qzss: "J"}
  @letter_systems Map.new(@system_letters, fn {atom, letter} -> {letter, atom} end)
  # Sort order matching the core's `GnssSystem` enum (used to keep multi-system
  # results deterministic), not Elixir's atom ordering.
  @system_order %{gps: 0, glonass: 1, galileo: 2, beidou: 3, qzss: 4}

  @type system :: :gps | :glonass | :galileo | :beidou | :qzss

  defmodule Record do
    @moduledoc """
    A normalized GNSS satellite identity record.

    `active?` means the satellite is present in the base source used to build the
    catalog. `usable?` is an advisory health/status flag; for GPS it is `true`
    unless a merged NAVCEN row has an active NANU that marks the PRN unusable or
    decommissioned. The `source` map preserves source-specific provenance under
    `:celestrak`, `:navcen`, and `:navcen_conflict`.

    `fdma_channel` is the GLONASS FDMA L1/L2 frequency-channel number `k`
    (`-7..=6`); it is `nil` for the CDMA constellations (GPS, Galileo, BeiDou,
    QZSS). It is the one identity datum not present in any OMM feed; the core
    resolves it from the orbital slot via the published IGS/MCC slot-channel
    table (`glonass_fdma_channel/1`).
    """

    @enforce_keys [:system, :prn, :norad_id, :sp3_id, :active?, :usable?, :source]
    defstruct [
      :system,
      :prn,
      :svn,
      :norad_id,
      :sp3_id,
      :fdma_channel,
      :active?,
      :usable?,
      :source
    ]

    @type t :: %__MODULE__{
            system: Constellation.system(),
            prn: pos_integer(),
            svn: pos_integer() | nil,
            norad_id: pos_integer(),
            sp3_id: String.t(),
            fdma_channel: integer() | nil,
            active?: boolean(),
            usable?: boolean(),
            source: map()
          }
  end

  defmodule SkippedOmm do
    @moduledoc """
    An OMM entry that `Sidereon.GNSS.Constellation.from_celestrak_omm_lenient/2`
    could not resolve to a `Record` for the requested system.

    Carries the entry's identity so the caller can triage why it was skipped: a
    record from another constellation in a combined feed, or a satellite of the
    requested system whose `OBJECT_NAME` does not yet resolve.
    """

    @enforce_keys [:object_name, :norad_id]
    defstruct [:object_name, :norad_id]

    @type t :: %__MODULE__{
            object_name: String.t() | nil,
            norad_id: pos_integer()
          }
  end

  defmodule Catalog do
    @moduledoc """
    The result of a lenient catalog build: the records that resolved, plus the
    OMM entries that did not.

    Resolvable entries become `records` (sorted by `{system, prn}`); every entry
    whose `OBJECT_NAME` did not resolve is collected into `skipped` with its
    identity, in input order.
    """

    alias Sidereon.GNSS.Constellation.SkippedOmm

    @enforce_keys [:records, :skipped]
    defstruct [:records, :skipped]

    @type t :: %__MODULE__{
            records: [Sidereon.GNSS.Constellation.Record.t()],
            skipped: [SkippedOmm.t()]
          }
  end

  defmodule NavcenStatus do
    @moduledoc """
    A parsed row from NAVCEN's GPS constellation status table.
    """

    @enforce_keys [:system, :prn, :svn, :usable?, :active_nanu?]
    defstruct [
      :system,
      :prn,
      :svn,
      :usable?,
      :active_nanu?,
      :nanu_type,
      :nanu_subject,
      :plane,
      :slot,
      :block_type,
      :clock
    ]

    @type t :: %__MODULE__{
            system: Constellation.system(),
            prn: pos_integer(),
            svn: pos_integer() | nil,
            usable?: boolean(),
            active_nanu?: boolean(),
            nanu_type: String.t() | nil,
            nanu_subject: String.t() | nil,
            plane: String.t() | nil,
            slot: String.t() | nil,
            block_type: String.t() | nil,
            clock: String.t() | nil
          }
  end

  defmodule Validation do
    @moduledoc """
    Validation report for a GNSS constellation catalog.

    `duplicate_prns` and `inactive_unusable_prns` are keyed by `{system, prn}` so
    a legitimate multi-system catalog (GPS PRN 1 and Galileo PRN 1) is not a
    false duplicate.
    """

    @enforce_keys [
      :missing_sp3_ids,
      :duplicate_prns,
      :duplicate_norad_ids,
      :inactive_unusable_prns,
      :extra_sp3_ids
    ]
    defstruct [
      :missing_sp3_ids,
      :duplicate_prns,
      :duplicate_norad_ids,
      :inactive_unusable_prns,
      :extra_sp3_ids
    ]

    @type prn_key :: {Constellation.system(), pos_integer()}

    @type t :: %__MODULE__{
            missing_sp3_ids: [String.t()],
            duplicate_prns: [prn_key()],
            duplicate_norad_ids: [pos_integer()],
            inactive_unusable_prns: [prn_key()],
            extra_sp3_ids: [String.t()]
          }
  end

  defmodule Diff do
    @moduledoc """
    Change report between two GNSS constellation catalog snapshots.
    """

    @enforce_keys [
      :added,
      :removed,
      :norad_reassigned,
      :sp3_id_changed,
      :svn_changed,
      :fdma_channel_changed,
      :activity_changed,
      :usability_changed
    ]
    defstruct [
      :added,
      :removed,
      :norad_reassigned,
      :sp3_id_changed,
      :svn_changed,
      :fdma_channel_changed,
      :activity_changed,
      :usability_changed
    ]

    @type record_change(value) :: %{
            required(:system) => Constellation.system(),
            required(:prn) => pos_integer(),
            required(:from) => value,
            required(:to) => value
          }

    @type t :: %__MODULE__{
            added: [Record.t()],
            removed: [Record.t()],
            norad_reassigned: [record_change(pos_integer())],
            sp3_id_changed: [record_change(String.t())],
            svn_changed: [record_change(pos_integer() | nil)],
            fdma_channel_changed: [record_change(integer() | nil)],
            activity_changed: [record_change(boolean())],
            usability_changed: [record_change(boolean())]
          }
  end

  @type error ::
          {:error, {:unsupported_system, term()}}
          | {:error, {:bad_celestrak_record, term(), map()}}
          | {:error, {:invalid_input, term()}}
          | {:error, {:bad_navcen_html, term()}}
          | {:error, term()}

  @doc """
  Build records for `system` from a JSON OMM feed.

  This is the string-input sibling of `from_celestrak_omm/2`; decoded entries
  are still resolved by the shared Rust core.
  """
  @spec from_celestrak_json(String.t(), system()) :: {:ok, [Record.t()]} | error()
  def from_celestrak_json(json, system \\ :gps)

  def from_celestrak_json(json, system) when is_binary(json) do
    with {:ok, letter} <- system_letter(system) do
      case NIF.constellation_from_celestrak_json(letter, json) do
        {:ok, records} ->
          {:ok, Enum.map(records, &from_nif_record/1)}

        {:error, {:missing_prn, name}} ->
          {:error, {:bad_celestrak_record, {:missing_prn, name}, nil}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def from_celestrak_json(other, _system), do: {:error, {:invalid_input, {:not_a_binary, other}}}

  @doc """
  Build records for `system` from CelesTrak OMM/JSON maps, failing on the first
  entry whose `OBJECT_NAME` does not resolve to a PRN for `system`.

  CelesTrak does not publish SVN, so records built from this source alone have
  `svn: nil`. Records are returned sorted by `{system, prn}`.
  """
  @spec from_celestrak_omm(system(), [map()]) :: {:ok, [Record.t()]} | error()
  def from_celestrak_omm(system, omms) when is_list(omms) do
    with {:ok, letter} <- system_letter(system),
         {:ok, lites} <- omm_lites(omms) do
      case NIF.constellation_from_celestrak_omm(letter, lites) do
        {:ok, records} ->
          {:ok, Enum.map(records, &from_nif_record/1)}

        {:error, {:missing_prn, name}} ->
          {:error, {:bad_celestrak_record, {:missing_prn, name}, find_omm(omms, name)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def from_celestrak_omm(_system, other), do: {:error, {:invalid_input, {:not_a_list, other}}}

  @doc """
  Build a lenient catalog from a JSON OMM feed.

  This is the string-input sibling of `from_celestrak_omm_lenient/2`.
  """
  @spec from_celestrak_json_lenient(String.t(), system()) :: {:ok, Catalog.t()} | error()
  def from_celestrak_json_lenient(json, system \\ :gps)

  def from_celestrak_json_lenient(json, system) when is_binary(json) do
    with {:ok, letter} <- system_letter(system) do
      case NIF.constellation_from_celestrak_json_lenient(letter, json) do
        {:ok, %{records: records, skipped: skipped}} ->
          {:ok,
           %Catalog{
             records: Enum.map(records, &from_nif_record/1),
             skipped: Enum.map(skipped, &from_nif_skipped/1)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def from_celestrak_json_lenient(other, _system), do: {:error, {:invalid_input, {:not_a_binary, other}}}

  @doc """
  Build records for `system` from CelesTrak OMM/JSON maps, skipping (rather than
  aborting on) entries whose `OBJECT_NAME` does not resolve to a PRN for
  `system`.

  The lenient sibling of `from_celestrak_omm/2`: every OMM that resolves becomes
  a `Record`; every entry that does not (an other-constellation satellite in a
  combined `gnss` feed, or a freshly launched vehicle whose name does not yet
  resolve) is collected into `Catalog.skipped` with its identity. Resolvable
  records are returned sorted by `{system, prn}`.

  Leniency covers identity resolution only: an entry missing a valid
  `NORAD_CAT_ID` still aborts with `{:error, reason}`.

  ## Examples

      iex> omms = [
      ...>   %{"OBJECT_NAME" => "GPS BIIF-8  (PRN 03)", "NORAD_CAT_ID" => 40294},
      ...>   %{"OBJECT_NAME" => "GSAT0210 (GALILEO 13)", "NORAD_CAT_ID" => 41859}
      ...> ]
      iex> {:ok, catalog} = Sidereon.GNSS.Constellation.from_celestrak_omm_lenient(:gps, omms)
      iex> Enum.map(catalog.records, & &1.sp3_id)
      ["G03"]
      iex> Enum.map(catalog.skipped, &{&1.object_name, &1.norad_id})
      [{"GSAT0210 (GALILEO 13)", 41859}]
  """
  @spec from_celestrak_omm_lenient(String.t()) :: {:ok, Catalog.t()} | error()
  def from_celestrak_omm_lenient(json) when is_binary(json) do
    from_celestrak_omm_lenient(json, :gps)
  end

  @spec from_celestrak_omm_lenient(String.t(), system()) :: {:ok, Catalog.t()} | error()
  def from_celestrak_omm_lenient(json, system) when is_binary(json) do
    from_celestrak_json_lenient(json, system)
  end

  @spec from_celestrak_omm_lenient(system(), [map()]) :: {:ok, Catalog.t()} | error()
  def from_celestrak_omm_lenient(system, omms) when is_list(omms) do
    with {:ok, letter} <- system_letter(system),
         {:ok, lites} <- omm_lites(omms) do
      case NIF.constellation_from_celestrak_omm_lenient(letter, lites) do
        {:ok, %{records: records, skipped: skipped}} ->
          {:ok,
           %Catalog{
             records: Enum.map(records, &from_nif_record/1),
             skipped: Enum.map(skipped, &from_nif_skipped/1)
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def from_celestrak_omm_lenient(_system, other), do: {:error, {:invalid_input, {:not_a_list, other}}}

  @doc """
  Parse NAVCEN's GPS constellation status HTML.

  Returns status rows keyed by PRN/SVN; merge them into CelesTrak records with
  `merge_navcen/2`.
  """
  @spec parse_navcen_html(String.t()) :: {:ok, [NavcenStatus.t()]} | error()
  def parse_navcen_html(html) when is_binary(html) do
    case NIF.constellation_parse_navcen(html) do
      {:ok, statuses} -> {:ok, Enum.map(statuses, &from_nif_status/1)}
      {:error, reason} -> {:error, {:bad_navcen_html, reason}}
    end
  end

  def parse_navcen_html(_), do: {:error, {:bad_navcen_html, :not_binary}}

  @doc """
  Merge NAVCEN status rows into normalized records by PRN.

  NAVCEN does not publish NORAD ids, so CelesTrak stays the identity base. When a
  PRN is present in both sources and the block types are compatible, this fills
  `svn`, updates `usable?`, and records the NAVCEN provenance under
  `source.navcen`. A NAVCEN row that matches the PRN but carries an incompatible
  block type (a PRN transition) is recorded under `source.navcen_conflict`.
  """
  @spec merge_navcen([Record.t()], [NavcenStatus.t()]) :: [Record.t()]
  def merge_navcen(records, statuses) when is_list(records) and is_list(statuses) do
    # The core merges by PRN only, so a NAVCEN row for PRN 3 would otherwise
    # overlay onto any constellation's PRN 3. NAVCEN is a GPS oracle; merge each
    # system's records only against that same system's status rows.
    statuses_by_system = Enum.group_by(statuses, & &1.system)

    records
    |> Enum.group_by(& &1.system)
    |> Enum.flat_map(fn {system, system_records} ->
      case Map.fetch(statuses_by_system, system) do
        {:ok, system_statuses} -> nif_merge_navcen(system_records, system_statuses)
        :error -> system_records
      end
    end)
    |> Enum.sort_by(&{Map.fetch!(@system_order, &1.system), &1.prn})
  end

  defp nif_merge_navcen(records, statuses) do
    NIF.constellation_merge_navcen(
      Enum.map(records, &to_nif_record/1),
      Enum.map(statuses, &to_nif_status/1)
    )
    |> Enum.map(&from_nif_record/1)
  end

  @doc """
  Export records as the compact mapping CSV:

      prn,norad_cat_id,active,sp3_id

  The `active` column is `true` only when `record.active?` and `record.usable?`
  are both true. Records are sorted by `{system, prn}`.

  ## Options

    * `:booleans` - how the `active` column is rendered: `:lower` (default:
      `true`/`false`) or `:title` (`True`/`False`, for a pandas consumer).
  """
  @spec to_csv([Record.t()], keyword()) :: String.t()
  def to_csv(records, opts \\ []) when is_list(records) do
    booleans = if Keyword.get(opts, :booleans, :lower) == :title, do: "title", else: "lower"
    NIF.constellation_to_csv(Enum.map(records, &to_nif_record/1), booleans)
  end

  @doc """
  Compare two constellation catalog snapshots by `{system, prn}` identity.

  The result separates added/removed PRNs from identity/status changes on a PRN
  that exists in both snapshots. Assumes each input has at most one record per
  `{system, prn}`; run `validate/1` first on hand-edited catalogs.

      iex> previous = [
      ...>   %Sidereon.GNSS.Constellation.Record{
      ...>     system: :gps, prn: 3, svn: 69, norad_id: 40294, sp3_id: "G03",
      ...>     active?: true, usable?: true, source: %{}
      ...>   }
      ...> ]
      iex> current = [%{hd(previous) | norad_id: 99999, active?: false}]
      iex> diff = Sidereon.GNSS.Constellation.diff(previous, current)
      iex> [norad] = diff.norad_reassigned
      iex> {norad.system, norad.prn, norad.from, norad.to}
      {:gps, 3, 40294, 99999}
      iex> [activity] = diff.activity_changed
      iex> {activity.system, activity.prn, activity.from, activity.to}
      {:gps, 3, true, false}
      iex> Sidereon.GNSS.Constellation.changed?(diff)
      true
  """
  @spec diff([Record.t()], [Record.t()]) :: Diff.t()
  def diff(previous, current) when is_list(previous) and is_list(current) do
    NIF.constellation_diff(
      Enum.map(previous, &to_nif_record/1),
      Enum.map(current, &to_nif_record/1)
    )
    |> from_nif_diff()
  end

  def diff(_previous, _current) do
    raise ArgumentError, "Sidereon.GNSS.Constellation.diff/2 expects two record lists"
  end

  @doc """
  Validate catalog identity without an SP3 product.

  Reports duplicate PRNs, duplicate NORAD ids, and PRNs that are inactive or
  unusable according to the normalized records.
  """
  @spec validate([Record.t()]) :: Validation.t()
  def validate(records) when is_list(records) do
    records
    |> Enum.map(&to_nif_record/1)
    |> NIF.constellation_validate()
    |> from_nif_validation()
  end

  @doc """
  Validate catalog identity against SP3 satellite ids.

  The second argument may be a loaded `%Sidereon.GNSS.SP3{}` or a list of SP3/RINEX
  satellite tokens. `missing_sp3_ids` reports active+usable catalog ids absent
  from the product; `extra_sp3_ids` reports product ids absent from the
  active+usable catalog, restricted to the systems the catalog covers.
  """
  @spec validate_sp3([Record.t()], SP3.t() | [String.t()]) :: Validation.t()
  def validate_sp3(records, %SP3{} = sp3), do: validate_sp3(records, SP3.satellite_ids(sp3))

  def validate_sp3(records, sp3_ids) when is_list(records) and is_list(sp3_ids) do
    records
    |> Enum.map(&to_nif_record/1)
    |> NIF.constellation_validate_against_sp3_ids(sp3_ids)
    |> from_nif_validation()
  end

  @doc """
  Validate against SP3 satellite ids and raise unless the catalog is clean.

  A build-time gate: returns `:ok` when the catalog has no findings, otherwise
  raises `ArgumentError` describing them. Intended for catalog-build / automation
  steps, not the positioning runtime.
  """
  @spec validate_sp3!([Record.t()], SP3.t() | [String.t()]) :: :ok
  def validate_sp3!(records, %SP3{} = sp3), do: validate_sp3!(records, SP3.satellite_ids(sp3))

  def validate_sp3!(records, sp3_ids) when is_list(records) and is_list(sp3_ids) do
    case NIF.constellation_validate_against_sp3_ids_strict(
           Enum.map(records, &to_nif_record/1),
           sp3_ids
         ) do
      :ok -> :ok
      {:error, message} -> raise ArgumentError, "GNSS catalog failed SP3 validation: " <> message
    end
  end

  @doc """
  Returns `true` when a validation report has no findings.
  """
  @spec valid?(Validation.t()) :: boolean()
  def valid?(%Validation{} = report) do
    report.missing_sp3_ids == [] and report.duplicate_prns == [] and
      report.duplicate_norad_ids == [] and report.inactive_unusable_prns == [] and
      report.extra_sp3_ids == []
  end

  @doc """
  Returns `true` when a constellation diff has any findings.
  """
  @spec changed?(Diff.t()) :: boolean()
  def changed?(%Diff{} = diff) do
    diff.added != [] or diff.removed != [] or diff.norad_reassigned != [] or
      diff.sp3_id_changed != [] or diff.svn_changed != [] or diff.fdma_channel_changed != [] or
      diff.activity_changed != [] or diff.usability_changed != []
  end

  @doc """
  Render the canonical SP3/RINEX satellite token for a supported GNSS PRN.

      iex> Sidereon.GNSS.Constellation.sp3_id(:gps, 7)
      "G07"
      iex> Sidereon.GNSS.Constellation.sp3_id(:galileo, 7)
      "E07"
  """
  @spec sp3_id(system(), pos_integer()) :: String.t()
  def sp3_id(system, prn) when is_integer(prn) and prn > 0 do
    NIF.constellation_sp3_id(Map.fetch!(@system_letters, system), prn)
  end

  @doc """
  Resolve a GLONASS orbital slot (`1..24`) to its FDMA L1/L2 frequency-channel
  number `k`, or `nil` for a slot outside the operational range.

      iex> Sidereon.GNSS.Constellation.glonass_fdma_channel(1)
      1
      iex> Sidereon.GNSS.Constellation.glonass_fdma_channel(2)
      -4
      iex> Sidereon.GNSS.Constellation.glonass_fdma_channel(0)
      nil
  """
  @spec glonass_fdma_channel(integer()) :: integer() | nil
  def glonass_fdma_channel(slot) when is_integer(slot), do: NIF.constellation_glonass_fdma_channel(slot)

  @doc """
  Resolve a Galileo `GSATdddd` build id to its SVID/PRN (E-number), or `nil` when
  no SVID is assigned yet.

      iex> Sidereon.GNSS.Constellation.galileo_prn_for_gsat(210)
      1
  """
  @spec galileo_prn_for_gsat(integer()) :: integer() | nil
  def galileo_prn_for_gsat(gsat) when is_integer(gsat), do: NIF.constellation_galileo_prn_for_gsat(gsat)

  @doc """
  Resolve a GLONASS (Uragan) number to its orbital slot (`1..24`), or `nil` when
  the number is not in the published constellation table.

      iex> Sidereon.GNSS.Constellation.glonass_slot_for_number(730)
      1
  """
  @spec glonass_slot_for_number(integer()) :: integer() | nil
  def glonass_slot_for_number(number) when is_integer(number), do: NIF.constellation_glonass_slot_for_number(number)

  # --- system identity helpers ---------------------------------------------

  defp system_letter(system) do
    case Map.fetch(@system_letters, system) do
      {:ok, letter} -> {:ok, letter}
      :error -> {:error, {:unsupported_system, system}}
    end
  end

  defp letter_to_system(letter), do: Map.fetch!(@letter_systems, letter)

  # --- OMM extraction (user maps -> NIF OMM-lite maps) ---------------------

  defp omm_lites(omms) do
    omms
    |> Enum.reduce_while({:ok, []}, fn omm, {:ok, acc} ->
      case omm_lite(omm) do
        {:ok, lite} -> {:cont, {:ok, [lite | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, lites} -> {:ok, Enum.reverse(lites)}
      {:error, _} = err -> err
    end
  end

  defp omm_lite(%{} = omm) do
    case fetch_norad(omm) do
      {:ok, norad} ->
        {:ok,
         %{
           object_name: optional_string(omm["OBJECT_NAME"]),
           norad_id: norad,
           object_id: optional_string(omm["OBJECT_ID"]),
           epoch: optional_string(omm["EPOCH"])
         }}

      {:error, reason} ->
        {:error, {:bad_celestrak_record, reason, omm}}
    end
  end

  defp omm_lite(other), do: {:error, {:bad_celestrak_record, :not_a_map, %{value: other}}}

  defp fetch_norad(omm) do
    case Map.fetch(omm, "NORAD_CAT_ID") do
      {:ok, value} -> parse_positive_int(value)
      :error -> {:error, {:missing_field, "NORAD_CAT_ID"}}
    end
  end

  defp parse_positive_int(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_positive_int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, {:bad_integer, "NORAD_CAT_ID", value}}
    end
  end

  defp parse_positive_int(value), do: {:error, {:bad_integer, "NORAD_CAT_ID", value}}

  defp optional_string(value) when is_binary(value), do: value
  defp optional_string(_), do: nil

  # Recover the offending OMM map by object name for the error payload, so a
  # missing-PRN failure carries the same `{tag, reason, omm}` shape as the other
  # bad-record failures.
  defp find_omm(omms, name) do
    Enum.find(omms, %{}, fn
      %{"OBJECT_NAME" => object_name} -> object_name == name
      _ -> false
    end)
  end

  # --- NIF record/struct marshaling ----------------------------------------

  defp to_nif_record(%Record{} = record) do
    %{
      system: Map.fetch!(@system_letters, record.system),
      prn: record.prn,
      svn: record.svn,
      norad_id: record.norad_id,
      sp3_id: record.sp3_id,
      fdma_channel: record.fdma_channel,
      active: record.active?,
      usable: record.usable?,
      source: record.source || %{}
    }
  end

  defp from_nif_record(%{} = map) do
    %Record{
      system: letter_to_system(map.system),
      prn: map.prn,
      svn: map.svn,
      norad_id: map.norad_id,
      sp3_id: map.sp3_id,
      fdma_channel: map.fdma_channel,
      active?: map.active,
      usable?: map.usable,
      source: map.source
    }
  end

  defp from_nif_skipped(%{} = map) do
    %SkippedOmm{object_name: map.object_name, norad_id: map.norad_id}
  end

  defp to_nif_status(%NavcenStatus{} = status) do
    %{
      system: Map.fetch!(@system_letters, status.system),
      prn: status.prn,
      svn: status.svn,
      usable: status.usable?,
      active_nanu: status.active_nanu?,
      nanu_type: status.nanu_type,
      nanu_subject: status.nanu_subject,
      plane: status.plane,
      slot: status.slot,
      block_type: status.block_type,
      clock: status.clock
    }
  end

  defp from_nif_status(%{} = map) do
    %NavcenStatus{
      system: letter_to_system(map.system),
      prn: map.prn,
      svn: map.svn,
      usable?: map.usable,
      active_nanu?: map.active_nanu,
      nanu_type: map.nanu_type,
      nanu_subject: map.nanu_subject,
      plane: map.plane,
      slot: map.slot,
      block_type: map.block_type,
      clock: map.clock
    }
  end

  defp from_nif_validation(%{} = map) do
    %Validation{
      missing_sp3_ids: map.missing_sp3_ids,
      duplicate_prns: Enum.map(map.duplicate_prns, &prn_key/1),
      duplicate_norad_ids: map.duplicate_norad_ids,
      inactive_unusable_prns: Enum.map(map.inactive_unusable_prns, &prn_key/1),
      extra_sp3_ids: map.extra_sp3_ids
    }
  end

  defp prn_key({letter, prn}), do: {letter_to_system(letter), prn}

  defp from_nif_diff(%{} = map) do
    %Diff{
      added: Enum.map(map.added, &from_nif_record/1),
      removed: Enum.map(map.removed, &from_nif_record/1),
      norad_reassigned: Enum.map(map.norad_reassigned, &from_nif_change/1),
      sp3_id_changed: Enum.map(map.sp3_id_changed, &from_nif_change/1),
      svn_changed: Enum.map(map.svn_changed, &from_nif_change/1),
      fdma_channel_changed: Enum.map(map.fdma_channel_changed, &from_nif_change/1),
      activity_changed: Enum.map(map.activity_changed, &from_nif_change/1),
      usability_changed: Enum.map(map.usability_changed, &from_nif_change/1)
    }
  end

  defp from_nif_change(%{system: letter, prn: prn, from: from, to: to}) do
    %{system: letter_to_system(letter), prn: prn, from: from, to: to}
  end
end
