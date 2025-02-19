# app/backend/core/search_manager.py (Modified to handle the search API changes)
class SearchManager:
    def __init__(self, cache_manager=cache_manager, search_api=search_api, llm_api=llm_api):
        self.cache_manager = cache_manager
        self.search_api = search_api
        self.llm_api = llm_api
        self.db_semaphore = Semaphore(10)  # Limit concurrent DB writes

    async def get_streaming_response(self, query: str, session_id: str, search_enabled: bool = True,
                                     llm_name: str = None,
                                     db: Session = next(get_db())) -> AsyncGenerator[Dict, None]:
        chat_count_key = f"chat_count:{session_id}"
        chat_count = self.cache_manager.redis_client.incr(chat_count_key)
        self.cache_manager.redis_client.expire(chat_count_key, 3600)

        if chat_count > MAX_CHATS:
            yield {"error": "Chat limit reached for this session."}
            return

        cached_response = self.cache_manager.get_cached_response(query)
        if cached_response:
            yield {"type": "full_response", "content": cached_response['response'], "search_results": cached_response['search_results'], "llm_used": cached_response['llm_used']}
            return

        search_results = []
        if search_enabled:
            async for result_chunk in self.search_api.search(query):
                yield result_chunk
                if result_chunk.get('type') == 'search_results':
                    search_results.extend(result_chunk.get('results', []))

        try:
            async for chunk in self.llm_api.stream_query_llm(query, search_results, llm_name):
                yield {"type": "llm_response", "content": chunk}

            full_response = await self.llm_api.query_llm(query, search_results, llm_name)
            self.cache_manager.cache_response(query, full_response, llm_name, search_results)
            asyncio.create_task(self.save_query_to_db(query, full_response, search_results, llm_name, db))

        except Exception as e:
            logger.error(f"Error querying LLM: {e}", exc_info=True)
            yield {"error": f"Error querying LLM: {e}"}
            return

    async def save_query_to_db(self, query, llm_response, search_results, llm_name, db: Session):
        async with self.db_semaphore:
            try:
                existing_query = db.query(UserQuery).filter(UserQuery.query_text == query).first()
                if existing_query:
                    logger.info(f"Query already exists in DB: {query}")
                    return

search_manager = SearchManager()
