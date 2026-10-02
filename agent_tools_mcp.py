#!/usr/bin/env python3
"""Server-hosted web fetch and sequential-thinking MCP tools."""
import argparse
import html.parser
import http.client
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


def _resolve_public_addresses(host: str, port: int | None):
    try:
        results = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except OSError as exc:
        raise ValueError(f"Could not resolve hostname: {exc}") from exc
    if not results:
        raise ValueError("Could not resolve hostname")
    for result in results:
        try:
            address = ipaddress.ip_address(result[4][0])
        except ValueError as exc:
            raise ValueError("Only publicly routable hosts can be fetched") from exc
        if not address.is_global:
            raise ValueError("Only publicly routable hosts can be fetched")
    return results


def validate_public_url(url: str) -> None:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise ValueError("URL must use http or https and include a hostname")
    if parsed.username or parsed.password:
        raise ValueError("URLs containing credentials are not supported")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError:
        _resolve_public_addresses(parsed.hostname, None)
    else:
        if not address.is_global:
            raise ValueError("Only publicly routable hosts can be fetched")


def _connect_public_socket(host, port, timeout, source_address):
    addresses = _resolve_public_addresses(host, port)
    last_error = None
    for family, socktype, proto, _, sockaddr in addresses:
        sock = socket.socket(family, socktype, proto)
        try:
            if timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
                sock.settimeout(timeout)
            if source_address:
                sock.bind(source_address)
            sock.connect(sockaddr)
            return sock
        except OSError as exc:
            last_error = exc
            sock.close()
    if last_error:
        raise last_error
    raise OSError("Could not connect to public host")


class PublicHTTPConnection(http.client.HTTPConnection):
    def connect(self):
        self.sock = _connect_public_socket(self.host, self.port, self.timeout, self.source_address)


class PublicHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        self.sock = _connect_public_socket(self.host, self.port, self.timeout, self.source_address)
        server_hostname = self._tunnel_host or self.host
        try:
            self.sock = self._context.wrap_socket(self.sock, server_hostname=server_hostname)
        except Exception:
            self.sock.close()
            raise


class PublicHTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(PublicHTTPConnection, req)


class PublicHTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(
            PublicHTTPSConnection,
            req,
            context=self._context,
            check_hostname=self._check_hostname,
        )


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

    Use web_search first to discover URLs unless the URL is already known.

    Args:
        url: Public HTTP or HTTPS URL to fetch.
    """
    try:
        validate_public_url(url)
        request = urllib.request.Request(
            url,
            headers={"User-Agent": "local-intelligence-mcp/1.0", "Accept": "text/html,application/json,text/plain,*/*"},
        )
        context = ssl.create_default_context(cafile=certifi.where() if certifi else None)
        handlers = [
            urllib.request.ProxyHandler({}),
            PublicHTTPHandler(),
            PublicHTTPSHandler(context=context),
            PublicRedirectHandler(),
        ]
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
    except Exception as exc:  # noqa: BLE001 — surface as tool result, not crash
        return f"Fetch failed: {exc}"


@server.tool()
def web_search(query: str, count: int = 5) -> str:
    """Search the public web and return titles, URLs, and snippets.

    Use this for current or live information (weather, prices, news,
    recent events) and to discover page URLs. Results are titles and
    snippets only: always web_fetch the most relevant URL(s) to get
    details before answering — never ask the user to pick a source.

    Args:
        query: Search keywords or a question.
        count: Number of results to return (1-10, default 5).
    """
    query = (query or "").strip()
    if not query:
        return "Search failed: query must not be empty."
    count = max(1, min(int(count), 10))
    try:
        from ddgs import DDGS

        results = DDGS().text(query, max_results=count) or []
    except ImportError:
        return "Search failed: search backend not installed (phase3 installs it)."
    except Exception as exc:  # noqa: BLE001 — surface as tool result, not crash
        return f"Search failed: {exc}"
    if not results:
        return f"No results for {query!r}."
    lines = []
    for i, r in enumerate(results[:count], 1):
        title = (r.get("title") or "untitled").strip()
        url = (r.get("href") or r.get("url") or "").strip()
        snippet = (r.get("body") or "").strip().replace("\n", " ")
        lines.append(f"{i}. {title}\n   URL: {url}\n   {snippet[:500]}")
    return "\n".join(lines)[:MAX_OUTPUT_CHARS]


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