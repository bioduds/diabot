const api = (path, options = {}) =>
  fetch(path, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  }).then(async (res) => {
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.detail || res.statusText);
    return data;
  });

const $ = (sel) => document.querySelector(sel);
const chatMessages = $("#chat-messages");
const setupOverlay = $("#setup-overlay");
const toast = $("#toast");

function showToast(message) {
  toast.textContent = message;
  toast.classList.remove("hidden");
  setTimeout(() => toast.classList.add("hidden"), 2600);
}

function appendMessage(role, content) {
  const div = document.createElement("div");
  div.className = `msg ${role}`;
  div.textContent = content;
  chatMessages.appendChild(div);
  chatMessages.scrollTop = chatMessages.scrollHeight;
}

async function loadLibreLinkUpStatus() {
  const status = await api("/api/librelinkup/status");
  const connectedView = $("#llu-connected");
  const connectForm = $("#llu-connect-form");

  if (status.connected) {
    connectedView.classList.remove("hidden");
    connectForm.classList.add("hidden");
    $("#llu-email").textContent = status.email ? ` · ${status.email}` : "";
    $("#llu-patient").textContent = status.patient_name ? ` · ${status.patient_name}` : "";
    const syncInfo = $("#llu-sync-info");
    if (status.last_sync_at) {
      const when = new Date(status.last_sync_at).toLocaleString();
      syncInfo.textContent =
        status.last_sync_status === "ok"
          ? `Last sync: ${when}`
          : `Last sync failed (${when}): ${status.last_error || "unknown error"}`;
    } else {
      syncInfo.textContent = "Not synced yet.";
    }
  } else {
    connectedView.classList.add("hidden");
    connectForm.classList.remove("hidden");
  }
}

$("#llu-connect-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const statusEl = $("#llu-status");
  const btn = e.target.querySelector("button[type='submit']");
  const data = formToObject(e.target);
  btn.disabled = true;
  statusEl.textContent = "Connecting to LibreLinkUp…";
  try {
    const result = await api("/api/librelinkup/connect", {
      method: "POST",
      body: JSON.stringify(data),
    });
    statusEl.textContent = `Connected. Imported ${result.sync?.inserted ?? 0} new readings.`;
    e.target.password.value = "";
    await Promise.all([loadLibreLinkUpStatus(), loadStats(), loadReminders()]);
  } catch (err) {
    statusEl.textContent = err.message;
  } finally {
    btn.disabled = false;
  }
});

$("#llu-sync-btn").addEventListener("click", async () => {
  const btn = $("#llu-sync-btn");
  btn.disabled = true;
  try {
    const result = await api("/api/librelinkup/sync", { method: "POST" });
    showToast(`Synced ${result.inserted} new readings`);
    await Promise.all([loadLibreLinkUpStatus(), loadStats(), loadReminders()]);
  } catch (err) {
    showToast(err.message);
  } finally {
    btn.disabled = false;
  }
});

$("#llu-disconnect-btn").addEventListener("click", async () => {
  if (!confirm("Disconnect LibreLinkUp from GlycoGuide?")) return;
  await api("/api/librelinkup/disconnect", { method: "DELETE" });
  showToast("LibreLinkUp disconnected");
  await loadLibreLinkUpStatus();
});

async function loadHealth() {
  const data = await api("/api/health");
  const badge = $("#ollama-status");
  const ollama = data.ollama;
  if (ollama.connected && ollama.model_available) {
    badge.textContent = `Ollama · ${ollama.model}`;
    badge.classList.add("ok");
  } else if (ollama.connected) {
    badge.textContent = `Model missing: ${ollama.model}`;
    badge.classList.add("err");
  } else {
    badge.textContent = "Ollama offline";
    badge.classList.add("err");
  }
}

async function loadStats() {
  const stats = await api("/api/glucose/stats?hours=24");
  const unit = stats.unit || "mg/dL";
  $("#stat-latest").textContent = stats.count ? `${stats.latest} ${unit}` : "—";
  $("#stat-avg").textContent = stats.count ? `${stats.average} ${unit}` : "—";
  $("#stat-range").textContent = stats.count ? `${stats.min}–${stats.max}` : "—";
  $("#stat-count").textContent = stats.count ?? 0;
}

async function loadReminders() {
  const items = await api("/api/checkins");
  const list = $("#reminders-list");
  list.innerHTML = "";
  if (!items.length) {
    list.innerHTML = '<p class="muted">All caught up — keep logging so I can help interpret trends.</p>';
    return;
  }
  items.forEach((item) => {
    const div = document.createElement("div");
    div.className = `reminder ${item.priority}`;
    div.textContent = item.message;
    list.appendChild(div);
  });
}

async function loadChatHistory() {
  const history = await api("/api/chat/history");
  chatMessages.innerHTML = "";
  history.forEach((msg) => appendMessage(msg.role, msg.content));
}

async function ensureProfile() {
  const profile = await api("/api/profile");
  if (!profile.disclaimer_accepted) {
    setupOverlay.classList.remove("hidden");
    return false;
  }
  setupOverlay.classList.add("hidden");
  prefillInsulinFields(profile);
  return true;
}

function prefillInsulinFields(profile) {
  const insulinType = $("#insulin-form input[name='insulin_type']");
  if (insulinType && !insulinType.value) {
    insulinType.placeholder = profile.bolus_insulin || "Insulin type";
  }
}

function formToObject(form) {
  const data = Object.fromEntries(new FormData(form).entries());
  Object.keys(data).forEach((key) => {
    if (data[key] === "") delete data[key];
    else if (!isNaN(data[key]) && data[key] !== "") data[key] = Number(data[key]);
  });
  return data;
}

$("#setup-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const data = formToObject(e.target);
  data.disclaimer_accepted = e.target.disclaimer_accepted.checked;
  try {
    await api("/api/profile", { method: "PUT", body: JSON.stringify(data) });
    setupOverlay.classList.add("hidden");
    showToast("Profile saved");
    await bootstrap();
  } catch (err) {
    showToast(err.message);
  }
});

$("#edit-profile-btn").addEventListener("click", async () => {
  const profile = await api("/api/profile");
  const form = $("#setup-form");
  Object.entries(profile).forEach(([key, value]) => {
    const field = form.elements[key];
    if (!field) return;
    if (field.type === "checkbox") field.checked = !!value;
    else field.value = value ?? "";
  });
  setupOverlay.classList.remove("hidden");
});

document.querySelectorAll(".tab").forEach((tab) => {
  tab.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach((t) => t.classList.remove("active"));
    document.querySelectorAll(".log-form").forEach((f) => f.classList.remove("active"));
    tab.classList.add("active");
    document.querySelector(`.log-form[data-panel='${tab.dataset.tab}']`).classList.add("active");
  });
});

async function bindLogForm(formId, endpoint) {
  $(formId).addEventListener("submit", async (e) => {
    e.preventDefault();
    const data = formToObject(e.target);
    try {
      await api(endpoint, { method: "POST", body: JSON.stringify(data) });
      e.target.reset();
      showToast("Logged successfully");
      await Promise.all([loadStats(), loadReminders()]);
    } catch (err) {
      showToast(err.message);
    }
  });
}

bindLogForm("#carbs-form", "/api/logs/carbs");
bindLogForm("#exercise-form", "/api/logs/exercise");
bindLogForm("#weight-form", "/api/logs/weight");
bindLogForm("#insulin-form", "/api/logs/insulin");

$("#csv-import").addEventListener("change", async (e) => {
  const file = e.target.files[0];
  if (!file) return;
  const status = $("#import-status");
  status.textContent = "Importing…";
  const body = new FormData();
  body.append("file", file);
  try {
    const res = await fetch("/api/glucose/import", { method: "POST", body });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || "Import failed");
    status.textContent = `Imported ${data.inserted} new readings (${data.parsed} parsed).`;
    await Promise.all([loadStats(), loadReminders()]);
  } catch (err) {
    status.textContent = err.message;
  }
  e.target.value = "";
});

$("#chat-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const input = $("#chat-input");
  const message = input.value.trim();
  if (!message) return;
  input.value = "";
  appendMessage("user", message);
  const btn = e.target.querySelector("button");
  btn.disabled = true;
  try {
    const { reply } = await api("/api/chat", {
      method: "POST",
      body: JSON.stringify({ message }),
    });
    appendMessage("assistant", reply);
    await loadReminders();
  } catch (err) {
    appendMessage("assistant", err.message);
  } finally {
    btn.disabled = false;
  }
});

async function bootstrap() {
  await loadHealth();
  const ready = await ensureProfile();
  await loadLibreLinkUpStatus();
  await loadStats();
  await loadReminders();
  if (ready) {
    await loadChatHistory();
    if (!chatMessages.children.length) {
      try {
        const { reply } = await api("/api/chat/welcome", { method: "POST" });
        appendMessage("assistant", reply);
      } catch {
        appendMessage(
          "assistant",
          "Hi — I'm GlycoGuide. Connect LibreLinkUp or import a CSV, log carbs, exercise, weight, and insulin, then ask me to help interpret patterns. I'm not a doctor."
        );
      }
    }
  }
}

bootstrap();
setInterval(loadReminders, 60_000);
setInterval(loadStats, 120_000);
setInterval(loadLibreLinkUpStatus, 180_000);
