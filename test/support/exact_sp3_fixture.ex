defmodule Sidereon.TestSupport.ExactSp3Fixture do
  @moduledoc false

  @seconds_per_day 86_400
  @gps_epoch ~D[1980-01-06]
  @mjd_epoch ~D[1858-11-17]

  def build(date, opts \\ []) do
    sample_s = Keyword.get(opts, :sample_s, 300)
    span_s = Keyword.get(opts, :span_s, @seconds_per_day)
    coverage = Keyword.get(opts, :coverage, :half_open)

    count =
      Keyword.get_lazy(opts, :count, fn ->
        div(span_s, sample_s) + if(coverage == :inclusive, do: 1, else: 0)
      end)

    offsets_s = Keyword.get_lazy(opts, :offsets_s, fn -> regular_offsets(count, sample_s) end)
    declared_count = Keyword.get(opts, :declared_count, count)
    header_cadence = Keyword.get(opts, :header_cadence, fixed(sample_s, 8))
    agency = Keyword.get(opts, :agency, "TST")
    issue = Keyword.get(opts, :issue, "0000")
    x_km = Keyword.get(opts, :x_km, 15_000.0)
    {hour, minute} = parse_issue!(issue)
    start = NaiveDateTime.new!(date, Time.new!(hour, minute, 0))

    gps_days = Date.diff(date, @gps_epoch)
    gps_week = div(gps_days, 7)
    seconds_of_week = rem(gps_days, 7) * @seconds_per_day + hour * 3_600 + minute * 60
    mjd = Date.diff(date, @mjd_epoch) + (hour * 3_600 + minute * 60) / @seconds_per_day

    header = [
      "#dP#{datetime_fields(start)} #{pad(declared_count, 7)} " <>
        "#{String.pad_trailing("ORBIT", 5)}#{String.pad_leading("IGS20", 6)}" <>
        "#{String.pad_leading("FIT", 4)} #{agency}",
      "## #{pad(gps_week, 4)} #{fixed(seconds_of_week, 8) |> String.pad_leading(15)} " <>
        "#{to_string(header_cadence) |> String.pad_leading(14)} #{pad(trunc(mjd), 5)} " <>
        "#{fixed(mjd - trunc(mjd), 13)}",
      "+    1   G01" <> String.duplicate("  0", 16)
    ]

    header =
      header ++
        List.duplicate("+        " <> String.duplicate("  0", 17), 4) ++
        List.duplicate("++       " <> String.duplicate("  0", 17), 5) ++
        [
          "%c M  cc GPS ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
          "%c cc cc ccc ccc cccc cccc cccc cccc ccccc ccccc ccccc ccccc",
          "%f  1.2500000  1.025000000  0.00000000000  0.000000000000000",
          "%f  0.0000000  0.000000000  0.00000000000  0.000000000000000",
          "%i    0    0    0    0      0      0      0      0         0",
          "%i    0    0    0    0      0      0      0      0         0"
        ] ++
        List.duplicate("/* EXACT VALIDATION TEST FIXTURE", 4)

    record =
      "PG01" <>
        (:io_lib.format(~c"~14.6f", [x_km]) |> IO.iodata_to_binary()) <>
        " -20000.000000   5000.000000    123.456789"

    body =
      Enum.flat_map(offsets_s, fn offset_s ->
        epoch = NaiveDateTime.add(start, offset_s, :second)
        ["*  #{datetime_fields(epoch)}", record]
      end)

    Enum.join(header ++ body ++ ["EOF", ""], "\n")
  end

  def regular_offsets(count, cadence_s) when count > 0 do
    for index <- 0..(count - 1), do: index * cadence_s
  end

  def regular_offsets(0, _cadence_s), do: []

  defp datetime_fields(datetime) do
    Enum.join(
      [
        pad(datetime.year, 4),
        pad(datetime.month, 2),
        pad(datetime.day, 2),
        pad(datetime.hour, 2),
        pad(datetime.minute, 2),
        fixed(datetime.second + elem(datetime.microsecond, 0) / 1_000_000, 8)
        |> String.pad_leading(11)
      ],
      " "
    )
  end

  defp parse_issue!(<<hour::binary-size(2), minute::binary-size(2)>>),
    do: {String.to_integer(hour), String.to_integer(minute)}

  defp pad(value, width), do: value |> to_string() |> String.pad_leading(width)
  defp fixed(value, decimals), do: :erlang.float_to_binary(value / 1.0, decimals: decimals)
end
