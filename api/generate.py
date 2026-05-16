import time

import httpx

import config
import retrieve as retrieve_lib


class OllamaUnconfigured(Exception):
    pass


class OllamaUnreachable(Exception):
    pass


class OllamaTimeout(Exception):
    pass


class OllamaModelMissing(Exception):
    pass


class OllamaInvalidResponse(Exception):
    pass


def build_prompt(query: str, chunks: list[dict]) -> str:
    context_lines = "\n".join(
        f"[{i + 1}] ({chunk['doc_id']}) {chunk['text']}"
        for i, chunk in enumerate(chunks)
    )
    return (
        "You are an assistant for the HersonBot RAG Sandbox knowledge base.\n"
        "Answer the user's question using ONLY the context below.\n"
        'If the context does not contain the answer, say:\n'
        '"I don\'t have that information in the knowledge base."\n'
        "Do not invent facts. Cite source numbers in square brackets when relevant.\n"
        "\n"
        "Context:\n"
        f"{context_lines}\n"
        "\n"
        f"Question: {query}\n"
        "\n"
        "Answer:"
    )


def generate_answer(query: str) -> dict:
    if not config.OLLAMA_HOST:
        raise OllamaUnconfigured("OLLAMA_HOST is not configured")

    t0 = time.monotonic()
    chunks = retrieve_lib.query(text=query, top_k=config.OLLAMA_CONTEXT_TOP_K)
    retrieval_ms = int((time.monotonic() - t0) * 1000)

    prompt = build_prompt(query, chunks)

    payload = {
        "model": config.OLLAMA_MODEL,
        "prompt": prompt,
        "stream": False,
    }

    t1 = time.monotonic()
    try:
        response = httpx.post(
            f"{config.OLLAMA_HOST}/api/generate",
            json=payload,
            timeout=config.OLLAMA_TIMEOUT_SECONDS,
        )
    except httpx.ConnectError as exc:
        raise OllamaUnreachable(f"Cannot connect to Ollama at {config.OLLAMA_HOST}") from exc
    except httpx.TimeoutException as exc:
        raise OllamaTimeout(f"Ollama request timed out after {config.OLLAMA_TIMEOUT_SECONDS}s") from exc
    generation_ms = int((time.monotonic() - t1) * 1000)

    if response.status_code == 404:
        raise OllamaModelMissing(f"Model '{config.OLLAMA_MODEL}' not found on Ollama")

    if not response.is_success:
        raise OllamaInvalidResponse(f"Ollama returned HTTP {response.status_code}")

    try:
        data = response.json()
        answer = data["response"]
    except Exception as exc:
        raise OllamaInvalidResponse("Ollama response could not be parsed") from exc

    sources = [
        {"index": i + 1, "doc_id": c["doc_id"], "chunk_index": c["chunk_index"], "score": c["score"]}
        for i, c in enumerate(chunks)
    ]

    return {
        "query": query,
        "answer": answer,
        "model": config.OLLAMA_MODEL,
        "sources": sources,
        "retrieval_ms": retrieval_ms,
        "generation_ms": generation_ms,
    }
