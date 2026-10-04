defmodule Sidereon.NifCallTest do
  use ExUnit.Case, async: true

  alias Sidereon.Astro.Anomaly
  alias Sidereon.Geoid
  alias Sidereon.GNSS.Bias
  alias Sidereon.GNSS.Ntrip
  alias Sidereon.GNSS.Ntrip.GgaPosition
  alias Sidereon.GNSS.Observables
  alias Sidereon.GNSS.SP3
  alias Sidereon.NifCall
  alias Sidereon.SpaceWeather

  @dcb Path.join([__DIR__, "fixtures", "bias", "P1C1_RINEX.DCB"])
  @rx {3_512_900.0, 780_500.0, 5_248_700.0}
  @epoch ~N[2020-06-24 12:00:00]

  # A geoid grid is a resource handle of one kind; handed to a call that decodes
  # another kind, it is the reference rustler reports as `:badarg`.
  defp geoid_handle do
    assert {:ok, grid} = Geoid.grid(0.0, 0.0, 10.0, 10.0, 2, 2, [1.0, 3.0, 5.0, 11.0])
    grid
  end

  describe "an exception bound by `rescue e in ErlangError`" do
    test "an ErlangError gives its original term, as before" do
      result =
        try do
          :erlang.error({:decoder, "Could not decode field :year on %{}"})
        rescue
          e in ErlangError -> NifCall.error(e, __STACKTRACE__, :any_call)
        end

      assert result == {:error, {:decoder, "Could not decode field :year on %{}"}}
    end

    test "the atom :badarg arrives as ArgumentError and is named after the call" do
      result =
        try do
          :erlang.error(:badarg)
        rescue
          e in ErlangError -> NifCall.error(e, __STACKTRACE__, :any_call)
        end

      assert result == {:error, {:invalid_argument, :any_call}}
    end

    test "the atom :badarith arrives as ArithmeticError and is named after the call" do
      result =
        try do
          :erlang.error(:badarith)
        rescue
          e in ErlangError -> NifCall.error(e, __STACKTRACE__, :any_call)
        end

      assert result == {:error, {:arithmetic_error, :any_call}}
    end

    test "a tagged caller tags every reason" do
      tagged = fn raised ->
        try do
          :erlang.error(raised)
        rescue
          e in ErlangError -> NifCall.error(e, __STACKTRACE__, :any_call, :nif_error)
        end
      end

      assert tagged.(:nif_panicked) == {:error, {:nif_error, :nif_panicked}}
      assert tagged.(:badarg) == {:error, {:nif_error, {:invalid_argument, :any_call}}}
    end

    test "an ArgumentError raised by Elixir code never reaches the clause" do
      assert_raise ArgumentError, "raised by Elixir code", fn ->
        try do
          raise ArgumentError, "raised by Elixir code"
        rescue
          e in ErlangError -> NifCall.error(e, __STACKTRACE__, :any_call)
        end
      end
    end

    test "any other exception the clause binds is raised again as itself, with its stacktrace" do
      try do
        try do
          :erlang.error(:function_clause)
        rescue
          e in ErlangError -> NifCall.error(e, __STACKTRACE__, :any_call)
        end

        flunk("the FunctionClauseError was not raised again")
      rescue
        FunctionClauseError ->
          assert Enum.any?(__STACKTRACE__, &match?({__MODULE__, _fun, _arity, _location}, &1))
          refute Enum.any?(__STACKTRACE__, &match?({NifCall, _fun, _arity, _location}, &1))
      end
    end

    test "describe/1 gives the original term of an ErlangError and the message of anything else" do
      assert NifCall.describe(%ErlangError{original: {:bad, 1}}) == "{:bad, 1}"
      assert NifCall.describe(%ArgumentError{message: "argument error"}) == "argument error"
    end
  end

  describe "a reference to another kind of resource" do
    test "space weather lookups return the named error instead of raising" do
      weather = %SpaceWeather{handle: geoid_handle()}

      assert {:error, {:invalid_argument, :space_weather_space_weather_at}} =
               SpaceWeather.space_weather_at(weather, 0.0)

      assert {:error, {:invalid_argument, :space_weather_sample_at}} = SpaceWeather.sample_at(weather, 0.0)
      assert {:error, {:invalid_argument, :space_weather_ap_array_at}} = SpaceWeather.ap_array_at(weather, 0.0)
    end

    test "a reference that is no resource at all is refused the same way" do
      assert {:error, {:invalid_argument, :geoid_grid_undulation_proj_rad}} =
               Geoid.grid_undulation_proj_rad(make_ref(), 0.0, 0.0, :separate_multiply_add)
    end

    test "a batch whose handle is refused returns the named error for every request" do
      sp3 = %SP3{handle: geoid_handle(), time_scale: nil, coverage_start: nil, coverage_end: nil}
      requests = [{"G01", @rx, @epoch}, {"G02", @rx, @epoch}]
      refused = {:error, {:invalid_argument, :sp3_predict_batch}}

      assert Observables.predict_batch(sp3, requests) == [refused, refused]
    end

    test "an accessor whose contract is to raise raises ArgumentError, not KeyError" do
      sp3 = %SP3{handle: geoid_handle(), time_scale: nil, coverage_start: nil, coverage_end: nil}

      assert_raise ArgumentError, ~r/^could not read SP3 satellite ids: /, fn -> SP3.satellite_ids(sp3) end
      assert_raise ArgumentError, ~r/^could not read SP3 epoch count: /, fn -> SP3.epoch_count(sp3) end
    end
  end

  describe "an argument of another type that reaches the native call" do
    test "a satellite id that is not a string is named after the call" do
      assert {:ok, dcb} = Bias.load_code_dcb(@dcb, pair: {"P1", "C1"}, year: 2026, month: 6)

      assert {:error, {:invalid_argument, :bias_code_dsb}} = Bias.code_dsb(dcb, 42, "P1", "C1", ~N[2026-06-15 00:00:00])
    end

    test "bytes that are not a binary are named after the loader's call" do
      assert {:error, {:invalid_argument, :bias_parse_code_dcb}} = Bias.parse_code_dcb(123)
    end

    test "an integer outside the range the call decodes is named after the call" do
      assert {:error, {:invalid_argument, :geoid_grid_new}} =
               Geoid.grid(0.0, 0.0, 10.0, 10.0, -1, 2, [1.0, 3.0, 5.0, 11.0])
    end

    test "a map field the decoder names keeps the decoder's own reason" do
      # A field of the wrong type inside a map the call decodes directly is
      # reported by the decoder under the field's name, as an `ErlangError`.
      assert {:error, reason} = Ntrip.format_gga(%GgaPosition{lat_deg: "north"}, 12_345.67)
      assert is_binary(reason)
      assert reason =~ "lat_deg"
    end
  end

  describe "a value that must be a number and is not one" do
    test "is returned as an arithmetic error named after the call" do
      assert {:error, {:arithmetic_error, :anomaly_mean_to_eccentric}} = Anomaly.mean_to_eccentric("1.0", 0.1)
      assert {:error, {:arithmetic_error, :anomaly_solve_kepler}} = Anomaly.solve_kepler(1.0, "0.1")

      assert {:error, {:arithmetic_error, :geoid_grid_new}} =
               Geoid.grid(0.0, 0.0, 10.0, 10.0, 2, 2, [1.0, :three, 5.0, 11.0])
    end
  end
end
