defmodule Arbor.MCP.Protocol.Elicitation do
  @moduledoc false

  alias Arbor.MCP.Content.SchemaPolicy
  alias Arbor.MCP.Server.Runtime.{Deadline, OutputCodec}

  # Exact ElicitRequestParams and its transitive definitions from the pinned
  # 2026-07-28 primary schema. Includes legacy form/URL parameter shapes.
  @external_resource Path.join(__DIR__, "elicitation_schema.json")
  @schema @external_resource |> File.read!() |> Jason.decode!()

  # Keyed by the schema, so a recompiled module doesn't find a stale one.
  @compiled_key {__MODULE__, :erlang.phash2(@schema)}

  # The instance is bounded below and the schema is ours, so validation
  # gets more time than the default for untrusted schemas: on a busy
  # machine 100 ms failed real elicitations.
  @validation_timeout_ms 1_000

  def validate(params, deadline) do
    with remaining when remaining > 0 <- Deadline.remaining(deadline),
         {:ok, schema} <- compiled_schema(),
         {:ok, prepared} <-
           OutputCodec.prepare(params,
             codec: :protocol,
             deadline: deadline,
             max_frame_bytes: 65_536,
             max_term_bytes: 65_536
           ),
         normalized = Jason.decode!(prepared.wire),
         :ok <-
           SchemaPolicy.validate(normalized, schema,
             max_instance_bytes: 65_536,
             max_instance_depth: 32,
             validation_timeout_ms: min(@validation_timeout_ms, remaining)
           ),
         true <- deadline > Deadline.now() do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_elicitation_params}
    end
  end

  # Compiled once, rather than for each request under its deadline.
  defp compiled_schema do
    case :persistent_term.get(@compiled_key, nil) do
      nil ->
        with {:ok, compiled} <- SchemaPolicy.compile(@schema) do
          :persistent_term.put(@compiled_key, compiled)
          {:ok, compiled}
        end

      compiled ->
        {:ok, compiled}
    end
  end
end
