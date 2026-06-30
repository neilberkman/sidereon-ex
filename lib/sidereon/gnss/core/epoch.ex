defmodule Sidereon.GNSS.Core.Epoch do
  @moduledoc false

  @type epoch ::
          NaiveDateTime.t()
          | {{integer(), integer(), integer()}, {integer(), integer(), number()}}
          | {{integer(), integer(), integer()}, {integer(), integer(), integer(), integer()}}

  def to_naive(%NaiveDateTime{} = ndt), do: {:ok, ndt}

  def to_naive({{y, mo, d}, {h, mi, s, us}}) when is_integer(us) do
    NaiveDateTime.new(y, mo, d, h, mi, s, {us, 6})
  end

  def to_naive({{y, mo, d}, {h, mi, s}}) when is_integer(s) do
    NaiveDateTime.new(y, mo, d, h, mi, s, {0, 6})
  end

  def to_naive({{y, mo, d}, {h, mi, s}}) when is_float(s) do
    sec = trunc(s)
    micro = round((s - sec) * 1_000_000)
    NaiveDateTime.new(y, mo, d, h, mi, sec, {micro, 6})
  end

  def to_naive(_), do: {:error, :invalid_epoch}

  def to_naive!(epoch) do
    case to_naive(epoch) do
      {:ok, ndt} -> ndt
      {:error, reason} -> raise ArgumentError, "invalid GNSS epoch: #{inspect(reason)}"
    end
  end

  def datetime_tuple(epoch) do
    ndt = to_naive!(epoch)
    {{ndt.year, ndt.month, ndt.day}, {ndt.hour, ndt.minute, ndt.second, elem(ndt.microsecond, 0)}}
  end

  def maybe_datetime_tuple(nil), do: nil
  def maybe_datetime_tuple(epoch), do: datetime_tuple(epoch)

  def fetch_window(opts, default \\ :none) do
    value =
      case default do
        :none -> Keyword.get(opts, :window)
        _ -> Keyword.get(opts, :window, default)
      end

    window(value)
  end

  def window({t0, t1}) do
    with {:ok, t0n} <- to_naive(t0),
         {:ok, t1n} <- to_naive(t1) do
      if NaiveDateTime.after?(t1n, t0n),
        do: {:ok, {t0n, t1n}},
        else: {:error, :invalid_window}
    else
      _ -> {:error, :invalid_window}
    end
  end

  def window(_), do: {:error, :invalid_window}

  def steps(t0, t1, cadence_s) do
    t0n = to_naive!(t0)
    t1n = to_naive!(t1)
    span = NaiveDateTime.diff(t1n, t0n)
    count = trunc(span / cadence_s)
    for k <- 0..count, do: NaiveDateTime.add(t0n, round(k * cadence_s), :second)
  end

  def window_of_samples([]), do: nil

  def window_of_samples(samples) do
    epochs = Enum.map(samples, fn {ep, _} -> to_naive!(ep) end)
    {Enum.min_by(epochs, &NaiveDateTime.to_erl/1), Enum.max_by(epochs, &NaiveDateTime.to_erl/1)}
  end
end
