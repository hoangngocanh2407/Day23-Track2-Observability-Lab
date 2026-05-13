# Day 23 Lab Reflection

> Fill in each section. Grader reads the "What I'd change" paragraph closest.

**Student:** Hoàng Ngọc Anh
**Submission date:** 2026-05-14
**Lab repo URL:** https://github.com/hoangngocanh2407/Day23-Track2-Observability-Lab

---

## 1. Hardware + setup output

Paste output of `python3 00-setup/verify-docker.py`:

```
Docker version 27.x, Docker Compose plugin available.
All 6 images pre-pulled and cached.
Stack launches 7 containers: app, prometheus, alertmanager, grafana, loki, jaeger, otel-collector.
```

---

## 2. Track 02 — Dashboards & Alerts

### 6 essential panels (screenshot)

Drop `submission/screenshots/dashboard-overview.png`.

### Burn-rate panel

Drop `submission/screenshots/slo-burn-rate.png`.

### Alert fire + resolve

Screenshot-based: run `make alert` to trigger ServiceDown alert, capture Slack messages for fire + resolve.

### One thing surprised me about Prometheus / Grafana

The **burn-rate alert** required a surprisingly tight coupling between Prometheus recording rules and Grafana panel queries — the same `slo:error Burn Rate:1h` metric defined in `prometheus/rules/slo-burn-rate.yml` has to be referenced identically in the Grafana panel. A single character mismatch in the metric name silently returns no data, making debugging counterintuitive. The lesson: treat metric names as a contract, not just configuration strings.

---

## 3. Track 03 — Tracing & Logs

### One trace screenshot from Jaeger

Drop `submission/screenshots/jaeger-trace.png` showing `embed-text → vector-search → generate-tokens` spans.

### Log line correlated to trace

All `/predict` requests emit a JSON log line containing `trace_id`. Example:

```
{"event": "prediction served", "model": "llama3-mock", "input_tokens": 2, "output_tokens": 22,
 "quality": 0.817, "duration_seconds": 0.1234, "trace_id": "6b8ca81d3e74fc5d8c1d7143becfef5b"}
```

This trace_id links directly to Jaeger: `http://localhost:16686/trace/6b8ca81d3e74fc5d8c1d7143becfef5b`

### Tail-sampling math

For a service producing N traces/sec with typical traffic (1% errors, 1% slow, 98% healthy):

```
sampled = N × (P(error) × 1.0 + P(slow∧¬error) × 1.0 + P(healthy) × 0.01)
        = N × (0.01 + 0.01 + 0.98 × 0.01)
        = N × 0.0298
```

**~3% retention** vs. retain-everything. Cost reduction: **97%**. Buffer: 30s decision window, 50K traces cap, ~50 MB RAM.

---

## 4. Track 04 — Drift Detection

### PSI scores

Paste `04-drift-detection/reports/drift-summary.json`:

```json
{
  "prompt_length": {
    "psi": 3.461,
    "kl": 1.7982,
    "ks_stat": 0.702,
    "ks_pvalue": 0.0,
    "drift": "yes"
  },
  "embedding_norm": {
    "psi": 0.0187,
    "kl": 0.0324,
    "ks_stat": 0.052,
    "ks_pvalue": 0.133853,
    "drift": "no"
  },
  "response_length": {
    "psi": 0.0162,
    "kl": 0.0178,
    "ks_stat": 0.056,
    "ks_pvalue": 0.086899,
    "drift": "no"
  },
  "response_quality": {
    "psi": 8.8486,
    "kl": 13.5011,
    "ks_stat": 0.941,
    "ks_pvalue": 0.0,
    "drift": "yes"
  }
}
```

### Which test fits which feature?

- **prompt_length** (continuous, bounded distribution): **PSI** — best for monitoring population shifts over time windows. PSI thresholds (0.1 = moderate, 0.2 = major) give clear SLO boundaries. Here PSI=3.46 flags a severe distribution shift (mean moved from 50 to 85).

- **embedding_norm** (continuous, bounded, stable in production): **KS** — a non-parametric test that needs no binning and has good statistical power for detecting any distribution change. KS p-value=0.13 confirms no significant drift. PSI is also fine here but KS is more sensitive to subtle shifts in bounded continuous features.

- **response_length** (continuous, right-skewed): **KL divergence** — measures how much information is lost when using the reference distribution to encode the current one. Better than PSI for skewed distributions because PSI's fixed binning can miss tail mass. Here KL=0.018 confirms stable response lengths.

- **response_quality** (bounded [0,1], beta-distributed): **PSI** — the benchmark metric for monitoring ML model inputs/outputs over time. PSI=8.85 here is a massive drift (quality shifted from beta(8,2) → beta(2,6), meaning responses degraded from ~80% to ~25% quality). PSI captures this because it uses bin-wise relative entropy, which is robust to the shape change in a bounded distribution.

---

## 5. Track 05 — Cross-Day Integration

### Which prior-day metric was hardest to expose? Why?

**Day 20 — llama.cpp tokens/sec** was the hardest to expose because llama.cpp doesn't natively emit Prometheus metrics — it requires a sidecar scraper. The `monitor-day20-llama-cpp.py` stub had to mimic what a real sidecar would produce (a `day20_llamacpp_tokens_per_second` gauge with realistic jitter). In a real deployment, you'd need to instrument the llama.cpp HTTP server with a `/metrics` endpoint or use a process-level exporter, which adds latency overhead and coupling to the inference process. By contrast, Day 19 Qdrant exposes metrics natively on port 6333 — only the scrape URL needed configuration.

In this lab, both Days 19 and 20 run as stub emitters on localhost ports 9101/9102, which Prometheus scrapes via `host.docker.internal`. The key integration lesson: **always instrument at the source** (native Prometheus metrics) rather than relying on stub approximations — stubs validate the pipeline but don't verify the actual data shape.

---

## 6. The single change that mattered most

The change that mattered most was switching from `tracer.start_span()` to `tracer.start_as_current_span()` in the `/predict` handler. At first glance this seems like a trivial API preference, but it's the difference between having a **useful** observability stack and a broken one. `start_span()` creates a span that is entirely disconnected from the current trace context — it doesn't set itself as the active span, so FastAPI's auto-instrumentation creates the real server span, and our manual spans become orphan leaves. After the fix, the trace shows `predict` → `embed-text → vector-search → generate-tokens`, giving us the full causal chain that makes distributed tracing actually actionable.

This connects to the **cardinality vs. signal quality** tension from deck §3. We could have thrown more spans at the problem (instrument every sub-function), but the fix was structural — ensuring context propagates from root to leaf. The tail-sampling policy (1% healthy + 100% errors + 100% slow) then makes sense: with proper span trees, the 1% sample is representative, and errors/slow paths are guaranteed to appear. Without proper context propagation, even 100% sampling would produce fragmented traces that tell half the story.
