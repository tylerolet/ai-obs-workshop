"""Lightweight mock server — emulates vLLM and Llama-Guard for local development.

Returns canned responses:
- POST /v1/chat/completions → OpenAI-compatible chat completion
- GET  /health              → {"status": "ok"}
"""

import json
import os
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn

PORT = int(os.environ.get("PORT", "8000"))
MOCK_ROLE = os.environ.get("MOCK_ROLE", "vllm")

# Problem injection: slow safety model responses to exhaust safety-gateway thread pool
SAFETY_LATENCY_MS = int(os.environ.get("SAFETY_LATENCY_MS", "0"))

SAFETY_RESPONSE = "safe"
INFERENCE_RESPONSE = (
    "I'm a local development mock. In production, this response would come "
    "from a real LLM running on vLLM."
)


class MockHandler(BaseHTTPRequestHandler):

    def do_GET(self):
        if self.path == "/health":
            self._json_response(200, {"status": "ok"})
        else:
            self._json_response(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/v1/chat/completions":
            content_length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(content_length)) if content_length else {}

            model = body.get("model", "mock")
            messages = body.get("messages", [])

            prompt_parts = [msg.get("content", "") for msg in messages if msg.get("content")]
            prompt_text = "\n".join(prompt_parts).strip()
            prompt_tokens = max(1, len(prompt_text) // 4)

            is_safety = "llama-guard" in model.lower() or MOCK_ROLE == "safety-model"

            if is_safety:
                if SAFETY_LATENCY_MS > 0:
                    # Problem scenario: slow safety model — saturates safety-gateway thread pool
                    time.sleep(SAFETY_LATENCY_MS / 1000.0)
                reply = SAFETY_RESPONSE
                completion_tokens = 1
            else:
                # Simulate compute latency for longer prompts
                prompt_len = len(prompt_text)
                if prompt_len > 800:
                    delay_ms = min(4000, (prompt_len - 800) * 10)
                    time.sleep(delay_ms / 1000.0)
                reply = INFERENCE_RESPONSE
                completion_tokens = 25

            self._json_response(200, {
                "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
                "object": "chat.completion",
                "created": int(time.time()),
                "model": model,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": reply},
                    "finish_reason": "stop",
                }],
                "usage": {
                    "prompt_tokens": prompt_tokens,
                    "completion_tokens": completion_tokens,
                    "total_tokens": prompt_tokens + completion_tokens,
                },
            })
        else:
            self._json_response(404, {"error": "not found"})

    def _json_response(self, status, data):
        payload = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, format, *args):
        pass


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    server = ThreadedHTTPServer(("0.0.0.0", PORT), MockHandler)
    print(f"mock-server ({MOCK_ROLE}) listening on :{PORT}", flush=True)
    server.serve_forever()
