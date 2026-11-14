# Skillbazaar.pk

Two-sided home-services marketplace (Pakistan).

- Source of truth: [docs/SKILLBAZAAR_MASTER_BACKLOG.md](docs/SKILLBAZAAR_MASTER_BACKLOG.md)
- Requirements: SRS v3.0 (baseline)

| Path | Purpose |
|---|---|
| backend/ | Django + DRF modular monolith |
| apps/web/ | Customer web/PWA (Next.js) |
| apps/provider/ | Provider app (React Native) |
| packages/ | Shared TypeScript packages |
| infra/ | Docker and gate scripts |
| docs/ | Backlog, ADRs, gate evidence |

## Run it locally

Tested on Windows 11 with Docker Desktop (WSL2 backend), using Git Bash.

### Prerequisites

- Git
- Docker Desktop with Compose (tested with Docker Engine 29.9.2)
- Optional, only for the TypeScript workspace: Node and pnpm (tested with Node 24.14.1 and pnpm 12.18.0; the repo pins pnpm in `package.json`)

### First run

```bash
git clone https://github.com/Mujee125/skillbazaar.git
cd skillbazaar
cp .env.example .env
docker compose up -d --build --wait
```

The first run downloads the PostGIS and Redis images and builds the backend image, so it is slow. On our machine the backend build took about 6 minutes and starting the stack took about 20 seconds. The image downloads come on top of that and depend on your network (several minutes for us). Allow about 20 minutes the first time. Later starts take seconds.

After `up`, wait about 10 seconds before calling the API. Docker opens port 8001 before Django is ready, so an early request may return `Empty reply from server`. If that happens, wait a few seconds and try again.

### Check that it works

```bash
curl -i http://127.0.0.1:8001/v1/health
docker compose exec backend python manage.py migrate
docker compose exec backend pytest
```

- Health returns HTTP 200 with `{"status": "ok", "db": "ok", "redis": "ok"}`.
- `migrate` applies the Django migrations without errors.
- `pytest` reports `1 passed`.

### Host ports

| Service | Host port | Inside Compose |
|---|---|---|
| PostGIS | 5433 | db:5432 |
| Redis | 6380 | redis:6379 |
| Django | 8001 | backend:8000 |

Port 8000 is not used because another local project occupies it.

### TypeScript workspace

```bash
pnpm install
pnpm -r ls --depth -1
```

This lists the five placeholder packages (`@skillbazaar/web`, `provider`, `api-client`, `validation`, `tokens`). pnpm may warn that it uses a store on the D: drive. That is harmless.

### Stop

```bash
docker compose down        # stop containers, keep the database
docker compose down -v     # stop and also delete the database volume
```

`.env` holds dev-only dummy values and is not committed. Never put real secrets in `.env.example`.
