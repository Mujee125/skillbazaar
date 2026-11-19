# Skillbazaar.pk — Master Backlog (Single Source of Truth)
Version: 0.9 | Updated: 2026-11-17 | Status: DRAFT for PO ratification | Basis: SRS v3.0 (BASELINE, 2026-10-08)
SRS v3.1 (PROPOSED, 2026-11-01) has NOT been read by the assistant. Items marked [v3.1?] are provisional.

## 0. How to use this file across chat sessions
1. Paste this file at the start of every new session.
2. Say which story and task to work on (see Section 0a).
3. After each session, update Section 16 (change log) and commit to `main` via PR.
4. If this file and chat history disagree, this file wins.

## 0a. Prompt template for new sessions
"Please work on story `<ID>`, task `<Tn>`. Keep replies concise and step-by-step: first explain your plan, then give the code for this task only, then give the single check to run."

## 1. Product summary
Two-sided home-services marketplace, Pakistan. Customers book Providers (electrician, plumber, AC technician, etc.).
Payments: cash-on-service plus JazzCash/Easypaisa-class rails. Quote comes after arrival.
Flow: ARRIVED → DIAGNOSING → QUOTED → IN_PROGRESS → completion.

## 2. Locked decisions
| # | Decision | Status |
|---|---|---|
| D1 | Backend: Python, Django, DRF, GeoDjango; modular monolith | Locked |
| D2 | DB: PostgreSQL 18 + PostGIS 3.7 locally (image `postgis/postgis:18-3.7`), Cloud SQL `POSTGRES_18`; SRID 4326, GiST | Locked (SRS §1.7); versions decided after SB-E00-013 T3 |
| D3 | Redis-class store for live GPS (Tier 1), PostGIS for Tier 2 | Locked (SRS §1.7) |
| D4 | Customer: Next.js PWA/Web. Provider: React Native (Expo dev builds), Android-first | Locked |
| D5 | Admin: Django Admin, guard-railed | Locked |
| D6 | Payments via PaymentPort + adapters: Fake → JazzCash + Easypaisa → Raast (P2) → Card (later) | Locked |
| D7 | Number masking and ranked dispatch are Phase 2; build seams now | Locked |
| D8 | Validation chain: Frontend → Service → DB trigger/constraint | Locked |
| D9 | CLOSED is terminal; rework = new job (job_type=REWORK, parent_job_id) | Locked |
| D10 | Commission base NOT NULL for new settlements via job_settlements table | Locked |
| D11 | Dev: local Docker Compose (Windows 11, Docker Desktop with WSL2 backend; repo on D: drive, used from Git Bash). Sprint 0 gate + staging: GCP free credit, EXPIRES 2026-12-31. No GCP resources before gate scripts are ready | Locked |
| D12 | Pilot host: decided before 2026-12-31 using real gate cost numbers (GCP vs DigitalOcean). Staging after expiry = local + tunnel unless budget approved | OPEN |
| D13 | Hostinger shared plan cannot run the stack; landing page/email only | Locked |
| D14 | Job verification state name: PENDING_VERIFICATION vs COMPLETION_VERIFYING | OPEN (recommend rename; collides with Provider status in SRS §7.3) |

## 3. Hard constraints from SRS v3.0
- §1.7: PostGIS binding; modular monolith; single cross-platform Provider codebase; Customer = Web/PWA; location pings never written one-by-one synchronously to the durable store.
- §3.5: host "within or with low-latency access to Pakistan". No in-country storage rule found. BR-025 is PII data-minimization, not residency.
- §14.8: avoid vendor-proprietary services beyond PostgreSQL/PostGIS and the in-memory store.
- REL-04 RPO ≤ 15 min | REL-05 RTO ≤ 4 h | AVL-01 99.5% monthly | TEST-07 restore drill before launch.
- SEC-INFRA-01 secrets manager | SEC-DATA-01 PII encrypted at rest.
- DR-01 money = integer minor units | DR-02 UTC | DR-04 SRID 4326 | DR-05 PINs hashed.
- BR-001 one phone per account type | BR-003 CNIC unique via hash | BR-008 ledger sole financial truth.
- BR-009..011 overdraft ceiling/suspension | BR-012 four-eyes wallet adjustments | BR-013 four-eyes high-impact disputes.
- BR-015 min two Super Admins | BR-019 PIN override Super Admin only | BR-027 commission configurable.
- FR-AUTH-02 OTP: 5 min expiry, 60 s resend, 5 attempts, 10 req/IP/h | FR-AUTH-04 access ~1 h, refresh ~30 d rotated.
- FR-COM-02 SOS notifies Admin | NET-01 offline queue | PR-DAT-01 retention 6 y financial/audit, 3 y job/identity (interim, OD-09).
- OD-07 (Legal) open: data-protection law. Lawyer confirmation needed before real CNIC data goes live.

## 4. Architecture summary
Django apps: identity, verification, catalog, dispatch (Ranker interface + dispatch_decisions log), location, quoting, jobs (owns state machine), ledger (append-only), payments (port + adapters), disputes, warranty, safety, reviews, notifications, communications (contact-reveal port), audit, config, reporting.
Infra: PostgreSQL/PostGIS + PgBouncer; Redis (GPS GEOSEARCH, Celery broker, cache, rate limit); Celery queues sos-critical / notifications / money / media / reports; S3-compatible object storage behind StoragePort (KYC in separate bucket); OpenAPI via drf-spectacular → TS client via openapi-typescript.
Local dev environment: Windows 11 + Docker Desktop (WSL2 backend). Repo lives at D:\skillsbazar.pk\skillbazaar and is used from Git Bash, not from inside WSL. Django runs in a container for GDAL/GEOS/PROJ; images: postgis/postgis and redis:7-alpine. Host ports: PostGIS 5433, Redis 6380, Django 8001 (8000 is used by another local project).
Observability: OpenTelemetry, Sentry, Prometheus/Grafana, structured logs. Testing: pytest+Hypothesis, Playwright, Maestro, k6, Schemathesis.
Rejected: microservices now, SQLite on server, Rust now, NestJS in MVP, Django Channels in MVP (poll Redis 5–10 s), Material UI, offline PIN validation, django-fsm.

## 5. Ten modularity rules
1. Public services.py per module; import-linter/tach enforced.
2. Sync calls only when one transaction is needed; else transactional outbox + idempotent consumers.
3. Ledger is the only money writer; overdraft checked in-transaction under row lock; app DB role has no UPDATE/DELETE on ledger/audit.
4. Admin never writes tables directly; actions call services.
5. Adapters have circuit breakers; SMS has primary + secondary.
6. Queue isolation; sos-critical has dedicated workers.
7. Config is data.
8. Feature flags and kill switches per module.
9. Versioned contracts (/v1 APIs, versioned event schemas).
10. Reporting off the OLTP path.

## 6. Validation matrix (Frontend → Service → DB)
| Rule | Frontend | Service | DB |
|---|---|---|---|
| Completion photo | Complete disabled until photo | Check object, size, checksum | Trigger blocks COMPLETED if completion_photo_ref NULL |
| Geofence [v3.1?] | Pre-check | Authoritative distance | Trigger needs accepted geofence record |
| Four-eyes | Hide approve action | Policy check | CHECK approved_by <> flagged_by (chk_four_eyes, chk_dispute_four_eyes) |
| Warranty window [v3.1?] | Hide claim button | Compare with completed_at + config | BEFORE INSERT trigger (not a CHECK) |
| Overdraft | Warn | Row-locked check | CHECK balance_minor >= overdraft_ceiling_minor |
| Job transitions | — | Transition table | Trigger vs seeded table; test asserts tables identical |
| Ledger/audit immutability | — | — | REVOKE UPDATE, DELETE + trigger |
Triggers via django-pgtrigger with a trigger catalog. Zod schemas generated from OpenAPI.

## 7. Key designs
**Job verification state (proposed, not ratified).** COMPLETION_PENDING → verification state once PIN is server-validated and geofence passes (PIN needs connectivity; only photo upload may defer). Exit to COMPLETED when photo is confirmed. Exit to Support review after repeated geofence failure or hard mock signal. Timeout escalates to Support. Settlement, dispute and warranty windows start at COMPLETED.
**Rework.** REWORK_PENDING removed. jobs.job_type in (STANDARD, REWORK), parent_job_id self-FK, per-type transition tables. REWORK: pre-assigned provider, no customer charge, ignored by settlement.
**job_settlements.** settlement_id, job_id UNIQUE NOT NULL, labor_minor >= 0, materials_minor >= 0, commission_base_amount_minor NOT NULL (= labor_minor), commission_rate_bps, commission_minor (0..base). wallet_transactions gets nullable settlement_id with CHECK (type <> 'JOB_SETTLEMENT' OR settlement_id IS NOT NULL). Integer basis-point math; rounding rule OPEN.
**Payments.** PaymentPort: initiate, confirm/status, refund/reverse, payout, verify_payee_title. Webhooks: signed → raw-stored inbox → idempotent processing. Daily reconciliation. Manual top-up with four-eyes as contingency. Cash-on-service handled as a payment method (FR-PAY-05).
**Phase 2 seams (build now).** No raw phone in API responses (use gated, audited GET /jobs/{id}/contact). Ranker interface (MVP = nearest-first behind hard filters). Log every dispatch decision from day 1.

## 8. Scrum setup
- **Team:** 1 full-stack engineer (solo; covers backend, web, mobile, QA/DevOps, and wears the Scrum Master hat) + client Product Owner (manages backlog priorities, business verifications, and scope trade-offs).
- **Cadence:** Sprint 0 = 3 weeks (2026-11-16 to 2026-12-04). Subsequent sprints = 2 weeks.
- **Ceremonies (solo-adapted):** Sprint Planning + Review Demo with client PO; weekly written Done / Next / Blocked summary to the PO, with hours logged as a comment on each story issue; Sprint Retrospective note. No scope enters a running sprint without swapping out equal work.
- **Hierarchy:** Theme → Epic → Story → Task. Story ID: `SB-E07-012`. Every story cites SRS IDs.
- **Story template:** As a / I want / So that; SRS refs; Given/When/Then; validation layers; events; NFR notes; dependencies; estimate.
- **Definition of Ready:** SRS refs identified; AC testable; dependencies known; estimate agreed; UX attached; SRS text available.
- **Definition of Done:** PR self-reviewed against checklist (peer-reviewed once a second engineer joins); tests pass; import-linter passes; migration tested on PostGIS; OpenAPI updated and TS client regenerated; validation layers per matrix; audit/event emission verified; strings externalized (en/ur) and RTL checked; a11y check; metrics/logs/Sentry wired; feature-flagged if risky; deployed to staging; accepted by PO.

## 8a. Working method (incremental execution)
- Keep WIP = 1 task at a time (all tasks assigned to the solo engineer).
- Each story is split into tasks of half a day or less just before work starts, tracked as a checklist in the story's GitHub issue.
- Loop per task: **explain plan → write code for this task only → run verification check → open PR & Squash-and-Merge → next task**.
- Branch naming: `SB-E00-001-t1-short-name`. PR body: `Part of #<issue>` for intermediate tasks; `Closes #<issue>` on the final task only.
- `SB-E00-001` tasks: T1 repo skeleton | T2 Compose (PostGIS, Redis) | T3 backend container | T4 health endpoint + pytest | T5 pnpm workspace | T6 README cold-run.

## 9. Epics and releases
| Epic | Name | Release |
|---|---|---|
| E00 | Foundation / DevEx | R0 |
| E01 | Identity | R0 |
| E02 | Provider onboarding / verification | R1 |
| E03 | Catalog | R1 |
| E04 | Location / dispatch | R1 |
| E05 | Scheduling | R1 |
| E06 | Quoting | R1 |
| E07 | Job lifecycle / PIN / evidence | R1 |
| E08 | Payments integration | R1 |
| E09 | Ledger / wallet | R1 |
| E10 | Safety / SOS | R1 |
| E11 | Notifications | R1 |
| E12 | Reviews | R1 |
| E13 | Disputes | R1.1 |
| E14 | Warranty / rework | R1.1 |
| E15 | Admin / back-office | R0–R1 |
| E16 | Reporting / ops | R1 |
| E17 | Localization / a11y / low-bandwidth | cross-cutting |
| E18 | Security / privacy / compliance | cross-cutting |
| E19 | Tiered overdraft | R1.1 |
| P2 | Number masking, ranked dispatch, Raast, Cards, Customer native app | Phase 2 |
Roadmap: R0 walking skeleton | R1 closed pilot (one city, 3–4 categories, manual KYC, one live payment adapter) | R1.1 | Phase 2. (Sprint counts originally estimated for 5–6 engineers will be re-forecast after Sprint 0/1 solo velocity is measured.)

## 10. Sprint backlogs
### Sprint 0 (3 weeks, 2026-11-16 to 2026-12-04, commit 18 pts (4 MUST stories), stretch 011, 009, 007a) — Goal: prove the data tier before GCP credit expiry; lock core ADRs
| ID | Pts | Priority | Story |
|---|---|---|---|
| SB-E00-001 | 3 | DONE | Monorepo scaffold: containerized Django backend + pnpm workspace (apps/web, apps/provider, packages/api-client, validation, tokens) |
| SB-E00-013 | 3 | MUST | Gate-in-a-box: scripted GCP create/teardown, benchmark and restore-drill scripts tested locally first so cloud window is 3–5 days |
| SB-E00-002 | 5 | MUST | GCP verification: Cloud SQL PostgreSQL + PostGIS, PITR enabled/retention noted, region list (Mumbai/Delhi), Redis option/price, latency test (Karachi/Lahore/Islamabad), confirm free plan allows services |
| SB-E00-004 | 8 | MUST | Data-tier gate: PostGIS dwithin benchmark (50k synthetic providers, 100 concurrent, p95 target 500 ms; SRS v3.0 PERF-03 is 2 s), PITR restore drill (TEST-07), Redis-loss recovery via outbox sweeper, resumable 3 MB upload at 2G speed |
| SB-E00-012 | 2 | MUST | GCP cost guardrails: budget alert, teardown verification, gate evidence exported to repo, pilot-host cost comparison before 2026-12-31 (closes D12) |
| SB-E00-007a | 3 | STRETCH 3 | Core ADRs: hosting/DR, job-state name, money representation (split from 007) |
| SB-E00-009 | 2 | STRETCH 2 | Client PO ratifies v3.2 amendments and answers OD-29/30/31 |
| SB-E00-011 | 1 | STRETCH 1 | Working agreements, solo PR self-review checklist, DoD, release-gate checklist |
| SB-E00-010 | 3 | SLIP FIRST | Start long-lead workstreams (Section 11) incl. asking gateways about data-location rules (kick-off minimum) |
| SB-E00-003 | 5 | SLIP FIRST | CI: lint, types, pytest on PostGIS container, import-linter, OpenAPI drift check, TS client generation |
Calibration note: Commit line = the four MUST stories above (18 pts; SB-E00-001 is done). STRETCH numbers give the order to pull them in. Measured pace after SB-E00-001: about 21 h for 3 pts, about 7 h per point, capacity 14 to 17 pts (verify). Checkpoint 2026-11-20: if SB-E00-013 takes more than about 21 h, cut scope from SB-E00-004. Go/no-go: if Cloud SQL lacks PostGIS or PITR misses REL-04, fall back to DigitalOcean or Postgres with WAL archiving.

### Sprint 1 (2 weeks, starts 2026-12-07 — commit line to be sized at Sprint 1 Planning using measured solo velocity)
| ID | Pts | Story |
|---|---|---|
| SB-E00-005 | 5 | RN spike: mock-location, Play Integrity, background upload on low-end Android (moved from S0; do not slip past S1) |
| SB-E00-006 | 2 | RN UI spike (NativeWind) and shared tokens (moved from S0) |
| SB-E00-007b | 2 | Remaining ADRs: modular monolith, validation layering + trigger catalog, outbox, state machine (split from 007) |
| SB-E00-008 | 3 | Data-flow inventory (processors, data categories, PII) for OD-07 / PR-07 (moved from S0) |
| SB-E00-101 | 5 | Module skeletons + import-linter contracts |
| SB-E00-102 | 5 | Config service |
| SB-E00-103 | 8 | Transactional outbox |
| SB-E00-104 | 5 | Append-only audit log |
| SB-E01-105 | 8 | Phone-OTP login (FR-AUTH-02) |
| SB-E01-106 | 5 | JWT + rotating refresh (FR-AUTH-04) |
| SB-E01-107 | 5 | RBAC, staff MFA, hardened Django Admin |
| SB-E00-108 | 2 | Feature flags + kill switches |
| SB-E17-109 | 8 | Next.js customer shell, en/ur, RTL |
| SB-E17-110 | 8 | RN Provider shell |
Also front-load in R0: observability baseline; CD pipeline with one-command rollback (plus `SB-E00-003` CI if not completed in Sprint 0).

### Sprints 2+ (candidate stories, unestimated — refine incrementally; SRS refs to be attached)
- E02: provider signup and docs upload; CNIC hash uniqueness (BR-003); admin review queue; status machine UNVERIFIED → PENDING_VERIFICATION → VERIFIED/REJECTED, DEVERIFIED.
- E03: category/service catalog; pilot categories; provider skill mapping.
- E04: live location ping ingest (Redis); nearest-first dispatch with hard filters; dispatch_decisions log; offer/accept/timeout.
- E05: instant vs scheduled booking; slot rules.
- E06: post-arrival quote; customer accept/decline; labor vs materials split.
- E07: job state machine + transition table; arrival; completion PIN; photo evidence; geofence [v3.1?]; verification state.
- E08: PaymentPort; Fake adapter; JazzCash; Easypaisa; webhook inbox; reconciliation; cash-on-service.
- E09: ledger tables; wallet; commission via job_settlements; overdraft/suspension; four-eyes adjustments.
- E10: SOS trigger → Admin alert (FR-COM-02); SMS fallback [v3.1?].
- E11: push (FCM), SMS, in-app; templates en/ur.
- E12: ratings and reviews.
- E13: dispute flow; four-eyes for high-impact (BR-013).
- E14: warranty claim; rework job; OD-29/30/31.
- E15–E16: admin tooling; dashboards; reports off OLTP.
- E18: PII encryption, secrets manager, retention jobs, legal review gate before real CNIC data.
- E19: tiered overdraft.

## 11. Long-lead non-engineering workstreams (start Sprint 0 — owned with client PO)
1. JazzCash/Easypaisa merchant onboarding (ask about data-location rules).
2. SMS gateway + sender-ID registration + secondary provider.
3. Google Play, Apple, FCM accounts (Play verification requirements unverified).
4. Legal brief: data protection (OD-07), stored-value wallet regulation, KYC handling.

## 12. Open questions / decisions (defaults in brackets)
| Q | Item | Status / Default |
|---|---|---|
| Q1 | Team size, PO, sprint length | **RESOLVED:** 1 solo full-stack engineer + client PO; 3-week S0, 2-week S1+ |
| Q2 | Pilot city and categories | OPEN (TBD with client PO) |
| Q3 | Job state name | OPEN [COMPLETION_VERIFYING] |
| Q4 | OD-29 rework cost bearer | OPEN (TBD with client PO) |
| Q5 | OD-30 claim effect on streak/ratings/dispatch | OPEN (TBD with client PO) |
| Q6 | OD-31 claim/dispute limits | OPEN [one active claim/dispute per job; max 1 rework; no window extension] |
| Q7 | Commission rounding | OPEN [half-up] |
| Q8 | Support geofence exception counts as four-eyes? | OPEN [No] |
| Q9 | Ops approach for solo engineer | Managed DB/Redis preferred; Dockerized local + scripted cloud setups |
| Q10 | Supply SRS v3.1 text | OPEN — needed to verify `[v3.1?]` items |
| Q11 | Pilot host (D12) | OPEN — decide before 2026-12-31 |

## 13. v3.2-draft SRS amendments (for client PO ratification)
1. Provider client native-capable (EIR-DEV-01/05; FR-DSP-16 integrity checks).
2. Validation-layering requirement; replace chk_warranty_window DDL.
3. Job verification state in Table 7.1-1; amend FR-JOB-13/14, BR-018, BR-032.
4. Remove REWORK_PENDING; add job_type, parent_job_id, per-type transitions.
5. Add job_settlements; amend FR-PAY-06 and §8.2.
6. Add OD-29/30/31 and Support-geofence-override question.
7. OD-12/13 "Phase 2 committed" with MVP seams.
8. Record chosen hosting in SRS hosting section.
(Amendments 1–3 cite IDs from v3.1 and must be re-checked against it.)

## 14. Risks (initial)
| Risk | Mitigation |
|---|---|
| Solo engineer capacity / bus factor | Strict WIP=1, scripted setups, ADRs in repo, re-forecast roadmap after S0 velocity check |
| PITR on chosen host misses REL-04 | Sprint 0 gate; fallback host |
| GCP credit expires 2026-12-31 | Budget alert; scripted 3–5 day gate window; teardown; D12 decision |
| Gateway onboarding delays | Fake adapter first; client PO starts onboarding in Sprint 0 |
| Gateway sets data-location rule | Docker portability; ask in Sprint 0 |
| Play Integrity / mock-location unreliable on low-end phones | RN spike in Sprint 1 |
| v3.1 conflicts with this file | Supply v3.1; re-verify `[v3.1?]` items |

## 15. Tracking tool mapping (GitHub Projects)
Epic = GitHub label `epic:E07` + Epic field. Story = Issue titled `SB-E07-012 …`. Tasks = checklist inside Story issue. Sprint = GitHub Iteration field. Points = Number field.

## 16. Change log
- 0.1 — Initial master backlog; hosting moved to GCP credit for gate/staging.
- 0.2 — GCP credit expiry fixed at 2026-12-31; added SB-E00-013.
- 0.3 — Sprint 0 set to 3 weeks (2026-11-16 to 2026-12-04); 007 split into 007a/007b; 005/006/008 moved to Sprint 1.
- 0.4 — Added prompt template (0a), incremental working method (8a), and SB-E00-001 tasks T1–T6.
- 0.5 — Updated for solo full-stack engineer + client PO (Windows 11 + WSL2 + Docker); cleaned duplicate rows; added Sprint 0 MUST/SHOULD priorities.
- 0.6 — T1 and T2 done. Host ports: PostGIS 5433, Redis 6380, Django 8001 (8000 is used by another local project). Repo lives at D:\skillsbazar.pk\skillbazaar, used from Git Bash, not WSL (decided; revisit only if reload or speed problems appear).
- 0.7 — SB-E00-001 done (PRs #2 to #7). Cold run from a fresh clone passed: first run about 20 minutes (backend build about 6 min, stack start about 20 s, plus image downloads). Measured pace about 21 h for 3 pts. Sprint 0 recut: commit line = the four MUST stories (18 pts); SB-E00-011, 009, 007a are stretch in that order; SB-E00-010 and 003 slip first. Backend has no healthcheck, so Django needs about 6 to 10 s after up (follow-up task).
- 0.8 — Database versions decided: local PostgreSQL 18.7 / PostGIS 3.7.0 and Cloud SQL POSTGRES_18 (PR #13). Cloud SQL sets its own PostGIS version, so record `postgis_full_version()` in the gate evidence (verify). Local data volume is now `pgdata18`, mounted at `/var/lib/postgresql`. The old PG16 volume `skillbazaar_pgdata` is kept unused until a removal decision. SB-E00-013 T1 to T3 are done (PRs #10 to #12) and were re-tested on PG18. T4 to T6 remain.
- 0.9 — Process change: the daily 5-minute written log is replaced by a weekly written Done / Next / Blocked summary to the PO; hours are logged as a comment on each story issue. SB-E00-013 done and closed (T1 to T7, PRs #10 to #18; T7 = benchmark warm-up, added after T6). Hours about 10.5 h of the ~21 h estimate (author's estimate).