defmodule Sidereon.GeofenceTest do
  use ExUnit.Case, async: true

  alias Sidereon.Geofence

  @vertices [
    {37.0, -122.0},
    {37.0, -121.99},
    {37.01, -121.99},
    {37.01, -122.0}
  ]
  @inside {37.005, -121.995}
  @outside {37.02, -121.995}
  @near_south_boundary {37.00002, -121.995}
  @uncertainty {:enu_covariance_m2,
                [
                  [25.0, 0.0, 0.0],
                  [0.0, 25.0, 0.0],
                  [0.0, 0.0, 1.0]
                ]}

  setup do
    {:ok, fence} = Geofence.new(@vertices)
    {:ok, fence: fence}
  end

  test "constructs a fence and returns typed construction errors", %{fence: fence} do
    assert fence.vertices == [
             {37.0, -122.0, 0.0},
             {37.0, -121.99, 0.0},
             {37.01, -121.99, 0.0},
             {37.01, -122.0, 0.0}
           ]

    assert {:error, :too_few_vertices} = Geofence.new([{0.0, 0.0}, {0.0, 1.0}])
  end

  test "pins core containment and signed boundary distance", %{fence: fence} do
    # Reference literals generated from sidereon-core through this binding
    # against the patched core on 2026-07-05.
    assert {:ok, true} = Geofence.containment(fence, @inside)
    assert {:ok, false} = Geofence.containment(fence, @outside)

    assert {:ok, inside_distance_m} = Geofence.distance_to_boundary(fence, @inside)
    assert {:ok, outside_distance_m} = Geofence.distance_to_boundary(fence, @outside)

    # Boundary distance comes from the iterative geodesic inverse, which is not
    # bit-reproducible across architectures; the bound is the core's documented
    # geodesic accuracy (1e-8 m), not the authoring machine's bits.
    assert_in_delta inside_distance_m, 445.0292149661649, 1.0e-8
    assert_in_delta outside_distance_m, -1109.7675457950174, 1.0e-8
  end

  test "pins uncertainty-aware containment probability with selectable methods", %{fence: fence} do
    assert {:ok, boundary_normal} =
             Geofence.containment_probability(fence, @near_south_boundary, @uncertainty)

    assert {:ok, planar} =
             Geofence.containment_probability(fence, @near_south_boundary, @uncertainty, method: :planar_quadrature)

    assert_in_delta boundary_normal, 0.6706009594981661, 1.0e-15
    assert_in_delta planar, 0.6704721891040564, 1.0e-15

    assert {:error, :invalid_probability_method} =
             Geofence.containment_probability(fence, @near_south_boundary, @uncertainty, method: :unknown)
  end

  test "pins boolean and probabilistic crossing events", %{fence: fence} do
    assert {:ok, [entered, left]} = Geofence.crossing(fence, [@outside, @inside, @outside])
    assert entered.sample_index == 1
    assert entered.kind == :entered
    assert entered.inside_probability == 1.0
    assert left.sample_index == 2
    assert left.kind == :left
    assert left.inside_probability == 0.0

    assert {:ok, [entered_probability, left_probability]} =
             Geofence.crossing_probability(
               fence,
               [{@outside, @uncertainty}, {@inside, @uncertainty}, {@outside, @uncertainty}],
               hysteresis: [enter_confidence: 0.7, leave_confidence: 0.7]
             )

    assert entered_probability.sample_index == 1
    assert entered_probability.kind == :entered
    assert entered_probability.inside_probability == 1.0
    assert left_probability.sample_index == 2
    assert left_probability.kind == :left
    assert left_probability.inside_probability == 0.0
  end
end
