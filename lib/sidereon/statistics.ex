defmodule Sidereon.Statistics do
  @moduledoc """
  Residual-distribution diagnostics: sample moments and normality tests.

  Post-fit residuals from a converged least-squares solve should look like
  zero-mean Gaussian noise. These primitives quantify departures from that ideal
  on an arbitrary residual set: sample skewness and kurtosis, the combined
  moments, the Jarque-Bera moment test, and the Shapiro-Wilk W test.

  The moment definitions match `scipy.stats` (the central moments are the
  population/biased moments), so a caller can cross-check against the reference
  implementation. The numerical modeling lives in the `sidereon-core` Rust core;
  this module marshals the residual list and convention flags and decodes the
  results.

  Each function returns `{:ok, value}` or `{:error, reason}`, where `reason` is a
  typed atom: `:non_finite`, `:insufficient_data`, `:zero_variance`, or
  `:zero_range`.
  """

  alias Sidereon.NIF

  @typedoc """
  Sample moments: `mean`, the biased `variance`, `skewness`, and the excess
  `kurtosis` (Gaussian -> 0 when `fisher: true`).
  """
  @type moments :: %{
          mean: float(),
          variance: float(),
          skewness: float(),
          kurtosis: float()
        }

  @doc """
  Sample skewness.

  `bias: true` (default) is the Fisher-Pearson coefficient `g1 = m3 / m2^(3/2)`
  (`scipy.stats.skew`); `bias: false` applies the sample correction
  (`scipy.stats.skew(bias=False)`), which needs at least three residuals.
  """
  @spec skewness([number()], keyword()) :: {:ok, float()} | {:error, atom()}
  def skewness(x, opts \\ []) when is_list(x) do
    NIF.normality_skewness(to_floats(x), Keyword.get(opts, :bias, true))
  end

  @doc """
  Sample kurtosis.

  `fisher: true` (default) returns the excess kurtosis `m4 / m2^2 - 3`
  (Gaussian -> 0); `fisher: false` returns the Pearson kurtosis (Gaussian -> 3).
  `bias: false` applies the sample correction, which needs at least four
  residuals.
  """
  @spec kurtosis([number()], keyword()) :: {:ok, float()} | {:error, atom()}
  def kurtosis(x, opts \\ []) when is_list(x) do
    NIF.normality_kurtosis(to_floats(x), Keyword.get(opts, :fisher, true), Keyword.get(opts, :bias, true))
  end

  @doc """
  Mean, biased variance, skewness, and excess kurtosis in one pass.

  `:fisher` and `:bias` select the kurtosis convention and the bias correction,
  exactly as in `skewness/2` and `kurtosis/2`.
  """
  @spec moments([number()], keyword()) :: {:ok, moments()} | {:error, atom()}
  def moments(x, opts \\ []) when is_list(x) do
    case NIF.normality_moments(to_floats(x), Keyword.get(opts, :fisher, true), Keyword.get(opts, :bias, true)) do
      {:ok, {mean, variance, skewness, kurtosis}} ->
        {:ok, %{mean: mean, variance: variance, skewness: skewness, kurtosis: kurtosis}}

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Jarque-Bera normality test (`scipy.stats.jarque_bera`).

  Returns `{:ok, %{statistic: jb, p_value: p}}` with the chi-square(2) upper-tail
  p-value `exp(-jb/2)`. Needs at least two residuals.
  """
  @spec jarque_bera([number()]) :: {:ok, %{statistic: float(), p_value: float()}} | {:error, atom()}
  def jarque_bera(x) when is_list(x) do
    case NIF.normality_jarque_bera(to_floats(x)) do
      {:ok, {statistic, p_value}} -> {:ok, %{statistic: statistic, p_value: p_value}}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Shapiro-Wilk W test for normality (Royston AS R94, the `scipy.stats.shapiro`
  algorithm).

  Returns `{:ok, %{w: w, p_value: p}}` with `w` in `(0, 1]` (closer to one is
  more Gaussian). Needs at least three residuals; returns `{:error, :zero_range}`
  when every residual is equal.
  """
  @spec shapiro_wilk([number()]) :: {:ok, %{w: float(), p_value: float()}} | {:error, atom()}
  def shapiro_wilk(x) when is_list(x) do
    case NIF.normality_shapiro_wilk(to_floats(x)) do
      {:ok, {w, p_value}} -> {:ok, %{w: w, p_value: p_value}}
      {:error, _reason} = err -> err
    end
  end

  defp to_floats(values), do: Enum.map(values, &(&1 / 1.0))
end
