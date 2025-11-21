#app.backend.config.llm_api

from langchain_community.llms import HuggingFaceHub
from langchain_core.prompts import PromptTemplate
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
        self.llms = LLM_CONFIGS
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

    async def _retry_request(self, client, url, payload, headers, retries=3, delay=1):
        for attempt in range(retries):
            try:
                response = await client.post(url, json=payload, headers=headers, timeout=180, stream=True)
                response.raise_for_status()
                return response
            except httpx.RequestError as e:
                logger.warning(f"Attempt {attempt + 1} failed: {e}")
                await asyncio.sleep(delay * (2 ** attempt))
        raise Exception("All retry attempts failed.")

    def _handle_error(self, error_type: str, message: str, status_code: str = "N/A"):
        logger.error(message, exc_info=True)
        return {"type": error_type, "message": message, "status_code": status_code}

    async def stream_query_llm(self, query: str, search_results: List[Dict[str, str]], llm_name: str = None) -> AsyncGenerator[str, None]:
        llm_name = llm_name or self.default_llm
        llm = self._get_llm(llm_name)
        prompt = self.generate_prompt(query, search_results)

        tgi_server_url = self.llms[llm_name]["tgi_server_url"]
        if not tgi_server_url:
            yield self._handle_error("error", f"TGI server URL not configured for LLM: {llm_name}")
            return

        hf_token = os.getenv("HUGGINGFACEHUB_API_TOKEN")
        if not hf_token:
            yield self._handle_error("error", "API token is missing.")
            return

        try:
            async with httpx.AsyncClient() as client:
                response = await self._retry_request(
                    client,
                    tgi_server_url,
                    {"inputs": prompt, "parameters": {"max_new_tokens": 512}},
                    {"Authorization": f"Bearer {hf_token}"}
                )

                partial_results = []
                try:
                    async for line in response.aiter_lines():
                        if line.strip():
                            try:
                                data = json.loads(line)
                                if "token" in data:
                                    token_text = data["token"]["text"]
                                    token_metadata = data["token"].get("metadata", {})
                                    partial_results.append(token_text)
                                    yield {"type": "token", "text": token_text, "metadata": token_metadata}
                                elif "error" in data:
                                    yield self._handle_error("error", data["error"])
                            except json.JSONDecodeError:
                                logger.warning(f"Failed to parse line: {line}")
                                continue
                except Exception as e:
                    logger.error(f"Streaming failed for LLM '{llm_name}' with query '{query}': {e}", exc_info=True)
                    yield self._handle_error("warning", "Streaming failed, providing partial results.")
                    for token in partial_results:
                        yield {"type": "token", "text": token}
                    return

        except httpx.HTTPStatusError as e:
            status_code = getattr(e.response, "status_code", "N/A")
            yield self._handle_error("error", f"Server returned {status_code}", status_code)
        except httpx.RequestError as e:
            status_code = getattr(e.response, "status_code", "N/A")
            yield self._handle_error("error", f"LLM connect failed {status_code}", status_code)
        except Exception as e:
            status_code = getattr(e.response, "status_code", "N/A")
            yield self._handle_error("error", f"An unexpected error occurred while streaming {status_code}", status_code)

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
