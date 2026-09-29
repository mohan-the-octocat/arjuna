# Prompt library brief

This folder holds the prompt library for the synthetic telemetry generator.
Each file `<category_key>.jsonl` holds typed user prompts (the text a person
types into Google Antigravity, an agentic coding IDE) for one activity
category. The generator wraps them in `<USER_REQUEST>` tags and adds all
metadata itself, so write **only what the person types**.

## The fictional company: Cymbal

Cymbal is a 200-person software company (HQ in Bengaluru, India, plus a small
team in Seattle) that builds an online retail and payments platform.

| Area | Stack | Example names |
|---|---|---|
| Checkout service | Java 21, Spring Boot, PostgreSQL (Cloud SQL) | `checkout-service`, `OrderController.java`, `CartPricingService` |
| Payments gateway | Go 1.23, gRPC, Pub/Sub | `payments-gateway`, `refund_handler.go`, `upi_adapter.go` |
| Catalog and search API | Python 3.12, FastAPI, Elasticsearch | `catalog-api`, `search/ranker.py`, `models/product.py` |
| Web storefront | TypeScript, Next.js 15, React, Tailwind | `storefront-web`, `components/ProductCard.tsx`, `app/checkout/page.tsx` |
| Merchant admin portal | Angular 18, TypeScript | `merchant-portal`, `settlements.component.ts` |
| Mobile apps | Kotlin (Android, Jetpack Compose), Swift (iOS, SwiftUI) | `cymbal-android`, `CartViewModel.kt`, `CheckoutView.swift` |
| Data platform | BigQuery, dbt, Airflow (Cloud Composer), Looker | `dbt/models/marts/fct_orders.sql`, `dags/daily_settlement.py` |
| Platform and infra | GKE, Terraform, Helm, Cloud Build, Argo CD, Cloud Monitoring | `infra/terraform/modules/gke`, `charts/checkout/values.yaml`, `cloudbuild.yaml` |
| QA | JUnit 5, pytest, Playwright, Espresso, XCUITest, k6 | `e2e/checkout.spec.ts`, `load/k6_checkout.js` |

## Roles (use these exact keys in `roles`)

`swe_backend`, `swe_frontend`, `swe_mobile`, `swe_platform`, `qa`, `sre`,
`pm`, `ux`, `data`, `em` (engineering manager), `other` (tech writer,
security engineer, TPM).

## Categories (use the exact `category` string)

| Key | `category` string | Covers |
|---|---|---|
| build_feature | Build a feature | New functionality, apps, services, scaffolding |
| debug_fix | Debug and fix | Errors, failing builds or tests, wrong behavior, crashes |
| refactor_migrate | Refactor and migrate | Restructuring, version upgrades, porting, cleanup |
| understand_code | Understand code | Explaining code, Q&A about code or architecture, codebase exploration |
| test_verify | Test and verify | Writing tests, test plans, browser or UI verification |
| ui_frontend | UI and front-end | Layout, styling, components, visual design, image assets |
| devops_infra | DevOps, cloud and infra | Deploys, CI/CD, containers, infrastructure as code, cloud config, environment setup |
| data_analysis | Data and analysis | SQL, pipelines, notebooks, metrics, data processing |
| research_docs | Research and docs | Web research, docs, PRDs, reports, summaries |
| other | Other | Nothing fits, or the prompt is too short to tell |

**Precedence rule (the classifier follows it, so the labels must too).**
Classify by what the user wants done first. Use the three domain categories
(UI and front-end; DevOps, cloud and infra; Data and analysis) only when the
request is to build or change something in that domain.

- "Fix the broken CSS on the cart page" → Debug and fix (not UI)
- "Build a React settings page" → UI and front-end
- "Why does the Terraform plan fail with this error" → Debug and fix
- "Write Playwright tests for checkout" → Test and verify
- "Explain how the dbt model fct_orders is built" → Understand code

So every prompt in your file must be **unambiguously** in your category under
this rule. If a prompt could reasonably be read as another category, rewrite
it or drop it.

## Record format (one JSON object per line, no trailing commas)

```json
{"id": "debug_fix-001", "category": "Debug and fix", "roles": ["swe_backend", "sre"], "length": "medium", "text": "...", "followups": ["..."]}
```

- `id`: `<category_key>-NNN`, zero-padded, 001 upward, unique.
- `roles`: 1–4 role keys who would plausibly type this.
- `length`: `short` (< 80 chars), `medium` (80–400), `long` (400–1,500; usually pasted stack traces, logs, code, or a detailed spec).
- `text`: what the person types. Plain text; newlines as `\n`.
- `followups`: 0–3 later messages the same person types in the same
  conversation, same category (e.g. "still failing, new trace: ...", "good,
  now also handle the empty cart case", "make it shorter"). Mix: about 40% of
  records have 0, 40% have 1, 20% have 2–3.

## Realism

- Real developer prompts: often terse, lowercase, a few typos, imperative;
  sometimes polite and detailed. Vary tone and phrasing widely. No two
  prompts should read as templates of each other.
- Length mix per file: ~30% short, ~50% medium, ~20% long.
- Use Cymbal file paths, services, errors, tickets (e.g. `CYM-4821`), and
  realistic pasted snippets (stack traces, compiler errors, log lines, SQL).
- Spread the prompts across the roles that plausibly do this work.
- Mention public tools and products freely (GitHub, GCP services, npm, Gradle).

## Must not contain

- Any real secret, API key, password, token, or personal data. (The
  generator injects fake ones separately. Leave them out.)
- Real people's names or real company names other than public tech vendors.
- XML-like tags such as `<USER_REQUEST>`, `<SKILL>`, `<SUBAGENT>`, or slash
  commands like `/goal`. The generator adds those.

## Validate before you finish

```
python3 validate_prompts.py <category_key>.jsonl
```

It must print `OK`.
