# Observability Stack Design — Hybrid Platform

**Author:** Gideon Warui
**Date:** May 2026
**Status:** Proposed
**Audience:** Technical / Platform Team

---

## 1. Context and Constraints

Our platform spans a self-managed kubeadm cluster in Nairobi (on-premise)
and an EKS cluster in af-south-1, connected via AWS Direct Connect. A third
cluster (eu-west-1) is planned within 6 months.

Key constraints driving this design:

- **Budget:** ~$800/month for managed AWS tooling
- **Team:** 2 platform engineers — operational simplicity is non-negotiable
- **Data residency:** Customer PII logs must remain in af-south-1
- **Retention:** Metrics 15d hot / 90d cold. Logs 30d queryable / 1yr archived
- **Compliance:** ISO 27001 — audit trail for all log access and config changes
- **Current state:** Node Exporter deployed on bare metal but not scraped
  centrally. Fluentd on on-prem ships to an ELK stack with no TLS. EKS
  has zero observability — no metrics, no log collection. PagerDuty is
  configured but has never triggered. On-call engineers SSH to nodes
  and run `journalctl` manually.

The goal is a unified observability layer across both clusters,
extensible to eu-west-1 without redesign.

---

## 2. Metrics

### Tooling

- **Prometheus** (per cluster, via kube-prometheus-stack Helm chart) —
  scrapes cluster metrics locally. Keeps scraping reliable even if
  the central layer is unavailable.
- **Thanos** — sidecar on each Prometheus instance ships blocks to
  S3 (af-south-1). Thanos Query aggregates across all clusters into
  a single query endpoint.
- **Grafana** (self-hosted, on EKS) — unified query interface across
  both clusters via Thanos Query datasource. New dev teams get
  read-only access via Grafana Org-level RBAC as they onboard.

### Alternatives Considered

**Amazon Managed Prometheus (AMP)** is available in af-south-1 since
June 2025, but at $0.90/10M samples ingested, ~50,000 active series
across both clusters costs ~$260/month for ingestion alone — a third
of our budget before logging. Thanos on existing nodes with S3 storage
(~$50/month) achieves the same federation. AMP becomes viable when
operational overhead of self-hosted Thanos outweighs the cost delta.

**Grafana Mimir** requires replacing Prometheus with a new ingestion
layer — unnecessary complexity for two clusters and two engineers.

**VictoriaMetrics** single-node is Apache 2.0, but its cluster edition
(needed for cross-cluster federation) is open-core with enterprise-only
features. The vmagent/vmselect/vminsert/vmstorage stack is harder to
justify than a Thanos sidecar on existing Prometheus.

### Scraping Architecture

**On-premise cluster:**
Node Exporter is already deployed on bare metal — we keep it and
add Prometheus (via kube-prometheus-stack) to scrape it alongside
kube-state-metrics. Thanos sidecar uploads 2-hour TSDB blocks to
S3 over Direct Connect. Block shipping is more resilient than remote
write to connectivity issues — Prometheus retains 6 hours locally
and replays the backlog once the link recovers.

**EKS (af-south-1):**
Same kube-prometheus-stack deployment. IRSA grants Thanos sidecar
write access to S3 — no long-lived credentials in cluster. The spot
node group means pods can be preempted; kube-state-metrics captures
eviction events for the alerting layer.

**Retention:**
Prometheus local retention: 15 days (hot).
Thanos compactor applies downsampling and retention policy —
raw data 90 days, 5m downsampled 1 year, in S3 (cold).

### eu-west-1 Readiness

Adding a third cluster requires deploying the same kube-prometheus-stack
chart and pointing the Thanos sidecar at the same S3 bucket with a
different `external_labels` value. Thanos Query discovers it via the
Store API — no architectural changes needed.

---

## 3. Logging

### Stack

Fluent Bit (DaemonSet, per cluster)
-> Amazon OpenSearch Service (af-south-1)
-> S3 (af-south-1) via Index State Management for archive

### Why Fluent Bit over Fluentd?

Fluent Bit is written in C with a ~450 KB base footprint. AWS
benchmarks show 4-6x less CPU and memory than Fluentd — typical
per-node usage is 10-50 MB versus Fluentd's 150-300 MB. Across 12
bare metal nodes plus EKS, the savings are material. Fluent Bit's
native Kubernetes filter handles pod metadata enrichment without
plugins, and its OpenSearch output is stable.

### On-Premise Delivery

Fluent Bit ships logs over TLS to OpenSearch in af-south-1 via
Direct Connect. The current ELK setup has no TLS — an ISO 27001
finding we close with this migration. Once verified, the legacy
Fluentd agents and ELK stack are decommissioned.

If Direct Connect drops, Fluent Bit buffers to local disk (500 MB
per node) and replays on reconnect — reliable delivery without a
message queue at this scale.

### Data Residency

All logs land in OpenSearch in af-south-1. PII-tagged streams route
to dedicated indices with stricter IAM policies. When eu-west-1 is
added, European customer logs ship to a local OpenSearch domain —
never cross-region.

### Structured Logging and Trace Correlation

Application teams emit JSON logs with a `trace_id` field. Fluent Bit
parses JSON natively — no regex. OpenSearch Dashboards filters by
`trace_id` to correlate logs across services. Full distributed
tracing (OpenTelemetry) is out of scope for the first 90 days, but
the `trace_id` convention is established now so correlation works
retroactively once tracing is added.

### Retention

OpenSearch hot tier: 30 days (queryable). ISM policy transitions
indices to cold storage after 30 days using the `cold_migration`
action. Automated snapshots archive to S3 for long-term retention.
1 year total retention. S3 lifecycle policy transitions objects to
Glacier after 90 days for cost efficiency.

### ISO 27001

OpenSearch Fine-Grained Access Control is enabled — all index access
is authenticated and CloudTrail logs every API call. Access to audit
log indices is restricted to platform engineers only.

---

## 4. Alerting

### SLO Definition — API Service (99.9% over 30 days)

99.9% availability over 30 days = **43.8 minutes allowable downtime**.

I would use multiwindow burn rate alerts per the Google SRE Workbook
— two windows per alert to filter transient spikes:

| Alert | Burn Rate | Windows | Severity | Action |
|---|---|---|---|---|
| Critical | 14x | 1h + 5m | Page immediately | On-call engineer |
| Warning | 6x | 6h + 30m | Ticket | Next business day |

14x exhausts the budget in ~2 days — warrants immediate response.
6x exhausts it in ~5 days — investigation, not a 2 AM page.

### Alert Fatigue Strategy

PagerDuty is configured but has never triggered — either nothing
has gone wrong (unlikely) or alerts were never defined. I would
start from zero and build incrementally.

**First 30 days — I would define only these alerts:**
- API error rate burn rate (above)
- Node not ready (on-premise + EKS)
- PersistentVolume > 85% full
- Certificate expiry < 14 days

I would not alert on CPU, memory, or pod restarts initially. These
are symptoms, not causes — they generate noise without actionable
signal. After 30 days of baseline data, I would revisit and add
alerts backed by observed thresholds, not guesses.

**I would require a runbook for every alert.** If an alert fires
and there is no runbook, the alert gets disabled until one exists.
This forces deliberate alert design and prevents alert sprawl.

### On-Call Escalation

Alert fires -> PagerDuty (already configured)
-> Engineer 1 (primary, 5 min acknowledgement window)
-> Engineer 2 (secondary, if unacknowledged)
-> Engineering Manager (if unacknowledged after 15 min)

With 2 platform engineers, we run a simple primary/secondary rotation.
No third-party escalation service needed at this team size.

---

## 5. Trade-offs and Prioritisation

### Managed vs Self-Hosted

I would self-host any component where the managed alternative
consumes over 40% of the budget for a single concern. AMP at
~$260/month fails — I would run Thanos instead. OpenSearch at
~$350/month passes because self-hosting Elasticsearch requires
dedicated nodes, JVM tuning, and index lifecycle management that
two engineers cannot sustain. Managed where operational burden is
high, self-hosted where the tool is lightweight.

### Budget Breakdown ($800/month)

| Component | Cost |
|---|---|
| OpenSearch (2x r6g.large.search, af-south-1) | ~$350 |
| S3 storage (metrics blocks + log archive) | ~$80 |
| Thanos, Grafana, Prometheus, Alertmanager, Fluent Bit | $0 (run on existing EKS/on-prem nodes) |
| **Total** | **~$430/month** |

$370 headroom retained for the eu-west-1 OpenSearch domain when that
cluster is added.

### What I Would Not Do in the First 90 Days

- **Distributed tracing** — requires application-side instrumentation
  across all services. I would establish metrics and logging first,
  then add OpenTelemetry in month 4.
- **Custom Grafana dashboards** — I would use community dashboards
  (kubernetes-mixin, node-exporter-full) until we know what we
  actually look at during incidents.
- **Multi-tenancy on observability** — I would wait until the 3 new
  dev teams onboard and requirements are concrete. Over-engineering
  RBAC before teams exist wastes time.
- **Synthetic monitoring** — I would prioritise real alerting over
  Blackbox Exporter probes. First PagerDuty page first.

### How I Would Sequence the First 90 Days

1. **Days 1-14:** Deploy Fluent Bit + OpenSearch. Close the no-TLS
   ISO finding. Get logs flowing from both clusters. Decommission
   legacy ELK.
2. **Days 15-30:** Deploy kube-prometheus-stack + Thanos.
   Unified metrics view in Grafana.
3. **Days 31-60:** Define SLOs, write first alert runbooks,
   trigger first PagerDuty test page.
4. **Days 61-90:** ISO 27001 audit log review, OpenSearch access
   control hardening, retention policy validation.

---

## 6. Architecture Diagram

```
+-----------------------------------------------------------------+
|                  On-Premise (Nairobi DC)                        |
|  +--------------+    +--------------+    +------------------+   |
|  |  Fluent Bit  |    |  Prometheus  |    |  Node Exporter   |   |
|  |  (DaemonSet) |    |  + Thanos    |    |  (bare metal)    |   |
|  +------+-------+    +------+-------+    +------------------+   |
+---------|-------------------|-----------+-----------------------+
          | TLS / Direct Connect          | S3 block upload
          v                               v
+-----------------------------------------------------------------+
|                       AWS af-south-1                            |
|  +--------------+    +--------------+    +------------------+   |
|  |  OpenSearch  |    |  S3 Bucket   |    |  Thanos Query    |   |
|  |  (hot logs)  |    |  (cold store)|    |  + Grafana       |   |
|  +--------------+    +--------------+    +------------------+   |
|                                                                 |
|  +--------------+    +--------------+                           |
|  | EKS Cluster  |    | Alertmanager |                           |
|  | Fluent Bit   |    | -> PagerDuty |                           |
|  | Prometheus   |    +--------------+                           |
|  | Thanos       |                                               |
|  +--------------+                                               |
+-----------------------------------------------------------------+
```

---

## References

1. [Amazon Managed Service for Prometheus — Pricing](https://aws.amazon.com/prometheus/pricing/) — AMP ingestion tiers ($0.90/10M samples first 2B, $0.35/10M next 250B)
2. [AMP available in af-south-1 (June 2025)](https://aws.amazon.com/about-aws/whats-new/2025/06/amazon-managed-service-prometheus-7-regions/) — region expansion announcement
3. [Thanos Sidecar — Object Storage Upload](https://thanos.io/tip/components/sidecar.md/) — 2-hour TSDB block shipping, recommended 6h local retention
4. [Thanos — CNCF Incubating Project](https://www.cncf.io/projects/thanos/) — project status and governance
5. [kube-prometheus-stack Helm Chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) — Prometheus + Grafana + Alertmanager deployment
6. [Fluent Bit — Performance Tuning](https://docs.fluentbit.io/manual/administration/performance) — ~450 KB base footprint, memory estimation formula
7. [Fluent Bit — Memory Management](https://docs.fluentbit.io/manual/administration/memory-management) — `Mem_Buf_Limit` and backpressure handling
8. [Fluentd vs Fluent Bit (Better Stack, 2026)](https://betterstack.com/community/logging/fluentd-vs-fluent-bit/) — side-by-side comparison including resource benchmarks
9. [Amazon OpenSearch Service — Pricing](https://aws.amazon.com/opensearch-service/pricing/) — instance, storage, and transfer costs by region
10. [OpenSearch Index State Management (ISM)](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/ism.html) — hot/UltraWarm/cold tier transitions and lifecycle automation
11. [Google SRE Workbook — Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/) — multiwindow multi-burn-rate alerting methodology
12. [VictoriaMetrics — License (Apache 2.0)](https://github.com/VictoriaMetrics/VictoriaMetrics/blob/master/LICENSE) — open-source single-node; enterprise features under separate EULA
13. [AMP Cost Optimization](https://docs.aws.amazon.com/prometheus/latest/userguide/AMP-costs.html) — ingestion cost drivers and label-based series limits
