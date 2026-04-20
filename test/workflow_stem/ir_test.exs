defmodule WorkflowStem.IRTest do
  use ExUnit.Case, async: true

  alias WorkflowStem.IR

  describe "normalize/1" do
    test "normalizes string profile to atom" do
      spec = %{"profile" => "stepwise", "initial_state" => :start, "states" => %{}}
      ir = IR.normalize(spec)
      assert ir.profile == :stepwise
    end

    test "preserves atom profile" do
      spec = %{profile: :fsm, initial_state: :idle, states: %{}}
      ir = IR.normalize(spec)
      assert ir.profile == :fsm
    end

    test "normalizes all three profiles" do
      for p <- ["stepwise", "fsm", "flow"] do
        ir = IR.normalize(%{"profile" => p, "states" => %{}})
        assert ir.profile == String.to_atom(p)
      end
    end

    test "preserves initial_state" do
      spec = %{profile: :stepwise, initial_state: :greeting, states: %{}}
      ir = IR.normalize(spec)
      assert ir.initial_state == :greeting
    end

    test "preserves string initial_state" do
      spec = %{"profile" => "fsm", "initial_state" => "idle", "states" => %{}}
      ir = IR.normalize(spec)
      assert ir.initial_state == "idle"
    end

    test "defaults states to empty map when missing" do
      ir = IR.normalize(%{profile: :stepwise})
      assert ir.states == %{}
    end

    test "preserves existing states" do
      states = %{step_1: %{step_number: 0}, step_2: %{step_number: 1}}
      ir = IR.normalize(%{profile: :stepwise, states: states})
      assert ir.states == states
    end

    test "normalizes transitions from list to map" do
      transitions = [{:next, %{to: :step_2}}, {:back, %{to: :step_1}}]
      ir = IR.normalize(%{profile: :stepwise, transitions: transitions})
      assert is_map(ir.transitions)
      assert ir.transitions[:next] == %{to: :step_2}
    end

    test "preserves map transitions" do
      transitions = %{next: %{to: :step_2}, back: %{to: :step_1}}
      ir = IR.normalize(%{profile: :stepwise, transitions: transitions})
      assert ir.transitions == transitions
    end

    test "defaults transitions to empty map" do
      ir = IR.normalize(%{profile: :stepwise})
      assert ir.transitions == %{}
    end

    test "preserves extra fields" do
      spec = %{profile: :stepwise, custom_field: "hello", nested: %{a: 1}}
      ir = IR.normalize(spec)
      assert ir.custom_field == "hello"
      assert ir.nested == %{a: 1}
    end

    test "defaults routing to empty map" do
      ir = IR.normalize(%{profile: :stepwise})
      assert ir.routing == %{}
    end

    test "preserves routing map" do
      routing = %{triage: {SomeMod, :pick}}
      ir = IR.normalize(%{profile: :stepwise, routing: routing})
      assert ir.routing == routing
    end

    test "normalizes string-keyed routing" do
      ir = IR.normalize(%{"profile" => "stepwise", "routing" => %{r: {M, :f}}})
      assert ir.routing == %{r: {M, :f}}
    end
  end

  describe "route_for_state/2" do
    test "returns the route tuple when a state declares one" do
      spec =
        IR.normalize(%{
          profile: :stepwise,
          states: %{
            a: %{route: {:switch, :r, %{x: [], y: []}}}
          }
        })

      assert IR.route_for_state(spec, :a) == {:switch, :r, %{x: [], y: []}}
    end

    test "returns nil for a state without :route" do
      spec = IR.normalize(%{profile: :stepwise, states: %{a: %{action: %{type: :noop}}}})
      assert IR.route_for_state(spec, :a) == nil
    end

    test "returns nil for an unknown state name" do
      spec = IR.normalize(%{profile: :stepwise, states: %{}})
      assert IR.route_for_state(spec, :unknown) == nil
    end
  end

  describe "routing_for/2" do
    test "returns the {mod, fun} resolver tuple when present" do
      spec = IR.normalize(%{profile: :stepwise, routing: %{r: {SomeMod, :pick}}})
      assert IR.routing_for(spec, :r) == {SomeMod, :pick}
    end

    test "returns nil for an unknown route name" do
      spec = IR.normalize(%{profile: :stepwise, routing: %{}})
      assert IR.routing_for(spec, :unknown) == nil
    end
  end
end
