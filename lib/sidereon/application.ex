defmodule Sidereon.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Elixir.Finch, name: :"Elixir.Sidereon.GNSS.Data.Finch"},
      {Elixir.Finch, name: :"Elixir.Sidereon.GNSS.Ntrip.Finch", pools: %{default: [size: 1]}}
    ]

    opts = [strategy: :one_for_one, name: Sidereon.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
