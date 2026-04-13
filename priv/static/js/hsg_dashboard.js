// =============================================================================
// HSG PANOPTICON — Complete Dashboard v3
// Real family-tree hierarchy via mat_path | Premium node cards | Full controls
// =============================================================================

'use strict';
const { Socket } = Phoenix;

// ── Global State ──────────────────────────────────────────────────────────────
const nodeMap       = new Map();   // mat_path → NodeRecord
const eventLog      = [];          // chronological list of events
let totalEvents     = 0;
let channel         = null;
let startTime       = Date.now();
let selectedPath    = null;
let currentTransform = d3.zoomIdentity;

window.__getSelectedPath = () => selectedPath;

// ── Node Record Factory ───────────────────────────────────────────────────────
function makeNode(data) {
  const key = data.mat_path || data.node_id || data.id;
  return {
    id:           data.node_id || data.id || key,
    mat_path:     key,
    node_tier:    data.node_tier || 'leaf',
    phase:        data.phase_to || data.last_phase || 'pending',
    stress:       typeof data.stress === 'number' ? data.stress : 0,
    stressHistory:[],
    agents:       { cognitive: null, physical: null, security: null, autonomic: null },
    collapsed:    false,
    eventCount:   0,
    lastSeen:     Date.now(),
    traceId:      data.trace_id || null,
    type:         data.type || 'agent',
  };
}

// ── Colour System ─────────────────────────────────────────────────────────────
const PHASE_COLOR = {
  completed:    '#00ff9d',
  failed:       '#ff4757',
  frozen:       '#ff4757',
  running:      '#00a8ff',
  architecting: '#a55eea',
  execution:    '#00a8ff',
  initialized:  '#feca57',
  pending:      '#747d8c',
};

const TIER_BG = {
  root:         'rgba(26,10,46,0.92)',
  intermediate: 'rgba(10,20,46,0.92)',
  leaf:         'rgba(8,14,34,0.92)',
};

const TIER_BORDER = {
  root:         '#a55eea',
  intermediate: '#00e5ff',
  leaf:         '#747d8c',
};

const AGENT_COLOR = {
  cognitive:  '#00a8ff',
  physical:   '#00ff9d',
  security:   '#ff9f43',
  autonomic:  '#ff4757',
};

function phaseColor(phase) {
  return PHASE_COLOR[(phase || '').toLowerCase()] || '#747d8c';
}

function tierBorder(tier, phase) {
  const pc = phaseColor(phase);
  if (pc !== '#747d8c') return pc;
  return TIER_BORDER[tier] || '#747d8c';
}

function isRunning(p)   { return ['architecting','execution','running','initialized'].includes((p||'').toLowerCase()); }
function isCompleted(p) { return (p||'').toLowerCase() === 'completed'; }
function isErrored(p)   { const q = (p||'').toLowerCase(); return q === 'failed' || q === 'frozen'; }

// ── Node label ────────────────────────────────────────────────────────────────
function nodeLabel(mat_path) {
  const parts = (mat_path || '').split('.');
  let seg = parts[parts.length - 1] || mat_path;
  // If last segment is purely numeric, prefix parent scope
  if (/^\d+$/.test(seg) && parts.length > 1) {
    seg = parts[parts.length - 2] + ' #' + seg;
  }
  return seg.toUpperCase();
}

// ── Build Hierarchy from mat_path ─────────────────────────────────────────────
function buildHierarchy() {
  if (nodeMap.size === 0) return null;

  // Clone every known node into a fresh children-array structure
  const cloneMap = new Map();
  for (const [k, v] of nodeMap) {
    if (k) cloneMap.set(k, { ...v, children: [] });
  }

  // Auto-synthesize any missing ancestor nodes
  for (const key of Array.from(cloneMap.keys())) {
    const parts = key.split('.');
    for (let i = 1; i < parts.length; i++) {
      const parentPath = parts.slice(0, i).join('.');
      if (!cloneMap.has(parentPath)) {
        cloneMap.set(parentPath, {
          id: parentPath, mat_path: parentPath,
          node_tier: i === 1 ? 'intermediate' : 'leaf',
          phase: 'pending', stress: 0, agents: {},
          stressHistory: [], collapsed: false,
          eventCount: 0, lastSeen: 0, type: 'synthesized',
          children: [],
        });
      }
    }
  }

  // Wire parent → child
  const rootsList = [];
  cloneMap.forEach((v, k) => {
    const parts = k.split('.');
    if (parts.length === 1) {
      rootsList.push(v);
    } else {
      const parentPath = parts.slice(0, -1).join('.');
      const parent = cloneMap.get(parentPath);
      if (parent) parent.children.push(v);
      else rootsList.push(v);
    }
  });

  if (rootsList.length === 0) return null;

  // Apply collapse
  function applyCollapse(n) {
    const real = nodeMap.get(n.mat_path);
    if (real && real.collapsed && n.children.length > 0) {
      n._hiddenChildren = n.children;
      n.children = [];
    } else {
      n.children.sort((a, b) => a.mat_path.localeCompare(b.mat_path));
      n.children.forEach(applyCollapse);
    }
  }
  rootsList.forEach(applyCollapse);

  let root;
  if (rootsList.length === 1) {
    root = rootsList[0];
  } else {
    root = { mat_path: '__synth_root__', id: '__synth_root__', node_tier: 'root',
             phase: '', stress: 0, agents: {}, stressHistory: [], type: 'synthesized',
             children: rootsList };
  }
  return d3.hierarchy(root, d => d.children);
}

// ── SVG / D3 Setup ────────────────────────────────────────────────────────────
const svg    = d3.select('#tree-svg');
const gMain  = svg.append('g').attr('class', 'g-main');
const gLinks = gMain.append('g').attr('class', 'g-links');
const gNodes = gMain.append('g').attr('class', 'g-nodes');

const miniSvg = d3.select('#minimap-svg');
const miniG   = miniSvg.append('g').attr('class', 'mini-root');

const NODE_W = 230;
const NODE_H = 100;
const H_GAP  = 60;
const V_GAP  = 80;

const treeLayout = d3.tree()
  .nodeSize([NODE_W + H_GAP, NODE_H + V_GAP])
  .separation((a, b) => a.parent === b.parent ? 1.1 : 1.5);

const zoom = d3.zoom()
  .scaleExtent([0.08, 4])
  .on('zoom', (e) => {
    currentTransform = e.transform;
    gMain.attr('transform', e.transform);
    updateMinimapViewport(e.transform);
  });

svg.call(zoom)
   .on('dblclick.zoom', null); // disable double-click zoom (we use it for node selection)

// ── Render ────────────────────────────────────────────────────────────────────
let renderScheduled = false;
function scheduleRender() {
  if (!renderScheduled) {
    renderScheduled = true;
    requestAnimationFrame(() => { renderScheduled = false; render(); });
  }
}

function render() {
  const hier = buildHierarchy();
  if (!hier) return;

  treeLayout(hier);

  const nodes = hier.descendants();
  const links = hier.links();

  // ── Links ────────────────────────────────────────────────────────────────
  const linkSel = gLinks.selectAll('.tree-link')
    .data(links, d => d.target.data.mat_path);

  const linkEnter = linkSel.enter().append('path')
    .attr('class', 'tree-link')
    .attr('fill', 'none')
    .attr('stroke-width', 1.5)
    .attr('opacity', 0);

  linkEnter.merge(linkSel)
    .transition().duration(400)
    .attr('opacity', 1)
    .attr('stroke', d => {
      const phase = d.target.data.phase || '';
      return isRunning(phase) ? 'rgba(0,168,255,0.5)' :
             isCompleted(phase) ? 'rgba(0,255,157,0.35)' :
             isErrored(phase) ? 'rgba(255,71,87,0.4)' : 'rgba(100,120,200,0.2)';
    })
    .attr('d', d => {
      const sx = d.source.x, sy = d.source.y + NODE_H / 2;
      const tx = d.target.x, ty = d.target.y - NODE_H / 2;
      const my = (sy + ty) / 2;
      return `M${sx},${sy} C${sx},${my} ${tx},${my} ${tx},${ty}`;
    });

  linkSel.exit().transition().duration(200).attr('opacity', 0).remove();

  // ── Nodes ────────────────────────────────────────────────────────────────
  const nodeSel = gNodes.selectAll('.tree-node')
    .data(nodes, d => d.data.mat_path);

  const nodeEnter = nodeSel.enter().append('foreignObject')
    .attr('class', 'tree-node')
    .attr('width', NODE_W)
    .attr('height', NODE_H)
    .attr('x', d => d.x - NODE_W / 2)
    .attr('y', d => d.y - NODE_H / 2)
    .attr('opacity', 0)
    .on('click', (evt, d) => { evt.stopPropagation(); selectNode(d.data); })
    .on('dblclick', (evt, d) => { evt.stopPropagation(); toggleCollapse(d.data.mat_path); });

  nodeEnter.append('xhtml:div').attr('class', 'node-card');

  const nodeMerge = nodeEnter.merge(nodeSel);

  nodeMerge.transition().duration(400)
    .attr('opacity', 1)
    .attr('x', d => d.x - NODE_W / 2)
    .attr('y', d => d.y - NODE_H / 2);

  nodeSel.exit().transition().duration(200).attr('opacity', 0).remove();

  // Update card content
  nodeMerge.each(function(d) {
    if (d.data.mat_path === '__synth_root__') return;
    renderCard(d3.select(this).select('.node-card'), d.data);
  });

  // Hide empty state
  if (nodes.length > 0) hideEmpty();

  // Update minimap
  renderMinimap(nodes, links);

  // Update topbar counters
  updateTopbar();
}

// ── Card Renderer ─────────────────────────────────────────────────────────────
const TIER_ICON = { root: '⬡', intermediate: '◈', leaf: '◆', synthesized: '◇' };

function renderCard(cardSel, nd) {
  const phase   = nd.phase || 'pending';
  const bc      = tierBorder(nd.node_tier, phase);
  const bgc     = TIER_BG[nd.node_tier] || 'rgba(8,14,34,0.92)';
  const running = isRunning(phase);
  const done    = isCompleted(phase);
  const errored = isErrored(phase);
  const selected = nd.mat_path === selectedPath;
  const synth    = nd.type === 'synthesized';

  // CSS class list
  let cls = 'node-card';
  if (running)  cls += ' nc-running';
  if (done)     cls += ' nc-done';
  if (errored)  cls += ' nc-error';
  if (selected) cls += ' nc-selected';
  if (synth)    cls += ' nc-synth';

  cardSel.node().className = cls;
  cardSel.node().style.cssText =
    `--bc:${bc};--bgc:${bgc};--pc:${phaseColor(phase)};`;

  // Heatmap bars
  const heat = (nd.stressHistory || []).slice(-8);
  const maxH = 18;
  const heatHtml = heat.map(s => {
    const v = Math.min(s || 0, 100) / 100;
    const h = Math.max(3, Math.round(v * maxH));
    const r = Math.round(v * 255);
    const g = Math.round((1 - v) * 200);
    return `<span class="hb" style="height:${h}px;background:rgb(${r},${g},60)"></span>`;
  }).join('');

  // Agent dots
  const agentHtml = ['cognitive','physical','security','autonomic'].map(k => {
    const ag = nd.agents ? nd.agents[k] : null;
    const color = AGENT_COLOR[k];
    const state = ag ? ag.state : 'none';
    return `<span class="ag-dot" data-state="${state}" style="--ac:${color}"
      title="${k}: ${state}" data-key="${k}" data-path="${escHtml(nd.mat_path)}"></span>`;
  }).join('');

  const label     = nodeLabel(nd.mat_path);
  const icon      = TIER_ICON[nd.node_tier] || '◆';
  const stress    = typeof nd.stress === 'number' ? nd.stress.toFixed(1) : '0.0';
  const evCount   = nd.eventCount || 0;
  const childCount = nd.children ? nd.children.length : 0;
  const phaseDisp = phase.toUpperCase();
  const tierDisp  = (nd.node_tier || 'node').toUpperCase();
  const lastSeen  = nd.lastSeen ? timeAgo(nd.lastSeen) : '—';

  cardSel.html(`
    <div class="nc-header">
      <span class="nc-icon">${icon}</span>
      <span class="nc-label" title="${escHtml(nd.mat_path)}">${escHtml(label)}</span>
      <span class="nc-tier">${tierDisp}</span>
    </div>
    <div class="nc-path">${escHtml(nd.mat_path)}</div>
    <div class="nc-mid">
      <div class="nc-agents">${agentHtml}</div>
      <div class="nc-heat">${heatHtml}</div>
    </div>
    <div class="nc-footer">
      <span class="nc-phase" style="color:var(--pc)">${phaseDisp}</span>
      <span class="nc-stat">⚡${stress}%</span>
      <span class="nc-stat">📨${evCount}</span>
      <span class="nc-stat">🕑${lastSeen}</span>
    </div>
  `);

  // Agent dot click
  cardSel.node().querySelectorAll('.ag-dot').forEach(el => {
    el.addEventListener('click', e => {
      e.stopPropagation();
      openAgentDetail(e.target.dataset.path, e.target.dataset.key);
    });
  });
}

// ── Selection / Detail Panel ──────────────────────────────────────────────────
function selectNode(nd) {
  if (nd.mat_path === '__synth_root__') return;
  selectedPath = nd.mat_path;
  renderDetailPanel(nd);
  scheduleRender();
  // Switch to detail tab
  switchSidebarTab('detail');
}

function renderDetailPanel(nd) {
  const el = document.getElementById('detail-body');
  if (!el) return;
  const bc = phaseColor(nd.phase);
  const childCount = nd.children ? nd.children.length : 0;
  const stress = typeof nd.stress === 'number' ? nd.stress.toFixed(1) : '0.0';
  const stressBar = `<div class="stress-track"><div class="stress-fill" style="width:${Math.min(nd.stress||0,100)}%;background:${bc}"></div></div>`;

  el.innerHTML = `
    <div class="dp-section">
      <div class="dp-label">IDENTITY</div>
      <div class="dp-row"><span class="dp-key">PATH</span><span class="dp-val mono">${escHtml(nd.mat_path)}</span></div>
      <div class="dp-row"><span class="dp-key">ID</span><span class="dp-val mono">${escHtml(nd.id||nd.mat_path)}</span></div>
      <div class="dp-row"><span class="dp-key">TIER</span><span class="dp-val">${escHtml(nd.node_tier||'—')}</span></div>
      <div class="dp-row"><span class="dp-key">TYPE</span><span class="dp-val">${escHtml(nd.type||'agent')}</span></div>
    </div>
    <div class="dp-section">
      <div class="dp-label">RUNTIME</div>
      <div class="dp-row"><span class="dp-key">PHASE</span><span class="dp-val" style="color:${bc}">${escHtml((nd.phase||'pending').toUpperCase())}</span></div>
      <div class="dp-row"><span class="dp-key">EVENTS</span><span class="dp-val">${nd.eventCount||0}</span></div>
      <div class="dp-row"><span class="dp-key">CHILDREN</span><span class="dp-val">${childCount}</span></div>
      <div class="dp-row"><span class="dp-key">LAST SEEN</span><span class="dp-val">${nd.lastSeen ? new Date(nd.lastSeen).toLocaleTimeString() : '—'}</span></div>
    </div>
    <div class="dp-section">
      <div class="dp-label">STRESS LEVEL — ${stress}%</div>
      ${stressBar}
    </div>
    <div class="dp-section">
      <div class="dp-label">AGENTS</div>
      ${['cognitive','physical','security','autonomic'].map(k => {
        const ag = nd.agents ? nd.agents[k] : null;
        const color = AGENT_COLOR[k];
        const state = ag ? ag.state : 'inactive';
        return `<div class="dp-row">
          <span class="dp-key" style="color:${color}">${k.toUpperCase()}</span>
          <span class="dp-val">${state}</span>
        </div>`;
      }).join('')}
    </div>
    <div class="dp-actions">
      <button class="dp-btn" onclick="toggleCollapse('${escHtml(nd.mat_path)}')">
        ⊞ TOGGLE SUBTREE
      </button>
      <button class="dp-btn dp-btn-accent" onclick="openShadowDrawer('${escHtml(nd.mat_path)}')">
        🗂 SHADOW FILES
      </button>
      <button class="dp-btn" onclick="fitToNode('${escHtml(nd.mat_path)}')">
        ⊙ FOCUS NODE
      </button>
    </div>
  `;
}

// ── Collapse ──────────────────────────────────────────────────────────────────
function toggleCollapse(mat_path) {
  const nd = nodeMap.get(mat_path);
  if (nd) { nd.collapsed = !nd.collapsed; scheduleRender(); }
}
window.toggleCollapse = toggleCollapse;

// ── Fit to node ───────────────────────────────────────────────────────────────
window.fitToNode = function(mat_path) {
  // Re-run layout to find x,y of node
  const hier = buildHierarchy();
  if (!hier) return;
  treeLayout(hier);
  const found = hier.descendants().find(d => d.data.mat_path === mat_path);
  if (!found) return;
  const svgEl = document.getElementById('tree-svg');
  const w = svgEl.clientWidth, h = svgEl.clientHeight;
  const scale = currentTransform.k;
  const tx = w / 2 - found.x * scale;
  const ty = h / 2 - found.y * scale;
  svg.transition().duration(600).call(
    zoom.transform, d3.zoomIdentity.translate(tx, ty).scale(scale)
  );
};

// ── Viewport Controls ─────────────────────────────────────────────────────────
window.vpZoom = function(factor) {
  svg.transition().duration(220).call(zoom.scaleBy, factor);
};

window.vpFitAll = function() {
  const hier = buildHierarchy();
  if (!hier) return;
  treeLayout(hier);
  const nodes = hier.descendants();
  if (nodes.length === 0) return;
  const xs = nodes.map(d => d.x), ys = nodes.map(d => d.y);
  const x0 = Math.min(...xs) - NODE_W, x1 = Math.max(...xs) + NODE_W;
  const y0 = Math.min(...ys) - NODE_H, y1 = Math.max(...ys) + NODE_H;
  const svgEl = document.getElementById('tree-svg');
  const w = svgEl.clientWidth, h = svgEl.clientHeight;
  const scale = Math.min(0.95 * w / (x1 - x0), 0.95 * h / (y1 - y0), 2);
  const tx = w / 2 - ((x0 + x1) / 2) * scale;
  const ty = h / 2 - ((y0 + y1) / 2) * scale;
  svg.transition().duration(600).call(
    zoom.transform, d3.zoomIdentity.translate(tx, ty).scale(scale)
  );
};

window.vpReset = function() {
  svg.transition().duration(500).call(
    zoom.transform, d3.zoomIdentity.translate(
      document.getElementById('tree-svg').clientWidth / 2, 80
    ).scale(0.9)
  );
};

// ── Minimap ───────────────────────────────────────────────────────────────────
function renderMinimap(nodes, links) {
  const SCALE = 0.1;
  miniG.selectAll('.ml').data(links).join('line')
    .attr('class','ml')
    .attr('stroke','rgba(0,168,255,0.25)').attr('stroke-width',1)
    .attr('x1', d => d.source.x * SCALE).attr('y1', d => d.source.y * SCALE)
    .attr('x2', d => d.target.x * SCALE).attr('y2', d => d.target.y * SCALE);

  miniG.selectAll('.mn').data(nodes, d => d.data.mat_path).join('rect')
    .attr('class','mn')
    .attr('width', NODE_W * SCALE).attr('height', NODE_H * SCALE)
    .attr('x', d => (d.x - NODE_W/2) * SCALE).attr('y', d => (d.y - NODE_H/2) * SCALE)
    .attr('rx',1).attr('ry',1)
    .attr('fill', d => d.data.mat_path === selectedPath ? 'rgba(0,229,255,0.5)' : 'rgba(30,50,100,0.6)')
    .attr('stroke', d => phaseColor(d.data.phase)).attr('stroke-width', 0.8);
}

function updateMinimapViewport(t) {
  miniG.selectAll('.mv').remove();
  const svgEl = document.getElementById('tree-svg');
  if (!svgEl) return;
  const s = 0.1;
  const vpW = (svgEl.clientWidth / t.k) * s;
  const vpH = (svgEl.clientHeight / t.k) * s;
  const vpX = (-t.x / t.k) * s;
  const vpY = (-t.y / t.k) * s;
  miniG.append('rect').attr('class','mv')
    .attr('x', vpX).attr('y', vpY).attr('width', vpW).attr('height', vpH)
    .attr('fill','none').attr('stroke','rgba(0,229,255,0.7)').attr('stroke-width',1.5);
}

// ── State Mutations ───────────────────────────────────────────────────────────
function upsertNode(data) {
  const key = data.mat_path || data.node_id || data.id;
  if (!key) return;

  // Guard: reject flat (depth-0) paths that are not already tracked as a root.
  // A single-segment key (no dots) that appears for the first time is almost
  // certainly an unresolved flat node_id whose ETS index lookup failed on the
  // backend. Inserting it would create a spurious second root → __synth_root__
  // wrapper → the original root node becomes a child of a blank rectangle.
  const isFlat = !key.includes('.');
  if (isFlat && !nodeMap.has(key)) {
    console.warn('[HSG] Dropped unresolved flat-path node:', key,
      '— expected a fully-qualified mat_path. Check ETS id_index seeding.');
    return;
  }

  if (!nodeMap.has(key)) {
    nodeMap.set(key, makeNode(data));
  }

  const nd = nodeMap.get(key);

  if (data.phase_to)    nd.phase = data.phase_to;
  if (data.last_phase)  nd.phase = data.last_phase;
  if (data.node_tier)   nd.node_tier = data.node_tier;

  if (typeof data.stress === 'number') {
    nd.stress = data.stress;
    nd.stressHistory.push(data.stress);
    if (nd.stressHistory.length > 20) nd.stressHistory.shift();
  }

  nd.lastSeen = Date.now();
  nd.eventCount = (nd.eventCount || 0) + 1;

  // Agent presence flags
  ['cognitive','physical','security','autonomic'].forEach(k => {
    const flag = data[`has_${k}`];
    if (flag === true) {
      nd.agents[k] = { state: isCompleted(nd.phase) ? 'done' : 'active' };
    } else if (flag === false && nd.agents[k]?.state === 'active') {
      nd.agents[k].state = 'done';
    }
  });

  if (isCompleted(nd.phase) || isErrored(nd.phase)) {
    Object.values(nd.agents).forEach(ag => { if (ag?.state === 'active') ag.state = 'done'; });
  }
}

function applySnapshot(data) {
  nodeMap.clear();
  (data.vertices || []).forEach(v => {
    upsertNode({
      node_id:    v.id,
      mat_path:   v.mat_path,
      node_tier:  v.node_tier,
      last_phase: v.last_phase,
      stress:     v.stress,
      type:       v.type,
    });
    // Override eventCount to 0 on snapshot (fresh load)
    const nd = nodeMap.get(v.mat_path);
    if (nd) nd.eventCount = 0;
  });
  scheduleRender();
}

function applyDiff(d) {
  upsertNode(d);
  totalEvents++;
  addEventLogEntry(d);
  addScrubberTick(d);
  scheduleRender();
}

// ── Topbar ────────────────────────────────────────────────────────────────────
function updateTopbar() {
  const running   = [...nodeMap.values()].filter(n => isRunning(n.phase)).length;
  const completed = [...nodeMap.values()].filter(n => isCompleted(n.phase)).length;
  const errored   = [...nodeMap.values()].filter(n => isErrored(n.phase)).length;

  setText('m-nodes',     nodeMap.size);
  setText('m-running',   running);
  setText('m-completed', completed);
  setText('m-errors',    errored);
  setText('m-events',    totalEvents);

  const secs = Math.floor((Date.now() - startTime) / 1000);
  const h = String(Math.floor(secs / 3600)).padStart(2,'0');
  const m = String(Math.floor((secs % 3600) / 60)).padStart(2,'0');
  const s = String(secs % 60).padStart(2,'0');
  setText('m-uptime', `${h}:${m}:${s}`);
}

setInterval(updateTopbar, 1000);

function setText(id, v) {
  const el = document.getElementById(id);
  if (el) el.textContent = v;
}

// ── Sidebar Tabs ──────────────────────────────────────────────────────────────
window.switchSidebarTab = function(tab) {
  document.querySelectorAll('.stab-btn').forEach(b => {
    b.classList.toggle('stab-active', b.dataset.tab === tab);
  });
  document.querySelectorAll('.stab-panel').forEach(p => {
    p.style.display = p.id === `stab-${tab}` ? 'flex' : 'none';
  });
};

// ── Event Log ─────────────────────────────────────────────────────────────────
const MAX_LOG = 60;

function addEventLogEntry(d) {
  const entry = {
    ts:         Date.now(),
    node_id:    d.node_id || d.mat_path,
    mat_path:   d.mat_path,
    phase_from: d.phase_from || '',
    phase_to:   d.phase_to || '',
    stress:     d.stress,
  };
  eventLog.unshift(entry);
  if (eventLog.length > MAX_LOG) eventLog.pop();
  renderEventLog();
}

function renderEventLog() {
  const container = document.getElementById('event-log-list');
  if (!container) return;
  container.innerHTML = eventLog.slice(0, 30).map(e => {
    const ts   = new Date(e.ts).toLocaleTimeString();
    const pc   = phaseColor(e.phase_to);
    const label = nodeLabel(e.mat_path || e.node_id || '');
    return `
      <div class="log-row">
        <span class="log-ts">${ts}</span>
        <span class="log-node" title="${escHtml(e.mat_path||'')}">${escHtml(label)}</span>
        <span class="log-phase" style="color:${pc};border-color:${pc}40">
          ${escHtml(e.phase_from||'?')}→${escHtml(e.phase_to||'?')}
        </span>
      </div>`;
  }).join('');
}

// ── Scrubber ──────────────────────────────────────────────────────────────────
function addScrubberTick(d) {
  const track = document.getElementById('scrubber-track');
  if (!track) return;
  const tick = document.createElement('div');
  tick.className = 's-tick';
  tick.style.background = phaseColor(d.phase_to);
  tick.title = `${d.node_id}: ${d.phase_from}→${d.phase_to}`;
  track.appendChild(tick);
  while (track.children.length > 250) track.removeChild(track.firstChild);
  track.scrollLeft = track.scrollWidth;
}

// ── Shadow Drawer ─────────────────────────────────────────────────────────────
async function openShadowDrawer(mat_path) {
  const drawer = document.getElementById('shadow-drawer');
  const title  = document.getElementById('shadow-title');
  const body   = document.getElementById('shadow-body');

  title.textContent = `⬡ ${mat_path}`;
  body.innerHTML = '<div class="loading">Loading shadow files…</div>';
  drawer.classList.add('open');

  try {
    const res  = await fetch(`/api/shadow/${encodeURIComponent(mat_path)}`);
    const data = await res.json();
    renderShadowTabs(data, body);
  } catch(e) {
    body.innerHTML = `<div class="err">Error: ${e.message}</div>`;
  }
}
window.openShadowDrawer = openShadowDrawer;

function renderShadowTabs(data, container) {
  const tabs = ['cognitive','physical','security','autonomic'];
  const tabBar = tabs.map(t =>
    `<button class="stab" data-stab="${t}" onclick="switchShadowStab('${t}')">${t.toUpperCase()}</button>`
  ).join('');

  const panels = tabs.map(t => {
    const content = data[t]
      ? `<pre class="shadow-pre">${escHtml(data[t])}</pre>`
      : '<div class="empty-msg">No data recorded yet.</div>';
    return `<div class="stab-content" id="sstab-${t}" style="display:none">${content}</div>`;
  }).join('');

  container.innerHTML = `<div class="stab-bar tabbar">${tabBar}</div>${panels}`;
  switchShadowStab('cognitive');
}

window.switchShadowStab = function(tab) {
  document.querySelectorAll('.stab[data-stab]').forEach(b =>
    b.classList.toggle('stab-active', b.dataset.stab === tab)
  );
  document.querySelectorAll('.stab-content').forEach(p =>
    p.style.display = p.id === `sstab-${tab}` ? 'block' : 'none'
  );
};

window.closeShadowDrawer = function() {
  document.getElementById('shadow-drawer').classList.remove('open');
};

// ── Agent Detail (via shadow drawer) ─────────────────────────────────────────
async function openAgentDetail(mat_path, agent_key) {
  const drawer = document.getElementById('shadow-drawer');
  const title  = document.getElementById('shadow-title');
  const body   = document.getElementById('shadow-body');

  title.textContent = `${agent_key.toUpperCase()} @ ${mat_path}`;
  body.innerHTML = '<div class="loading">Fetching agent record…</div>';
  drawer.classList.add('open');

  try {
    const res  = await fetch(`/api/shadow/${encodeURIComponent(mat_path)}`);
    const data = await res.json();
    if (agent_key === 'cognitive' && data.cognitive) {
      const lines = data.cognitive.trim().split('\n').filter(Boolean).slice(-5);
      const parsed = lines.map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
      const entry = parsed[parsed.length - 1];
      if (!entry) { body.innerHTML = '<div class="empty-msg">No cognitive entries.</div>'; return; }
      body.innerHTML = `
        <div class="agent-panel">
          <div class="ap-row"><div class="ap-key">MODEL</div><div class="ap-val">${escHtml(entry.model||'—')}</div></div>
          <div class="ap-row"><div class="ap-key">TOKENS ↑↓</div><div class="ap-val">${entry.token_count_in||0} / ${entry.token_count_out||0}</div></div>
          <div class="ap-row"><div class="ap-key">ACCEPTED</div><div class="ap-val" style="color:${entry.result_accepted?'#00ff9d':'#ff4757'}">${entry.result_accepted}</div></div>
          <div class="ap-row"><div class="ap-key">PROMPT</div></div>
          <pre class="shadow-pre">${escHtml(entry.prompt||'(not recorded)')}</pre>
          <div class="ap-row"><div class="ap-key">RESPONSE</div></div>
          <pre class="shadow-pre">${escHtml(entry.response||'(not recorded)')}</pre>
        </div>`;
    } else {
      body.innerHTML = data[agent_key]
        ? `<pre class="shadow-pre">${escHtml(data[agent_key])}</pre>`
        : '<div class="empty-msg">No data for this agent.</div>';
    }
  } catch(e) {
    body.innerHTML = `<div class="err">Error: ${e.message}</div>`;
  }
}
window.openAgentDetail = openAgentDetail;

// ── Query Modal ───────────────────────────────────────────────────────────────
window.runQuery = function(type, extra = {}) {
  if (!channel) return;
  channel.push('query', { type, ...extra }).receive('ok', () => {});
};

window.requestSnapshot = function() {
  if (!channel) return;
  channel.push('get_snapshot', {}).receive('ok', data => applySnapshot(data));
};

function showQueryModal(data) {
  const TITLES = {
    rejected_prompts: '🧠 Rejected Prompts',
    unauthorized_ops: '🔐 Unauthorized Ops',
    stress_spikes:    '⚡ Stress Spikes',
    replay_physical:  '🗂 Physical Replay',
  };
  document.getElementById('modal-title').textContent = TITLES[data.type] || data.type;
  const body = document.getElementById('modal-body');
  const rows = data.rows || [];
  if (!rows.length) {
    body.innerHTML = '<div class="empty-msg">No results found.</div>';
  } else {
    const hdr = rows[0].map((_, i) => `<th>COL ${i+1}</th>`).join('');
    const bdy = rows.map(r => '<tr>' + r.map(c => `<td>${escHtml(c)}</td>`).join('') + '</tr>').join('');
    body.innerHTML = `<table class="q-table"><thead><tr>${hdr}</tr></thead><tbody>${bdy}</tbody></table>`;
  }
  document.getElementById('modal-overlay').classList.add('open');
}
window.closeModal = () => document.getElementById('modal-overlay').classList.remove('open');

// ── Utils ─────────────────────────────────────────────────────────────────────
function escHtml(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function timeAgo(ts) {
  const d = Math.floor((Date.now() - ts) / 1000);
  if (d < 5)   return 'now';
  if (d < 60)  return `${d}s`;
  if (d < 3600) return `${Math.floor(d/60)}m`;
  return `${Math.floor(d/3600)}h`;
}

function hideEmpty() {
  const el = document.getElementById('empty-state');
  if (el) el.style.display = 'none';
}

// ── Phoenix WebSocket ─────────────────────────────────────────────────────────
function connect() {
  const socket = new Socket('/dashboard', {});
  socket.connect();
  channel = socket.channel('acn:panopticon', {});

  channel.on('snapshot',    data => { nodeMap.clear(); totalEvents = 0; applySnapshot(data); });
  channel.on('graph_diff',  data => applyDiff(data));
  channel.on('query_result', data => showQueryModal(data));

  channel.join()
    .receive('ok',    ()  => console.log('[HSG] Channel joined'))
    .receive('error', err => console.error('[HSG] Channel error', err));
}

// ── Bootstrap ─────────────────────────────────────────────────────────────────
connect();
updateTopbar();
// Initial viewport
setTimeout(() => {
  svg.call(zoom.transform, d3.zoomIdentity.translate(
    (document.getElementById('tree-svg')?.clientWidth || 800) / 2, 80
  ).scale(0.9));
}, 100);
