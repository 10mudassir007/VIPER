from __future__ import annotations

from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict
from supabase import Client, create_client
import uvicorn


BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")


class Settings(BaseSettings):
    supabase_url: str = ""
    supabase_secret_key: str = ""
    supabase_publishable_key: str = ""
    # Kept as a migration fallback for older .env files.
    supabase_service_role_key: str = ""
    app_name: str = Field(default="Shelfwise", validation_alias="APP_NAME")
    app_env: str = Field(default="development", validation_alias="APP_ENV")
    allowed_origins: str = Field(
        default="http://localhost:8000",
        validation_alias="ALLOWED_ORIGINS",
    )

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    @property
    def origins(self) -> list[str]:
        return [origin.strip() for origin in self.allowed_origins.split(",") if origin.strip()]


settings = Settings()
supabase: Client | None = None
supabase_key = (
    settings.supabase_secret_key
    or settings.supabase_publishable_key
    or settings.supabase_service_role_key
).strip()
supabase_url = settings.supabase_url.strip().rstrip("/")
if supabase_url.endswith("/rest/v1"):
    supabase_url = supabase_url[:-8].rstrip("/")
has_supabase_config = (
    supabase_url.startswith("https://")
    and "your-project" not in supabase_url
    and supabase_key
    and "replace-with-your-" not in supabase_key
    and "your-" not in supabase_key
)
if has_supabase_config:
    supabase = create_client(supabase_url, supabase_key)


app = FastAPI(title=settings.app_name, version="1.0.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def require_supabase() -> Client:
    if supabase is None:
        raise HTTPException(
            status_code=503,
            detail="Supabase is not configured. Add SUPABASE_URL and SUPABASE_SECRET_KEY or SUPABASE_PUBLISHABLE_KEY to .env.",
        )
    return supabase


def clean_location(row: dict[str, Any]) -> dict[str, Any]:
    expiry = row.get("expiry_date")
    return {
        "inventory_id": row.get("inventory_id"),
        "medicine_id": row.get("medicine_id"),
        "medicine_name": row.get("medicine_name"),
        "generic_name": row.get("generic_name"),
        "brand_name": row.get("brand_name"),
        "strength": row.get("strength"),
        "dosage_form": row.get("dosage_form"),
        "batch_number": row.get("batch_number"),
        "quantity": row.get("quantity", 0),
        "reserved_quantity": row.get("reserved_quantity", 0),
        "available_quantity": row.get("available_quantity", 0),
        "low_stock_threshold": row.get("low_stock_threshold", 0),
        "expiry_date": expiry,
        "is_blocked": row.get("is_blocked", False),
        "block_reason": row.get("block_reason"),
        "stock_status": row.get("stock_status"),
        "rack_number": row.get("rack_number"),
        "zone": row.get("zone"),
        "shelf_number": row.get("shelf_number"),
        "shelf_height_cm": row.get("shelf_height_cm"),
        "bin_code": row.get("bin_code"),
        "x_coordinate": row.get("x_coordinate"),
        "y_coordinate": row.get("y_coordinate"),
        "orientation_degrees": row.get("orientation_degrees"),
    }


def clean_catalog_medicine(row: dict[str, Any]) -> dict[str, Any]:
    return {
        "inventory_id": None,
        "medicine_id": row.get("medicine_id"),
        "medicine_name": row.get("name"),
        "generic_name": row.get("generic_name"),
        "brand_name": row.get("brand_name"),
        "strength": row.get("strength"),
        "dosage_form": row.get("dosage_form"),
        "batch_number": None,
        "quantity": 0,
        "reserved_quantity": 0,
        "available_quantity": 0,
        "low_stock_threshold": 0,
        "expiry_date": None,
        "is_blocked": False,
        "block_reason": None,
        "stock_status": "NO_LOCATION",
        "rack_number": None,
        "zone": None,
        "shelf_number": None,
        "shelf_height_cm": None,
        "bin_code": None,
        "x_coordinate": None,
        "y_coordinate": None,
        "orientation_degrees": None,
    }


@app.get("/api/health")
def health() -> dict[str, str]:
    return {
        "status": "ok",
        "database": "configured" if supabase else "not_configured",
    }


@app.get("/api/config")
def frontend_config() -> dict[str, str]:
    return {"app_name": settings.app_name}


@app.get("/api/lookup")
def lookup_medicine(
    q: str = Query(..., min_length=1, max_length=120, description="Medicine name or generic name"),
) -> dict[str, Any]:
    client = require_supabase()
    search = q.strip()
    try:
        medicine_response = (
            client.table("medicines")
            .select("*")
            .or_(f"name.ilike.%{search}%,generic_name.ilike.%{search}%,brand_name.ilike.%{search}%")
            .eq("is_active", True)
            .order("name")
            .limit(20)
            .execute()
        )
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Supabase lookup failed: {exc}") from exc

    # The catalog is the source of truth for medicine search. Inventory is
    # optional because a catalog item may not have stock received yet.
    catalog_rows = medicine_response.data or []
    medicine_ids = [row["medicine_id"] for row in catalog_rows]
    location_rows: list[dict[str, Any]] = []
    if medicine_ids:
        try:
            inventory_response = (
                client.table("inventory_status_view")
                .select("*")
                .in_("medicine_id", medicine_ids)
                .order("expiry_date", desc=False, nullsfirst=False)
                .limit(100)
                .execute()
            )
            location_rows = [clean_location(row) for row in (inventory_response.data or [])]
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Supabase location lookup failed: {exc}") from exc

    locations_by_medicine: dict[str, list[dict[str, Any]]] = {}
    for location in location_rows:
        locations_by_medicine.setdefault(location["medicine_id"], []).append(location)

    rows: list[dict[str, Any]] = []
    for medicine in catalog_rows:
        medicine_locations = locations_by_medicine.get(medicine["medicine_id"])
        rows.extend(medicine_locations or [clean_catalog_medicine(medicine)])

    return {
        "query": search,
        "count": len(catalog_rows),
        "locations": rows,
        "best_match": rows[0] if rows else None,
    }


@app.get("/api/inventory")
def inventory(
    status: str | None = Query(default=None, pattern="^(AVAILABLE|LOW_STOCK|OUT_OF_STOCK|EXPIRED|BLOCKED)$"),
    limit: int = Query(default=50, ge=1, le=200),
) -> dict[str, Any]:
    client = require_supabase()
    try:
        request = client.table("inventory_status_view").select("*").limit(limit)
        if status:
            request = request.eq("stock_status", status)
        response = request.order("medicine_name").execute()
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Supabase inventory request failed: {exc}") from exc
    rows = [clean_location(row) for row in (response.data or [])]
    return {"count": len(rows), "items": rows}


@app.get("/api/summary")
def summary() -> dict[str, Any]:
    client = require_supabase()
    try:
        response = client.table("inventory_status_view").select(
            "inventory_id,medicine_name,available_quantity,stock_status,rack_number,shelf_number"
        ).limit(1000).execute()
        medicine_response = client.table("medicines").select("medicine_id").eq("is_active", True).execute()
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Supabase summary request failed: {exc}") from exc

    rows = response.data or []
    statuses = {status: 0 for status in ("AVAILABLE", "LOW_STOCK", "OUT_OF_STOCK", "EXPIRED", "BLOCKED")}
    for row in rows:
        if row.get("stock_status") in statuses:
            statuses[row["stock_status"]] += 1
    return {
        "locations": len(rows),
        "medicines": len(medicine_response.data or []),
        "available_units": sum(row.get("available_quantity") or 0 for row in rows),
        "low_stock": statuses["LOW_STOCK"],
        "statuses": statuses,
    }


@app.get("/", include_in_schema=False)
def frontend() -> FileResponse:
    return FileResponse(BASE_DIR / "static" / "index.html")


@app.get("/{path:path}", include_in_schema=False)
def frontend_assets(path: str) -> FileResponse:
    file_path = BASE_DIR / "static" / path
    if file_path.is_file():
        return FileResponse(file_path)
    return FileResponse(BASE_DIR / "static" / "index.html")


if __name__ == "__main__":
    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=8000,
        reload=settings.app_env == "development",
    )
