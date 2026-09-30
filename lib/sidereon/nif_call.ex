defmodule Sidereon.NifCall do
  @moduledoc false

  # How a failure raised out of a native call becomes an error tuple.
  #
  # Two of a native call's failures arrive as exceptions rather than as return
  # values, and they are not the same exception:
  #
  #   * a decoder that names the field it could not read raises `ErlangError`
  #     carrying that name (rustler's `Error::RaiseTerm`; `Error::Term` instead
  #     returns `{:error, term}`), as a panic raises `ErlangError` carrying
  #     `:nif_panicked`, and
  #   * an argument the call could not decode at all - a value of another type,
  #     a map without a key the call reads, an integer outside the range the
  #     call accepts, a reference to another kind of resource, or an optional
  #     argument whose value fails to decode (rustler's `Option` decoder drops
  #     the field's name) - becomes rustler's `Error::BadArg`, which is
  #     `enif_make_badarg` and so the atom `:badarg`, which Elixir normalizes to
  #     `ArgumentError` - a different struct, with no `:original` field.
  #
  # Every caller rescues `e in ErlangError`. That clause matches every error
  # raised from Erlang that is not already an Elixir exception, `:badarg`
  # included, and binds it normalized; an `ArgumentError` this binding raises
  # itself is already an Elixir exception and does not reach it. So an
  # `ArgumentError` bound there came from the atom `:badarg`, and reading
  # `e.original` from it raised `KeyError`. `reason/3` reads `:original` only
  # from an `ErlangError`.
  #
  # The rescued body prepares the call's arguments as well as making the call.
  # `:badarg` comes from the call, or from a built-in function given an argument
  # of the wrong type while it is prepared. `:badarith`, which Elixir normalizes
  # to `ArithmeticError`, is never raised by a native call; it comes from
  # arithmetic in the rescued body, which on a caller's value is `value / 1.0`
  # on a value that is not a number. Both are named after the native call the
  # body was written for. Any other exception the clause binds, such as the
  # `FunctionClauseError` normalized from `:function_clause`, is a failure of
  # this binding's own code, not a refusal of the caller's input, and is raised
  # again as itself, with its stacktrace.

  @doc false
  # The error tuple for an exception bound by `rescue e in ErlangError` around a
  # call to `native_call`.
  @spec error(Exception.t(), Exception.stacktrace(), atom()) :: {:error, term()}
  def error(exception, stacktrace, native_call) do
    {:error, reason(exception, stacktrace, native_call)}
  end

  @doc false
  # As `error/3`, for a caller whose contract tags every reason: `{:error, {tag, reason}}`.
  @spec error(Exception.t(), Exception.stacktrace(), atom(), atom()) :: {:error, {atom(), term()}}
  def error(exception, stacktrace, native_call, tag) do
    {:error, {tag, reason(exception, stacktrace, native_call)}}
  end

  @doc false
  # The reason alone, for a caller that builds its own error shape.
  @spec reason(Exception.t(), Exception.stacktrace(), atom()) :: term()
  def reason(%ErlangError{original: original}, _stacktrace, _native_call), do: original
  def reason(%ArgumentError{}, _stacktrace, native_call), do: {:invalid_argument, native_call}
  def reason(%ArithmeticError{}, _stacktrace, native_call), do: {:arithmetic_error, native_call}
  def reason(exception, stacktrace, _native_call), do: reraise(exception, stacktrace)

  @doc false
  # The text of an exception bound by `rescue e in ErlangError`, for a function
  # whose contract is to raise `ArgumentError` with it rather than return an
  # error: the original term of an `ErlangError`, the message of anything else.
  @spec describe(Exception.t()) :: String.t()
  def describe(%ErlangError{original: original}), do: inspect(original)
  def describe(exception), do: Exception.message(exception)
end
