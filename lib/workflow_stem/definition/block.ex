defmodule WorkflowStem.Definition.Block do
  @moduledoc """
  A building block: one kind of step a workflow can take.

  The host registers blocks by handle (`"data_source.call"`,
  `"records.save"`); a node in a definition names one and gives it arguments
  under `with`. The arguments arrive with every `{{reference}}` already
  resolved.

  A block must be safe to run twice with the same arguments: a run that is
  interrupted resumes from its last checkpoint and repeats the step it was
  in.

  `run/2` returns:

    * `{:ok, value}` — stored in the run's context under the node's id, so a
      later node reads it as `{{node_id}}` or `{{node_id.field}}`
    * `{:merge, map}` — merged into the context as it stands
    * `{:wait, wait}` — pause this branch; `wait` may carry `:deadline`
    * `{:error, reason}`
  """

  @type env :: %{
          tenant_id: term(),
          node: String.t(),
          execution_id: String.t(),
          context: map(),
          params: map(),
          meta: map(),
          token_id: String.t() | nil,
          branch_id: term()
        }

  @callback handle() :: String.t()

  @doc "What the block is and the arguments it takes, for a designer palette."
  @callback describe() :: %{
              required(:label) => String.t(),
              optional(:description) => String.t(),
              optional(:arguments) => [map()]
            }

  @callback run(arguments :: map(), env()) ::
              {:ok, term()} | {:merge, map()} | {:wait, map()} | {:error, term()}
end
