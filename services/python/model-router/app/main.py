"""Model Router — gRPC service that routes inference requests to the inference pool.

Exposes a streaming gRPC endpoint that:
1. Receives a RouteInferenceRequest
2. Forwards to the inference-pool HTTP endpoint (OpenAI-compatible)
3. Streams tokens back as RouteInferenceResponse messages
"""

import os
import time
import random
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

import model_router_pb2
import model_router_pb2_grpc

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger(__name__)

GRPC_PORT = int(os.environ.get("GRPC_PORT", "50052"))
INFERENCE_POOL_ADDR = os.environ.get("INFERENCE_POOL_ADDR", "inference-pool:8081")
OTEL_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
SERVICE_NAME = os.environ.get("OTEL_SERVICE_NAME", "model-router")
STREAM_RESPONSES = os.environ.get("STREAM_RESPONSES", "true").lower() == "true"

# --- Problem injection knobs (set via chaos-config ConfigMap) ---
# Adds artificial delay before inference begins (simulates GPU throttling / model overload)
INJECT_LATENCY_MS = int(os.environ.get("INJECT_LATENCY_MS", "0"))
# Fraction of requests [0.0–1.0] that fail with an internal error
ERROR_RATE = float(os.environ.get("ERROR_RATE", "0.0"))

# Pool configuration (single pool in codespace mode)
POOL_CONFIG = {
    "pool-a-codespace": {
        "name": "pool-a-codespace",
        "endpoint": f"http://{INFERENCE_POOL_ADDR}",
        "model": "qwen2.5-0.5b-instruct",
        "type": "large",
        "region": "codespace",
    }
}


def setup_telemetry():
    resource = Resource.create({"service.name": SERVICE_NAME})
    provider = TracerProvider(resource=resource)
    exporter = OTLPSpanExporter(endpoint=OTEL_ENDPOINT, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)
    GrpcInstrumentorServer().instrument()
    OpenAIInstrumentor().instrument()


class ModelRouterServicer(model_router_pb2_grpc.ModelRouterServiceServicer):

    def __init__(self):
        self.tracer = trace.get_tracer(__name__)
        pool = list(POOL_CONFIG.values())[0]
        self.openai_client = openai.OpenAI(
            base_url=f"{pool['endpoint']}/v1",
            api_key="not-needed",
        )

    def RouteInference(self, request, context):
        with self.tracer.start_as_current_span("model_router.route") as span:
            span.set_attribute("gen_ai.request.model", request.model_id)
            span.set_attribute("gen_ai.request.max_tokens", request.max_tokens)
            span.set_attribute("gen_ai.request.temperature", request.temperature)

            pool = list(POOL_CONFIG.values())[0]
            span.set_attribute("model_router.pool_selected", pool["name"])

            # Problem scenario: random error injection
            if ERROR_RATE > 0.0 and random.random() < ERROR_RATE:
                span.set_attribute("model_router.error_injected", True)
                logger.warning("Error injection triggered (rate=%.2f)", ERROR_RATE)
                context.abort(grpc.StatusCode.INTERNAL, "inference backend unavailable (injected)")
                return

            # Problem scenario: artificial latency before inference (simulates model overload)
            if INJECT_LATENCY_MS > 0:
                span.set_attribute("model_router.injected_latency_ms", INJECT_LATENCY_MS)
                logger.warning("Latency injection: sleeping %dms before inference", INJECT_LATENCY_MS)
                time.sleep(INJECT_LATENCY_MS / 1000.0)

            logger.info(
                "Routing request model=%s tenant=%s → pool=%s",
                request.model_id, request.tenant_id, pool["name"]
            )

            messages = [
                {"role": "system", "content": "You are a helpful assistant. Always respond in English."},
                {"role": "user", "content": request.prompt},
            ]
            start = time.time()

            try:
                if STREAM_RESPONSES:
                    stream = self.openai_client.chat.completions.create(
                        model=pool["model"],
                        messages=messages,
                        max_tokens=request.max_tokens or 256,
                        temperature=request.temperature or 0.7,
                        stream=True,
                    )
                    for chunk in stream:
                        content = chunk.choices[0].delta.content or ""
                        if content:
                            yield model_router_pb2.RouteInferenceResponse(
                                text=content,
                                pool_name=pool["name"],
                            )
                else:
                    response = self.openai_client.chat.completions.create(
                        model=pool["model"],
                        messages=messages,
                        max_tokens=request.max_tokens or 256,
                        temperature=request.temperature or 0.7,
                        stream=False,
                    )
                    content = response.choices[0].message.content
                    usage = response.usage

                    yield model_router_pb2.RouteInferenceResponse(
                        text=content,
                        tokens_generated=usage.completion_tokens if usage else 0,
                        pool_name=pool["name"],
                        finish_reason="stop",
                    )

            except Exception as e:
                logger.error("Inference error: %s", e)
                span.record_exception(e)
                context.abort(grpc.StatusCode.INTERNAL, str(e))


def serve():
    setup_telemetry()
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    model_router_pb2_grpc.add_ModelRouterServiceServicer_to_server(
        ModelRouterServicer(), server
    )
    server.add_insecure_port(f"[::]:{GRPC_PORT}")
    server.start()
    logger.info("Model router listening on port %d", GRPC_PORT)
    server.wait_for_termination()


if __name__ == "__main__":
    serve()
