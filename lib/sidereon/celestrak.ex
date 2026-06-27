defmodule Sidereon.CelesTrak do
  @moduledoc """
  Fetch TLEs and orbital data from CelesTrak.

  CelesTrak provides free access to satellite orbital data without authentication.
  Data is sourced from the 18th Space Defense Squadron (formerly USSPACECOM).

  ## Examples

      # Fetch ISS TLE by NORAD catalog number
      {:ok, [tle]} = Sidereon.CelesTrak.fetch_tle(25544)

      # Fetch an entire constellation group
      {:ok, tles} = Sidereon.CelesTrak.fetch_group("stations")

      # List available groups
      groups = Sidereon.CelesTrak.groups()

  ## Rate Limiting

  CelesTrak asks users to limit requests. This module does not enforce rate
  limiting; callers should cache results and avoid polling more than once
  per hour for the same data.

  Live fetches use `Req`. Tests and applications that need to disable live HTTP
  calls can set `config :sidereon, celestrak_req_available: false`; fetch functions
  then return `{:error, :req_not_available}` without touching the network.
  """

  @base_url "https://celestrak.org/NORAD/elements/gp.php"

  @doc """
  Fetch TLE for a single satellite by NORAD catalog number.

  Returns `{:ok, [%Sidereon.Elements{}]}` or `{:error, reason}`.

  ## Examples

      {:ok, [tle]} = Sidereon.CelesTrak.fetch_tle(25544)
      tle.catalog_number
      #=> "25544"
  """
  @spec fetch_tle(integer() | String.t()) :: {:ok, [Sidereon.Elements.t()]} | {:error, term()}
  def fetch_tle(norad_id) do
    fetch_params(CATNR: to_string(norad_id), FORMAT: "tle")
  end

  @doc """
  Fetch TLEs for a constellation group.

  Common groups: `"stations"`, `"starlink"`, `"oneweb"`, `"globalstar"`,
  `"iridium-NEXT"`, `"planet"`, `"spire"`, `"active"`, `"analyst"`,
  `"geo"`, `"weather"`, `"noaa"`, `"goes"`, `"resource"`, `"sarsat"`,
  `"dmc"`, `"tdrss"`, `"argos"`, `"intelsat"`, `"ses"`, `"iridium"`,
  `"orbcomm"`, `"gnss"`, `"gps-ops"`, `"galileo"`, `"beidou"`,
  `"musson"`, `"science"`, `"geodetic"`, `"engineering"`, `"education"`,
  `"military"`, `"radar"`, `"cubesat"`, `"other"`.

  ## Examples

      {:ok, tles} = Sidereon.CelesTrak.fetch_group("stations")
      length(tles)
      #=> 15
  """
  @spec fetch_group(String.t()) :: {:ok, [Sidereon.Elements.t()]} | {:error, term()}
  def fetch_group(group_name) do
    fetch_params(GROUP: group_name, FORMAT: "tle")
  end

  @doc """
  Search for satellites by name fragment.

  ## Examples

      {:ok, tles} = Sidereon.CelesTrak.search("ISS")
  """
  @spec search(String.t()) :: {:ok, [Sidereon.Elements.t()]} | {:error, term()}
  def search(name) do
    fetch_params(NAME: name, FORMAT: "tle")
  end

  @doc """
  Fetch orbital data as JSON (OMM format) for a group.

  Returns raw list of OMM maps. Useful for metadata (object name,
  launch date, etc.) not available in TLE format.

  ## Examples

      {:ok, omms} = Sidereon.CelesTrak.fetch_omm("stations")
      hd(omms)["OBJECT_NAME"]
      #=> "ISS (ZARYA)"
  """
  @spec fetch_omm(String.t()) :: {:ok, [map()]} | {:error, term()}
  def fetch_omm(group_name) do
    case req_get(GROUP: group_name, FORMAT: "json") do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        # CelesTrak sometimes returns an error string
        {:error, body}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List commonly used CelesTrak constellation group names.
  """
  @spec groups() :: [String.t()]
  def groups do
    ~w(
      stations starlink oneweb globalstar iridium-NEXT planet spire
      active geo weather noaa goes resource sarsat tdrss argos
      intelsat ses iridium orbcomm gnss gps-ops galileo beidou
      science geodetic engineering education military radar cubesat
    )
  end

  # Private

  defp fetch_params(params) do
    case req_get(params) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        parse_tle_response(body)

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp req_get(params) do
    if req_available?() do
      Req.get(@base_url, params: params)
    else
      {:error, :req_not_available}
    end
  end

  defp req_available? do
    case Application.get_env(:sidereon, :celestrak_req_available) do
      nil -> Code.ensure_loaded?(Req) and function_exported?(Req, :get, 2)
      override -> override
    end
  end

  defp parse_tle_response(body) do
    lines =
      body
      |> String.trim()
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    # TLE format: pairs of lines starting with "1 " and "2 "
    # May have 3-line format with name line before each pair
    tles = parse_tle_lines(lines, [])

    if tles == [] do
      {:error, "no TLEs found in response"}
    else
      {:ok, Enum.reverse(tles)}
    end
  end

  defp parse_tle_lines([], acc), do: acc

  defp parse_tle_lines(["1 " <> _ = line1, "2 " <> _ = line2 | rest], acc) do
    case Sidereon.Format.TLE.parse(line1, line2) do
      {:ok, tle} -> parse_tle_lines(rest, [tle | acc])
      {:error, _} -> parse_tle_lines(rest, acc)
    end
  end

  # Skip name lines in 3-line format
  defp parse_tle_lines([_name | rest], acc) do
    parse_tle_lines(rest, acc)
  end
end
