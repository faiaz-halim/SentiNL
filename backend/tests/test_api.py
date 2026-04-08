"""Tests for SentiNL Backend API."""

import pytest
from unittest.mock import patch, MagicMock
from fastapi.testclient import TestClient
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
from main import app


@pytest.fixture
def client():
    """Create a test client for the FastAPI app."""
    return TestClient(app)


class TestDBUpdates:
    def test_db_updates_returns_200_with_valid_version(self, client):
        response = client.get("/api/db-updates?version=0")
        assert response.status_code == 200

    def test_db_updates_returns_json_with_blacklist_and_version(self, client):
        response = client.get("/api/db-updates?version=0")
        data = response.json()
        assert "version" in data
        assert "blacklist" in data
        assert isinstance(data["blacklist"], list)
        assert data["version"] > 0

    def test_db_updates_no_update_when_client_on_latest(self, client):
        response = client.get("/api/db-updates?version=0")
        data = response.json()
        latest_version = data["version"]

        response = client.get(f"/api/db-updates?version={latest_version}")
        assert response.status_code == 200
        data = response.json()
        if data.get("has_update") is False:
            assert data["version"] == latest_version
        else:
            assert "blacklist" in data


class TestVerify:
    def test_verify_returns_200_with_text_payload(self, client):
        response = client.post("/api/verify", json={"text": "suspicious text"})
        assert response.status_code == 200

    def test_verify_returns_json_with_summary(self, client):
        response = client.post("/api/verify", json={"text": "test scam text"})
        assert response.status_code == 200
        data = response.json()
        assert "summary" in data
        assert "results" in data
        assert isinstance(data["results"], list)

    def test_verify_handles_empty_text(self, client):
        response = client.post("/api/verify", json={"text": ""})
        assert response.status_code in [200, 400]

    def test_verify_handles_search_error(self, client):
        with patch("main.search_ddg") as mock_search:
            mock_search.side_effect = Exception("Search API error")
            response = client.post("/api/verify", json={"text": "test text"})
            assert response.status_code in [200, 500]
