#!/usr/bin/env python3
"""rag_demo.py — minimal LlamaIndex + Qdrant + Ollama RAG loop.

Default demo corpus: the *.md files in the project root (the plan this
stack implements). Point it at any coding project with --corpus/--pattern
and keep each project in its own --collection.

Embeddings: nomic-embed-text via Ollama. Store: Qdrant (default localhost:6333).

Usage (run with the project env, from this directory):
  .venv/bin/python rag_demo.py --ingest [--recreate]
  .venv/bin/python rag_demo.py --query "Which embedding models does the plan recommend?"
  .venv/bin/python rag_demo.py --verify   # deterministic end-of-phase checks
  .venv/bin/python rag_demo.py --corpus ~/code/myproj --pattern '**/*.py' \\
      --pattern '**/*.md' --collection myproj --ingest
  .venv/bin/python rag_demo.py --collection myproj --query "where is auth handled?"
"""
import argparse
import glob
import os
import sys
import uuid

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_COLLECTION = "local-intel"
QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
PROBE_QUERY = "Which embedding models does the plan recommend?"
PROBE_TOKEN = "nomic"

# Never ingest dependency/build/VCS noise, even if a pattern matches it.
SKIP_PARTS = (
    "/.git/", "/node_modules/", "/__pycache__/", "/.venv/",
    "/dist/", "/build/", "/.next/", "/target/",
)
SKIP_FILES = ("package-lock.json", "yarn.lock", "pnpm-lock.yaml", "poetry.lock")

from llama_index.core import Document
from llama_index.core.node_parser import SentenceSplitter
from llama_index.embeddings.ollama import OllamaEmbedding
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, PointStruct, VectorParams


def load_corpus(corpus_dir, patterns):
    docs = []
    for pat in patterns:
        for path in sorted(glob.glob(os.path.join(corpus_dir, pat), recursive=True)):
            if not os.path.isfile(path):
                continue
            if any(part in path for part in SKIP_PARTS):
                continue
            if os.path.basename(path) in SKIP_FILES:
                continue
            try:
                with open(path, encoding="utf-8") as f:
                    text = f.read().strip()
            except (OSError, UnicodeDecodeError):
                continue
            if text:
                docs.append(
                    Document(
                        text=text,
                        metadata={"source": os.path.relpath(path, corpus_dir)},
                    )
                )
    if not docs:
        sys.exit(f"no files matching {patterns} under {corpus_dir}")
    return docs


def chunk(docs):
    splitter = SentenceSplitter(chunk_size=512, chunk_overlap=50)
    nodes = splitter.get_nodes_from_documents(docs)
    return [n for n in nodes if n.get_content().strip()]


def embedder():
    return OllamaEmbedding(model_name=EMBED_MODEL, base_url=OLLAMA_URL)


def client():
    return QdrantClient(url=QDRANT_URL, timeout=120)


def ensure_collection(qc, collection, dim, recreate=False):
    if recreate and qc.collection_exists(collection):
        qc.delete_collection(collection)
    if not qc.collection_exists(collection):
        qc.create_collection(
            collection, vectors_config=VectorParams(size=dim, distance=Distance.COSINE)
        )


def ingest(corpus_dir, patterns, collection, recreate=False):
    docs = load_corpus(corpus_dir, patterns)
    nodes = chunk(docs)
    emb = embedder()
    texts = [n.get_content() for n in nodes]
    vectors = emb.get_text_embedding_batch(texts)
    qc = client()
    ensure_collection(qc, collection, len(vectors[0]), recreate=recreate)
    # Deterministic IDs (source:index) so re-ingest upserts in place.
    points = [
        PointStruct(
            id=str(uuid.uuid5(uuid.NAMESPACE_URL, f"{n.metadata['source']}:{i}")),
            vector=vec,
            payload={"text": txt, "source": n.metadata["source"]},
        )
        for i, (n, txt, vec) in enumerate(zip(nodes, texts, vectors))
    ]
    qc.upsert(collection, points)
    print(f"ingested {len(points)} chunks from {len(docs)} files -> {collection}")
    return len(points)


def query(text, collection, top_k=3):
    qc = client()
    vec = embedder().get_query_embedding(text)
    hits = qc.query_points(collection, query=vec, limit=top_k).points
    for h in hits:
        snippet = h.payload["text"][:200].replace("\n", " ")
        print(f"[{h.score:.3f}] {h.payload['source']}: {snippet}")
    return hits


def verify(collection):
    failures = []
    qc = client()
    try:
        info = qc.get_collection(collection)
    except Exception as e:  # noqa: BLE001 — report, don't traceback
        print(f"FAIL: collection {collection!r} missing: {e}")
        return 1
    dim = info.config.params.vectors.size
    count = info.points_count
    print(f"collection {collection!r}: {count} points, dim {dim}")
    if count < 5:
        failures.append(f"too few points ({count})")
    if dim != 768:
        failures.append(f"unexpected vector dim ({dim}, want 768 for {EMBED_MODEL})")
    # The probe is specific to the default demo corpus (the plan docs).
    if collection == DEFAULT_COLLECTION:
        vec = embedder().get_query_embedding(PROBE_QUERY)
        hits = qc.query_points(collection, query=vec, limit=5).points
        if not hits:
            failures.append("probe query returned no hits")
        elif not any(PROBE_TOKEN in h.payload["text"].lower() for h in hits):
            failures.append(f"probe token {PROBE_TOKEN!r} not in top-5 hits")
        elif hits[0].score < 0.3:
            failures.append(f"top hit score suspiciously low ({hits[0].score:.3f})")
        else:
            print(f"probe OK: top hit [{hits[0].score:.3f}] {hits[0].payload['source']}")
    else:
        print("custom collection: health checked, probe skipped (demo-corpus specific).")
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("RAG verify OK: ingest + retrieve grounded in the corpus.")
    return 0


def main():
    ap = argparse.ArgumentParser(description="minimal project RAG demo")
    ap.add_argument("--corpus", default=ROOT_DIR)
    ap.add_argument("--pattern", action="append", default=None)
    ap.add_argument("--collection", default=DEFAULT_COLLECTION)
    ap.add_argument("--ingest", action="store_true")
    ap.add_argument("--query")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--recreate", action="store_true")
    args = ap.parse_args()
    patterns = args.pattern or ["*.md"]
    if args.verify:
        sys.exit(verify(args.collection))
    if args.query:
        query(args.query, args.collection)
    elif args.ingest:
        ingest(args.corpus, patterns, args.collection, recreate=args.recreate)
    else:
        ap.print_help()
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
