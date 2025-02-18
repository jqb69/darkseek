#app/backend/api/llm_api
from langchain_community.llms import HuggingFaceHub
from langchain.prompts import PromptTemplate
from langchain.chains import LLMChain
from ..core.config import DEFAULT_LLM, STREAMING_CHUNK_SIZE,TGI_SERVER_URL
from typing import List, Dict, AsyncGenerator
import httpx
import json
import logging
import os

logger = logging.getLogger(__name__)

class LLMAPI:
    def __init__(self, default_llm=DEFAULT_LLM):
        self.llms = {
            "gemma_flash_2.0": {
                "repo_id": "google/gemma-1.1-2b-it",
                "config": {"max_new_tokens": 512, "temperature": 0.7, "repetition_penalty": 1.2}
            },
            "deepseek_r1_llm": {
                "repo_id": "deepseek-ai/deepseek-coder-1.3b-instruct",
                "config": {"max_new_tokens": 512, "temperature": 0.6}
            },
            "qwen_2.5_max": {
                "repo_id": "Qwen/Qwen1.5-72B-Chat",
                "config": {"max_new_tokens": 512, "temperature": 0.8}
            }
        }
        self.default_llm = default_llm
        self._llm_cache = {}
        self.chunk_size = int(os.getenv("STREAMING_CHUNK_SIZE", STREAMING_CHUNK_SIZE))

    def _get_llm(self, llm_name: str):
        if llm_name not in self.llms:
            logger.error(f"Invalid LLM name: {llm_name}")
            raise ValueError(f"LLM '{llm_name}' is not supported.")
        if llm_name not in self._llm_cache:
            llm_config = self.llms[llm_name]
            self._llm_cache[llm_name] = HuggingFaceHub(
                repo_id=llm_config["repo_id"], model_kwargs=llm_config["config"]
            )
        return self._llm_cache[llm_name]

    def generate_prompt(self, query: str, search_results: List[Dict[str, str]]) -> str:
        context = "\n".join(
            f"Source {i + 1}: {result['title']} - {result['snippet']}"
            for i, result in enumerate(search_results)
        )
        template = """You are a helpful AI assistant that provides concise answers based on the given context.
        Context: {context}
        Query: {query}
        Concise Answer:"""
        return PromptTemplate(input_variables=["query", "context"], template=template).format(
            query=query, context=context
        )

    async def stream_query_llm(self, query: str, search_results: List[Dict[str, str]], llm_name: str = None) -> AsyncGenerator[str, None]:
        llm_name = llm_name or self.default_llm
        llm = self._get_llm(llm_name)
        prompt = self.generate_prompt(query, search_results)

        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    self.tgi_server_url,  # Use the imported TGI_SERVER_URL
                    json={"prompt": prompt, "max_tokens": 512},
                    timeout=None
                )
                response.raise_for_status()
                data = response.json()

                
                for token in data.get("tokens", []):
                    yield {"type": "token", "content": token}  # Yield structured responses
        except httpx.RequestError as e:
            logger.error(f"HTTP request error: {e}", exc_info=True)
            yield {"type": "error", "message": "Failed to connect to the LLM server."}
        except Exception as e:
            logger.error(f"Unexpected error: {e}", exc_info=True)
            yield {"type": "error", "message": "An unexpected error occurred while streaming."}

    async def query_llm(self, query: str, search_results: List[Dict[str, str]], llm_name: str = None) -> str:
        llm_name = llm_name or self.default_llm
        llm = self._get_llm(llm_name)

        prompt = self.generate_prompt(query, search_results)
        llm_chain = LLMChain(prompt=PromptTemplate.from_template(prompt), llm=llm)

        try:
            response = await llm_chain.ainvoke({})
            return response['text'].strip()
        except Exception as e:
            logger.error(f"Error querying LLM: {e}", exc_info=True)
            return "An error occurred while processing your request."

llm_api = LLMAPI()
