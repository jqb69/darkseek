

# app/backend/api/search_api.py (Error propagation and Retry-After)
import httpx
from ..core.config import GOOGLE_API_KEY, GOOGLE_CSE_ID, DUCKDUCKGO_API_KEY, MAX_QUERY
from ..core.utils import sanitize_query
from typing import List, Dict, Optional, Union, AsyncGenerator
import asyncio
import logging
from tenacity import retry, stop_after_attempt, wait_fixed, retry_if_exception_type, before_sleep_log
import time

logger = logging.getLogger(__name__)

def after_retry_callback(retry_state):
    """Callback function for tenacity, executed after each retry."""
    if retry_state.outcome.failed:
        logger.warning(
            f"Retry attempt {retry_state.attempt_number} failed. Exception: {retry_state.outcome.exception()}"
        )

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

    def _get_wait_strategy(self):
        """Creates a wait strategy for tenacity, incorporating Retry-After."""
        def wait_with_retry_after(retry_state):
            if retry_state.outcome.failed:
                exception = retry_state.outcome.exception()
                if isinstance(exception, httpx.HTTPStatusError) and exception.response:
                    retry_after = self._get_retry_after(exception.response)
                    if retry_after > 0:
                        logger.info(f"Retrying after {retry_after} seconds (Retry-After header)")
                        return retry_after
            return wait_fixed(2)(retry_state)  # Default to waiting 2 seconds
        return wait_with_retry_after

    @retry(
      stop=stop_after_attempt(3),
      wait=_get_wait_strategy(),
      retry=retry_if_exception_type((httpx.RequestError, httpx.HTTPStatusError)),
      before_sleep=before_sleep_log(logger, logging.WARNING),
      after=after_retry_callback
    )
    async def google_search(self, query: str) -> List[Dict[str, str]]:
        # ... (rest of the google_search method remains the same as before the erroneous edit) ...
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
      wait=_get_wait_strategy(),
      retry=retry_if_exception_type((httpx.RequestError, httpx.HTTPStatusError)),
      before_sleep=before_sleep_log(logger, logging.WARNING),
      after=after_retry_callback
    )
    async def duckduckgo_search(self, query: str) -> List[Dict[str, str]]:
        # ... (rest of the duckduckgo_search method remains the same) ...
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
            logger.error(f"Request error during google search: {e}", exc_info=True)
            return []
    async def search(self, query: str) -> AsyncGenerator[Dict, None]:  # Now an async generator
        sanitized_query = sanitize_query(query)

        google_results, duckduckgo_results = await asyncio.gather(
            self.google_search(sanitized_query),
            self.duckduckgo_search(sanitized_query),
            return_exceptions=True  # Handle individual exceptions
        )

        # Handle Google results and errors
        if isinstance(google_results, list):
            for result in google_results:
                yield {"type": "search_results", "results": [result]}  # Yield individual results
        elif isinstance(google_results, Exception):
            logger.error(f"Google search failed: {google_results}")
            yield {"type": "error", "content": "Google search failed. Please try again later."}

        # Handle DuckDuckGo results and errors
        if isinstance(duckduckgo_results, list):
            for result in duckduckgo_results:
                yield {"type": "search_results", "results": [result]}  # Yield individual results
        elif isinstance(duckduckgo_results, Exception):
            logger.error(f"DuckDuckGo search failed: {duckduckgo_results}")
            yield {"type": "error", "content": "DuckDuckGo search failed. Please try again later."}


search_api = SearchAPI()
