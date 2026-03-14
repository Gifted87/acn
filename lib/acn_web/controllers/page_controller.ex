defmodule ACNWeb.PageController do
  use Phoenix.Controller, namespace: ACNWeb

  def index(conn, _params) do
    html(conn, dashboard_html())
  end

  defp dashboard_html do
    ~S"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ACN · Holographic Shadow-Graph</title>
    <script src="https://cdn.jsdelivr.net/npm/d3@7/dist/d3.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/phoenix@1.6.16/priv/static/phoenix.min.js"></script>
    <style>
    /* ─── Reset & Base ─────────────────────────────────────────── */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    :root {
      --bg:          #050810;
      --surface:     #0b1020;
      --border:      #1a2540;
      --accent-cyan: #00f5ff;
      --accent-blue: #4488ff;
      --accent-green:#39ff6f;
      --accent-orange:#ff8c42;
      --accent-red:  #ff3355;
      --accent-yellow:#ffd700;
      --text-primary:#e8edf8;
      --text-muted:  #4f6080;
      --font: 'Courier New', monospace;
      --sidebar-w: 280px;
      --topbar-h: 52px;
      --console-h: 160px;
    }
    html, body { width:100%; height:100%; background:var(--bg); color:var(--text-primary); font-family:var(--font); overflow:hidden; }

    /* ─── Top Bar ──────────────────────────────────────────────── */
    #topbar {
      position:fixed; top:0; left:0; right:0; height:var(--topbar-h);
      background: linear-gradient(90deg, #050810 0%, #0a1628 60%, #050810 100%);
      border-bottom:1px solid var(--border);
      display:flex; align-items:center; padding:0 20px; gap:16px; z-index:100;
    }
    #topbar .logo {
      font-size:18px; font-weight:700; letter-spacing:3px;
      background: linear-gradient(90deg, var(--accent-cyan), var(--accent-blue));
      -webkit-background-clip:text; -webkit-text-fill-color:transparent;
    }
    #topbar .pulse-dot {
      width:8px; height:8px; border-radius:50%; background:var(--accent-green);
      box-shadow:0 0 8px var(--accent-green);
      animation: pulse-glow 1.5s ease-in-out infinite;
    }
    @keyframes pulse-glow {
      0%,100%{box-shadow:0 0 4px var(--accent-green);opacity:1}
      50%{box-shadow:0 0 14px var(--accent-green);opacity:.7}
    }
    #topbar .spacer { flex:1; }
    #topbar .metric {
      display:flex; flex-direction:column; align-items:center;
      padding:4px 12px; border:1px solid var(--border); border-radius:6px;
      background:rgba(255,255,255,.02);
    }
    #topbar .metric .val { font-size:18px; color:var(--accent-cyan); font-weight:700; }
    #topbar .metric .lbl { font-size:9px; color:var(--text-muted); letter-spacing:1.5px; margin-top:2px; }

    /* ─── Sidebar ──────────────────────────────────────────────── */
    #sidebar {
      position:fixed; top:var(--topbar-h); left:0; bottom:var(--console-h);
      width:var(--sidebar-w);
      background:var(--surface); border-right:1px solid var(--border);
      display:flex; flex-direction:column; overflow:hidden; z-index:90;
    }
    .sidebar-section { padding:14px 16px; border-bottom:1px solid var(--border); }
    .sidebar-section h3 { font-size:10px; letter-spacing:2px; color:var(--text-muted); margin-bottom:10px; }
    .query-btn {
      width:100%; padding:8px 12px; margin-bottom:6px;
      background:rgba(0,245,255,.06); border:1px solid rgba(0,245,255,.2);
      color:var(--accent-cyan); font-family:var(--font); font-size:11px;
      letter-spacing:1px; border-radius:6px; cursor:pointer;
      transition: all .2s ease;
      text-align:left;
    }
    .query-btn:hover {
      background:rgba(0,245,255,.14); border-color:var(--accent-cyan);
      box-shadow:0 0 12px rgba(0,245,255,.25);
    }
    .query-btn .btn-icon { margin-right:6px; opacity:.7; }

    #node-detail { flex:1; overflow-y:auto; padding:14px 16px; }
    #node-detail h3 { font-size:10px; letter-spacing:2px; color:var(--text-muted); margin-bottom:10px; }
    .detail-row { display:flex; flex-direction:column; margin-bottom:10px; }
    .detail-row .key { font-size:9px; color:var(--text-muted); letter-spacing:1px; }
    .detail-row .val { font-size:12px; color:var(--text-primary); word-break:break-all; margin-top:2px; }
    .vector-badge {
      display:inline-block; padding:2px 7px; border-radius:3px; font-size:9px;
      letter-spacing:1px; margin:2px;
    }
    .v-cog  { background:rgba(68,136,255,.2);  border:1px solid var(--accent-blue);   color:var(--accent-blue); }
    .v-phys { background:rgba(57,255,111,.15); border:1px solid var(--accent-green);  color:var(--accent-green);}
    .v-sec  { background:rgba(255,140,66,.15); border:1px solid var(--accent-orange); color:var(--accent-orange);}
    .v-auto { background:rgba(255,51,85,.15);  border:1px solid var(--accent-red);    color:var(--accent-red); }

    /* Stress bar */
    #stress-bar-wrap { padding:12px 16px; border-bottom:1px solid var(--border); }
    #stress-bar-wrap h3 { font-size:10px; letter-spacing:2px; color:var(--text-muted); margin-bottom:8px; }
    #stress-track {
      height:6px; background:rgba(255,255,255,.06); border-radius:3px; overflow:hidden;
    }
    #stress-fill {
      height:100%; width:0%; border-radius:3px;
      background: linear-gradient(90deg, var(--accent-green), var(--accent-yellow), var(--accent-red));
      transition: width .3s ease;
    }
    #stress-val { font-size:11px; color:var(--text-muted); margin-top:4px; }

    /* ─── Canvas Area ───────────────────────────────────────────── */
    #canvas-wrap {
      position:fixed;
      top:var(--topbar-h); left:var(--sidebar-w); right:0; bottom:var(--console-h);
    }
    #hsg-canvas { display:block; width:100%; height:100%; }

    /* Tooltip */
    #tooltip {
      position:fixed; pointer-events:none; z-index:200;
      background:rgba(5,8,16,.92); border:1px solid var(--border);
      border-radius:8px; padding:10px 14px; font-size:11px;
      box-shadow:0 8px 32px rgba(0,0,0,.6);
      display:none; max-width:260px;
    }
    #tooltip .tt-id { font-size:13px; color:var(--accent-cyan); font-weight:700; margin-bottom:6px; }
    #tooltip .tt-row { color:var(--text-muted); font-size:10px; margin-top:3px; }
    #tooltip .tt-row span { color:var(--text-primary); }

    /* ─── Console ───────────────────────────────────────────────── */
    #console {
      position:fixed; left:var(--sidebar-w); right:0; bottom:0; height:var(--console-h);
      background:var(--surface); border-top:1px solid var(--border); z-index:90;
      display:flex; flex-direction:column;
    }
    #console-header {
      padding:6px 14px; background:rgba(0,245,255,.04); border-bottom:1px solid var(--border);
      display:flex; align-items:center; gap:8px;
    }
    #console-header span { font-size:9px; letter-spacing:2px; color:var(--text-muted); }
    #console-header .live-badge {
      font-size:8px; letter-spacing:1.5px; padding:2px 7px;
      border-radius:3px; background:rgba(57,255,111,.12); color:var(--accent-green);
      border:1px solid rgba(57,255,111,.3);
    }
    #event-log {
      flex:1; overflow-y:auto; padding:6px 14px; display:flex; flex-direction:column-reverse;
    }
    #event-log::-webkit-scrollbar { width:4px; }
    #event-log::-webkit-scrollbar-track { background:transparent; }
    #event-log::-webkit-scrollbar-thumb { background:var(--border); border-radius:2px; }
    .log-entry {
      display:flex; gap:8px; padding:3px 0; font-size:11px;
      border-bottom:1px solid rgba(255,255,255,.03);
      animation: fadeIn .3s ease;
    }
    @keyframes fadeIn { from{opacity:0;transform:translateY(4px)} to{opacity:1;transform:none} }
    .log-entry .ts  { color:var(--text-muted); white-space:nowrap; min-width:80px; }
    .log-entry .node { color:var(--accent-cyan); min-width:120px; }
    .log-entry .phase {
      padding:1px 6px; border-radius:3px; font-size:9px;
      color:#000; white-space:nowrap;
    }
    .log-entry .vectors { color:var(--text-muted); font-size:10px; }

    /* ─── Query Modal ───────────────────────────────────────────── */
    #modal-overlay {
      position:fixed; inset:0; background:rgba(0,0,0,.7); z-index:300;
      display:none; align-items:flex-end; justify-content:center;
      padding-bottom:20px;
    }
    #modal-overlay.open { display:flex; }
    #modal-box {
      background:var(--surface); border:1px solid var(--border);
      border-radius:12px 12px 0 0; width:100%; max-width:900px; max-height:60vh;
      display:flex; flex-direction:column;
      box-shadow:0 -20px 60px rgba(0,0,0,.5);
      animation: slideUp .25s ease;
    }
    @keyframes slideUp { from{transform:translateY(40px);opacity:0} to{transform:none;opacity:1} }
    #modal-header {
      padding:14px 20px; border-bottom:1px solid var(--border);
      display:flex; align-items:center; gap:10px;
    }
    #modal-title { font-size:13px; color:var(--accent-cyan); letter-spacing:1px; flex:1; }
    #modal-close {
      background:none; border:1px solid var(--border); color:var(--text-muted);
      width:28px; height:28px; border-radius:4px; cursor:pointer; font-size:14px;
      font-family:var(--font);
    }
    #modal-close:hover { border-color:var(--accent-red); color:var(--accent-red); }
    #modal-body { flex:1; overflow-y:auto; padding:14px 20px; }
    .result-table { width:100%; border-collapse:collapse; font-size:11px; }
    .result-table th { text-align:left; color:var(--text-muted); font-size:9px; letter-spacing:1.5px; padding:6px 8px; border-bottom:1px solid var(--border); }
    .result-table td { padding:6px 8px; border-bottom:1px solid rgba(255,255,255,.04); color:var(--text-primary); font-size:11px; }
    .result-table tr:hover td { background:rgba(0,245,255,.04); }
    .no-results { color:var(--text-muted); font-size:12px; padding:20px 0; text-align:center; }
    </style>
    </head>
    <body>

    <!-- Top bar -->
    <div id="topbar">
    <div class="logo">HSG ⬡</div>
    <div class="pulse-dot"></div>
    <div class="spacer"></div>
    <div class="metric"><div class="val" id="m-nodes">0</div><div class="lbl">NODES</div></div>
    <div class="metric"><div class="val" id="m-events">0</div><div class="lbl">EVENTS</div></div>
    <div class="metric"><div class="val" id="m-edges">0</div><div class="lbl">EDGES</div></div>
    <div class="metric"><div class="val" id="m-stress" style="color:var(--accent-green)">0%</div><div class="lbl">STRESS</div></div>
    </div>

    <!-- Sidebar -->
    <div id="sidebar">
    <!-- Stress bar -->
    <div id="stress-bar-wrap">
    <h3>⚡ AUTONOMIC STRESS</h3>
    <div id="stress-track"><div id="stress-fill"></div></div>
    <div id="stress-val">0.0%</div>
    </div>

    <!-- 5-Vector Query panel -->
    <div class="sidebar-section">
    <h3>⬡ 5-VECTOR QUERIES</h3>
    <button class="query-btn" onclick="runQuery('rejected_prompts')">
      <span class="btn-icon">🧠</span>REJECTED PROMPTS
    </button>
    <button class="query-btn" onclick="runQuery('stress_spikes')">
      <span class="btn-icon">⚡</span>STRESS SPIKE PROMPTS
    </button>
    <button class="query-btn" onclick="runQuery('unauthorized_ops', {node_id: selectedNode || 'root'})">
      <span class="btn-icon">🔐</span>UNAUTHORIZED OPS
    </button>
    <button class="query-btn" onclick="runQuery('replay_physical', {node_id: selectedNode || 'root'})">
      <span class="btn-icon">🗂</span>REPLAY PHYSICAL STATE
    </button>
    <button class="query-btn" onclick="requestSnapshot()">
      <span class="btn-icon">♻</span>REFRESH SNAPSHOT
    </button>
    </div>

    <!-- Node detail -->
    <div id="node-detail">
    <h3>◎ NODE DETAIL</h3>
    <div id="detail-content" style="color:var(--text-muted);font-size:11px;">
      Hover or click a node to inspect it.
    </div>
    </div>
    </div>

    <!-- Canvas -->
    <div id="canvas-wrap">
    <canvas id="hsg-canvas"></canvas>
    </div>

    <!-- Event Console -->
    <div id="console">
    <div id="console-header">
    <span>▸ LIVE TELEMETRY STREAM</span>
    <div class="live-badge">LIVE</div>
    </div>
    <div id="event-log"></div>
    </div>

    <!-- Tooltip -->
    <div id="tooltip">
    <div class="tt-id" id="tt-id"></div>
    <div class="tt-row">phase: <span id="tt-phase"></span></div>
    <div class="tt-row">path: <span id="tt-path"></span></div>
    <div class="tt-row">stress: <span id="tt-stress"></span></div>
    <div class="tt-row">vectors: <span id="tt-vectors"></span></div>
    </div>

    <!-- Query Modal -->
    <div id="modal-overlay" onclick="if(event.target===this)closeModal()">
    <div id="modal-box">
    <div id="modal-header">
      <div id="modal-title">Query Results</div>
      <button id="modal-close" onclick="closeModal()">✕</button>
    </div>
    <div id="modal-body"></div>
    </div>
    </div>

    <script>
    // ──────────────────────────────────────────────────────────────────
    // HSG PANOPTICON DASHBOARD  — D3 Force-Graph on Canvas
    // ──────────────────────────────────────────────────────────────────

    const { Socket } = Phoenix;

    // ── State ────────────────────────────────────────────────────────
    let nodes = [];               // D3 node objects  {id, type, phase, stress, mat_path, x, y, vx, vy}
    let links = [];               // D3 link objects  {source, target, type}
    let nodeMap  = new Map();     // id → node
    let linkMap  = new Map();     // id → link
    let eventCount = 0;
    let maxStress  = 0;
    let selectedNode = null;
    let hoveredNode  = null;
    let channel = null;

    // ── Canvas setup ─────────────────────────────────────────────────
    const canvas = document.getElementById('hsg-canvas');
    const ctx    = canvas.getContext('2d');

    function resize() {
    const wrap = document.getElementById('canvas-wrap');
    canvas.width  = wrap.clientWidth;
    canvas.height = wrap.clientHeight;
    if (simulation) simulation.force('center', d3.forceCenter(canvas.width/2, canvas.height/2)).restart();
    }
    window.addEventListener('resize', resize);
    resize();

    // ── D3 Force Simulation ──────────────────────────────────────────
    const simulation = d3.forceSimulation(nodes)
    .force('link',    d3.forceLink(links).id(d => d.id).distance(90).strength(0.4))
    .force('charge',  d3.forceManyBody().strength(-280))
    .force('center',  d3.forceCenter(canvas.width/2, canvas.height/2))
    .force('collide', d3.forceCollide(22))
    .alphaDecay(0.02)
    .on('tick', draw);

    // ── Color / Style Helpers ─────────────────────────────────────────
    const NODE_COLORS = {
    planned_agent: '#4488ff',
    agent:         '#39ff6f',
    event:         '#ffd700',
    unknown:       '#4f6080'
    };

    const EDGE_COLORS = {
    intent:               'rgba(0,245,255,0.35)',
    emission:             'rgba(255,255,255,0.25)',
    temporal_predecessor: 'rgba(255,140,66,0.4)',
    failure:              'rgba(255,51,85,0.5)',
    success:              'rgba(57,255,111,0.4)',
    };

    function nodeColor(n) { return NODE_COLORS[n.type] || NODE_COLORS.unknown; }
    function edgeColor(l) { return EDGE_COLORS[l.type] || 'rgba(255,255,255,0.15)'; }

    function nodeRadius(n) {
    let r = n.type === 'event' ? 5 : 12;
    if (n === hoveredNode || n === selectedNode) r += 4;
    return r;
    }

    // ── Draw Loop ─────────────────────────────────────────────────────
    function draw() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    // Grid dots
    ctx.fillStyle = 'rgba(26,37,64,0.4)';
    for (let x = 0; x < canvas.width; x += 40)
    for (let y = 0; y < canvas.height; y += 40)
      ctx.fillRect(x, y, 1, 1);

    // Edges
    links.forEach(l => {
    const sx = l.source.x, sy = l.source.y;
    const tx = l.target.x, ty = l.target.y;
    ctx.beginPath();
    ctx.strokeStyle = edgeColor(l);
    ctx.lineWidth   = l.type === 'intent' ? 1 : 1.5;
    if (l.type === 'intent') {
      ctx.setLineDash([4, 6]);
    } else {
      ctx.setLineDash([]);
    }
    ctx.moveTo(sx, sy);
    ctx.lineTo(tx, ty);
    ctx.stroke();
    ctx.setLineDash([]);

    // Arrowhead
    const angle = Math.atan2(ty - sy, tx - sx);
    const r = nodeRadius(l.target);
    const ax = tx - r * Math.cos(angle);
    const ay = ty - r * Math.sin(angle);
    ctx.beginPath();
    ctx.fillStyle = edgeColor(l);
    ctx.moveTo(ax, ay);
    ctx.lineTo(ax - 8*Math.cos(angle-0.3), ay - 8*Math.sin(angle-0.3));
    ctx.lineTo(ax - 8*Math.cos(angle+0.3), ay - 8*Math.sin(angle+0.3));
    ctx.fill();
    });

    // Nodes
    nodes.forEach(n => {
    const r = nodeRadius(n);
    const col = nodeColor(n);

    // Stress glow
    if (n.stress > 0) {
      const intensity = Math.min(n.stress / 100, 1);
      const glowColor = `rgba(255,${Math.floor(140-140*intensity)},${Math.floor(66-66*intensity)},${0.15+intensity*0.25})`;
      ctx.beginPath();
      ctx.arc(n.x, n.y, r + 10 + intensity*8, 0, Math.PI*2);
      ctx.fillStyle = glowColor;
      ctx.fill();
    }

    // Outer ring for selected/hovered
    if (n === selectedNode) {
      ctx.beginPath(); ctx.arc(n.x, n.y, r+5, 0, Math.PI*2);
      ctx.strokeStyle = '#ffffff'; ctx.lineWidth = 1.5; ctx.stroke();
    } else if (n === hoveredNode) {
      ctx.beginPath(); ctx.arc(n.x, n.y, r+4, 0, Math.PI*2);
      ctx.strokeStyle = col; ctx.lineWidth = 1; ctx.stroke();
    }

    // Node fill
    ctx.beginPath();
    ctx.arc(n.x, n.y, r, 0, Math.PI*2);

    if (n.type === 'planned_agent') {
      ctx.fillStyle   = 'rgba(0,0,0,0)';
      ctx.strokeStyle = col;
      ctx.lineWidth   = 1.5;
      ctx.fill();
      ctx.stroke();
      // Ghostly inner fill
      ctx.beginPath(); ctx.arc(n.x, n.y, r, 0, Math.PI*2);
      ctx.fillStyle = 'rgba(68,136,255,0.12)'; ctx.fill();
    } else {
      const grd = ctx.createRadialGradient(n.x-r*0.3, n.y-r*0.3, 0, n.x, n.y, r);
      grd.addColorStop(0, col);
      grd.addColorStop(1, hexAlpha(col, 0.55));
      ctx.fillStyle = grd;
      ctx.fill();
      ctx.strokeStyle = col;
      ctx.lineWidth   = 1;
      ctx.stroke();
    }

    // Label for agent nodes
    if (n.type !== 'event') {
      ctx.font = '9px Courier New';
      ctx.fillStyle   = '#e8edf8';
      ctx.textAlign   = 'center';
      ctx.textBaseline = 'middle';
      const label = n.id.length > 10 ? n.id.slice(0,9)+'…' : n.id;
      ctx.fillText(label, n.x, n.y + r + 11);
    }
    });
    }

    // ── Hex alpha helper ──────────────────────────────────────────────
    function hexAlpha(hex, a) {
    if (!hex.startsWith('#')) return hex;
    const r = parseInt(hex.slice(1,3),16);
    const g = parseInt(hex.slice(3,5),16);
    const b = parseInt(hex.slice(5,7),16);
    return `rgba(${r},${g},${b},${a})`;
    }

    // ── Graph mutation helpers ─────────────────────────────────────────
    function upsertNode(id, attrs) {
    if (nodeMap.has(id)) {
    Object.assign(nodeMap.get(id), attrs);
    } else {
    const n = {id, x: canvas.width/2 + (Math.random()-0.5)*200,
                   y: canvas.height/2 + (Math.random()-0.5)*200, ...attrs};
    nodes.push(n);
    nodeMap.set(id, n);
    }
    }

    function upsertLink(id, src, tgt, type) {
    if (!linkMap.has(id)) {
    const l = {id, source: src, target: tgt, type};
    links.push(l);
    linkMap.set(id, l);
    }
    }

    function restartSim() {
    simulation.nodes(nodes);
    simulation.force('link').links(links);
    simulation.alpha(0.3).restart();
    }

    // ── Apply full snapshot ───────────────────────────────────────────
    function applySnapshot(data) {
    (data.vertices || []).forEach(v => {
    upsertNode(v.id, {type: v.type, mat_path: v.mat_path, phase: v.last_phase, stress: v.stress || 0});
    });
    (data.edges || []).forEach(e => {
    upsertLink(e.id, e.from, e.to, e.type);
    });
    updateMetrics();
    restartSim();
    }

    // ── Apply incremental diff ────────────────────────────────────────
    function applyDiff(d) {
    // Upsert the agent node
    upsertNode(d.node_id, {
    type:   'agent',
    phase:  d.phase_to,
    stress: d.stress || 0,
    mat_path: d.mat_path,
    has_cognitive: d.has_cognitive,
    has_physical:  d.has_physical,
    has_security:  d.has_security,
    has_autonomic: d.has_autonomic
    });

    // Upsert event hash node
    if (d.event_hash) {
    upsertNode(d.event_hash, {type: 'event', phase: '', stress: 0, mat_path: d.mat_path});
    upsertLink(`${d.node_id}->${d.event_hash}`, d.node_id, d.event_hash, 'emission');

    if (d.prev_hash && nodeMap.has(d.prev_hash)) {
      upsertLink(`${d.event_hash}->${d.prev_hash}`, d.event_hash, d.prev_hash, 'temporal_predecessor');
    }
    }

    // Update global stress
    if (d.stress != null && d.stress > maxStress) {
    maxStress = d.stress;
    updateStress(d.stress);
    }

    eventCount++;
    updateMetrics();
    restartSim();

    // Pulse the node
    const n = nodeMap.get(d.node_id);
    if (n) { n._pulse = 8; setTimeout(()=>{ n._pulse = 0; }, 600); }

    // Log entry
    addLogEntry(d);
    }

    // ── Metrics ───────────────────────────────────────────────────────
    function updateMetrics() {
    const agentCount = nodes.filter(n => n.type !== 'event').length;
    document.getElementById('m-nodes').textContent  = agentCount;
    document.getElementById('m-events').textContent = eventCount;
    document.getElementById('m-edges').textContent  = links.length;
    }

    function updateStress(s) {
    const pct = Math.min(s, 100).toFixed(1);
    document.getElementById('stress-fill').style.width = pct + '%';
    document.getElementById('stress-val').textContent  = pct + '%';
    const el = document.getElementById('m-stress');
    el.textContent = pct + '%';
    el.style.color = s > 80 ? 'var(--accent-red)' : s > 50 ? 'var(--accent-yellow)' : 'var(--accent-green)';
    }

    // ── Event Log ─────────────────────────────────────────────────────
    const MAX_LOGS = 30;
    function addLogEntry(d) {
    const log = document.getElementById('event-log');
    while (log.children.length >= MAX_LOGS) log.removeChild(log.lastChild);

    const phaseColor = d.phase_to === 'failed' || d.phase_to === 'frozen'
    ? 'background:#ff3355;'
    : d.phase_to === 'completed'
    ? 'background:#39ff6f;'
    : 'background:#4488ff;';

    const vectors = [
    d.has_cognitive ? '🧠' : '',
    d.has_physical  ? '🖐' : '',
    d.has_security  ? '🔐' : '',
    d.has_autonomic ? '⚡' : ''
    ].join('');

    const ts = new Date().toTimeString().slice(0,8);
    const entry = document.createElement('div');
    entry.className = 'log-entry';
    entry.innerHTML = `
    <span class="ts">${ts}</span>
    <span class="node">${(d.node_id||'').slice(0,18)}</span>
    <span class="phase" style="${phaseColor}color:#000;font-size:8px;">&nbsp;${d.phase_from}→${d.phase_to}&nbsp;</span>
    <span class="vectors">${vectors}</span>
    `;
    log.insertBefore(entry, log.firstChild);
    }

    // ── Tooltip & Node Interaction ────────────────────────────────────
    const tooltip = document.getElementById('tooltip');

    function nodeAtPos(mx, my) {
    const rect = canvas.getBoundingClientRect();
    const x = mx - rect.left, y = my - rect.top;
    for (let i = nodes.length-1; i >= 0; i--) {
    const n = nodes[i];
    const r = nodeRadius(n) + 4;
    if ((n.x-x)**2 + (n.y-y)**2 <= r*r) return n;
    }
    return null;
    }

    canvas.addEventListener('mousemove', e => {
    const n = nodeAtPos(e.clientX, e.clientY);
    hoveredNode = n;
    if (n) {
    tooltip.style.display = 'block';
    tooltip.style.left    = (e.clientX + 14) + 'px';
    tooltip.style.top     = (e.clientY - 10) + 'px';
    document.getElementById('tt-id').textContent     = n.id;
    document.getElementById('tt-phase').textContent  = n.phase || '—';
    document.getElementById('tt-path').textContent   = n.mat_path || '—';
    document.getElementById('tt-stress').textContent = (n.stress||0).toFixed(1) + '%';
    const vv = [n.has_cognitive?'COGNITIVE':'', n.has_physical?'PHYSICAL':'',
                n.has_security?'SECURITY':'', n.has_autonomic?'AUTONOMIC':''].filter(Boolean);
    document.getElementById('tt-vectors').textContent = vv.join(', ') || 'none';
    } else {
    tooltip.style.display = 'none';
    }
    });

    canvas.addEventListener('click', e => {
    const n = nodeAtPos(e.clientX, e.clientY);
    selectedNode = n;
    renderNodeDetail(n);
    });

    function renderNodeDetail(n) {
    const el = document.getElementById('detail-content');
    if (!n) {
    el.innerHTML = '<span style="color:var(--text-muted);font-size:11px;">Hover or click a node to inspect it.</span>';
    return;
    }
    const vectors = [
    n.has_cognitive ? '<span class="vector-badge v-cog">COGNITIVE</span>'       : '',
    n.has_physical  ? '<span class="vector-badge v-phys">PHYSICAL</span>'       : '',
    n.has_security  ? '<span class="vector-badge v-sec">SECURITY</span>'        : '',
    n.has_autonomic ? '<span class="vector-badge v-auto">AUTONOMIC</span>'      : ''
    ].join('');
    el.innerHTML = `
    <div class="detail-row"><div class="key">NODE ID</div><div class="val">${n.id}</div></div>
    <div class="detail-row"><div class="key">TYPE</div><div class="val">${n.type}</div></div>
    <div class="detail-row"><div class="key">MAT PATH</div><div class="val">${n.mat_path||'—'}</div></div>
    <div class="detail-row"><div class="key">LAST PHASE</div><div class="val">${n.phase||'—'}</div></div>
    <div class="detail-row"><div class="key">STRESS</div><div class="val">${(n.stress||0).toFixed(1)}%</div></div>
    <div class="detail-row"><div class="key">VECTORS ACTIVE</div><div class="val">${vectors||'<span style="color:var(--text-muted)">none yet</span>'}</div></div>
    `;
    }

    // ── Query Panel ───────────────────────────────────────────────────
    function runQuery(type, extra) {
    if (!channel) return;
    channel.push('query', {type, ...extra});
    }

    function requestSnapshot() {
    if (!channel) return;
    channel.push('get_snapshot', {})
    .receive('ok', data => applySnapshot(data));
    }

    function showModal(title, rows) {
    document.getElementById('modal-title').textContent = title;
    const body = document.getElementById('modal-body');
    if (!rows || rows.length === 0) {
    body.innerHTML = '<div class="no-results">No results found.</div>';
    } else {
    const header = rows[0].map((_, i) => `<th>COL ${i}</th>`).join('');
    const rowsHtml = rows.map(r =>
      '<tr>' + r.map(c => `<td>${c}</td>`).join('') + '</tr>'
    ).join('');
    body.innerHTML = `<table class="result-table"><thead><tr>${header}</tr></thead><tbody>${rowsHtml}</tbody></table>`;
    }
    document.getElementById('modal-overlay').classList.add('open');
    }

    function closeModal() {
    document.getElementById('modal-overlay').classList.remove('open');
    }

    // ── Phoenix Channel ───────────────────────────────────────────────
    function connect() {
    const socket = new Socket('/dashboard', {});
    socket.connect();

    channel = socket.channel('acn:panopticon', {});

    channel.on('snapshot', data => {
    nodes = []; links = []; nodeMap.clear(); linkMap.clear();
    applySnapshot(data);
    });

    channel.on('graph_diff', data => applyDiff(data));

    channel.on('query_result', data => {
    const titles = {
      rejected_prompts:  '🧠 Rejected Prompts',
      unauthorized_ops:  '🔐 Unauthorized Operations',
      stress_spikes:     '⚡ Stress Spike Prompts',
      replay_physical:   '🗂 Physical State Replay'
    };
    showModal(titles[data.type] || data.type, data.rows);
    });

    channel.join()
    .receive('ok', () => { console.log('[HSG] Channel joined'); })
    .receive('error', e => { console.error('[HSG] Channel error', e); });
    }

    connect();

    // ── Initial draw (even with empty graph) ─────────────────────────
    simulation.alpha(0.01).restart();
    </script>
    </body>
    </html>
    """
  end
end
