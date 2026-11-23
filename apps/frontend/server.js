// frontend: entry point. Customer page + admin page + JSON API that calls orders and inventory.
// No tracing / OpenTelemetry code on purpose: OBI must see it from the kernel.
//
// Env: PORT (3000), ORDERS_URL, INVENTORY_URL,
//      ADMIN_USER (admin), ADMIN_PASSWORD (empty = admin area disabled),
//      ROBOT_ENABLED (true): start state of the loadgen "robot customer" switch
const crypto = require("crypto");
const express = require("express");

const PORT = process.env.PORT || 3000;
const ORDERS_URL = process.env.ORDERS_URL || "http://orders:8000";
const INVENTORY_URL = process.env.INVENTORY_URL || "http://inventory:8080";
const ADMIN_USER = process.env.ADMIN_USER || "admin";
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || "";

// Robot switch. Kept in memory: a pod restart resets it to ROBOT_ENABLED.
let robotEnabled = (process.env.ROBOT_ENABLED || "true") === "true";

const app = express();
app.use(express.json());

// Call a backend and pass its status code + JSON body straight through.
async function proxy(res, url, options = {}) {
  try {
    const r = await fetch(url, {
      ...options,
      headers: { "content-type": "application/json" },
      signal: AbortSignal.timeout(5000),
    });
    res.status(r.status).json(await r.json());
  } catch (err) {
    res.status(502).json({ error: `upstream ${url}: ${err.message}` });
  }
}

// ---------- admin auth (HTTP Basic) ----------
function safeEqual(a, b) {
  const A = Buffer.from(a);
  const B = Buffer.from(b);
  return A.length === B.length && crypto.timingSafeEqual(A, B);
}

function requireAdmin(req, res, next) {
  const [type, cred] = (req.headers.authorization || "").split(" ");
  if (ADMIN_PASSWORD && type === "Basic" && cred) {
    const [user, ...rest] = Buffer.from(cred, "base64").toString().split(":");
    if (safeEqual(user, ADMIN_USER) && safeEqual(rest.join(":"), ADMIN_PASSWORD)) return next();
  }
  res.set("WWW-Authenticate", 'Basic realm="shop admin"').status(401).json({ error: "admin login required" });
}

// ---------- public API ----------
app.get("/health", (_req, res) => res.json({ status: "ok" }));
app.get("/api/items", (_req, res) => proxy(res, `${INVENTORY_URL}/items`));
app.get("/api/orders", (_req, res) => proxy(res, `${ORDERS_URL}/orders`));
app.post("/api/orders", (req, res) =>
  proxy(res, `${ORDERS_URL}/orders`, {
    method: "POST",
    body: JSON.stringify({ item: req.body.item, qty: Number(req.body.qty) }),
  })
);
// loadgen reads this to know if it should run
app.get("/api/robot", (_req, res) => res.json({ enabled: robotEnabled }));

// ---------- admin area: everything under /admin needs a login ----------
const admin = express.Router();
admin.use(requireAdmin);
admin.post("/api/robot", (req, res) => {
  robotEnabled = req.body.enabled === true;
  console.log(`robot customer ${robotEnabled ? "started" : "stopped"} by admin`);
  res.json({ enabled: robotEnabled });
});
admin.post("/api/restock", (_req, res) => proxy(res, `${INVENTORY_URL}/restock`, { method: "POST" }));
admin.get("/", (req, res) => {
  // Express 5 matches "/admin" and "/admin/" the same; only redirect the one without a slash
  if (!req.originalUrl.split("?")[0].endsWith("/")) return res.redirect("/admin/");
  res.type("html").send(ADMIN_PAGE);
});
app.use("/admin", admin);

// ---------- pages ----------
const STYLE = `<style>body{font-family:sans-serif;max-width:640px;margin:2rem auto;padding:0 1rem}
table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left}
pre{background:#f4f4f4;padding:8px}.on{color:green}.off{color:#b00}</style>`;

app.get("/", (_req, res) => {
  res.type("html").send(`<!doctype html>
<html><head><meta charset="utf-8"><title>Shop</title>${STYLE}</head>
<body>
<h1>Shop (OBI POC)</h1>
<p>Robot customer: <b id="robot">…</b> · <a href="/admin/">admin</a></p>
<h2>Stock</h2><pre id="items">loading…</pre>
<h2>Place order</h2>
<form id="f">
  <select name="item"><option>apple</option><option>banana</option><option>cherry</option></select>
  <input name="qty" type="number" value="1" min="1" style="width:4rem">
  <button>Buy</button>
</form>
<pre id="result"></pre>
<h2>Recent orders</h2><table id="orders"></table>
<script>
async function load() {
  document.getElementById("items").textContent = JSON.stringify(await (await fetch("/api/items")).json());
  const robot = (await (await fetch("/api/robot")).json()).enabled;
  const r = document.getElementById("robot");
  r.textContent = robot ? "running" : "stopped"; r.className = robot ? "on" : "off";
  const orders = await (await fetch("/api/orders")).json();
  document.getElementById("orders").innerHTML = "<tr><th>id</th><th>item</th><th>qty</th><th>amount</th><th>status</th></tr>" +
    orders.map(o => "<tr><td>"+o.id+"</td><td>"+o.item+"</td><td>"+o.qty+"</td><td>"+o.amount+"</td><td>"+o.status+"</td></tr>").join("");
}
document.getElementById("f").onsubmit = async (e) => {
  e.preventDefault();
  const body = Object.fromEntries(new FormData(e.target));
  const r = await fetch("/api/orders", {method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify(body)});
  document.getElementById("result").textContent = r.status + " " + JSON.stringify(await r.json());
  load();
};
load(); setInterval(load, 5000);
</script>
</body></html>`);
});

const ADMIN_PAGE = `<!doctype html>
<html><head><meta charset="utf-8"><title>Shop admin</title>${STYLE}</head>
<body>
<h1>Shop admin</h1>
<p><a href="/">← back to shop</a></p>
<h2>Robot customer (loadgen)</h2>
<p>Status: <b id="robot">…</b> <button id="toggle">…</button></p>
<p><small>loadgen checks this switch every few seconds.</small></p>
<h2>Stock</h2>
<pre id="items">loading…</pre>
<button id="restock">Restock all items</button>
<pre id="result"></pre>
<script>
let enabled = null;
async function load() {
  document.getElementById("items").textContent = JSON.stringify(await (await fetch("/api/items")).json());
  enabled = (await (await fetch("/api/robot")).json()).enabled;
  const r = document.getElementById("robot");
  r.textContent = enabled ? "running" : "stopped"; r.className = enabled ? "on" : "off";
  document.getElementById("toggle").textContent = enabled ? "Stop robot" : "Start robot";
}
async function post(url, body) {
  const r = await fetch(url, {method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify(body || {})});
  document.getElementById("result").textContent = r.status + " " + JSON.stringify(await r.json());
  load();
}
document.getElementById("toggle").onclick = () => post("/admin/api/robot", {enabled: !enabled});
document.getElementById("restock").onclick = () => post("/admin/api/restock");
load(); setInterval(load, 5000);
</script>
</body></html>`;

if (!ADMIN_PASSWORD) console.warn("ADMIN_PASSWORD is empty: admin area is disabled");
app.listen(PORT, () => console.log(`frontend listening on :${PORT}`));
