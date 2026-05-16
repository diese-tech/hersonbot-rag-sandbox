from qdrant_client import QdrantClient
from qdrant_client.models import ScoredPoint

import config
import embedder


def get_client() -> QdrantClient:
    return QdrantClient(host=config.QDRANT_HOST, port=config.QDRANT_PORT)


def query(text: str, top_k: int = 5) -> list[dict]:
    vector = embedder.embed_one(text)
    client = get_client()

    hits: list[ScoredPoint] = client.search(
        collection_name=config.QDRANT_COLLECTION,
        query_vector=vector,
        limit=top_k,
        with_payload=True,
    )

    return [
        {
            "score": round(hit.score, 4),
            "doc_id": hit.payload.get("doc_id"),
            "chunk_index": hit.payload.get("chunk_index"),
            "text": hit.payload.get("text"),
        }
        for hit in hits
    ]
