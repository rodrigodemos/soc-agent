"""Minimal MCP HTTP server with one example tool.

Run with:
    python -m app.main

Listens on 0.0.0.0:${PORT:-8080}.
"""

from __future__ import annotations

import os

from mcp.server.fastmcp import FastMCP

from .tools.echo import register as register_echo


def build_server() -> FastMCP:
    """Construct the FastMCP server and register all tools."""
    mcp = FastMCP(
        name="soc-mcp-http-server",
        instructions=(
            "Sample MCP server for the SOC Copilot agent. Replace the echo "
            "tool with real SOC tools (Sentinel KQL, ServiceNow lookup, "
            "S3 search, etc.) as you build out the agent."
        ),
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8080")),
    )
    register_echo(mcp)
    return mcp


def main() -> None:
    mcp = build_server()
    mcp.run(transport="streamable-http")


if __name__ == "__main__":
    main()
