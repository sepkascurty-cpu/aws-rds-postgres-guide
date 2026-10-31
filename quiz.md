# Quiz — AWS RDS PostgreSQL

5 questions. Try them from memory first, then expand the answers.

---

### 1. What is the difference between a Multi-AZ standby, a read replica, and an automated snapshot?

<details>
<summary>Answer</summary>

Three different tools for three different jobs:

- **Multi-AZ standby** → *availability*. Synchronous replica in another AZ
  with automatic failover (same endpoint, ~1–2 min). You cannot query it.
  Costs ~2× the instance.
- **Read replica** → *read scaling*. Asynchronous, has lag (seconds), you
  query it, promotion is manual. Not a backup.
- **Automated snapshot** → *recovery*. Daily snapshots + WAL for
  point-in-time restore to a *new* instance. The only thing that saves you
  from `DROP TABLE` or data corruption.

</details>

### 2. Your app runs 500 Fargate tasks and the database keeps hitting `max_connections`. What do you add, and why does it help?

<details>
<summary>Answer</summary>

**RDS Proxy** between the app tier and the instance. Each direct
PostgreSQL connection spawns a backend process that costs RAM, so 500
tasks × N connections per task exhausts the instance quickly. The proxy
multiplexes thousands of client connections into a small pool of real
database connections. Bonus: it makes Multi-AZ failovers transparent —
the proxy drains and reconnects, the app just retries.

</details>

### 3. True or false: placing the RDS instance in a public subnet is fine as long as the security group only allows your office IP.

<details>
<summary>Answer</summary>

**False.** A production database belongs in **private DB subnets with no
internet route**, reachable only through the app tier (or RDS Proxy).
Security groups are one layer; subnet placement is defense in depth — it
removes entire classes of mistakes (a bad SG edit no longer exposes the
database to the internet). `publicly_accessible = false`, always.

</details>

### 4. Which is cheaper for a dev database you use 8 hours a day: Multi-AZ `db.m6i.large`, or Single-AZ `db.t4g.micro` that you stop every night? Why?

<details>
<summary>Answer</summary>

**Single-AZ `db.t4g.micro`, stopped nightly — by a large margin.**

- Multi-AZ roughly doubles instance cost (you pay for the standby 24/7).
- `db.m6i.large` is several times the hourly price of `db.t4g.micro`.
- A stopped instance bills $0 for compute (storage still bills).
- Rule: **Single-AZ for dev/staging, Multi-AZ for prod only** — and set a
  billing alarm *before* creating the instance.

</details>

### 5. You need to rotate the database master password without restarting the app. What is the AWS-native way?

<details>
<summary>Answer</summary>

Store the credentials in **Secrets Manager** with **automatic rotation**
(a Lambda rotates the password on a schedule, e.g. every 30 days). The
app reads the secret at startup or via the RDS Proxy (which integrates
with Secrets Manager directly), so rotation needs no redeploy. Even
better: use **IAM database authentication** — short-lived 15-minute auth
tokens instead of any static password, so there is nothing to rotate or
leak.

</details>
