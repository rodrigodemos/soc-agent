"""Example MCP tool: echo back the input.

Replace with real SOC tools as needed. Each tool module should expose a
``register(mcp)`` function that decorates one or more callables with
``@mcp.tool()``.
"""

from __future__ import annotations

from mcp.server.fastmcp import FastMCP


def register(mcp: FastMCP) -> None:
    @mcp.tool()
    def echo(message: str) -> str:
        """Echo back the provided message. Replace with a real SOC tool."""
        return message
