# Shelfwise inventory locator

Shelfwise is a FastAPI application that searches the Supabase `inventory_status_view` from your schema and returns the best medicine location: rack, shelf, bin, stock state, and available quantity.

## Setup

1. Create a Supabase project and run `SCHEMA.sql` in the SQL Editor.
2. Copy `.env.example` to `.env`.
3. Fill in `SUPABASE_URL` and one of the following keys:
   - `SUPABASE_SECRET_KEY` (recommended for this backend; server-only and bypasses RLS)
   - `SUPABASE_PUBLISHABLE_KEY` (use only when your RLS policies allow the request)
   - `SUPABASE_SERVICE_ROLE_KEY` (legacy fallback supported for older projects)

   Never expose a secret key or service-role key to the browser. The application automatically prefers `SUPABASE_SECRET_KEY`, then `SUPABASE_PUBLISHABLE_KEY`, then the legacy service-role key. Use the project URL without `/rest/v1/`; the application removes that suffix if it is accidentally included.
4. Install dependencies and start the app:

```powershell
& D:\Portfolio\venv\Scripts\python.exe -m pip install -r requirements.txt
& D:\Portfolio\venv\Scripts\python.exe main.py
```

The application serves the frontend at http://localhost:8000/ and Swagger documentation at http://localhost:8000/docs. You can also start it with `uvicorn main:app --reload`.

The backend reads the v3 schema's `public.inventory_status_view`, including FEFO-ready stock status, blocked-bin state, rack, shelf, and bin location. The service/secret key is required because the schema intentionally grants no table or view access to anonymous or authenticated clients. If Supabase reports that the view is missing from the schema cache, run the complete `SCHEMA.sql` in Supabase SQL Editor, then reload the schema cache from Supabase Dashboard -> Settings -> API (or wait briefly for it to refresh).
