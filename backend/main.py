"""SentiNL Backend - FastAPI server for scam detection."""

import json
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

try:
    from ddgs import DDGS
except ImportError:
    DDGS = None


app = FastAPI(title="SentiNL Backend", version="1.0.0")

# Serve the static folder so the mobile app can download the model
import os

os.makedirs("static", exist_ok=True)
app.mount("/static", StaticFiles(directory="static"), name="static")

BLACKLIST_PATH = Path(__file__).parent / "blacklist.json"


def load_blacklist() -> list[dict[str, Any]]:
    """Load blacklist rules from JSON file."""
    if not BLACKLIST_PATH.exists():
        return []
    with open(BLACKLIST_PATH, "r") as f:
        return json.load(f)


def get_current_version() -> int:
    """Get current blacklist version based on rules count."""
    blacklist = load_blacklist()
    return len(blacklist)


class VerifyRequest(BaseModel):
    text: str


class VerifyResponse(BaseModel):
    summary: str
    results: list[dict[str, str]]


def search_web(query: str, max_results: int = 3) -> list[dict[str, str]]:
    """Search the web using DuckDuckGo, and instantly fallback to Google if rate-limited."""
    results = []
    
    # Attempt 1: DuckDuckGo
    if DDGS is not None:
        try:
            ddgs = DDGS(timeout=10)
            for r in ddgs.text(query, max_results=max_results):
                results.append({
                    "title": r.get("title", ""),
                    "body": r.get("body", ""),
                    "href": r.get("href", ""),
                })
            if results:  # If DDG successfully bypassed the bot filter, return the results
                return results
        except Exception as e:
            print(f"DuckDuckGo search failed/rate-limited: {e}")

    # Attempt 2: Google Search Fallback
    try:
        from googlesearch import search
        print("Falling back to Google Search...")
        for r in search(query, num_results=max_results, advanced=True):
            results.append({
                "title": r.title,
                "body": r.description,
                "href": r.url,
            })
        if results:
            return results
    except ImportError:
        pass
    except Exception as e:
        print(f"Google Search fallback failed: {e}")

    # If both block our server IP, return a controlled error message.
    return [{"title": "Search error", "body": "Both DuckDuckGo and Google rate-limited the backend IP. Try again later."}]


def summarize_results(results: list[dict[str, str]]) -> str:
    """Summarize web search results for context."""
    if not results:
        return "No results found."

    summary_parts = []
    for r in results[:3]:
        title = r.get("title", "")
        body = r.get("body", "")
        if title or body:
            summary_parts.append(f"- {title}: {body[:100]}...")

    if not summary_parts:
        return "Could not retrieve search context."

    return " | ".join(summary_parts)


@app.get("/api/db-updates")
def get_db_updates(version: int = Query(0, ge=0)):
    """Return blacklist updates if client version is older than current."""
    current_version = get_current_version()
    blacklist = load_blacklist()

    if version < current_version:
        return {"version": current_version, "blacklist": blacklist, "has_update": True}

    return {"version": current_version, "blacklist": [], "has_update": False}


@app.post("/api/verify", response_model=VerifyResponse)
def verify_text(request: VerifyRequest):
    if not request.text or not request.text.strip():
        raise HTTPException(status_code=400, detail="Text cannot be empty")

    import re
    urls = re.findall(r'http[s]?://(?:[a-zA-Z]|[0-9]|[$-_@.&+]|[!*\(\),]|(?:%[0-9a-fA-F][0-9a-fA-F]))+', request.text)
    if urls:
        search_query = f'"{urls[0]}" scam or review'
    else:
        clean_text = request.text.replace('\n', ' ')
        search_query = clean_text[:100] + " scam"

    results = search_web(search_query)
    summary = summarize_results(results)
    return VerifyResponse(summary=summary, results=results)


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
