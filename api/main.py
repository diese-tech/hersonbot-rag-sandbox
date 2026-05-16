import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

import config
import ingest as ingest_lib
import retrieve as retrieve_lib
from qdrant_client import QdrantClient

logging.basicConfig(level=config.LOG_LEVEL.upper())
logger = logging.getLogger("hersonbot")


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("HersonBot API starting — ensuring Qdrant collection exists")
    client = ingest_lib.get_client()
    ingest_lib.ensure_collection(client)
    logger.info("Ready")
    yield


app = FastAPI(title="HersonBot RAG Sandbox API", version="0.1.0", lifespan=lifespan)


# ── Models ────────────────────────────────────────────────────────────────────

class IngestTextRequest(BaseModel):
    doc_id: str
    text: str


class IngestFileRequest(BaseModel):
    path: str  # filename relative to /docs


class QueryRequest(BaseModel):
    query: str
    top_k: int = 5


# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/ingest/text")
def ingest_text(req: IngestTextRequest):
    try:
        n = ingest_lib.ingest_text(doc_id=req.doc_id, text=req.text)
        return {"status": "ingested", "doc_id": req.doc_id, "chunks": n}
    except Exception as e:
        logger.exception("ingest/text failed")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/ingest/file")
def ingest_file(req: IngestFileRequest):
    try:
        n = ingest_lib.ingest_file(filename=req.path)
        return {"status": "ingested", "file": req.path, "chunks": n}
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except Exception as e:
        logger.exception("ingest/file failed")
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/ingest/{doc_id}")
def delete_doc(doc_id: str):
    try:
        ingest_lib.delete_doc(doc_id)
        return {"status": "deleted", "doc_id": doc_id}
    except Exception as e:
        logger.exception("delete failed")
        raise HTTPException(status_code=500, detail=str(e))


@app.post("/query")
def query(req: QueryRequest):
    try:
        results = retrieve_lib.query(text=req.query, top_k=req.top_k)
        return {"query": req.query, "results": results}
    except Exception as e:
        logger.exception("query failed")
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/collections")
def list_collections():
    client = QdrantClient(host=config.QDRANT_HOST, port=config.QDRANT_PORT)
    cols = client.get_collections().collections
    return {"collections": [{"name": c.name} for c in cols]}
