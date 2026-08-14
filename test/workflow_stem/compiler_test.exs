defmodule WorkflowStem.CompilerTest do
  use ExUnit.Case, async: true

  alias WorkflowStem.{Compiler, IR}

  defp spec(opts \\ []) do
    IR.normalize(
      Enum.into(opts, %{
        profile: :stepwise,
        initial_state: :a,
        states: %{a: %{}},
        routing: %{}
      })
    )
  end

  def pick(_event, _opts), do: :x

  describe "has_routes?/1" do
    test "false when no state declares :route" do
      refute Compiler.has_routes?(spec(states: %{a: %{action: %{type: :noop}}}))
    end

    test "true when at least one state declares :route" do
      s = spec(states: %{a: %{route: {:tbd, :marker}}})
      assert Compiler.has_routes?(s)
    end
  end

  describe "components_for/1 — individual primitives" do
    test ":stage (2-arity) emits a stage descriptor with defaults" do
      s = spec(states: %{a: %{route: {:stage, :my_stage}}})
      assert [{:stage, :my_stage, %{state: :a, count: 1, opts: []}}] = Compiler.components_for(s)
    end

    test ":stage (3-arity) accepts count and opts" do
      s = spec(states: %{a: %{route: {:stage, :my_stage, count: 4, opts: [foo: 1]}}})

      assert [{:stage, :my_stage, %{state: :a, count: 4, opts: [foo: 1]}}] =
               Compiler.components_for(s)
    end

    test ":switch emits resolver + compiled branches" do
      s =
        spec(
          states: %{
            a: %{
              route:
                {:switch, :triage,
                 %{
                   simple: [{:stage, :s1}],
                   deep: [{:stage, :s2}, {:done, :terminal}]
                 }}
            }
          },
          routing: %{triage: {__MODULE__, :pick}}
        )

      [{:switch, :triage, meta}] = Compiler.components_for(s)
      assert meta.state == :a
      assert meta.resolver == {__MODULE__, :pick}
      assert Map.keys(meta.branches) |> Enum.sort() == [:deep, :simple]

      # Branches are themselves compiled — nested descriptors preserved
      assert [{:stage, :s1, _}] = meta.branches[:simple]
      assert [{:stage, :s2, _}, {:done, :terminal, _}] = meta.branches[:deep]
    end

    test ":composer emits memo + opts" do
      s =
        spec(
          states: %{
            a: %{route: {:composer, FanOutParallel, memo: [], count: 3, opts: [chunk: 10]}}
          }
        )

      assert [{:composer, FanOutParallel, %{memo: [], count: 3, opts: [chunk: 10]}}] =
               Compiler.components_for(s)
    end

    test ":goto emits to, resolver, if" do
      s =
        spec(
          states: %{
            a: %{route: {:goto, :loop_back, to: :start, if: :should_loop}}
          },
          routing: %{should_loop: {__MODULE__, :pick}}
        )

      [{:goto, :loop_back, meta}] = Compiler.components_for(s)
      assert meta.to == :start
      assert meta.resolver == {__MODULE__, :pick}
      assert meta.if == :should_loop
    end

    test ":goto defaults :if to the goto name when omitted" do
      s =
        spec(
          states: %{a: %{route: {:goto, :retry, to: :start}}},
          routing: %{retry: {__MODULE__, :pick}}
        )

      [{:goto, :retry, %{resolver: {__MODULE__, :pick}, if: :retry}}] = Compiler.components_for(s)
    end

    test ":goto_point emits a label descriptor" do
      s = spec(states: %{a: %{route: {:goto_point, :retry_label}}})
      assert [{:goto_point, :retry_label, %{state: :a}}] = Compiler.components_for(s)
    end

    test ":done emits descriptor with opts" do
      s = spec(states: %{a: %{route: {:done, :finish, opts: [if: :done?]}}})

      assert [{:done, :finish, %{state: :a, opts: [if: :done?]}}] = Compiler.components_for(s)
    end

    test ":dead_end emits a terminator descriptor" do
      s = spec(states: %{a: %{route: {:dead_end, :drop}}})
      assert [{:dead_end, :drop, %{state: :a}}] = Compiler.components_for(s)
    end

    test ":from emits module inclusion descriptor" do
      s = spec(states: %{a: %{route: {:from, SharedPrelude, count: 2}}})
      assert [{:from, SharedPrelude, %{count: 2}}] = Compiler.components_for(s)
    end

    test ":plug_with recursively compiles its body" do
      s =
        spec(
          states: %{
            a: %{
              route: {:plug_with, SubPipeline, [{:stage, :inner}, {:dead_end, :end}]}
            }
          }
        )

      [{:plug_with, SubPipeline, meta}] = Compiler.components_for(s)
      assert [{:stage, :inner, _}, {:dead_end, :end, _}] = meta.body
    end

    test ":tbd emits placeholder descriptor" do
      s = spec(states: %{a: %{route: {:tbd, :not_yet}}})
      assert [{:tbd, :not_yet, %{state: :a}}] = Compiler.components_for(s)
    end
  end

  describe "components_for/1 — composition" do
    test "a state's :route may be a list of primitives" do
      s =
        spec(
          states: %{
            a: %{
              route: [
                {:stage, :prep},
                {:dead_end, :end}
              ]
            }
          }
        )

      assert [{:stage, :prep, _}, {:dead_end, :end, _}] = Compiler.components_for(s)
    end

    test "routes are flattened across multiple states" do
      s =
        spec(
          initial_state: :a,
          states: %{
            a: %{route: {:stage, :first}},
            b: %{route: {:stage, :second}}
          }
        )

      descriptors = Compiler.components_for(s)
      assert length(descriptors) == 2
      tags = Enum.map(descriptors, fn {kind, name, _} -> {kind, name} end) |> Enum.sort()
      assert tags == [{:stage, :first}, {:stage, :second}]
    end

    test "nested switches inside a switch branch are compiled recursively" do
      s =
        spec(
          states: %{
            a: %{
              route:
                {:switch, :outer,
                 %{
                   left: [
                     {:switch, :inner,
                      %{
                        yes: [{:stage, :y}],
                        no: [{:stage, :n}]
                      }}
                   ],
                   right: [{:stage, :r}]
                 }}
            }
          },
          routing: %{
            outer: {__MODULE__, :pick},
            inner: {__MODULE__, :pick}
          }
        )

      [{:switch, :outer, outer_meta}] = Compiler.components_for(s)
      [{:switch, :inner, inner_meta}] = outer_meta.branches[:left]
      assert Map.keys(inner_meta.branches) |> Enum.sort() == [:no, :yes]
    end
  end

  describe "components_for/1 — errors" do
    test "raises when a :switch references an unknown routing name" do
      s = spec(states: %{a: %{route: {:switch, :missing, %{a: [], b: []}}}}, routing: %{})

      assert_raise ArgumentError, ~r/unknown routing name/, fn ->
        Compiler.components_for(s)
      end
    end

    test "raises when a :goto references an unknown routing name" do
      s = spec(states: %{a: %{route: {:goto, :jump, to: :x, if: :missing}}}, routing: %{})

      assert_raise ArgumentError, ~r/unknown routing name/, fn ->
        Compiler.components_for(s)
      end
    end

    test "raises on unrecognised primitive" do
      s = spec(states: %{a: %{route: {:nonsense, :x, %{}}}})

      assert_raise ArgumentError, ~r/unrecognised :route primitive/, fn ->
        Compiler.components_for(s)
      end
    end

    test "raises when routing entry is not a {module, function} tuple" do
      s =
        spec(
          states: %{a: %{route: {:switch, :r, %{x: [], y: []}}}},
          routing: %{r: "not a tuple"}
        )

      assert_raise ArgumentError, ~r/must be \{module, function\}/, fn ->
        Compiler.components_for(s)
      end
    end
  end

  describe "validate/1" do
    test "accepts a spec without any routes" do
      assert Compiler.validate(spec()) == :ok
    end

    test "accepts a spec whose every :switch/:goto name resolves" do
      s =
        spec(
          states: %{a: %{route: {:switch, :r, %{x: [], y: []}}}},
          routing: %{r: {__MODULE__, :pick}}
        )

      assert Compiler.validate(s) == :ok
    end

    test "descends into nested :switch branches" do
      s =
        spec(
          states: %{
            a: %{
              route:
                {:switch, :outer,
                 %{
                   left: [{:switch, :inner, %{a: [], b: []}}],
                   right: []
                 }}
            }
          },
          routing: %{outer: {__MODULE__, :pick}}
        )

      assert {:error, {:missing_routing, :inner}} = Compiler.validate(s)
    end

    test "descends into :plug_with bodies" do
      s =
        spec(
          states: %{
            a: %{
              route: {:plug_with, Outer, [{:goto, :jump, to: :x, if: :unrouted}]}
            }
          }
        )

      assert {:error, {:missing_routing, :unrouted}} = Compiler.validate(s)
    end

    test "rejects a missing routing name at the top level" do
      s = spec(states: %{a: %{route: {:switch, :r, %{x: [], y: []}}}}, routing: %{})
      assert {:error, {:missing_routing, :r}} = Compiler.validate(s)
    end

    test "rejects unknown tuple primitives and malformed options before AST emission" do
      unknown = spec(states: %{a: %{route: {:not_an_alf_primitive, :x}}})
      assert {:error, {:bad_primitive, {:not_an_alf_primitive, :x}}} = Compiler.validate(unknown)

      malformed = spec(states: %{a: %{route: {:stage, :x, %{count: 1}}}})
      assert {:error, {:bad_primitive_options, %{count: 1}}} = Compiler.validate(malformed)
    end
  end
end
