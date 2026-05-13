"""Prometheus + OTel + structlog wiring.

Single source of truth for the metric/span/log namespace.
"""
from __future__ import annotations

import logging
import os
import sys

import structlog
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import Counter, Gauge, Histogram

# ── Prometheus metrics ────────────────────────────────────────
INFERENCE_REQUESTS = Counter(
    "inference_requests_total",
    "Total inference requests",
    ["model", "status"],
)
INFERENCE_LATENCY = Histogram(
    "inference_latency_seconds",
    "Inference end-to-end latency",
    ["model"],
    buckets=(0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0),
)
INFERENCE_ACTIVE = Gauge(
    "inference_active_gauge",
    "In-flight inference requests",
)
INFERENCE_TOKENS = Counter(
    "inference_tokens_total",
    "Tokens processed (input/output)",
    ["model", "direction"],
)
INFERENCE_QUALITY = Gauge(
    "inference_quality_score",
    "Latest eval-as-metric quality score [0,1]",
    ["model"],
)
GPU_UTIL = Gauge(
    "gpu_utilization_percent",
    "Simulated GPU utilization [0,100]",
)

tracer = trace.get_tracer(__name__)


def setup_otel() -> None:
    """Configure OTLP trace export + FastAPI auto-instrumentation."""
    resource = Resource.create(
        {
            "service.name": os.getenv("OTEL_SERVICE_NAME", "inference-api"),
            "service.namespace": "aicb",
            "deployment.environment": os.getenv(
                "DEPLOY_ENV",
                "lab",
            ),
        }
    )
    provider = TracerProvider(resource=resource)
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector:4317")
    provider.add_span_processor(
        BatchSpanProcessor(OTLPSpanExporter(endpoint=endpoint, insecure=True))
    )
    trace.set_tracer_provider(provider)

    # OTel log export: bridge structlog → OTLP → Loki
    from opentelemetry._logs import set_logger_provider
    from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
    from opentelemetry.sdk._logs import LoggerProvider
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry.sdk.resources import Resource as LogResource

    log_endpoint = os.getenv("OTEL_EXPORTER_OTLP_LOG_ENDPOINT", "http://otel-collector:4317")
    log_resource = LogResource.create({
        "service.name": os.getenv("OTEL_SERVICE_NAME", "inference-api"),
        "service.namespace": "aicb",
    })
    log_provider = LoggerProvider(resource=log_resource)
    log_provider.add_log_record_processor(
        BatchLogRecordProcessor(OTLPLogExporter(endpoint=log_endpoint, insecure=True))
    )
    set_logger_provider(log_provider)

    # Auto-instrument FastAPI handlers (creates server spans for every route)
    from fastapi import FastAPI  # local import: only needed at setup

    FastAPIInstrumentor().instrument()
    _configure_logging()


def _configure_logging() -> None:
    from opentelemetry.instrumentation.logging import LoggingInstrumentor

    LoggingInstrumentor().instrument()

    logging.basicConfig(
        format="%(message)s",
        stream=sys.stdout,
        level=os.getenv("LOG_LEVEL", "INFO"),
    )
    structlog.configure(
        processors=[
            structlog.contextvars.merge_contextvars,
            structlog.processors.add_log_level,
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.JSONRenderer(),
        ],
        wrapper_class=structlog.make_filtering_bound_logger(logging.INFO),
        logger_factory=structlog.PrintLoggerFactory(),
        cache_logger_on_first_use=True,
    )


def bind_log(name: str) -> structlog.BoundLogger:
    return structlog.get_logger(name)
