defmodule Sidereon.CCSDS.TDM.Policy do
  @moduledoc """
  The departures from CCSDS 503.0-B-2 the TDM reader forgives.

  Each axis is `:strict`, which refuses the message naming the departure, or
  `:forgive`, which reads the message and reports the departure as a
  `Sidereon.CCSDS.TDM.Warning`:

    * `:non_printable` - characters outside the printable ASCII 4.2.1 allows.
    * `:missing_keywords` - keywords tables 3-2 and 3-3 mark mandatory.
    * `:long_lines` - lines longer than the 254 characters 4.2.1 allows.
    * `:empty_data_sections` - data sections holding no record (3.1.3).
    * `:record_order` - a keyword's records out of chronological order
      (3.4.10).
    * `:duplicate_records` - a keyword and timetag pair repeating (3.4.11).
    * `:keyword_order` - keywords out of the order tables 3-2 and 3-3 fix, and
      comments away from the start of their section (4.5.2).
    * `:final_terminator` - a last line with no terminator (4.2.11).

  The default forgives nothing, which is what `Sidereon.CCSDS.TDM.parse_kvn/1`
  applies. Nothing that changes what a value means is forgivable: a value that
  does not parse, a unit that contradicts table 3-5, an undefined keyword,
  conflicting values for one keyword, or a structural error is refused under
  every policy. A message read under a lenient policy is written back unchanged
  or refused by name; the writer does not repair it.

  ## What is refused

    * `{:invalid_policy_value, axis, value}` - a choice that is neither
      `:strict` nor `:forgive`.
    * `{:unknown_policy_key, key}` - a key that is not an axis, returned as
      given.
    * `{:duplicate_policy_key, key}` - a keyword list stating one key twice.
    * `:bad_tdm_policy` - options that are neither a keyword list, a map nor
      this struct.
  """

  alias Sidereon.CCSDS.TDM.PolicyOptions

  @keys [
    :non_printable,
    :missing_keywords,
    :long_lines,
    :empty_data_sections,
    :record_order,
    :duplicate_records,
    :keyword_order,
    :final_terminator
  ]

  defstruct Enum.map(@keys, &{&1, :strict})

  @type choice :: :strict | :forgive

  @type t :: %__MODULE__{
          non_printable: choice(),
          missing_keywords: choice(),
          long_lines: choice(),
          empty_data_sections: choice(),
          record_order: choice(),
          duplicate_records: choice(),
          keyword_order: choice(),
          final_terminator: choice()
        }

  @doc "The policy that forgives nothing."
  @spec strict() :: t()
  def strict, do: %__MODULE__{}

  @doc "The policy that forgives every forgivable departure."
  @spec lenient() :: t()
  def lenient, do: struct(__MODULE__, Enum.map(@keys, &{&1, :forgive}))

  @doc """
  Builds a policy from a keyword list or map of axes, or checks a policy
  struct. Returns `{:ok, policy}` or one of the refusals the moduledoc lists.
  """
  @spec new(t() | keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(opts \\ []), do: PolicyOptions.build(__MODULE__, @keys, opts)

  @doc false
  @spec to_nif_map(t() | keyword() | map()) :: {:ok, map()} | {:error, term()}
  def to_nif_map(opts) do
    case new(opts) do
      {:ok, policy} -> {:ok, PolicyOptions.to_nif_map(policy)}
      {:error, _reason} = error -> error
    end
  end
end
