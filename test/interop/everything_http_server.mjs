/**
 * Launches the MCP "everything" server on streamable HTTP transport.
 * Listens on a random available port and prints the port number to stdout
 * so the Elixir test process can read it.
 *
 * Uses the official @modelcontextprotocol/server-everything package. Its
 * `createApp()` serves both protocol eras on `/mcp`: 2025-era sessions
 * (initialize, GET stream, DELETE) and session-less 2026-07-28 requests.
 */

import { createApp } from "@modelcontextprotocol/server-everything/dist/transports/streamableHttp.js";

const { app, shutdown } = createApp();

// Listen on port 0 for random available port
const httpServer = app.listen(0, "127.0.0.1", (error) => {
  if (error) {
    console.error("Everything server failed to listen:", error);
    process.exit(1);
  }

  // Print port to stdout so Elixir can read it
  process.stdout.write(`PORT:${httpServer.address().port}\n`);
});

// `shutdown` closes the sessions and exits the process.
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
