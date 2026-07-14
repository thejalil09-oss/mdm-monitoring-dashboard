/* OrgLab MDM Dashboard renderer */
(function () {
  "use strict";

  var DATA = window.MDM_DATA;
  if (!DATA) { document.title = "No data"; return; }

  var RING_R = 36;
  var RING_C = 2 * Math.PI * RING_R;

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function ringColor(score) {
    if (score >= 100) return "#34d399";
    if (score >= 60) return "#fbbf24";
    return "#f87171";
  }

  function statusToken(status) {
    return String(status || "NON-COMPLIANT").replace(/ /g, "-").toUpperCase();
  }

  function scoreRing(score) {
    var frac = Math.max(0, Math.min(1, score / 100));
    return (
      '<div class="score-ring">' +
        '<svg width="84" height="84" viewBox="0 0 84 84">' +
          '<circle class="ring-bg" cx="42" cy="42" r="' + RING_R + '" fill="none" stroke-width="7" />' +
          '<circle class="ring-val" cx="42" cy="42" r="' + RING_R + '" fill="none" stroke-width="7" ' +
            'stroke-dasharray="' + RING_C + '" stroke-dashoffset="' + (RING_C * (1 - frac)) + '" ' +
            'style="--ring-color:' + ringColor(score) + '" />' +
        "</svg>" +
        '<div class="score-text">' + Math.round(score) + "</div>" +
      "</div>"
    );
  }

  function batteryHealthLabel(h) {
    var m = { 1: "Unknown", 2: "Good", 3: "Overheat", 4: "Dead", 5: "Over voltage", 6: "Unspecified failure", 7: "Cold" };
    return m[h] || ("(" + h + ")");
  }

  function batteryStatusLabel(s) {
    var m = { 1: "Unknown", 2: "Charging", 3: "Discharging", 4: "Not charging", 5: "Full" };
    return m[s] || ("(" + s + ")");
  }

  function renderMeta() {
    document.getElementById("agentName").textContent = DATA.agent;
    document.getElementById("agentVersion").textContent = "v" + DATA.agentVersion;
    document.getElementById("generatedAt").textContent = "Collected " + (DATA.generatedAt || "").replace("T", " ").replace("Z", " UTC");
  }

  function renderKpis() {
    var devices = DATA.devices || [];
    var compliant = devices.filter(function (d) { return d.compliance.status === "COMPLIANT"; }).length;
    var atRisk = devices.filter(function (d) { return d.compliance.status === "AT RISK"; }).length;
    var nonCompliant = devices.filter(function (d) { return d.compliance.status === "NON-COMPLIANT"; }).length;
    var avg = devices.length
      ? (devices.reduce(function (s, d) { return s + d.compliance.score; }, 0) / devices.length).toFixed(1)
      : 0;

    var items = [
      { label: "Devices monitored", value: devices.length, note: "Android emulator fleet", color: "#22d3ee" },
      { label: "Compliant", value: compliant, note: "score = 100%", color: "#34d399" },
      { label: "At risk", value: atRisk, note: "score 60-99%", color: "#fbbf24" },
      { label: "Non-compliant", value: nonCompliant, note: "score < 60%", color: "#f87171" },
      { label: "Fleet avg score", value: avg + "%", note: "weighted per policy", color: "#60a5fa" }
    ];

    document.getElementById("kpis").innerHTML = items.map(function (it) {
      return (
        '<div class="kpi" style="--kpi-color:' + it.color + '">' +
          '<div class="kpi-label">' + it.label + "</div>" +
          '<div class="kpi-value">' + it.value + "</div>" +
          '<div class="kpi-note">' + it.note + "</div>" +
        "</div>"
      );
    }).join("");
  }

  function renderPolicyStrip() {
    document.getElementById("policyName").textContent = (DATA.policy && DATA.policy.name) || "Policy";
    document.getElementById("policyDesc").textContent = (DATA.policy && DATA.policy.description) || "";
  }

  function renderDeviceCard(d) {
    var id = d.identity;
    var inv = d.inventory;
    var checks = d.compliance.checks || [];

    var checkRows = checks.map(function (c) {
      return (
        "<tr>" +
          '<td><span class="result ' + c.result + '">' + c.result + "</span></td>" +
          "<td>" + esc(c.title) + (c.detail ? '<div style="font-size:10.5px;color:var(--muted)">' + esc(c.detail) + "</div>" : "") + "</td>" +
          "<td>" + c.weight + "</td>" +
          '<td class="actual">' + esc(c.actual) + "</td>" +
        "</tr>"
      );
    }).join("");

    var apps = (inv.apps || []).slice(0, 12).map(function (a) { return '<span class="chip">' + esc(a) + "</span>"; }).join("");

    return (
      '<div class="card">' +
        '<div class="card-head">' +
          scoreRing(d.compliance.score) +
          '<div class="card-title">' +
            "<h3>" + esc(id.deviceName || id.model) + "</h3>" +
            '<div class="meta">' + esc(id.model) + " &middot; " + esc(id.manufacturer) + " &middot; " + esc(id.adbSerial) + "</div>" +
            '<div class="meta">' + esc(id.osVersion || "") + " (API " + esc(id.sdkLevel || "?") + ") &middot; patch " + esc(id.securityPatch || "?") + "</div>" +
          "</div>" +
          '<span class="badge ' + statusToken(d.compliance.status) + '">' + esc(d.compliance.status) + "</span>" +
        "</div>" +
        '<div class="card-body">' +
          '<div class="info-grid">' +
            infoItem("Android ID", id.androidId) +
            infoItem("Battery", (inv.batteryLevel >= 0 ? inv.batteryLevel + "%" : "n/a") + " · " + batteryHealthLabel(inv.batteryHealth)) +
            infoItem("Charge status", batteryStatusLabel(inv.batteryStatus)) +
            infoItem("Storage", (inv.storageUsedGb || 0) + " / " + (inv.storageTotalGb || 0) + " GB") +
            infoItem("Installed apps", inv.appCount + "") +
            infoItem("Last check-in", (d.lastCheckIn || "").replace("T", " ").replace("Z", "")) +
          "</div>" +
          '<table class="checks">' +
            "<thead><tr><th>Result</th><th>Control</th><th>W</th><th>Observed state</th></tr></thead>" +
            "<tbody>" + checkRows + "</tbody>" +
          "</table>" +
          (apps ? '<div class="apps-strip"><div class="apps-label">Third-party apps (' + inv.appCount + ")</div><div class=\"app-chips\">" + apps + "</div></div>" : "") +
        "</div>" +
      "</div>"
    );
  }

  function infoItem(k, v) {
    return '<div class="info-item"><div class="k">' + k + '</div><div class="v">' + esc(v) + "</div></div>";
  }

  function renderCards() {
    var devices = DATA.devices || [];
    document.getElementById("fleetCount").textContent = devices.length + " device" + (devices.length === 1 ? "" : "s") + " online";
    document.getElementById("cards").innerHTML = devices.map(renderDeviceCard).join("");
  }

  function renderBaseline() {
    var rules = (DATA.policy && DATA.policy.rules) || [];
    document.getElementById("ruleRows").innerHTML = rules.map(function (r) {
      return (
        "<tr>" +
          "<td><code>" + esc(r.id) + "</code></td>" +
          "<td>" + esc(r.title) + "</td>" +
          '<td><span class="sev ' + (r.severity || "").toLowerCase() + '">' + esc(r.severity) + "</span></td>" +
          "<td>" + r.weight + "</td>" +
          "<td>" + esc(r.expected) + "</td>" +
        "</tr>"
      );
    }).join("");
  }

  renderMeta();
  renderKpis();
  renderPolicyStrip();
  renderCards();
  renderBaseline();
})();
