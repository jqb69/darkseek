#app/backend/api/llm_api
#app.backend.config.llm_api
from langchain_community.llms import HuggingFaceHub
from langchain.prompts import PromptTemplate
from langchain.chains import LLMChain
from app.backend.core.config import LLM_CONFIGS, DEFAULT_LLM, STREAMING_CHUNK_SIZE
from typing import List, Dict, AsyncGenerator
import httpx
import json
import logging
import os

logger = logging.getLogger(__name__)

class LLMAPI:
    def __init__(self, default_llm=DEFAULT_LLM):
        self.llms = LLM_CONFIGS  # Use the configurations from config.py
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
        # Set the LLM to use (default if none provided)
        llm_name = llm_name or self.default_llm
        llm = self._get_llm(llm_name)  # Retained for potential non-streaming use elsewhere
        prompt = self.generate_prompt(query, search_results)

         # Retrieve the Inference Endpoint URL dynamically
        tgi_server_url = self.llms[llm_name]["tgi_server_url"]

        # Fetch the API token from environment variables
        hf_token = os.getenv("HUGGINGFACEHUB_API_TOKEN")
        if not hf_token:
            logger.error("HUGGINGFACEHUB_API_TOKEN not set in environment.")
            yield {"type": "error", "message": "API token is missing."}
            return

        try:
            async with httpx.AsyncClient() as client:
                response = await client.post(
                    tgi_server_url,
                    json={"inputs": prompt, "parameters": {"max_new_tokens": 512}},
                    headers={"Authorization": f"Bearer {hf_token}"},
                    timeout=None,
                    stream=True
                )
                response.raise_for_status()
    
                # Process the streamed Server-Sent Events (SSE) response
                async for line in response.aiter_lines():
                    if line.strip():  # Skip empty lines
                        try:
                            data = json.loads(line)
                            if "token" in data:
                                yield data["token"]["text"]  # Adjust based on actual response structure
                            elif "error" in data:
                                yield {"type": "error", "message": data["error"]}
                        except json.JSONDecodeError:
                            logger.warning(f"Failed to parse line: {line}")
                            continue
    
        except httpx.HTTPStatusError as e:
            logger.error(f"HTTP error: {e.response.status_code} - {e.response.text}", exc_info=True)
            yield {"type": "error", "message": f"Server error: {e.response.status_code}"}
        except httpx.RequestError as e:
            logger.error(f"Network error: {e}", exc_info=True)
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
