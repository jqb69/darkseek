# app/backend/api/search2_api.py

import httpx
from app.backend.core.config import GOOGLE_API_KEY, GOOGLE_CSE_ID, DUCKDUCKGO_API_KEY, MAX_QUERY
from app.backend.core.utils import sanitize_query, add_results, validate_query  # Import validate_query
from typing import List, Dict, Optional, Union, AsyncGenerator
import asyncio
import logging
from tenacity import retry, stop_after_attempt, wait_fixed, retry_if_exception_type, before_sleep_log

import time

logger = logging.getLogger(__name__)



def get_retry_wait_strategy():
    def wait_with_retry_after(retry_state):
        if retry_state.outcome.failed:
            exc = retry_state.outcome.exception()
            if isinstance(exc, httpx.HTTPStatusError):
                retry_after = exc.response.headers.get("Retry-After")
                if retry_after and retry_after.isdigit():
                    secs = int(retry_after)
                    logger.info(f"Respecting Retry-After: {secs}s")
                    return secs
        return wait_fixed(2)(retry_state)
    return wait_with_retry_after

class SearchAPI:
    def __init__(self, google_api_key=GOOGLE_API_KEY, google_cse_id=GOOGLE_CSE_ID,
                 duckduckgo_api_key=DUCKDUCKGO_API_KEY):
        self.google_api_key = google_api_key
        self.google_cse_id = google_cse_id
        self.duckduckgo_api_key = duckduckgo_api_key

    def _get_retry_after(self, response: httpx.Response) -> int:
        """Checks for Retry-After header and returns seconds to wait."""
        retry_after = response.headers.get("Retry-After")
        if retry_after:
            try:
                return int(retry_after)  # Seconds
            except ValueError:
                # Handle date-based Retry-After (more complex, out of scope for now)
                return 0
        return 0

    
    @retry(
      stop=stop_after_attempt(3),
      wait=get_retry_wait_strategy(),
      retry=retry_if_exception_type((httpx.RequestError, httpx.HTTPStatusError)),
      before_sleep=before_sleep_log(logger, logging.WARNING),
      
    )
    async def google_search(self, query: str) -> List[Dict[str, str]]:
        if not self.google_api_key or not self.google_cse_id:
          return []  # Or raise exception.
        url = "https://www.googleapis.com/customsearch/v1"
        params = {"key": self.google_api_key, "cx": self.google_cse_id, "q": query}
        try:
            async with httpx.AsyncClient() as client:
                response = await client.get(url, params=params)
                response.raise_for_status()
                data = response.json()
                return [{"title": item["title"], "link": item["link"], "snippet": item["snippet"]}
                        for item in data.get("items", [])]
        except httpx.HTTPError as e:
            logger.error(f"HTTP error during Google search: {e}", exc_info=True)
            return [] # Return empty list
        except httpx.RequestError as e:
            logger.error(f"Request error during Google search: {e}", exc_info=True)
            return []

    @retry(
      stop=stop_after_attempt(3),
      wait=get_retry_wait_strategy(),
      retry=retry_if_exception_type((httpx.RequestError, httpx.HTTPStatusError)),
      before_sleep=before_sleep_log(logger, logging.WARNING),
      
    )
    async def duckduckgo_search(self, query: str) -> List[Dict[str, str]]:
        url = "https://api.duckduckgo.com/"
        params = {"q": query, "format": "json", "t": "DarkSeek"}
        try:
            async with httpx.AsyncClient() as client:
                response = await client.get(url, params=params)
                response.raise_for_status()
                data = response.json()
                return [
                    {"title": result.get('Text', ''), "link": result.get('FirstURL', ''), "snippet": result.get('Text', '')}
                    for result in data.get('RelatedTopics', []) if 'Text' in result and 'FirstURL' in result
                ]
        except httpx.HTTPError as e:
            logger.error(f"HTTP error during DuckDuckGo search: {e}", exc_info=True)
            return []
        except httpx.RequestError as e:
            logger.error(f"Request error during DuckDuckGo search: {e}", exc_info=True)
            return []

    async def combinedsearch(self, query: str, num_limit: int) -> AsyncGenerator[Dict[str, str], None]:
        """
        Combines search results from Google and DuckDuckGo, limited by num_limit.
        Yields results incrementally to avoid memory issues.
        """
        sanitized_query = validate_query(query)
        if not sanitized_query:
            logger.error("Invalid query provided.")
            yield {"type": "error", "content": "Invalid query. Please provide a valid search term."}
            return

        # Fetch results from both engines concurrently
        google_results, duckduckgo_results = await asyncio.gather(
            self.google_search(sanitized_query),
            self.duckduckgo_search(sanitized_query),
            return_exceptions=True
        )

        seen_links = set()

        # Yield Google results first
        if isinstance(google_results, list):
            for result in google_results:
                if result['link'] not in seen_links:
                    seen_links.add(result['link'])
                    yield {"type": "search_results", "results": [result]}
                    if len(seen_links) >= num_limit:
                        return

        # Yield DuckDuckGo results next
        if isinstance(duckduckgo_results, list):
            for result in duckduckgo_results:
                if result['link'] not in seen_links:
                    seen_links.add(result['link'])
                    yield {"type": "search_results", "results": [result]}
                    if len(seen_links) >= num_limit:
                        return

    async def search(self, query: str) -> AsyncGenerator[Dict, None]:
        """
        Updated search method to use combinedsearch with MAX_QUERY as the limit.
        Yields results as they are processed.
        """
        try:
            async for result in self.combinedsearch(query, num_limit=MAX_QUERY):
                yield result
        except Exception as e:
            logger.error(f"Combined search failed: {e}")
            yield {"type": "error", "content": "Search failed. Please try again later."}

search_api = SearchAPI()
