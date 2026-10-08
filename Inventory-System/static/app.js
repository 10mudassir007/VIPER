const form = document.querySelector("#search-form");
const input = document.querySelector("#medicine-search");
const resultContainer = document.querySelector("#result-container");
const resultTitle = document.querySelector("#result-title");
const resultCount = document.querySelector("#result-count");
const connectionLabel = document.querySelector("#connection-label");

const escapeHtml = (value) =>
  String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#039;"
  }[char]));

async function loadAppConfig() {
  try {
    const response = await fetch("/api/config");
    const config = await response.json();
    if (!response.ok || !config.app_name) return;
    const appName = config.app_name;
    document.title = `${appName} | Pharmacy inventory`;
    document.querySelectorAll("[data-app-name]").forEach((element) => {
      element.textContent = config.app_name;
    });
    document.querySelector(".brand")?.setAttribute("aria-label", `${config.app_name} home`);
  } catch {
    // Keep the static fallback text when configuration is unavailable.
  }
}

function showError(message) {
  resultContainer.innerHTML = `<div class="empty-state"><div class="empty-icon">!</div><h3>Could not load that location</h3><p>${escapeHtml(message)}</p></div>`;
}

function statusClass(status) {
  if (status === "LOW_STOCK") return "low";
  if (status === "OUT_OF_STOCK" || status === "EXPIRED" || status === "BLOCKED") return "out";
  if (status === "NO_LOCATION") return "out";
  return "available";
}

function renderLocations(locations) {
  resultContainer.innerHTML = locations.map((location) => `
    <article class="location-card ${location.stock_status === "LOW_STOCK" ? "low-stock" : ""}">
      <div>
        <h3 class="medicine-name">${escapeHtml(location.medicine_name)}</h3>
        <p class="medicine-meta">${escapeHtml(location.generic_name || "No generic name")} · ${escapeHtml(location.dosage_form || "Medicine")}</p>
        <span class="stock-chip ${statusClass(location.stock_status)}">${location.stock_status === "NO_LOCATION" ? "No shelf assigned" : escapeHtml((location.stock_status || "available").replaceAll("_", " "))}</span>
      </div>
      <div class="location-block">
        <p class="location-label">Rack / shelf</p>
        <p class="location-value">${escapeHtml(location.rack_number || "—")} <span>${location.shelf_number ? `· shelf ${escapeHtml(location.shelf_number)}` : ""}</span></p>
        <p class="medicine-meta">${location.shelf_height_cm ? `${escapeHtml(location.shelf_height_cm)} cm high` : "Receive stock to assign a location"}</p>
      </div>
      <div class="location-block">
        <p class="location-label">Bin / available</p>
        <p class="location-value">${escapeHtml(location.bin_code || "Open shelf")}</p>
        <p class="medicine-meta">${location.inventory_id ? `${escapeHtml(location.available_quantity)} units ready · batch ${escapeHtml(location.batch_number || "—")}` : "No inventory recorded"}</p>
        ${location.block_reason ? `<p class="medicine-meta">${escapeHtml(location.block_reason)}</p>` : ""}
      </div>
    </article>
  `).join("");
}

async function lookup(query) {
  resultTitle.textContent = "Searching inventory";
  resultCount.textContent = "";
  resultContainer.innerHTML = '<p class="loading">Checking every active location…</p>';
  try {
    const response = await fetch(`/api/lookup?q=${encodeURIComponent(query)}`);
    const data = await response.json();
    if (!response.ok) throw new Error(data.detail || "The inventory service is unavailable.");
    if (!data.locations.length) {
      resultTitle.textContent = "No location found";
      resultContainer.innerHTML = `<div class="empty-state"><div class="empty-icon">⌕</div><h3>Nothing matched “${escapeHtml(query)}”</h3><p>Try the brand name, generic name, or a shorter search.</p></div>`;
      return;
    }
    resultTitle.textContent = data.best_match.medicine_name;
    resultCount.textContent = `${data.count} location${data.count === 1 ? "" : "s"} found`;
    renderLocations(data.locations);
  } catch (error) {
    resultTitle.textContent = "Location unavailable";
    showError(error.message);
  }
}

async function loadSummary() {
  try {
    const response = await fetch("/api/summary");
    const data = await response.json();
    if (!response.ok) throw new Error(data.detail || "Inventory request failed.");
    document.querySelector("#stat-medicines").textContent = data.medicines;
    document.querySelector("#stat-units").textContent = data.available_units.toLocaleString();
    document.querySelector("#stat-low").textContent = data.low_stock;
    connectionLabel.textContent = "Live inventory";
  } catch (error) {
    const message = error.message || "";
    connectionLabel.textContent = message.includes("not configured")
      ? "Needs configuration"
      : message.includes("inventory_status_view")
        ? "Database schema needs setup"
        : "Inventory request failed";
  }
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  const query = input.value.trim();
  if (query) lookup(query);
});
document.querySelector("#refresh-summary").addEventListener("click", loadSummary);
loadAppConfig();
loadSummary();
