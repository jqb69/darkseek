#app/backend/api/search_api.py
from .caching import cache_manager
from ..api.llm_api import llm_api
from ..api.search2.api import search_api
from .database import get_db, UserQuery
from sqlalchemy.orm import Session
from typing import List, Dict, AsyncGenerator
import json
from .config import MAX_CHATS
import asyncio
import logging
from asyncio import Semaphore

logger = logging.getLogger(__name__)

class SearchManager:
    def __init__(self, cache_manager=cache_manager, search_api=search_api, llm_api=llm_api):
        self.cache_manager = cache_manager
        self.search_api = search_api
        self.llm_api = llm_api
        self.db_semaphore = Semaphore(10)  # Limit concurrent DB writes

    async def get_streaming_response(
        self,
        query: str,
        session_id: str,
        search_enabled: bool = True,
        llm_name: str = None,
        db: Session = None  # Injected via Depends
    ) -> AsyncGenerator[Dict, None]:
        if db is None:
            raise ValueError("Database session is required.")

        # Validate chat count
        try:
            chat_count_key = f"chat_count:{session_id}"
            chat_count = self.cache_manager.redis_client.incr(chat_count_key)
            self.cache_manager.redis_client.expire(chat_count_key, 3600)
        except Exception as e:
            logger.error(f"Error managing chat count in Redis: {e}", exc_info=True)
            yield {"error": "Internal server error while managing chat count."}
            return

        if chat_count > MAX_CHATS:
            yield {"error": "Chat limit reached for this session."}
            return

        # Check cache for full response
        try:
            cached_response = self.cache_manager.get_cached_response(query)
            if cached_response:
                yield {
                    "type": "full_response",
                    "content": cached_response['response'],
                    "search_results": cached_response['search_results'],
                    "llm_used": cached_response['llm_used']
                }
                return
        except Exception as e:
            logger.error(f"Error retrieving cached response: {e}", exc_info=True)
            yield {"error": "Internal server error while retrieving cached response."}
            return

        # Perform search if enabled
        search_results = []
        if search_enabled:
            search_cache_key = f"search_results:{query}"
            try:
                cached_search_results = self.cache_manager.redis_client.get(search_cache_key)
                if cached_search_results:
                    try:
                        search_results = json.loads(cached_search_results)
                        logger.info(f"Using cached search results for query: {query}")
                    except json.JSONDecodeError:
                        logger.warning(f"Invalid cached data for query: {query}. Fetching fresh results.")
                        search_results = []
                else:
                    async for result_chunk in self.search_api.search(query):
                        if result_chunk.get('type') == 'search_results':
                            search_results.extend(result_chunk.get('results', []))
                        yield result_chunk  # Stream results to the client
                    try:
                        self.cache_manager.redis_client.setex(search_cache_key, 3600, json.dumps(search_results))
                    except Exception as e:
                        logger.error(f"Error caching search results: {e}", exc_info=True)
            except Exception as e:
                logger.error(f"Error during search: {e}", exc_info=True)
                yield {"error": f"Search failed: {str(e)}"}
                return

        # Stream LLM response
        try:
            async for chunk in self.llm_api.stream_query_llm(query, search_results, llm_name):
                yield {"type": "llm_response", "content": chunk}

            # Get full LLM response and cache it
            try:
                full_response = await self.llm_api.query_llm(query, search_results, llm_name)
                self.cache_manager.cache_response(query, full_response, llm_name, search_results)
            except Exception as e:
                logger.error(f"Error querying LLM: {e}", exc_info=True)
                yield {"error": f"LLM query failed: {str(e)}"}
                return

            # Save query to DB asynchronously
            save_task = asyncio.create_task(self.save_query_to_db(query, full_response, search_results, llm_name, db))
            save_task.add_done_callback(self._handle_save_task_completion)

        except Exception as e:
            logger.error(f"Error streaming LLM response: {e}", exc_info=True)
            yield {"error": f"Error streaming LLM response: {str(e)}"}

    async def save_query_to_db(self, query, llm_response, search_results, llm_name, db: Session):
        async with self.db_semaphore:
            try:
                existing_query = db.query(UserQuery).filter(UserQuery.query_text == query).first()
                if existing_query:
                    logger.info(f"Query already exists in DB: {query}")
                    return

                db_query = UserQuery(
                    query_text=query,
                    response_text=llm_response,
                    search_results=json.dumps(search_results),
                    llm_used=llm_name
                )
                db.add(db_query)
                db.commit()
                db.refresh(db_query)
            except Exception as e:
                logger.error(f"Error saving to DB: {e}", exc_info=True)
                db.rollback()

    def _handle_save_task_completion(self, task):
        """Callback to handle completion of the save_query_to_db task."""
        try:
            task.result()  # Raise any exceptions that occurred during task execution
        except Exception as e:
            logger.error(f"Error during asynchronous DB save: {e}", exc_info=True)

search_manager = SearchManager()
