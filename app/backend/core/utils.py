# app/backend/core/utils.py
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
