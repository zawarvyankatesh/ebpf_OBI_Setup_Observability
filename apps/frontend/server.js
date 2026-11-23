// frontend: entry point. Tiny HTML page + JSON API that calls orders and inventory.
// No tracing / OpenTelemetry code on purpose: OBI must see it from the kernel.
// Env: PORT (3000), ORDERS_URL, INVENTORY_URL
const express = require("express");

const PORT = process.env.PORT || 3000;
const ORDERS_URL = process.env.ORDERS_URL || "http://orders:8000";
const INVENTORY_URL = process.env.INVENTORY_URL || "http://inventory:8080";

const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: false }));

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

app.get("/health", (_req, res) => res.json({ status: "ok" }));

app.get("/api/items", (_req, res) => proxy(res, `${INVENTORY_URL}/items`));
app.post("/api/restock", (_req, res) => proxy(res, `${INVENTORY_URL}/restock`, { method: "POST" }));
app.get("/api/orders", (_req, res) => proxy(res, `${ORDERS_URL}/orders`));
app.post("/api/orders", (req, res) =>
  proxy(res, `${ORDERS_URL}/orders`, {
    method: "POST",
    body: JSON.stringify({ item: req.body.item, qty: Number(req.body.qty) }),
  })
);

// Minimal page: stock, an order form, recent orders.
app.get("/", (_req, res) => {
  res.type("html").send(`<!doctype html>
<html><head><meta charset="utf-8"><title>Shop</title>
<style>body{font-family:sans-serif;max-width:640px;margin:2rem auto;padding:0 1rem}
table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:4px 8px;text-align:left}
pre{background:#f4f4f4;padding:8px}</style></head>
<body>
<h1>Shop (OBI POC)</h1>
<h2>Stock</h2><pre id="items">loading…</pre>
<h2>Place order</h2>
<form id="f">
  <select name="item"><option>apple</option><option>banana</option><option>cherry</option></select>
  <input name="qty" type="number" value="1" min="1" style="width:4rem">
  <button>Buy</button> <button type="button" id="restock">Restock</button>
</form>
<pre id="result"></pre>
<h2>Recent orders</h2><table id="orders"></table>
<script>
async function load() {
  document.getElementById("items").textContent = JSON.stringify(await (await fetch("/api/items")).json());
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
document.getElementById("restock").onclick = async () => { await fetch("/api/restock", {method: "POST"}); load(); };
load(); setInterval(load, 5000);
</script>
</body></html>`);
});

app.listen(PORT, () => console.log(`frontend listening on :${PORT}`));
