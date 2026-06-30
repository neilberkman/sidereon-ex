defmodule Sidereon.GNSS.Core.Native do
  @moduledoc false

  def safe_nif(fun) do
    fun.()
  rescue
    e in ErlangError -> {:nif_raised, e.original}
  end
end
