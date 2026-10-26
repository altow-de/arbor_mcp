defmodule Arbor.MCP.Performance.SchemaCompilationPerformanceTest do
  @moduledoc """
  Performance test to verify the compile-time schema caching improvement.
  """
  use ExUnit.Case

  alias Arbor.MCP.Content.SchemaPolicy

  @moduletag :performance

  defp log_performance(message) do
    if System.get_env("VERBOSE_PERFORMANCE_TESTS") do
      IO.puts(message)
    end
  end

  @test_schema %{
    type: "object",
    properties: %{
      result: %{type: "number"},
      expression: %{type: "string"},
      metadata: %{
        type: "object",
        properties: %{
          timestamp: %{type: "integer"},
          operation: %{type: "string"}
        }
      }
    },
    required: ["result", "expression"]
  }

  @test_data %{
    "result" => 42,
    "expression" => "2+2",
    "metadata" => %{
      "timestamp" => 1_234_567_890,
      "operation" => "calculation"
    }
  }

  describe "compile-time schema caching performance" do
    test "compile/1 produces a reusable validator" do
      assert {:ok, compiled_schema} = SchemaPolicy.compile(@test_schema)
      assert :ok = SchemaPolicy.validate(@test_data, compiled_schema)

      assert {:error, _errors} =
               SchemaPolicy.validate(%{@test_data | "result" => "invalid"}, compiled_schema)

      assert :ok = SchemaPolicy.validate(@test_data, compiled_schema)
    end

    test "validation performance with pre-compiled schema" do
      # Pre-compile the schema (this happens at compile time in real usage)
      assert {:ok, compiled_schema} = SchemaPolicy.compile(@test_schema)

      for _ <- 1..20 do
        assert :ok = SchemaPolicy.validate(@test_data, compiled_schema)
      end

      # Wall-clock microseconds move when the scheduler is busy. Compilation
      # is the expensive step. The best sample is the one stalled the least.
      # Validating by compiling again collapses every sample toward 1.
      ratios =
        for _ <- 1..5 do
          {validate_us, results} =
            :timer.tc(fn ->
              for _ <- 1..100 do
                SchemaPolicy.validate(@test_data, compiled_schema)
              end
            end)

          assert Enum.all?(results, &(&1 == :ok))

          {compile_us, compiles} =
            :timer.tc(fn ->
              for _ <- 1..100 do
                SchemaPolicy.compile(@test_schema)
              end
            end)

          assert Enum.all?(compiles, &match?({:ok, _}, &1))
          compile_us / max(validate_us, 1)
        end

      best = Enum.max(ratios)

      log_performance("\n📊 Precompiled validation vs compilation (5 x 100):")
      log_performance("  Best compile/validate ratio: #{Float.round(best, 2)}")
      log_performance("  Samples: #{inspect(Enum.map(ratios, &Float.round(&1, 2)))}")

      assert best >= 10,
             "precompiled validation was not cheaper than compilation: #{inspect(ratios)}"
    end

    test "schema compilation is one-time cost" do
      # Measure compilation time (happens once at compile time)
      {compilation_time, compiled_schema} =
        :timer.tc(fn ->
          {:ok, compiled_schema} = SchemaPolicy.compile(@test_schema)
          compiled_schema
        end)

      # Measure validation time (happens many times at runtime)
      {validation_time, _} =
        :timer.tc(fn ->
          SchemaPolicy.validate(@test_data, compiled_schema)
        end)

      compilation_ms = compilation_time / 1000
      validation_ms = validation_time / 1000

      # Calculate break-even point
      break_even_calls =
        if validation_ms > 0 do
          Float.round(compilation_ms / validation_ms, 0)
        else
          1
        end

      log_performance("\n⚡ Compilation vs Validation Cost:")
      log_performance("  Schema compilation: #{Float.round(compilation_ms, 3)} ms (one-time)")
      log_performance("  Single validation: #{Float.round(validation_ms, 4)} ms (per call)")
      log_performance("  Break-even point: #{break_even_calls} tool calls")

      log_performance(
        "\n💡 In production, tools are typically called hundreds or thousands of times!"
      )

      log_performance("   The compilation cost is amortized very quickly.")

      assert compiled_schema != nil
      # Compilation should be reasonably fast
      assert compilation_ms < 50, "Schema compilation should be fast (< 50ms)"
    end
  end

  describe "integration with tools DSL" do
    defmodule TestPerformanceServer do
      use Arbor.MCP.Server.Handler
      use Arbor.MCP.Server.DSL

      tool "perf_test" do
        description("Performance test tool")

        output_schema(%{
          type: "object",
          properties: %{
            result: %{type: "number"},
            timestamp: %{type: "integer"}
          },
          required: ["result"]
        })

        run(fn _args, state ->
          {:ok,
           %{
             content: [%{type: "text", text: "Performance test"}],
             structuredContent: %{
               result: 42,
               timestamp: System.system_time(:second)
             }
           }, state}
        end)
      end

      @impl true
      def handle_initialize(_params, state) do
        {:ok,
         %{
           "protocolVersion" => "2025-06-18",
           "serverInfo" => %{"name" => "Test Performance Server", "version" => "1.0.0"},
           "capabilities" => %{"tools" => %{}}
         }, state}
      end
    end

    test "end-to-end tool call performance with schema validation" do
      state = %{}
      params = %{name: "perf_test", arguments: %{}}

      # Warm up
      for _ <- 1..5 do
        TestPerformanceServer.handle_call_tool(params.name, params.arguments, state)
      end

      # Measure tool call performance
      {time_microseconds, results} =
        :timer.tc(fn ->
          for _ <- 1..100 do
            TestPerformanceServer.handle_call_tool(params.name, params.arguments, state)
          end
        end)

      # Verify all calls succeeded with valid structured output
      assert length(results) == 100

      assert Enum.all?(results, fn
               {:ok, response, ^state} ->
                 Map.has_key?(response, :structuredContent) and
                   not Map.has_key?(response, :isError)

               _ ->
                 false
             end)

      time_ms = time_microseconds / 1000
      avg_per_call = time_ms / 100

      log_performance("\n🔧 End-to-End Tool Call Performance (100 calls):")
      log_performance("  Total time: #{Float.round(time_ms, 2)} ms")
      log_performance("  Average per call: #{Float.round(avg_per_call, 3)} ms")
      log_performance("  Calls per second: #{Float.round(1000 / avg_per_call, 0)}")

      # Assert reasonable performance
      assert avg_per_call < 1.0, "Expected sub-millisecond per call, got #{avg_per_call} ms"

      log_performance("\n✅ Performance test completed successfully!")
    end
  end
end
