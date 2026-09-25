#!/usr/bin/env python3
"""rag_mcp.py — stdio MCP server exposing the project Qdrant RAG loop.

Tools: rag_query (retrieve grounded chunks), rag_ingest (ingest a corpus
into a collection), rag_collections (list collections). Reuses rag_demo.py
helpers (same chunking, embeddings, deterministic upsert IDs) but returns
strings instead of printing — stdout is the MCP protocol channel.

Run by opencode / Continue as an MCP server, e.g.:
  .venv/bin/python rag_mcp.py
Remote clients (Continue on another machine) cannot spawn this over stdio —
serve it over HTTP on the LAN instead:
  .venv/bin/python rag_mcp.py --transport streamable-http --port 8011
then point the client's Continue `mcpServers` at the URL (see plan §9).
Trusted LAN only — no auth, same posture as Ollama's LAN bind (phase 5).
Env overrides (same as rag_demo.py): QDRANT_URL, EMBED_MODEL, OLLAMA_URL.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rag_demo  # noqa: E402
from mcp.server.mcpserver import MCPServer

server = MCPServer("rag")


@server.tool()
def rag_query(collection: str, query: str, top_k: int = 5) -> str:
    """Retrieve the most relevant chunks for a question from a Qdrant collection.

    Args:
        collection: Qdrant collection name (e.g. 'alice', 'myproj', 'local-intel').
        query: Natural-language question.
        top_k: Number of chunks to return (default 5).
    """
    try:
        qc = rag_demo.client()
        if not qc.collection_exists(collection):
            return f"ERROR: collection {collection!r} does not exist."
        vec = rag_demo.embedder().get_query_embedding(query)
        hits = qc.query_points(collection, query=vec, limit=top_k).points
    except Exception as e:  # noqa: BLE001 — surface as tool result, not crash
        return f"ERROR: retrieval failed: {e}"
    if not hits:
        return f"No hits in collection {collection!r}."
    out = []
    for h in hits:
        payload = h.payload or {}
        out.append(f"[{h.score:.3f}] source={payload.get('source', '?')}\n{payload.get('text', '')}")
    return "\n\n---\n\n".join(out)


@server.tool()
def rag_ingest(collection: str, corpus: str, patterns: str = "", recreate: bool = False) -> str:
    """Ingest a corpus directory into a Qdrant collection (upserts in place).

    Args:
        collection: Qdrant collection name to write to.
        corpus: Directory to ingest (absolute path or repo-relative).
        patterns: Comma-separated glob patterns (default '*.md').
        recreate: Delete and rebuild the collection first.
    """
    pats = [p.strip() for p in patterns.split(",") if p.strip()] or ["*.md"]
    if not os.path.isabs(corpus):
        corpus = os.path.join(rag_demo.ROOT_DIR, corpus)
    try:
        docs = rag_demo.load_corpus(corpus, pats)
    except SystemExit as e:
        return f"ERROR: {e}"
    try:
        nodes = rag_demo.chunk(docs)
        emb = rag_demo.embedder()
        texts = [n.get_content() for n in nodes]
        vectors = emb.get_text_embedding_batch(texts)
        qc = rag_demo.client()
        rag_demo.ensure_collection(qc, collection, len(vectors[0]), recreate=recreate)
        import uuid

        from qdrant_client.models import PointStruct

        points = [
            PointStruct(
                id=str(uuid.uuid5(uuid.NAMESPACE_URL, f"{n.metadata['source']}:{i}")),
                vector=vec,
                payload={"text": txt, "source": n.metadata["source"]},
            )
            for i, (n, txt, vec) in enumerate(zip(nodes, texts, vectors))
        ]
        qc.upsert(collection, points)
    except Exception as e:  # noqa: BLE001 — surface as tool result, not crash
        return f"ERROR: ingest failed: {e}"
    return f"ingested {len(points)} chunks from {len(docs)} files -> {collection}"


@server.tool()
def rag_collections() -> str:
    """List available Qdrant collections."""
    try:
        names = [c.name for c in rag_demo.client().get_collections().collections]
    except Exception as e:  # noqa: BLE001 — surface as tool result, not crash
        return f"ERROR: cannot list collections: {e}"
    return ", ".join(names) if names else "(no collections)"


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="project RAG over MCP")
    ap.add_argument("--transport", default="stdio",
                    choices=["stdio", "streamable-http", "sse"])
    ap.add_argument("--port", type=int, default=8011)
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()
    if args.transport == "stdio":
        server.run()
    else:
        server.run(transport=args.transport, host=args.host, port=args.port)
