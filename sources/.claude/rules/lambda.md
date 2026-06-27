---
paths:
  - "**/lambda/**"
  - "**/lambdas/**"
  - "**/functions/**"
  - "**/handler.{py,js,mjs,ts,go,rb,java,cs,rs}"
  - "**/*handler*.{py,js,mjs,ts,go,rb,java,cs,rs}"
  - "**/template.{yaml,yml}"
  - "**/serverless.{yml,yaml}"
  - "**/samconfig.toml"
---

# Global Claude Instructions

## AWS Lambda Best Practices

When writing, reviewing, or modifying AWS Lambda functions or their infrastructure, enforce the following rules. Every rule is drawn from two sources only: the canonical [AWS Lambda best-practices documentation](https://docs.aws.amazon.com/lambda/latest/dg/best-practices.html) (which itself recommends Powertools for AWS Lambda) and the [`awslabs/serverless-rules`](https://awslabs.github.io/serverless-rules/) ruleset. Point out violations and suggest corrections.

---

### Function Code

- **Reuse the execution environment**: Initialize SDK clients, database connections, and load static assets *outside* the handler so warm invocations reuse them — this reduces run time and cost. Cache static assets locally in `/tmp`.
- **Don't keep user data in the execution environment**: Instances are reused, so state held outside the handler can leak across invocations. Never store events, user data, or security-sensitive information there; if a function needs per-user mutable state, use separate functions or separate versions.
- **Maintain persistent connections with keep-alive**: Lambda purges idle connections, and reusing a stale one throws a connection error — enable your runtime's keep-alive directive.
- **Pass operational parameters via environment variables**: Don't hard-code values like a bucket name — read them from environment variables.
- **Never invoke recursively**: Don't let a function invoke itself or trigger a process that re-invokes it — this leads to unintended invocation volume and escalating cost. If you see runaway invocations, set the function's reserved concurrency to `0` immediately to throttle while you fix the code.
- **Use only public, documented APIs**: Don't depend on non-documented/non-public APIs — managed-runtime internal API updates can be backwards-incompatible and break your function.
- **Write idempotent code**: Validate events and handle duplicate events gracefully so duplicates are processed the same way. Consider the Powertools for AWS Lambda idempotency utility.

---

### Function Configuration

- **Right-size memory deliberately**: Never ship the default 128 MB. Memory scales CPU proportionally — performance-test, read `Max Memory Used` from the CloudWatch `REPORT` log line to size it, and use AWS Lambda Power Tuning to find the optimum.
- **Set the timeout deliberately**: Never ship the default 3 s. Load-test to measure real run time and set the timeout accordingly — especially important when the function makes network calls to dependencies that may not scale with Lambda.
- **Don't use an end-of-life runtime**: Stay on a supported runtime version — EOL runtimes stop receiving updates.
- **SQS source — function time must fit the queue's visibility timeout**: A function whose expected invocation time exceeds the source queue's Visibility Timeout fails creation (`CreateFunction`) or causes duplicate invocations (`UpdateFunctionConfiguration`).
- **Delete functions you no longer use**: Unused functions needlessly count against the deployment-package size limit.

---

### Scalability & Throttling

- **Respect upstream/downstream throughput constraints**: Lambda scales seamlessly, but its dependencies may not. To cap how high a function scales (e.g. to protect a downstream), configure reserved concurrency.
- **Build throttle tolerance**: For synchronous functions hitting Lambda's scaling rate, use timeouts, retries, and backoff with jitter to smooth retried invocations; use provisioned concurrency (pre-initialized execution environments, at additional cost) for latency-sensitive paths.

---

### Reliability & Failure Handling

- **Give asynchronous invocations a failure destination**: Configure an on-failure destination (or DLQ) so events that exhaust retries are captured, not silently dropped.
- **Give event source mappings a failure destination**: Configure a failure destination / DLQ on poll-based event source mappings so failed records are captured.

---

### Streams & Event Source Mappings

- **Tune batch and record sizes**: Match `BatchSize` to how quickly the function drains a batch — a larger batch amortizes invoke overhead across more records and raises throughput.
- **Use a batching window**: Have the source buffer records (up to 5 minutes); Lambda invokes once the batch is full, the window expires, or the payload reaches the 6 MB limit — avoiding invokes on single records.
- **Assume duplicates — be idempotent**: Event source mappings process each event at least once, so duplicate record processing can occur.
- **Enable partial batch response**: For Kinesis / DynamoDB Streams, report failures so Lambda retries only the failed records instead of the whole batch. The Powertools Batch utility simplifies this.
- **Scale Kinesis with shards and good partition keys**: Read throughput scales linearly with shard count; choose a partition key that distributes related records well across shards.
- **Alarm on `IteratorAge`**: Watch IteratorAge to confirm the stream is being processed (e.g. a CloudWatch alarm with a maximum of 30000 ms / 30 s).

---

### Metrics, Logging & Alarms

- **Use structured JSON logging**: Format logs as JSON so they're easier to search, filter, and analyze — the Powertools Logger does this automatically.
- **Emit custom metrics asynchronously via EMF**: Don't make synchronous CloudWatch API calls from the handler — emit metrics through the function's logs using Embedded Metric Format (Powertools Metrics) to reduce latency.
- **Alarm from CloudWatch, not from code**: Use CloudWatch metrics and alarms instead of creating/updating metrics inside function code — for example, alarm on the expected invocation duration to catch latency early.
- **Surface app errors through your logs**: Leverage your logging library together with Lambda metrics and dimensions to catch application errors (ERR / ERROR / WARNING).
- **Enable active tracing (X-Ray)**: Turn on AWS X-Ray tracing for the function for observability.
- **Set log retention**: Apply a CloudWatch Logs retention policy to the function's log group instead of leaving it to never expire.
- **Watch for cost anomalies**: Use AWS Cost Anomaly Detection to catch unusual usage and cost (e.g. from accidental recursion).

---

### Security & Permissions

- **Use most-restrictive execution-role permissions**: Understand the resources and operations the function needs and limit the execution role to exactly those.
- **No wildcard permissions**: Eliminate `Action: "*"` / `Resource: "*"` from the execution role.
- **One principal per invoke permission**: Don't grant a function's resource-based (invoke) permission to multiple principals — scope each statement to a single principal.
- **Monitor with Security Hub CSPM**: Use AWS Security Hub's Lambda controls to evaluate function configurations against security standards.
- **Monitor with GuardDuty Lambda Protection**: Enable GuardDuty Lambda Protection to flag suspicious network activity from function invocations.
