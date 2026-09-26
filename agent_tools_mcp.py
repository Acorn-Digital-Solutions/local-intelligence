#!/usr/bin/env python3
"""Server-hosted web fetch and sequential-thinking MCP tools."""
import argparse
import html.parser
import ipaddress
import ssl
import socket
import urllib.error
import urllib.parse
import urllib.request

try:
    import certifi
except ImportError:
    certifi = None

from mcp.server.mcpserver import MCPServer

server = MCPServer("agent-tools")
MAX_RESPONSE_BYTES = 1_000_000
MAX_OUTPUT_CHARS = 20_000


def validate_public_url(url: str) -> None:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("URL must use http or https and include a hostname")
    if parsed.username or parsed.password:
        raise ValueError("URLs containing credentials are not supported")
    try:
        addresses = [ipaddress.ip_address(parsed.hostname)]
    except ValueError:
        try:
            addresses = [
                ipaddress.ip_address(result[4][0])
                for result in socket.getaddrinfo(parsed.hostname, None, type=socket.SOCK_STREAM)
            ]
        except OSError as exc:
            raise ValueError(f"Could not resolve hostname: {exc}") from exc
    if not addresses or any(not address.is_global for address in addresses):
        raise ValueError("Only publicly routable hosts can be fetched")


class PublicRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        validate_public_url(new_url)
        return super().redirect_request(request, response, code, message, headers, new_url)


class PageTextExtractor(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.title_parts = []
        self.text_parts = []
        self.in_title = False
        self.skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag == "title":
            self.in_title = True
        if tag in {"script", "style", "noscript", "svg"}:
            self.skip_depth += 1
        if tag in {"p", "br", "div", "li", "h1", "h2", "h3", "tr"}:
            self.text_parts.append("\n")

    def handle_endtag(self, tag):
        if tag == "title":
            self.in_title = False
        if tag in {"script", "style", "noscript", "svg"} and self.skip_depth:
            self.skip_depth -= 1
        if tag in {"p", "div", "li", "h1", "h2", "h3", "tr"}:
            self.text_parts.append("\n")

    def handle_data(self, data):
        if self.in_title:
            self.title_parts.append(data)
        if not self.skip_depth:
            self.text_parts.append(data)


def readable_page(body: bytes, content_type: str) -> tuple[str, str]:
    text = body.decode("utf-8", errors="replace")
    if "html" not in content_type.lower():
        return "", text
    parser = PageTextExtractor()
    parser.feed(text)
    title = " ".join(" ".join(parser.title_parts).split())
    page_text = " ".join(" ".join(parser.text_parts).split())
    return title, page_text


@server.tool()
def web_fetch(url: str) -> str:
    """Fetch a public HTTP(S) page and return its title and readable text.

    Args:
        url: Public HTTP or HTTPS URL to fetch.
    """
    try:
        validate_public_url(url)
        request = urllib.request.Request(
            url,
            headers={"User-Agent": "local-intelligence-mcp/1.0", "Accept": "text/html,application/json,text/plain,*/*"},
        )
        handlers = [PublicRedirectHandler()]
        if certifi:
            handlers.append(urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=certifi.where())))
        opener = urllib.request.build_opener(*handlers)
        with opener.open(request, timeout=20) as response:
            content_type = response.headers.get("Content-Type", "")
            body = response.read(MAX_RESPONSE_BYTES + 1)
            truncated = len(body) > MAX_RESPONSE_BYTES
            body = body[:MAX_RESPONSE_BYTES]
            title, text = readable_page(body, content_type)
            result = [
                f"URL: {response.geturl()}",
                f"Status: {response.status}",
                f"Content-Type: {content_type or 'unknown'}",
            ]
            if title:
                result.append(f"Title: {title}")
            result.append(f"Content:\n{text[:MAX_OUTPUT_CHARS]}")
            if truncated or len(text) > MAX_OUTPUT_CHARS:
                result.append("[Response truncated]")
            return "\n".join(result)
    except (OSError, ValueError, urllib.error.URLError) as exc:
        return f"Fetch failed: {exc}"


@server.tool()
def sequential_thinking(
    thought: str,
    thought_number: int,
    total_thoughts: int,
    next_thought_needed: bool,
) -> str:
    """Track a step in a structured, multi-step reasoning sequence.

    Args:
        thought: The current reasoning step or intermediate conclusion.
        thought_number: One-based number of this step.
        total_thoughts: Current estimated number of steps; may change later.
        next_thought_needed: Whether another reasoning step is planned.
    """
    if thought_number < 1 or total_thoughts < 1 or thought_number > total_thoughts:
        return "Invalid sequence: thought_number must be between 1 and total_thoughts."
    if not thought.strip():
        return "Invalid sequence: thought must not be empty."
    if next_thought_needed:
        return f"Recorded step {thought_number} of {total_thoughts}. Continue with the next step; revise the estimate if needed."
    return f"Recorded final step {thought_number} of {total_thoughts}. The sequence is complete."


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Agent tools over MCP")
    parser.add_argument("--transport", default="stdio", choices=["stdio", "streamable-http", "sse"])
    parser.add_argument("--port", type=int, default=8012)
    parser.add_argument("--host", default="127.0.0.1")
    args = parser.parse_args()
    if args.transport == "stdio":
        server.run()
    else:
        server.run(transport=args.transport, host=args.host, port=args.port)