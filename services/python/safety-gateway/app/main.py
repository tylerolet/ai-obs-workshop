"""Safety Gateway — gRPC service for content safety classification.

Receives text, calls the safety model (mock in codespace mode),
and returns a classification result.
"""

import os
import time
import logging
from concurrent import futures

import grpc
import openai

from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.grpc import GrpcInstrumentorServer
from opentelemetry.instrumentation.openai import OpenAIInstrumentor
from opentelemetry.sdk.resources import Resource

import safety_pb2
import safety_pb2_grpc

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

GRPC_PORT = int(os.environ.get("GRPC_PORT", "50053"))
SAFETY_MODEL_URL = os.environ.get("SAFETY_MODEL_URL", "http://mock-safety:8000")
OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
SERVICE_NAME = os.environ.get("OTEL_SERVICE_NAME", "safety-gateway")


def setup_telemetry():
    resource = Resource.create({"service.name": SERVICE_NAME})
    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    GrpcInstrumentorServer().instrument()
    OpenAIInstrumentor().instrument()


class SafetyServicer(safety_pb2_grpc.SafetyServiceServicer):

    def __init__(self):
        self.tracer = trace.get_tracer(__name__)
        self.openai_client = openai.OpenAI(
            base_url=f"{SAFETY_MODEL_URL}/v1",
            api_key="not-needed",
        )

    def Classify(self, request, context):
        with self.tracer.start_as_current_span("safety.classify") as span:
            span.set_attribute("safety.text_length", len(request.text))
            span.set_attribute("safety.conversation_id", request.conversation_id)
            span.set_attribute("safety.tenant_id", request.tenant_id)

            start = time.time()

            try:
                response = self.openai_client.chat.completions.create(
                    model="llama-guard",
                    messages=[{"role": "user", "content": request.text}],
                    max_tokens=10,
                )
                content = response.choices[0].message.content.strip().lower()
                is_safe = "unsafe" not in content

                latency_ms = int((time.time() - start) * 1000)

                span.set_attribute("safety.result", "safe" if is_safe else "unsafe")
                span.set_attribute("safety.latency_ms", latency_ms)

                logger.info(
                    "Safety classification: safe=%s latency=%dms text_len=%d",
                    is_safe, latency_ms, len(request.text)
                )

                return safety_pb2.ClassifyResponse(
                    safe=is_safe,
                    category="none" if is_safe else "harmful_content",
                    confidence=0.95,
                    latency_ms=latency_ms,
                )

            except Exception as e:
                logger.error("Safety model call failed: %s", e)
                span.record_exception(e)
                # Fail-open: allow request if safety model is down
                return safety_pb2.ClassifyResponse(
                    safe=True,
                    category="error_failopen",
                    confidence=0.0,
                    latency_ms=int((time.time() - start) * 1000),
                )


def serve():
    setup_telemetry()
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    safety_pb2_grpc.add_SafetyServiceServicer_to_server(SafetyServicer(), server)
    server.add_insecure_port(f"[::]:{GRPC_PORT}")
    server.start()
    logger.info("Safety gateway listening on port %d", GRPC_PORT)
    server.wait_for_termination()


if __name__ == "__main__":
    serve()
