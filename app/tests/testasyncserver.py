import unittest
from unittest.mock import AsyncMock, patch
from app.backend.api.mqtt_api import AsyncMQTTServe

class TestAsyncMQTTServer(unittest.IsolatedAsyncioTestCase):
    async def test_process_message(self):
        mqtt_server = AsyncMQTTServer()
        message = {
            "query": "What is AI?",
            "session_id": "1234",
            "search_enabled": True,
            "llm_name": "GPT-4"
        }
        response = await mqtt_server.process_message(message)
        self.assertIn("content", response)

if __name__ == "__main__":
    unittest.main()
