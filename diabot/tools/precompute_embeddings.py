#!/usr/bin/env python3
"""Dev-time tool: precompute EmbeddingGemma vectors for the DiabAI RAG
knowledge base.

This is NOT shipped with the app. Run it manually whenever
`assets/rag/knowledge_base.json` content changes, to regenerate
`assets/rag/knowledge_embeddings.json` (bundled as a Flutter asset and
loaded at runtime by `lib/rag.dart` for on-device cosine-similarity
retrieval).

Requires a native `llama-embedding` CLI binary built from the same
llama.cpp commit pinned by `llama_cpp_dart` (see /memories/repo for the
exact commit and build instructions), plus the EmbeddingGemma GGUF at
`assets/models/embeddinggemma-300m-Q4_0.gguf`.

Usage:
    python3 tools/precompute_embeddings.py \
        --llama-embedding /path/to/llama-embedding \
        --model assets/models/embeddinggemma-300m-Q4_0.gguf
"""
import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DIABAI_DIR = SCRIPT_DIR.parent
KNOWLEDGE_BASE_PATH = DIABAI_DIR / "assets" / "rag" / "knowledge_base.json"
OUTPUT_PATH = DIABAI_DIR / "assets" / "rag" / "knowledge_embeddings.json"


def build_document_prompt(text: str) -> str:
    """EmbeddingGemma's documented document-style prompt prefix.

    Newlines are collapsed since llama-embedding treats each input line
    (via -f) as a separate prompt.
    """
    flat_text = " ".join(text.split())
    return f"title: none | text: {flat_text}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--llama-embedding",
        required=True,
        help="Path to a compiled llama-embedding CLI binary.",
    )
    parser.add_argument(
        "--model",
        default=str(DIABAI_DIR / "assets" / "models" / "embeddinggemma-300m-Q4_0.gguf"),
        help="Path to the EmbeddingGemma GGUF model.",
    )
    args = parser.parse_args()

    with open(KNOWLEDGE_BASE_PATH, encoding="utf-8") as f:
        kb = json.load(f)
    chunks = kb["chunks"]

    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as tmp:
        for chunk in chunks:
            tmp.write(build_document_prompt(chunk["text"]) + "\n")
        prompts_path = tmp.name

    cmd = [
        args.llama_embedding,
        "-m", args.model,
        "--embd-normalize", "2",
        "--embd-output-format", "array",
        "-f", prompts_path,
        "--no-warmup",
    ]
    print(f"Running: {' '.join(cmd)}", file=sys.stderr)
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        return result.returncode

    vectors = json.loads(result.stdout)
    if len(vectors) != len(chunks):
        print(
            f"Mismatch: {len(chunks)} chunks but {len(vectors)} embeddings returned",
            file=sys.stderr,
        )
        return 1

    output = {
        "version": kb.get("version", 1),
        "dim": len(vectors[0]) if vectors else 0,
        "chunks": [
            {
                "id": chunk["id"],
                "topic": chunk["topic"],
                "text": chunk["text"],
                "vector": vector,
            }
            for chunk, vector in zip(chunks, vectors)
        ],
    }

    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False)

    print(f"Wrote {len(chunks)} embeddings (dim={output['dim']}) to {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
