defmodule Sidereon.GNSS.Ionosphere.Boundary do
  @moduledoc false

  # The one place a call into the IONEX or TEC-grid boundary is made.
  #
  # Two of the boundary's failures arrive as exceptions rather than as return
  # values, and they are not the same exception:
  #
  #   * a decoder that names the field it could not read raises `ErlangError`
  #     carrying that name (rustler's `Error::RaiseTerm`; `Error::Term` instead
  #     returns `{:error, term}`), and
  #   * an argument the boundary could not decode at all becomes rustler's
  #     `Error::BadArg`, which is `enif_make_badarg` and so the atom `:badarg`,
  #     which Elixir normalizes to `ArgumentError` - a different struct, with no
  #     `:original` field.
  #
  # `rescue e in ErlangError` matches every error raised from Erlang that is not
  # already an Elixir exception, `:badarg` included, and binds it normalized. So
  # a `:badarg` reaching that clause binds an `ArgumentError`, and reading
  # `e.original` from it raises `KeyError`. The `ArgumentError` clause is
  # therefore first. What the boundary raises otherwise - a decoder's
  # `Error::RaiseTerm` or `Error::RaiseAtom`, or rustler's `:nif_panicked` - is
  # none of the terms Elixir maps to a struct of its own, so it reaches the
  # `ErlangError` clause as an `ErlangError`.
  #
  # A reference to another resource kind is the second case: `ResourceArc`
  # decoding gives `BadArg`, so passing a TEC-grid handle to an IONEX getter
  # raised `ArgumentError` out of a function whose contract is
  # `{:ok, _} | {:error, _}`. Every other argument of these calls is checked in
  # Elixir before the call, each field under its own name, so the reference is
  # what `:badarg` leaves to report, and the resource the call expected is named
  # in its place.
  #
  # Only the call itself is wrapped. Reading the returned term into a struct is
  # this binding's own code, as is the merge of batch rows: an exception from
  # either is a defect here, not a refusal of the caller's input, and is left to
  # raise as itself.

  @doc false
  # For a NIF that returns its own `{:ok, _}` / `{:error, _}`: the result is
  # passed through untouched, including the whole payload of an `ErlangError`.
  @spec result(atom(), (-> term())) :: term()
  def result(resource, fun) when is_atom(resource) and is_function(fun, 0) do
    fun.()
  rescue
    ArgumentError -> {:error, {:invalid_resource, resource}}
    e in ErlangError -> {:error, e.original}
  end

  @doc false
  # For a NIF that returns a bare value, which becomes `{:ok, value}`.
  @spec call(atom(), (-> term())) :: {:ok, term()} | {:error, term()}
  def call(resource, fun) when is_atom(resource) and is_function(fun, 0) do
    result(resource, fn -> {:ok, fun.()} end)
  end
end
