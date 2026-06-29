# Copyright (c) Microsoft. All rights reserved.

"""SOC Copilot agent — Microsoft Foundry hosted agent using the GitHub Copilot SDK.

Auth is BYOK only: the agent obtains a managed-identity token for the
Foundry project endpoint and uses it as the bearer token for the Copilot SDK's
``ProviderConfig``. There is no ``GITHUB_TOKEN`` code path because this template
targets a private-network deployment that blocks egress to ``github.com``.

Required environment variables (auto-injected when deployed as a hosted agent):
    FOUNDRY_PROJECT_ENDPOINT       Project-level OpenAI endpoint
                                   (e.g. https://<account>.services.ai.azure.com/api/projects/<project>)
    AZURE_AI_MODEL_DEPLOYMENT_NAME Name of the model deployment (e.g. gpt-4o-mini)
"""

import asyncio
import json
import logging
import os
import pathlib
import sys
import uuid

from dotenv import load_dotenv
from starlette.requests import Request
from starlette.responses import JSONResponse, Response, StreamingResponse

from azure.ai.agentserver.invocations import InvocationAgentServerHost
from azure.identity import DefaultAzureCredential
from copilot import CopilotClient, PermissionHandler, ProviderConfig
from copilot.session_events import SessionEventType

load_dotenv(override=False)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = InvocationAgentServerHost()

_client: CopilotClient | None = None
_session = None
_session_id: str | None = None
_skills_dir = str(pathlib.Path(__file__).parent / "skills")

_SYSTEM_PROMPT = (
    "You are a SOC triage assistant. Help the analyst investigate alerts, "
    "incidents, and indicators of compromise. Use the tools you have to query "
    "data sources, summarize findings, and propose next actions. Always cite "
    "the tools and data sources you used."
)


def _byok_provider() -> tuple[ProviderConfig, str]:
    """Build the Foundry BYOK ProviderConfig from environment variables."""
    endpoint = os.environ.get("FOUNDRY_PROJECT_ENDPOINT", "")
    model = os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME", "")
    if not endpoint or not model:
        raise RuntimeError(
            "FOUNDRY_PROJECT_ENDPOINT and AZURE_AI_MODEL_DEPLOYMENT_NAME "
            "must both be set for BYOK auth.")

    token = DefaultAzureCredential().get_token(
        "https://ai.azure.com/.default"
    ).token

    provider = ProviderConfig(
        type="azure",
        base_url=endpoint,
        wire_api="responses",
        bearer_token=token,
    )
    return provider, model


async def _ensure_session() -> None:
    """Resume a persisted session or create a new one (lazy, runs once)."""
    global _client, _session, _session_id
    if _session is not None:
        return

    _session_id = os.environ.get("FOUNDRY_AGENT_SESSION_ID")
    if not _session_id:
        _session_id = str(uuid.uuid4())
        logger.warning(
            "FOUNDRY_AGENT_SESSION_ID not set, using: %s", _session_id)

    provider, model = _byok_provider()
    _client = CopilotClient()
    await _client.start()

    working_dir = (
        os.environ.get("HOME")
        or os.environ.get("USERPROFILE")
        or os.path.expanduser("~")
    )

    common = dict(
        on_permission_request=PermissionHandler.approve_all,
        streaming=True,
        skill_directories=[_skills_dir],
        working_directory=working_dir,
        provider=provider,
        model=model,
        system_prompt=_SYSTEM_PROMPT,
    )

    try:
        _session = await _client.resume_session(_session_id, **common)
        logger.info("Resumed session: %s", _session_id)
    except Exception:
        _session = await _client.create_session(session_id=_session_id, **common)
        logger.info("Created session: %s", _session_id)


async def _stream_response(invocation_id: str, input_text: str):
    """Forward Copilot SDK session events as Server-Sent Events."""
    await _ensure_session()
    queue: asyncio.Queue = asyncio.Queue()

    def on_event(event):
        if event.type == SessionEventType.SESSION_IDLE:
            queue.put_nowait(None)
        elif event.type == SessionEventType.SESSION_ERROR:
            queue.put_nowait(RuntimeError(
                getattr(event.data, "message", "error")))
        else:
            queue.put_nowait(event)

    unsubscribe = _session.on(on_event)
    try:
        await _session.send(input_text)
        while True:
            item = await queue.get()
            if item is None:
                break
            if isinstance(item, Exception):
                yield f"data: {json.dumps({'type': 'error', 'message': str(item)})}\n\n".encode()
                break
            yield f"data: {json.dumps(item.to_dict())}\n\n".encode()

        yield f"event: done\ndata: {json.dumps({'invocation_id': invocation_id, 'session_id': _session_id})}\n\n".encode()
    finally:
        unsubscribe()


@app.invoke_handler
async def handle_invoke(request: Request) -> Response:
    """Accept the analyst's prompt in any of the following body shapes:

    - JSON object: ``{"input": "investigate IP 1.2.3.4"}``
    - JSON string: ``"investigate IP 1.2.3.4"``
    - Plain text:  ``investigate IP 1.2.3.4``
    """
    raw = await request.body()
    text = raw.decode("utf-8", errors="replace").strip()
    input_text: str | None = None

    if text:
        try:
            data = json.loads(text)
            if isinstance(data, dict):
                value = data.get("input")
                if isinstance(value, str):
                    input_text = value
            elif isinstance(data, str):
                input_text = data
        except json.JSONDecodeError:
            input_text = text

    if not input_text or not input_text.strip():
        return JSONResponse(
            status_code=400,
            content={
                "error": "invalid_request",
                "message": (
                    "Request body must be a non-empty prompt — either plain text, "
                    'a JSON string ("hello"), or {"input": "hello"}.'
                ),
            },
        )
    return StreamingResponse(
        _stream_response(request.state.invocation_id, input_text),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive"},
    )


if __name__ == "__main__":
    if not (os.environ.get("FOUNDRY_PROJECT_ENDPOINT")
            and os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME")):
        sys.exit(
            "Error: Set FOUNDRY_PROJECT_ENDPOINT and "
            "AZURE_AI_MODEL_DEPLOYMENT_NAME (BYOK Foundry model). "
            "These are auto-injected when deployed as a Foundry hosted agent.")
    app.run()
