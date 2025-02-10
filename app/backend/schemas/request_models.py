# app/backend/schemas/request_models.py (THIS WAS MISSING)
from pydantic import BaseModel
from typing import Optional

class QueryRequest(BaseModel):
    query: str
    session_id: str
    search_enabled: Optional[bool] = True
    llm_name: Optional[str] = None
