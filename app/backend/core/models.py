# app/backend/core/models.py
from sqlalchemy import create_engine, Column, Integer, String, DateTime, Text
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker
from .config import DATABASE_URL
import datetime
from .database import Base # Import Base from database.py

class UserQuery(Base):
    __tablename__ = "user_queries"

    id = Column(Integer, primary_key=True, index=True)
    query_text = Column(String, index=True)
    timestamp = Column(DateTime, default=datetime.datetime.utcnow)
    response_text = Column(Text)
    search_results = Column(Text)  # Store as JSON string
    llm_used = Column(String)
