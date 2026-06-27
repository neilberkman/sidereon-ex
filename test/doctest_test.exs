defmodule Sidereon.DoctestTest do
  use ExUnit.Case

  doctest Sidereon
  doctest Sidereon.RF
  doctest Sidereon.GNSS.Constellation
  doctest Sidereon.Format.TLE
  doctest Sidereon.Format.OMM
  doctest Sidereon.GNSS.Signal.CA
  doctest Sidereon.GNSS.Navigation.LNAV
end
