defmodule WorkflowStem.Definition.TemplateInputsTest do
  use ExUnit.Case, async: true

  alias WorkflowStem.Definition.{Inputs, Template}

  @context %{
    "params" => %{"lookback_days" => 2},
    "search" => %{"ids" => [7, 9], "count" => 2},
    "item" => %{"id" => 7}
  }

  describe "Template" do
    test "a value that is exactly one reference keeps its type" do
      assert {:ok, [7, 9]} = Template.render("{{search.ids}}", @context)
      assert {:ok, 2} = Template.render("{{ params.lookback_days }}", @context)
    end

    test "references inside text are written into it" do
      assert {:ok, "2 found, first 7"} =
               Template.render("{{search.count}} found, first {{search.ids.0}}", @context)
    end

    test "maps and lists are rendered through" do
      assert {:ok, %{"id" => 7, "all" => [[7, 9], "x"]}} =
               Template.render(
                 %{"id" => "{{item.id}}", "all" => ["{{search.ids}}", "x"]},
                 @context
               )
    end

    test "a reference to nothing is an error, unless marked optional" do
      assert {:error, {:unresolved_reference, "guest.phone"}} =
               Template.render(%{"to" => "{{guest.phone}}"}, @context)

      assert {:ok, %{"to" => nil}} = Template.render(%{"to" => "{{?guest.phone}}"}, @context)
      assert {:ok, "tel: "} = Template.render("tel: {{?guest.phone}}", @context)
    end

    test "reference_path/1 reads the path out of a whole-value reference" do
      assert Template.reference_path("{{search.ids}}") == "search.ids"
      assert Template.reference_path("search.ids") == nil
      assert Template.reference_path("a {{search.ids}}") == nil
    end
  end

  describe "Inputs" do
    @declared %{
      "interval_minutes" => %{
        "type" => "integer",
        "default" => 15,
        "min" => 5,
        "label" => "Check every"
      },
      "statuses" => %{
        "type" => "list",
        "enum" => ["confirmed", "cancelled"],
        "default" => ["confirmed"]
      },
      "notify" => %{"type" => "boolean", "required" => true},
      "from" => %{"type" => "date"}
    }

    test "defaults fill what was not chosen; absent optional values stay absent" do
      assert {:ok, params} = Inputs.resolve(@declared, %{"notify" => true})
      assert params == %{"interval_minutes" => 15, "statuses" => ["confirmed"], "notify" => true}
    end

    test "text from a form is coerced to the declared type" do
      assert {:ok, params} =
               Inputs.resolve(@declared, %{
                 "interval_minutes" => "30",
                 "notify" => "false",
                 "statuses" => "confirmed, cancelled",
                 "from" => "2026-10-01"
               })

      assert params == %{
               "interval_minutes" => 30,
               "notify" => false,
               "statuses" => ["confirmed", "cancelled"],
               "from" => "2026-10-01"
             }
    end

    test "every wrong setting is named" do
      assert {:error, errors} =
               Inputs.resolve(@declared, %{
                 "interval_minutes" => 1,
                 "statuses" => ["pending"],
                 "from" => "tomorrow"
               })

      assert errors == %{
               "interval_minutes" => {:below_min, 5},
               "statuses" => {:not_in_enum, ["pending"]},
               "notify" => :required,
               "from" => :not_a_date
             }
    end

    test "values nobody declared are dropped" do
      assert {:ok, params} = Inputs.resolve(@declared, %{"notify" => true, "rogue" => 1})
      refute Map.has_key?(params, "rogue")
    end

    test "a declaration whose own default breaks its rules is refused" do
      assert {:error, %{"n" => {:invalid_default, {:below_min, 5}}}} =
               Inputs.validate(%{"n" => %{"type" => "integer", "default" => 1, "min" => 5}})

      assert {:error, %{"n" => {:unknown_type, "money"}}} =
               Inputs.validate(%{"n" => %{"type" => "money"}})
    end

    test "describe/1 gives a form its fields, in order" do
      assert [%{name: "from"}, %{name: "interval_minutes", label: "Check every", min: 5} | _] =
               Inputs.describe(@declared)
    end
  end
end
