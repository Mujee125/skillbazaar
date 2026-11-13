"""Liveness/readiness endpoint: GET /v1/health.

Returns 200 when the database and Redis both respond, otherwise 503.
Only "ok" / "down" is exposed, never error details.
"""
import redis
from django.conf import settings
from django.db import connection
from django.http import JsonResponse
from django.views.decorators.http import require_GET


def _check_db():
    try:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
        return "ok"
    except Exception:
        return "down"


def _check_redis():
    client = None
    try:
        client = redis.Redis.from_url(
            settings.REDIS_URL, socket_connect_timeout=1, socket_timeout=1
        )
        client.ping()
        return "ok"
    except Exception:
        return "down"
    finally:
        if client is not None:
            client.close()


@require_GET
def health(request):
    db = _check_db()
    cache = _check_redis()
    healthy = db == "ok" and cache == "ok"
    return JsonResponse(
        {"status": "ok" if healthy else "degraded", "db": db, "redis": cache},
        status=200 if healthy else 503,
    )
