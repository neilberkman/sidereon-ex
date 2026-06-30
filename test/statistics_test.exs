defmodule Sidereon.StatisticsTest do
  use ExUnit.Case, async: true

  alias Sidereon.Statistics

  # Fixed residual vectors with golden scipy 1.18.0 values (same fixtures the
  # core's normality tests use). The moment statistics are deterministic
  # left-to-right folds that agree with scipy to ~1e-11 on every platform; only
  # the Shapiro-Wilk W carries platform ULPs, so its tight check is pinned to
  # Linux x86_64 and it is structural elsewhere.
  @v1 [0.12, -0.34, 0.05, 0.88, -1.21, 0.42, -0.07, 0.63, -0.55, 0.19, 0.27, -0.91, 1.04, -0.16, 0.33]
  @v2 [1.0, -2.0, 0.5, 3.2, -1.1, 0.0, 2.3, -0.7, 4.5, -3.1, 0.9, -1.8]

  @linux_x86 :os.type() == {:unix, :linux} and
               :erlang.system_info(:system_architecture)
               |> List.to_string()
               |> String.contains?("x86_64")

  @tol 1.0e-9

  describe "skewness (vs scipy.stats.skew)" do
    test "biased and bias-corrected" do
      assert {:ok, g1} = Statistics.skewness(@v1)
      assert_in_delta g1, -3.990_837_649_877_545e-1, @tol
      assert {:ok, big1} = Statistics.skewness(@v1, bias: false)
      assert_in_delta big1, -4.448_671_685_942_52e-1, @tol
      assert {:ok, g2} = Statistics.skewness(@v2)
      assert_in_delta g2, 3.471_961_494_435_007e-1, @tol
    end

    test "zero variance is a typed error" do
      assert {:error, :zero_variance} = Statistics.skewness([1.0, 1.0, 1.0, 1.0])
    end
  end

  describe "kurtosis (vs scipy.stats.kurtosis)" do
    test "fisher/pearson and bias variants" do
      assert {:ok, k} = Statistics.kurtosis(@v1)
      assert_in_delta k, -3.608_466_739_341_209_5e-1, @tol
      assert {:ok, kp} = Statistics.kurtosis(@v1, fisher: false)
      assert_in_delta kp, 2.639_153_326_065_879, @tol
      assert {:ok, ku} = Statistics.kurtosis(@v1, bias: false)
      assert_in_delta ku, 2.032_272_460_741_557_7e-2, @tol
    end
  end

  describe "moments bundle" do
    test "matches the component statistics and scipy moments" do
      assert {:ok, m} = Statistics.moments(@v1)
      assert_in_delta m.mean, 4.6e-2, @tol
      assert_in_delta m.variance, 3.582_106_666_666_667_3e-1, @tol
      assert {:ok, g1} = Statistics.skewness(@v1)
      assert {:ok, k} = Statistics.kurtosis(@v1)
      assert_in_delta m.skewness, g1, 0.0
      assert_in_delta m.kurtosis, k, 0.0
    end
  end

  describe "Jarque-Bera (vs scipy.stats.jarque_bera)" do
    test "statistic and p-value" do
      assert {:ok, jb1} = Statistics.jarque_bera(@v1)
      assert_in_delta jb1.statistic, 4.795_510_799_978_267_6e-1, @tol
      assert_in_delta jb1.p_value, 7.868_044_473_746_433e-1, @tol
      assert {:ok, jb2} = Statistics.jarque_bera(@v2)
      assert_in_delta jb2.statistic, 4.923_694_883_298_767_6e-1, @tol
    end
  end

  describe "Shapiro-Wilk" do
    test "structural: W in (0, 1], p in [0, 1] (every platform)" do
      assert {:ok, sw} = Statistics.shapiro_wilk(@v1)
      assert sw.w > 0.0 and sw.w <= 1.0 + 1.0e-12
      assert sw.p_value >= 0.0 and sw.p_value <= 1.0
    end

    test "rejects a zero-range residual set" do
      assert {:error, :zero_range} = Statistics.shapiro_wilk([2.0, 2.0, 2.0])
    end

    @tag skip:
           if(@linux_x86,
             do: false,
             else: "Shapiro-Wilk W bit-exact tolerance is pinned to Linux x86_64"
           )
    test "W matches scipy.stats.shapiro to ~1e-10 (Linux x86_64)" do
      assert {:ok, sw1} = Statistics.shapiro_wilk(@v1)
      assert_in_delta sw1.w, 9.760_100_117_114_072e-1, 1.0e-10
      assert {:ok, sw2} = Statistics.shapiro_wilk(@v2)
      assert_in_delta sw2.w, 9.773_113_095_849_641e-1, 1.0e-10
    end
  end
end
