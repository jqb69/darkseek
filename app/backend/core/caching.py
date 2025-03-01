# app/backend/core/caching.py
import redis
import json
from app.backend.core.config import REDIS_URL
from app.backend.core.utils import generate_query_hash

class CacheManager:
    def __init__(self, redis_url=REDIS_URL):
        self.redis_client = redis.Redis.from_url(redis_url)

    def get_cached_response(self, query):
        """Retrieves a cached response for a given query."""
        query_hash = generate_query_hash(query)
        cached_data = self.redis_client.get(query_hash)
        if cached_data:
            return json.loads(cached_data)
        return None

    def cache_response(self, query, response_data, llm_used, search_results):
        """Caches a response for a given query."""
        query_hash = generate_query_hash(query)
        data_to_cache = {
            'response': response_data,
            'llm_used': llm_used,
            'search_results': search_results
        }
        # Cache for a reasonable amount of time (e.g., 1 hour)
        self.redis_client.setex(query_hash, 3600, json.dumps(data_to_cache))

    def enqueue_query(self, query):
        """Adds a query to the processing queue."""
        self.redis_client.rpush("query_queue", query)  # Use a list as a queue

    def dequeue_query(self):
        """Retrieves and removes the next query from the queue."""
        query = self.redis_client.lpop("query_queue")
        return query.decode('utf-8') if query else None

cache_manager = CacheManager()
