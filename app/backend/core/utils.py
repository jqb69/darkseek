# app/backend/core/utils.py
from typing import Optional
import re
import hashlib

def sanitize_query(query):
    """Sanitizes and normalizes a user query."""
    query = query.strip().lower()
    query = re.sub(r'\s+', ' ', query)  # Replace multiple spaces with single space
    return query

def generate_query_hash(query):
    """Generates a unique hash for a query (for caching)."""
    return hashlib.md5(query.encode('utf-8')).hexdigest()

def add_results(combined_results: list, seen_links: set, results: list, num_limit: int) -> bool:
    """
    Adds search results to the combined_results list while avoiding duplicates.
    Stops adding if the number of results reaches num_limit.
    
    Args:
        combined_results (list): The list to which results are added.
        seen_links (set): A set of links already added to avoid duplicates.
        results (list): The list of results to be added.
        num_limit (int): The maximum number of results allowed.

    Returns:
        bool: True if the limit is reached, False otherwise.
    """
    for result in results:
        if result['link'] not in seen_links:
            combined_results.append(result)
            seen_links.add(result['link'])
            if len(combined_results) >= num_limit:
                return True  # Stop adding if limit reached
    return False

def validate_query(query: str) -> Optional[str]:
    """
    Validates and sanitizes the query.
    Returns None if the query is invalid, otherwise returns the sanitized query.
    """
    query = sanitize_query(query)
    if not query:
        return None  # Empty query is invalid
    return query
