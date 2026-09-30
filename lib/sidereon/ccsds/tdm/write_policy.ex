defmodule Sidereon.CCSDS.TDM.WritePolicy do
  @moduledoc """
  The departures from CCSDS 503.0-B-2 the TDM writer may emit.

  Each axis is `:strict`, which refuses a value the writer cannot write
  conformingly, or `:forgive`, which writes it and reports the departure as a
  `Sidereon.CCSDS.TDM.Departure`. The axes mirror those of
  `Sidereon.CCSDS.TDM.Policy`, so a message read leniently can be written back
  by asking for the same departures, and add one:

    * `:repeated_keywords` - a keyword written twice in one block with the same
      value, which 4.2.5 a) gives one value assignment.

  The default emits none, which is what `Sidereon.CCSDS.TDM.encode_kvn/1`
  applies. Nothing outside the mirror is emittable under any policy: a field
  keyed `COMMENT`, a key holding `=` or whitespace, a comment holding a line
  break, a value that does not parse as its keyword's type, or a comment
  position or order the writer cannot emit unchanged each produce a file that
  reads back as something else.

  The refusals for options that do not read are those
  `Sidereon.CCSDS.TDM.Policy` lists.
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
    :final_terminator,
    :repeated_keywords
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
          final_terminator: choice(),
          repeated_keywords: choice()
        }

  @doc "The policy that emits no departure."
  @spec strict() :: t()
  def strict, do: %__MODULE__{}

  @doc "The policy that emits every departure the mirror allows."
  @spec lenient() :: t()
  def lenient, do: struct(__MODULE__, Enum.map(@keys, &{&1, :forgive}))

  @doc """
  Builds a policy from a keyword list or map of axes, or checks a policy
  struct. Returns `{:ok, policy}` or one of the refusals
  `Sidereon.CCSDS.TDM.Policy` lists.
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
