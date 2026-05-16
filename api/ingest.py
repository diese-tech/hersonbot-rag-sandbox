import hashlib
import uuid
from pathlib import Path

from qdrant_client import QdrantClient
from qdrant_client.models import (
    Distance,
    FieldCondition,
    Filter,
    FilterSelector,
    MatchValue,
    PointStruct,
    VectorParams,
)

import config
import embedder


def get_client() -> QdrantClient:
    return QdrantClient(host=config.QDRANT_HOST, port=config.QDRANT_PORT)


def ensure_collection(client: QdrantClient) -> None:
    existing = {c.name for c in client.get_collections().collections}
    if config.QDRANT_COLLECTION not in existing:
        client.create_collection(
            collection_name=config.QDRANT_COLLECTION,
            vectors_config=VectorParams(
                size=embedder.VECTOR_SIZE,
                distance=Distance.COSINE,
            ),
        )


def _chunk_id(doc_id: str, chunk_index: int) -> str:
    # Deterministic UUID from doc_id + chunk_index so repeated upserts are idempotent.
    # SHA-256 first 32 hex chars → valid UUID; same inputs always yield the same ID.
    raw = f"{doc_id}:{chunk_index}".encode()
    return str(uuid.UUID(hashlib.sha256(raw).hexdigest()[:32]))


def chunk_text(text: str) -> list[str]:
    chunks = []
    start = 0
    while start < len(text):
        end = start + config.CHUNK_SIZE
        chunks.append(text[start:end].strip())
        start += config.CHUNK_SIZE - config.CHUNK_OVERLAP
    return [c for c in chunks if c]


def ingest_text(doc_id: str, text: str) -> int:
    chunks = chunk_text(text)
    if not chunks:
        return 0

    vectors = embedder.embed(chunks)
    client = get_client()
    ensure_collection(client)

    points = [
        PointStruct(
            id=_chunk_id(doc_id, i),
            vector=vec,
            payload={"doc_id": doc_id, "chunk_index": i, "text": chunk},
        )
        for i, (chunk, vec) in enumerate(zip(chunks, vectors))
    ]
    client.upsert(collection_name=config.QDRANT_COLLECTION, points=points)
    return len(points)


def delete_doc(doc_id: str) -> None:
    client = get_client()
    client.delete(
        collection_name=config.QDRANT_COLLECTION,
        points_selector=FilterSelector(
            filter=Filter(
                must=[FieldCondition(key="doc_id", match=MatchValue(value=doc_id))]
            )
        ),
    )


def ingest_file(filename: str) -> int:
    path = Path(config.DOCS_DIR) / filename
    if not path.exists():
        raise FileNotFoundError(f"{filename} not found in docs directory")
    text = path.read_text(encoding="utf-8")
    return ingest_text(doc_id=filename, text=text)
