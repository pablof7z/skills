#!/usr/bin/env python3
"""Browser approval and metadata routes for pairing-code OAuth."""

from __future__ import annotations

from html import escape
import time

from starlette.requests import Request
from starlette.responses import HTMLResponse, JSONResponse, RedirectResponse
from starlette.routing import Route

from tts_mcp_oauth import PairingApprovalError, PairingOAuthProvider, SCOPE


def oauth_extra_routes(provider: PairingOAuthProvider) -> list[Route]:
    async def pair(request: Request):
        if request.method == "POST":
            form = await request.form()
            request_id = str(form.get("request") or "")
            submitted = str(form.get("pairing_code") or "")
            try:
                redirect = await provider.complete_authorization(request_id, submitted)
            except PairingApprovalError as error:
                return pair_page(provider, request_id, str(error), error.status_code)
            return RedirectResponse(
                redirect, status_code=303, headers={"Cache-Control": "no-store"}
            )
        return pair_page(provider, request.query_params.get("request", ""))

    async def root_metadata(_request: Request):
        return JSONResponse(
            {
                "resource": provider.resource_url,
                "authorization_servers": [provider.issuer_url],
                "scopes_supported": [SCOPE],
                "bearer_methods_supported": ["header"],
                "resource_name": "TTS MCP",
            },
            headers={"Cache-Control": "max-age=60", "Access-Control-Allow-Origin": "*"},
        )

    return [
        Route("/pair", pair, methods=["GET", "POST"]),
        Route("/.well-known/oauth-protected-resource", root_metadata, methods=["GET"]),
    ]


def pair_page(
    provider: PairingOAuthProvider,
    request_id: str,
    error: str | None = None,
    status_code: int = 200,
) -> HTMLResponse:
    try:
        summary = provider.pending_summary(request_id)
        pairing = provider.pairing.current()
    except PairingApprovalError as approval_error:
        return message_page(str(approval_error), approval_error.status_code)
    seconds = max(
        0, min(int(summary["expires_at"]), pairing.expires_at) - int(time.time())
    )
    error_html = f'<p class="error">{escape(error)}</p>' if error else ""
    body = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Pair with TTS MCP</title><style>{styles()}</style></head>
<body><main><p class="eyebrow">TTS MCP</p><h1>Approve this MCP caller</h1>
<p><strong>{escape(str(summary["client_name"]))}</strong> will return through
<code>{escape(str(summary["redirect_host"]))}</code>.</p>
<p>Enter the four-character code shown by <code>tts-mcp pairing-code</code>.</p>
{error_html}<form method="post" action="/pair" autocomplete="off">
<input type="hidden" name="request" value="{escape(request_id)}">
<label for="pairing_code">Pairing code</label>
<input id="pairing_code" name="pairing_code" minlength="4" maxlength="4"
 inputmode="text" autocapitalize="characters" spellcheck="false" required autofocus>
<button type="submit">Approve caller</button></form>
<p class="fine">One use only. Expires in at most {seconds} seconds.</p></main></body></html>"""
    return HTMLResponse(
        body,
        status_code=status_code,
        headers=security_headers(str(summary["redirect_origin"])),
    )


def message_page(message: str, status_code: int) -> HTMLResponse:
    body = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width"><title>TTS MCP</title>
<style>{styles()}</style></head><body><main><p class="eyebrow">TTS MCP</p>
<h1>Authorization unavailable</h1><p>{escape(message)}</p></main></body></html>"""
    return HTMLResponse(body, status_code=status_code, headers=security_headers())


def security_headers(redirect_origin: str | None = None) -> dict[str, str]:
    form_action = "form-action 'self'"
    if redirect_origin:
        # Chromium applies form-action to redirects caused by a form submission.
        form_action += f" {redirect_origin}"
    return {
        "Cache-Control": "no-store",
        "Content-Security-Policy": (
            f"default-src 'none'; style-src 'unsafe-inline'; {form_action}; "
            "frame-ancestors 'none'; base-uri 'none'"
        ),
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
    }


def styles() -> str:
    return """
:root{color-scheme:dark;font-family:ui-sans-serif,system-ui;background:#111;color:#f3efe7}
body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;box-sizing:border-box}
main{width:min(440px,100%);background:#1b1b1a;border:1px solid #383633;border-radius:18px;padding:32px;box-sizing:border-box}
.eyebrow{color:#d6a85f;text-transform:uppercase;letter-spacing:.14em;font-size:12px;font-weight:700}
h1{font-size:30px;line-height:1.1;margin:12px 0}p{color:#c7c1b7;line-height:1.55}code{color:#f3efe7}
form{display:grid;gap:10px;margin-top:28px}label{font-size:14px;font-weight:700}
input{font:700 28px ui-monospace,monospace;letter-spacing:.35em;text-transform:uppercase;padding:14px;border-radius:10px;border:1px solid #57524b;background:#10100f;color:#fff;text-align:center}
button{margin-top:8px;padding:14px;border:0;border-radius:10px;background:#e5b768;color:#17130d;font-weight:800;font-size:16px;cursor:pointer}
.fine{font-size:13px}.error{color:#ff9d94;background:#351d1b;padding:10px 12px;border-radius:8px}
"""
