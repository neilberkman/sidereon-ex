defmodule Sidereon.DoctestTest do
  use ExUnit.Case

  alias Sidereon.Format.OMM
  alias Sidereon.Format.TLE
  alias Sidereon.GNSS.Constellation
  alias Sidereon.GNSS.Navigation.LNAV
  alias Sidereon.GNSS.Signal.CA

  doctest Sidereon
  doctest Sidereon.RF
  doctest Constellation
  doctest TLE
  doctest OMM
  doctest CA
  doctest LNAV
end
