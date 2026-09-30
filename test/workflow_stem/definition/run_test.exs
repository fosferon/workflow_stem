defmodule WorkflowStem.Definition.RunTest do
  @moduledoc """
  Whole workflows, written as data, run end to end against stand-in blocks:
  the reservation sync and both of the client's charts. Every run that
  pauses is stored as JSON and picked up from the stored form.
  """

  use ExUnit.Case, async: false

  alias WorkflowStem.Definition
  alias WorkflowStem.Definition.Run
  alias WorkflowStem.Test.DefinitionBlocks

  setup do
    previous = Application.get_env(:mobus_stepwise, :capability_runner_adapter)
    Application.put_env(:mobus_stepwise, :capability_runner_adapter, DefinitionBlocks.Runner)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mobus_stepwise, :capability_runner_adapter)
        adapter -> Application.put_env(:mobus_stepwise, :capability_runner_adapter, adapter)
      end
    end)

    :ok
  end

  defp stub(node, result), do: Process.put({:stub, node}, result)
  defp stored(outcome), do: outcome.checkpoint |> Jason.encode!() |> Jason.decode!()
  defp call(arguments \\ %{}), do: %{"action" => "stub.call", "with" => arguments}

  describe "the reservation sync" do
    defp reservation_sync do
      %{
        "name" => "reservation_sync",
        "inputs" => %{
          "interval_minutes" => %{"type" => "integer", "default" => 15, "min" => 5},
          "lookback_days" => %{"type" => "integer", "default" => 2}
        },
        "start" => "modified",
        "nodes" => %{
          "modified" =>
            call(%{
              "operation" => "reservation_search",
              "params" => %{
                "last_mod_fromd" => "{{run.since}}",
                "last_mod_tod" => "{{run.until}}"
              }
            }),
          "booked" =>
            call(%{
              "operation" => "reservation_search",
              "params" => %{"bk_fromd" => "{{run.since}}", "bk_tod" => "{{run.until}}"}
            }),
          "changed" => call(%{"union" => ["{{modified.ids}}", "{{booked.ids}}"]}),
          "each_booking" => %{
            "type" => "for_each",
            "over" => "{{changed.ids}}",
            "on_error" => "stop",
            "collect" => "save.outcome"
          },
          "fetch" => call(%{"operation" => "reservation_retrieve", "id" => "{{item}}"}),
          "save" => call(%{"attribute_set" => "hospitality_reservation", "from" => "{{fetch}}"}),
          "saved" => %{"type" => "join"},
          "done" => %{"type" => "end"}
        },
        "edges" => [
          ["modified", "booked"],
          ["booked", "changed"],
          ["changed", "each_booking"],
          ["each_booking", "fetch"],
          ["fetch", "save"],
          ["save", "saved"],
          ["saved", "done"]
        ]
      }
    end

    defp start_sync(opts \\ []) do
      stub("modified", {:ok, %{"ids" => [11, 12]}})
      stub("booked", {:ok, %{"ids" => [12, 13]}})
      stub("changed", {:ok, %{"ids" => [11, 12, 13]}})
      stub("fetch", fn %{"id" => id} -> {:ok, %{"id" => id, "status" => "confirmed"}} end)

      stub("save", fn %{"from" => booking} ->
        {:ok, %{"outcome" => if(booking["id"] == 13, do: "created", else: "unchanged")}}
      end)

      Run.start(
        reservation_sync(),
        [
          tenant_id: "smv",
          context: %{"run" => %{"since" => "2026-09-28", "until" => "2026-10-01"}}
        ] ++ opts
      )
    end

    test "searches both ways, then fetches and saves each booking once" do
      assert {:ok, outcome} = start_sync()

      assert outcome.status == :completed
      assert outcome.context["params"] == %{"interval_minutes" => 15, "lookback_days" => 2}

      assert outcome.context["flow_results"]["saved"] == %{
               "total" => 3,
               "completed" => 3,
               "failed" => 0,
               "errors" => [],
               "items" => ["unchanged", "unchanged", "created"]
             }

      assert_received {:called, "modified", %{"params" => %{"last_mod_fromd" => "2026-09-28"}}}
      assert_received {:called, "booked", %{"params" => %{"bk_tod" => "2026-10-01"}}}
      assert_received {:called, "fetch", %{"id" => 11}}
      assert_received {:called, "save", %{"from" => %{"id" => 13, "status" => "confirmed"}}}
    end

    test "a provider failure on one booking fails the run and says which step" do
      stub("modified", {:ok, %{"ids" => [11, 12]}})
      stub("booked", {:ok, %{"ids" => []}})
      stub("changed", {:ok, %{"ids" => [11, 12]}})

      stub("fetch", fn
        %{"id" => 12} -> {:error, :http_503}
        %{"id" => id} -> {:ok, %{"id" => id}}
      end)

      stub("save", {:ok, %{"outcome" => "created"}})

      assert {:ok, outcome} =
               Run.start(reservation_sync(),
                 tenant_id: "smv",
                 context: %{"run" => %{"since" => "a", "until" => "b"}}
               )

      assert outcome.status == :failed
      assert outcome.error == :http_503
    end

    test "an interrupted run carries on from its last snapshot, not from the start" do
      snapshots = :ets.new(:snapshots, [:ordered_set, :public])

      assert {:ok, _outcome} =
               start_sync(
                 checkpoint_every: 1,
                 persist: fn outcome -> :ets.insert(snapshots, {outcome.events, outcome}) end
               )

      # a snapshot taken mid-loop: two searches and the union done, one item in
      [{_, mid}] = :ets.lookup(snapshots, 6)
      assert mid.status == :running
      flush()

      assert {:ok, outcome} =
               Run.continue(reservation_sync(), stored(mid), tenant_id: "smv")

      assert outcome.status == :completed
      assert outcome.context["flow_results"]["saved"]["completed"] == 3
      refute_received {:called, "modified", _}
      refute_received {:called, "booked", _}
    end

    test "a block that raises fails the run at the state before the step" do
      stub("modified", fn _ -> raise "socket closed" end)

      assert {:ok, outcome} =
               Run.start(reservation_sync(),
                 tenant_id: "smv",
                 context: %{"run" => %{"since" => "a", "until" => "b"}}
               )

      assert outcome.status == :failed
      assert outcome.error == {:exception, "socket closed"}
      assert outcome.checkpoint.active_tokens["tok:root:modified"].status == :ready
    end

    test "a dial outside its limits stops the run before anything is called" do
      assert {:error, {:invalid_params, %{"interval_minutes" => {:below_min, 5}}}} =
               Run.start(reservation_sync(), tenant_id: "smv", params: %{"interval_minutes" => 1})

      refute_received {:called, _, _}
    end
  end

  describe "the notification chart" do
    # Timer fires → find waiting guests → for each: ask the provider → if
    # there is room, email a claim link and wait for the click → on the click,
    # ask again → send to booking, or say it has gone. A link nobody clicks
    # lapses.
    defp notification do
      available = %{"op" => "truthy", "left" => "check.available"}
      still_available = %{"op" => "truthy", "left" => "recheck.available"}

      %{
        "name" => "waitlist_notification",
        "inputs" => %{
          "days_ahead" => %{"type" => "integer", "default" => 3},
          "claim_hours" => %{"type" => "integer", "default" => 48}
        },
        "start" => "find_guests",
        "nodes" => %{
          "find_guests" => call(%{"check_in_after_days" => "{{params.days_ahead}}"}),
          "each_guest" => %{
            "type" => "for_each",
            "over" => "{{find_guests.entries}}",
            "as" => "guest",
            "max_concurrency" => 50,
            "on_error" => "continue",
            "collect" => "outcome"
          },
          "check" => call(%{"operation" => "availability", "dates" => "{{guest.dates}}"}),
          "not_yet" => %{"set" => %{"outcome" => "still_waiting"}},
          "email_link" => call(%{"template" => "availability_alert", "to" => "{{guest.email}}"}),
          "await_click" => %{"wait" => %{"reason" => "claim", "deadline_minutes" => 2880}},
          "recheck" => call(%{"operation" => "availability", "dates" => "{{guest.dates}}"}),
          "to_booking" => %{"set" => %{"outcome" => "redirected"}},
          "gone" => call(%{"template" => "no_longer_available", "to" => "{{guest.email}}"}),
          "gone_done" => %{"set" => %{"outcome" => "gone"}},
          "lapsed" => %{"set" => %{"outcome" => "lapsed"}},
          "guests_done" => %{"type" => "join"},
          "done" => %{"type" => "end"}
        },
        "edges" => [
          ["find_guests", "each_guest"],
          ["each_guest", "check"],
          %{"from" => "check", "to" => "email_link", "when" => available},
          ["check", "not_yet"],
          ["not_yet", "guests_done"],
          ["email_link", "await_click"],
          ["await_click", "recheck"],
          %{"from" => "await_click", "to" => "lapsed", "on" => "timeout"},
          ["lapsed", "guests_done"],
          %{"from" => "recheck", "to" => "to_booking", "when" => still_available},
          ["recheck", "gone"],
          ["gone", "gone_done"],
          ["gone_done", "guests_done"],
          ["to_booking", "guests_done"],
          ["guests_done", "done"]
        ]
      }
    end

    defp guests do
      for name <- ~w(ada ben cy dee) do
        %{"email" => "#{name}@example.com", "dates" => "2026-10-0#{String.length(name)}"}
      end
    end

    test "each guest takes their own path, and the run waits only for those with a link" do
      stub("find_guests", {:ok, %{"entries" => guests()}})
      # ada, ben, dee have room (dee's name is 3 letters like ada/ben; cy has none)
      stub("check", fn %{"dates" => dates} -> {:ok, %{"available" => dates != "2026-10-02"}} end)
      stub("email_link", {:ok, %{"sent" => true}})

      assert {:ok, outcome} = Run.start(notification(), tenant_id: "smv")

      assert outcome.status == :waiting
      assert map_size(outcome.waiting) == 3
      assert %DateTime{} = outcome.next_deadline
      assert_received {:called, "find_guests", %{"check_in_after_days" => 3}}
      assert_received {:called, "email_link", %{"to" => "ada@example.com"}}
      refute_received {:called, "email_link", %{"to" => "cy@example.com"}}

      # ada clicks: still available → booking
      stub("recheck", {:ok, %{"available" => true}})

      assert {:ok, outcome} =
               Run.resume(notification(), stored(outcome),
                 tenant_id: "smv",
                 token_id: "tok:root:find_guests:0:check",
                 context: %{"clicked_at" => "2026-10-01T10:00:00Z"}
               )

      assert outcome.status == :waiting
      assert map_size(outcome.waiting) == 2

      # ben clicks: gone in the meantime → told so
      stub("recheck", {:ok, %{"available" => false}})

      assert {:ok, outcome} =
               Run.resume(notification(), stored(outcome),
                 tenant_id: "smv",
                 token_id: "tok:root:find_guests:1:check"
               )

      assert_received {:called, "gone", %{"to" => "ben@example.com"}}
      assert outcome.status == :waiting
      assert Map.keys(outcome.waiting) == ["tok:root:find_guests:3:check"]

      # ada's link, clicked a second time, is refused rather than ignored
      assert {:error, {:not_waiting, "tok:root:find_guests:0:check"}} =
               Run.resume(notification(), stored(outcome),
                 tenant_id: "smv",
                 token_id: "tok:root:find_guests:0:check"
               )

      # dee never clicks: the deadline passes
      checkpoint =
        stored(outcome)
        |> update_in(["pending_waits"], fn waits ->
          Map.new(waits, fn {id, wait} ->
            {id, Map.put(wait, "deadline", "2020-01-01T00:00:00Z")}
          end)
        end)

      assert {:ok, outcome} = Run.timeout(notification(), checkpoint, tenant_id: "smv")

      assert outcome.status == :completed

      assert outcome.context["flow_results"]["guests_done"]["items"] ==
               ["redirected", "gone", "still_waiting", "lapsed"]
    end

    test "one guest's provider error does not stop the others" do
      stub("find_guests", {:ok, %{"entries" => Enum.take(guests(), 2)}})

      stub("check", fn
        %{"dates" => "2026-10-03"} -> {:error, :http_500}
      end)

      assert {:ok, outcome} = Run.start(notification(), tenant_id: "smv")

      assert outcome.status == :completed
      assert outcome.context["flow_results"]["guests_done"]["failed"] == 2
    end

    test "nobody waiting: the run ends at once" do
      stub("find_guests", {:ok, %{"entries" => []}})

      assert {:ok, %{status: :completed} = outcome} = Run.start(notification(), tenant_id: "smv")
      assert outcome.context["flow_results"]["guests_done"]["total"] == 0
      refute_received {:called, "check", _}
    end
  end

  describe "the registration chart" do
    # The website asks → log the search → ask the provider → room: answer
    # with the booking link. No room: answer "show the form" and wait for it;
    # when it comes, record the guest, then confirm to the website and email
    # the guest together (connector A). No form: end.
    defp registration do
      %{
        "name" => "waitlist_registration",
        "start" => "log_search",
        "nodes" => %{
          "log_search" => call(%{"record" => "search_log", "dates" => "{{trigger.dates}}"}),
          "check" => call(%{"operation" => "availability", "dates" => "{{trigger.dates}}"}),
          "answer_redirect" => %{"set" => %{"response" => %{"redirect" => "{{check.url}}"}}},
          "answer_form" => %{"set" => %{"response" => %{"show" => "waitlist_form"}}},
          "await_form" => %{"wait" => %{"reason" => "form", "deadline_minutes" => 30}},
          "record_guest" =>
            call(%{"record" => "waiting_list_entry", "email" => "{{form.email}}"}),
          "together" => %{"type" => "fork"},
          "confirm" => %{"set" => %{"response" => %{"registered" => true}}},
          "email_guest" =>
            call(%{"template" => "waitlist_confirmation", "to" => "{{form.email}}"}),
          "both_done" => %{"type" => "join"},
          "abandoned" => %{},
          "done" => %{"type" => "end"}
        },
        "edges" => [
          ["log_search", "check"],
          %{
            "from" => "check",
            "to" => "answer_redirect",
            "when" => %{"op" => "truthy", "left" => "check.available"}
          },
          ["check", "answer_form"],
          ["answer_redirect", "done"],
          ["answer_form", "await_form"],
          ["await_form", "record_guest"],
          %{"from" => "await_form", "to" => "abandoned", "on" => "timeout"},
          ["abandoned", "done"],
          ["record_guest", "together"],
          %{"from" => "together", "to" => "confirm", "branch_id" => "website"},
          %{"from" => "together", "to" => "email_guest", "branch_id" => "guest"},
          %{"from" => "confirm", "to" => "both_done", "branch_id" => "website"},
          %{"from" => "email_guest", "to" => "both_done", "branch_id" => "guest"},
          ["both_done", "done"]
        ]
      }
    end

    defp register(available?) do
      stub("log_search", {:ok, %{"logged" => true}})
      stub("check", {:ok, %{"available" => available?, "url" => "https://book.example/x"}})

      Run.start(registration(),
        tenant_id: "smv",
        context: %{"trigger" => %{"dates" => "2026-10-02/2026-10-05", "guests" => 2}}
      )
    end

    test "room: the website is answered with the booking link and the run ends" do
      assert {:ok, outcome} = register(true)

      assert outcome.status == :completed
      assert outcome.context["response"] == %{"redirect" => "https://book.example/x"}
      assert_received {:called, "log_search", %{"dates" => "2026-10-02/2026-10-05"}}
    end

    test "no room: show the form, wait, then record, confirm and email together" do
      assert {:ok, outcome} = register(false)

      assert outcome.status == :waiting
      assert outcome.context["response"] == %{"show" => "waitlist_form"}

      stub("record_guest", {:ok, %{"id" => "entry-1"}})
      stub("email_guest", {:ok, %{"sent" => true}})

      assert {:ok, outcome} =
               Run.resume(registration(), stored(outcome),
                 tenant_id: "smv",
                 context: %{"form" => %{"name" => "Ada", "email" => "ada@example.com"}}
               )

      assert outcome.status == :completed
      assert_received {:called, "record_guest", %{"email" => "ada@example.com"}}
      assert_received {:called, "email_guest", %{"to" => "ada@example.com"}}

      assert outcome.context["flow_results"]["both_done"]["website"]["response"] ==
               %{"registered" => true}
    end

    test "no form: the wait lapses and the run ends without recording anyone" do
      assert {:ok, outcome} = register(false)

      checkpoint =
        stored(outcome)
        |> update_in(["pending_waits"], fn waits ->
          Map.new(waits, fn {id, wait} ->
            {id, Map.put(wait, "deadline", "2020-01-01T00:00:00Z")}
          end)
        end)

      assert {:ok, outcome} = Run.timeout(registration(), checkpoint, tenant_id: "smv")

      assert outcome.status == :completed
      refute_received {:called, "record_guest", _}
    end
  end

  describe "definitions that are wrong are refused with the reason" do
    defp tiny(overrides) do
      Map.merge(
        %{
          "name" => "tiny",
          "start" => "a",
          "nodes" => %{"a" => call(), "b" => %{"type" => "end"}},
          "edges" => [["a", "b"]]
        },
        overrides
      )
    end

    test "structure" do
      assert :ok = Definition.validate(tiny(%{}))
      assert {:error, :missing_name} = Definition.validate(tiny(%{"name" => ""}))
      assert {:error, {:unknown_start, "z"}} = Definition.validate(tiny(%{"start" => "z"}))

      assert {:error, {:invalid_edge, ["a", "z"], {:unknown_node, "z"}}} =
               Definition.validate(tiny(%{"edges" => [["a", "z"]]}))

      assert {:error, {:reserved_node_id, "params"}} =
               Definition.validate(tiny(%{"nodes" => %{"a" => call(), "params" => %{}}}))

      assert {:error, {:invalid_node_id, "1st"}} =
               Definition.validate(tiny(%{"nodes" => %{"a" => call(), "1st" => %{}}}))
    end

    test "nodes" do
      assert {:error, {:invalid_node, "a", {:more_than_one_kind, ["action", "wait"]}}} =
               Definition.validate(
                 tiny(%{"nodes" => %{"a" => %{"action" => "x", "wait" => %{}}}})
               )

      assert {:error, {:invalid_node, "a", {:unknown_type, "frok"}}} =
               Definition.validate(tiny(%{"nodes" => %{"a" => %{"type" => "frok"}}}))

      assert {:error, {:invalid_node, "a", :for_each_needs_over}} =
               Definition.validate(tiny(%{"nodes" => %{"a" => %{"type" => "for_each"}}}))
    end

    test "what only the engine can see: conditions and loop bodies" do
      assert {:error,
              {:invalid_edge_condition, "a", "b", {:invalid_condition, {:unknown_op, "regex"}}}} =
               Definition.validate(
                 tiny(%{
                   "edges" => [
                     %{
                       "from" => "a",
                       "to" => "b",
                       "when" => %{"op" => "regex", "left" => "x", "right" => "y"}
                     }
                   ]
                 })
               )

      assert {:error, {:invalid_for_each, "a", :no_join}} =
               Definition.validate(
                 tiny(%{
                   "nodes" => %{"a" => %{"type" => "for_each", "over" => "{{x}}"}, "b" => %{}}
                 })
               )
    end

    test "atom keys are accepted; the same content gives the same hash" do
      as_atoms = %{name: "tiny", start: "a", nodes: %{"a" => %{action: "stub.call"}}, edges: []}

      as_strings = %{
        "name" => "tiny",
        "start" => "a",
        "nodes" => %{"a" => %{"action" => "stub.call"}},
        "edges" => []
      }

      assert :ok = Definition.validate(as_atoms)
      assert Definition.hash(as_atoms) == Definition.hash(as_strings)
      refute Definition.hash(as_atoms) == Definition.hash(Map.put(as_strings, "name", "other"))
    end
  end

  defp flush do
    receive do
      {:called, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end
