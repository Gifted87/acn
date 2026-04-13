defmodule ACNWeb.PageController do
  use Phoenix.Controller, namespace: ACNWeb

  # ── Main Dashboard ─────────────────────────────────────────────────────────

  def index(conn, _params) do
    html(conn, dashboard_html())
  end

  # ── Shadow File API ────────────────────────────────────────────────────────

  def shadow(conn, %{"node_id" => node_id}) do
    # node_id is actually the mat_path, e.g. "root.auth.db"
    workspace_root =
      Application.get_env(:acn, :hsg)[:shadow_root] || "tmp/acn_workspaces"
    workspace_root = Path.expand(workspace_root)

    # Derive shadow dir: root.auth.db → <workspace_root>/root/.shadow/auth/db
    parts = String.split(node_id, ".")
    [root_node | rest_path] = parts
    shadow_dir = Path.join([workspace_root, root_node, ".shadow"] ++ rest_path)

    result = %{
      cognitive: read_shadow_file(shadow_dir, "cognitive.jsonl"),
      physical:  read_shadow_file(shadow_dir, "physical.patch"),
      security:  read_shadow_file(shadow_dir, "security.audit"),
      autonomic: read_shadow_file(shadow_dir, "autonomic.log")
    }

    json(conn, result)
  end

  defp read_shadow_file(dir, filename) do
    path = Path.join(dir, filename)
    case File.read(path) do
      {:ok, content} -> content
      {:error, _}    -> nil
    end
  end

  # ── Dashboard HTML ─────────────────────────────────────────────────────────

  defp dashboard_html do
    ~S"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ACN · Holographic Shadow-Graph Panopticon</title>
    <meta name="description" content="ACN real-time agent hierarchy visualiser with shadow file inspection">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap" rel="stylesheet">
    <script src="https://cdn.jsdelivr.net/npm/d3@7/dist/d3.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/phoenix@1.6.16/priv/static/phoenix.min.js"></script>
    <style>

    /* ── Reset & Custom Properties ───────────────────────────────────────── */
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    :root {
      --bg:        #060810;
      --bg2:       #080b14;
      --surface:   rgba(11,15,28,0.9);
      --surface2:  rgba(15,20,38,0.95);
      --surface3:  rgba(20,26,50,0.95);
      --glass:     rgba(255,255,255,0.04);
      --glass2:    rgba(255,255,255,0.07);

      --cyan:      #00e5ff;
      --cyan-dim:  rgba(0,229,255,0.15);
      --cyan-glow: 0 0 24px rgba(0,229,255,0.4);
      --blue:      #0090ff;
      --indigo:    #6366f1;
      --purple:    #a855f7;
      --magenta:   #e879f9;
      --green:     #00ff9d;
      --orange:    #fb923c;
      --red:       #ff4757;
      --yellow:    #fbbf24;

      --text:      #e2e8f8;
      --text2:     #94a3c8;
      --muted:     #4a5680;
      --muted2:    #2d3555;

      --border:    rgba(0,229,255,0.12);
      --border2:   rgba(99,102,241,0.2);
      --border3:   rgba(255,255,255,0.06);

      --font:      'Inter', system-ui, sans-serif;
      --mono:      'JetBrains Mono', 'Fira Code', monospace;

      --topbar-h:  58px;
      --sidebar-w: 310px;
      --scrubber-h: 46px;
      --drawer-h:   46vh;
      --r:         10px;
      --r-lg:      14px;
      --r-sm:      6px;

      --ease-out:  cubic-bezier(0.16, 1, 0.3, 1);
    }

    html, body {
      width: 100%; height: 100%; overflow: hidden;
      background: var(--bg); color: var(--text);
      font-family: var(--font); font-size: 13px; line-height: 1.5;
    }

    /* ── Scrollbars ──────────────────────────────────────────────────────── */
    ::-webkit-scrollbar { width: 4px; height: 4px; }
    ::-webkit-scrollbar-track { background: transparent; }
    ::-webkit-scrollbar-thumb { background: var(--muted2); border-radius: 2px; }
    ::-webkit-scrollbar-thumb:hover { background: var(--muted); }

    /* ── Animations ──────────────────────────────────────────────────────── */
    @keyframes pulse-ring {
      0%, 100% { opacity: 1; box-shadow: 0 0 4px var(--green); }
      50%       { opacity: 0.6; box-shadow: 0 0 14px var(--green), 0 0 30px rgba(0,255,157,0.3); }
    }
    @keyframes swell-blue {
      0%, 100% { box-shadow: 0 0 8px rgba(0,144,255,0.3), inset 0 0 0 transparent; border-color: rgba(0,144,255,0.5); }
      50%       { box-shadow: 0 0 28px rgba(0,144,255,0.7), 0 0 60px rgba(0,144,255,0.15); border-color: rgba(0,144,255,1); }
    }
    @keyframes flash-red {
      0%, 100% { box-shadow: 0 0 12px rgba(255,71,87,0.4); border-color: rgba(255,71,87,0.6); }
      50%       { box-shadow: 0 0 32px rgba(255,71,87,0.9); border-color: #ff4757; }
    }
    @keyframes fade-in {
      from { opacity: 0; transform: translateY(6px); }
      to   { opacity: 1; transform: none; }
    }
    @keyframes slide-up {
      from { transform: translateY(30px); opacity: 0; }
      to   { transform: none; opacity: 1; }
    }

    /* ── Topbar ──────────────────────────────────────────────────────────── */
    #topbar {
      position: fixed; top: 0; left: 0; right: 0; height: var(--topbar-h); z-index: 500;
      background: linear-gradient(90deg, rgba(6,8,16,0.98) 0%, rgba(10,14,26,0.98) 50%, rgba(6,8,16,0.98) 100%);
      border-bottom: 1px solid var(--border);
      display: flex; align-items: center; padding: 0 20px; gap: 12px;
      backdrop-filter: blur(20px);
    }
    .tb-logo {
      display: flex; align-items: center; gap: 10px;
      font-size: 15px; font-weight: 700; letter-spacing: 3px;
      background: linear-gradient(90deg, var(--cyan), var(--purple));
      -webkit-background-clip: text; -webkit-text-fill-color: transparent;
      background-clip: text; white-space: nowrap; flex-shrink: 0;
    }
    .tb-logo-icon {
      -webkit-text-fill-color: var(--cyan); font-size: 22px;
      filter: drop-shadow(0 0 8px rgba(0,229,255,0.8));
    }
    .tb-separator { width: 1px; height: 28px; background: var(--border2); flex-shrink: 0; }
    .tb-spacer    { flex: 1; }

    .tb-metric {
      display: flex; flex-direction: column; align-items: center; gap: 1px;
      padding: 5px 14px; border: 1px solid var(--border2);
      border-radius: var(--r); background: var(--glass);
      min-width: 70px; flex-shrink: 0;
      transition: border-color 0.2s, background 0.2s;
    }
    .tb-metric:hover { background: var(--glass2); border-color: rgba(0,229,255,0.3); }
    .tb-metric .val {
      font-size: 16px; font-weight: 600; font-family: var(--mono);
      color: var(--cyan); line-height: 1;
    }
    .tb-metric .lbl { font-size: 8px; letter-spacing: 2px; color: var(--muted); }
    .tb-metric.metric-run .val    { color: var(--blue); }
    .tb-metric.metric-done .val   { color: var(--green); }
    .tb-metric.metric-err .val    { color: var(--red); }
    .tb-metric.metric-ev .val     { color: var(--yellow); }
    .tb-metric.metric-up .val     { font-size: 12px; color: var(--text2); }

    .tb-pulse {
      width: 8px; height: 8px; border-radius: 50%; background: var(--green);
      animation: pulse-ring 1.8s ease-in-out infinite; flex-shrink: 0;
    }

    .tb-icon-btn {
      width: 32px; height: 32px; border-radius: var(--r-sm);
      border: 1px solid var(--border2); background: var(--glass);
      color: var(--text2); cursor: pointer; font-size: 14px;
      display: flex; align-items: center; justify-content: center;
      transition: all 0.2s; flex-shrink: 0;
    }
    .tb-icon-btn:hover { background: var(--glass2); color: var(--cyan); border-color: var(--border); }

    /* ── Layout ──────────────────────────────────────────────────────────── */
    #sidebar {
      position: fixed; top: var(--topbar-h); left: 0; bottom: var(--scrubber-h);
      width: var(--sidebar-w); z-index: 200;
      background: var(--surface);
      border-right: 1px solid var(--border);
      display: flex; flex-direction: column; overflow: hidden;
    }

    #canvas-wrap {
      position: fixed;
      top: var(--topbar-h); left: var(--sidebar-w); right: 0;
      bottom: var(--scrubber-h);
      background: var(--bg);
      overflow: hidden;
    }
    /* Dot-grid background */
    #canvas-wrap::before {
      content: ''; position: absolute; inset: 0; pointer-events: none;
      background-image:
        radial-gradient(circle, rgba(0,229,255,0.055) 1px, transparent 1px);
      background-size: 52px 52px;
    }
    /* Vignette */
    #canvas-wrap::after {
      content: ''; position: absolute; inset: 0; pointer-events: none;
      background: radial-gradient(ellipse 80% 80% at 50% 50%,
        transparent 50%, rgba(6,8,16,0.6) 100%);
    }
    #tree-svg { width: 100%; height: 100%; display: block; }

    /* ── Sidebar Tabs ────────────────────────────────────────────────────── */
    .sidebar-tabbar {
      display: flex; border-bottom: 1px solid var(--border);
      background: rgba(0,0,0,0.2); flex-shrink: 0;
    }
    .stab-btn {
      flex: 1; padding: 10px 4px; font-size: 9px; letter-spacing: 1.8px; font-weight: 600;
      color: var(--muted); background: none; border: none;
      border-bottom: 2px solid transparent; cursor: pointer;
      font-family: var(--font); transition: all 0.2s;
    }
    .stab-btn:hover { color: var(--text2); }
    .stab-btn.stab-active { color: var(--cyan); border-bottom-color: var(--cyan); }

    .stab-panel {
      flex: 1; flex-direction: column; overflow-y: auto; display: none;
    }
    .stab-panel.panel-active { display: flex; }

    /* ── Detail Panel ────────────────────────────────────────────────────── */
    #detail-body {
      padding: 14px; flex: 1; overflow-y: auto;
      color: var(--text2); font-size: 11px; line-height: 1.6;
    }
    .dp-section {
      margin-bottom: 14px; padding-bottom: 12px;
      border-bottom: 1px solid var(--border3);
    }
    .dp-section:last-child { border-bottom: none; }
    .dp-label {
      font-size: 8px; letter-spacing: 2px; color: var(--muted);
      margin-bottom: 7px; font-weight: 600;
    }
    .dp-row {
      display: flex; justify-content: space-between; gap: 8px;
      padding: 3px 0; border-bottom: 1px solid rgba(255,255,255,0.03);
    }
    .dp-key { color: var(--muted); font-size: 10px; letter-spacing: 1px; flex-shrink: 0; }
    .dp-val { color: var(--text); font-family: var(--mono); font-size: 10px; text-align: right; word-break: break-all; }
    .dp-val.mono { font-family: var(--mono); }
    .stress-track {
      height: 5px; background: var(--muted2); border-radius: 3px; overflow: hidden; margin-top: 6px;
    }
    .stress-fill { height: 100%; border-radius: 3px; transition: width 0.4s; }

    .dp-actions { padding: 12px 14px 16px; display: flex; flex-direction: column; gap: 6px; }
    .dp-btn {
      width: 100%; padding: 8px 12px; border-radius: var(--r-sm);
      border: 1px solid var(--border2); background: var(--glass);
      color: var(--text2); font-size: 10px; letter-spacing: 1.2px;
      cursor: pointer; font-family: var(--font); transition: all 0.2s; text-align: left;
    }
    .dp-btn:hover { background: var(--glass2); color: var(--text); border-color: var(--border); }
    .dp-btn.dp-btn-accent {
      border-color: rgba(0,229,255,0.3); color: var(--cyan); background: rgba(0,229,255,0.06);
    }
    .dp-btn.dp-btn-accent:hover {
      background: rgba(0,229,255,0.14); border-color: var(--cyan);
      box-shadow: 0 0 14px rgba(0,229,255,0.25);
    }

    /* ── Event Log Panel ─────────────────────────────────────────────────── */
    #event-log-list {
      flex: 1; overflow-y: auto; padding: 6px 0;
    }
    .log-row {
      display: flex; gap: 8px; align-items: baseline;
      padding: 5px 12px; border-bottom: 1px solid rgba(255,255,255,0.03);
      animation: fade-in 0.2s ease; font-size: 10px;
    }
    .log-row:hover { background: rgba(255,255,255,0.02); }
    .log-ts   { color: var(--muted); font-family: var(--mono); white-space: nowrap; }
    .log-node { color: var(--cyan); font-family: var(--mono); min-width: 70px; max-width: 90px;
                overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .log-phase {
      font-size: 9px; font-family: var(--mono); padding: 1px 6px;
      border: 1px solid; border-radius: 3px; white-space: nowrap;
    }

    /* ── Vectors / Queries Panel ─────────────────────────────────────────── */
    #stab-vectors { padding: 14px; gap: 6px; }
    .q-btn {
      padding: 9px 14px; border-radius: var(--r-sm);
      border: 1px solid var(--border2); background: var(--glass);
      color: var(--text2); font-size: 10px; letter-spacing: 1.2px;
      cursor: pointer; font-family: var(--font); transition: all 0.2s; text-align: left;
    }
    .q-btn:hover {
      background: rgba(168,85,247,0.12); border-color: rgba(168,85,247,0.4);
      color: var(--text); box-shadow: 0 0 14px rgba(168,85,247,0.2);
    }

    /* ── Node Cards ──────────────────────────────────────────────────────── */
    .node-card {
      width: 230px; height: 100px;
      background: var(--bgc, rgba(8,14,34,0.92));
      backdrop-filter: blur(14px) saturate(1.4);
      -webkit-backdrop-filter: blur(14px) saturate(1.4);
      border: 1px solid var(--bc, rgba(70,90,150,0.4));
      border-radius: 12px; padding: 10px 12px;
      cursor: pointer; user-select: none;
      display: flex; flex-direction: column; gap: 5px;
      position: relative; overflow: hidden;
      transition: transform 0.25s var(--ease-out),
                  box-shadow 0.3s ease,
                  border-color 0.3s ease;
      box-shadow: 0 4px 24px rgba(0,0,0,0.5),
                  inset 0 0 0 1px rgba(255,255,255,0.04);
    }
    /* Neon accent bar at top */
    .node-card::before {
      content: ''; position: absolute; top: 0; left: 12px; right: 12px; height: 1.5px;
      background: linear-gradient(90deg, transparent, var(--pc, #555), transparent);
      opacity: 0.9; border-radius: 0 0 2px 2px;
    }
    .node-card:hover {
      transform: translateY(-3px);
      box-shadow: 0 14px 40px rgba(0,0,0,0.6), 0 0 0 1px rgba(0,229,255,0.35),
                  inset 0 0 30px rgba(0,229,255,0.04);
      border-color: rgba(0,229,255,0.55) !important;
    }
    .node-card.nc-selected {
      border-color: var(--cyan) !important; border-width: 1.5px;
      box-shadow: 0 0 0 2px rgba(0,229,255,0.2), 0 8px 32px rgba(0,229,255,0.25),
                  inset 0 0 40px rgba(0,229,255,0.07);
    }
    .node-card.nc-running    { animation: swell-blue 2.2s ease-in-out infinite; }
    .node-card.nc-done       { box-shadow: 0 0 20px rgba(0,255,157,0.12); }
    .node-card.nc-error      { animation: flash-red 1s ease-in-out infinite; }
    .node-card.nc-synth      { opacity: 0.65; border-style: dashed; }

    /* Card sections */
    .nc-header {
      display: flex; align-items: center; gap: 7px; min-width: 0;
    }
    .nc-icon {
      font-size: 13px; flex-shrink: 0;
      filter: drop-shadow(0 0 4px var(--pc, rgba(0,229,255,0.6)));
    }
    .nc-label {
      font-size: 12px; font-weight: 700; font-family: var(--mono);
      color: var(--text); flex: 1; overflow: hidden; text-overflow: ellipsis;
      white-space: nowrap; letter-spacing: 0.5px;
    }
    .nc-tier {
      font-size: 8px; font-weight: 600; letter-spacing: 1px;
      color: var(--pc, var(--muted));
      padding: 1px 6px; border: 1px solid;
      border-color: rgba(from var(--pc, #555) r g b / 0.35);
      border-radius: 3px; background: rgba(from var(--pc, #555) r g b / 0.07);
      flex-shrink: 0; white-space: nowrap;
    }
    .nc-path {
      font-size: 9px; font-family: var(--mono); color: var(--muted);
      overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      padding-left: 2px;
    }
    .nc-mid {
      display: flex; align-items: flex-end; justify-content: space-between; flex: 1;
    }
    .nc-agents { display: flex; gap: 5px; align-items: center; }
    .nc-heat   { display: flex; gap: 2px; align-items: flex-end; height: 18px; }

    .nc-footer {
      display: flex; gap: 6px; align-items: center; flex-wrap: wrap;
    }
    .nc-phase {
      font-size: 9px; font-family: var(--mono); font-weight: 600;
      letter-spacing: 1px; flex-shrink: 0;
    }
    .nc-stat {
      font-size: 9px; font-family: var(--mono); color: var(--muted);
      white-space: nowrap;
    }

    /* Heatmap bars */
    .hb {
      width: 5px; border-radius: 2px 2px 0 0; min-height: 3px;
      transition: height 0.3s, background 0.3s;
    }

    /* Agent dots */
    .ag-dot {
      width: 14px; height: 14px; border-radius: 50%;
      border: 1.5px solid rgba(255,255,255,0.1);
      cursor: pointer; transition: transform 0.15s, box-shadow 0.2s;
      position: relative; display: inline-block;
    }
    .ag-dot[data-state="none"]   { background: rgba(60,70,100,0.4); border-color: rgba(255,255,255,0.08); }
    .ag-dot[data-state="idle"]   { background: var(--ac); opacity: 0.5; border-color: var(--ac); }
    .ag-dot[data-state="active"] {
      background: var(--ac); border-color: var(--ac);
      box-shadow: 0 0 8px var(--ac);
      animation: pulse-ring 1.2s ease-in-out infinite;
    }
    .ag-dot[data-state="done"]   { background: var(--ac); border-color: var(--ac); opacity: 0.8; }
    .ag-dot:hover { transform: scale(1.35); }

    /* ── Viewport Controls ───────────────────────────────────────────────── */
    #vp-controls {
      position: absolute; left: 16px; top: 16px; z-index: 100;
      display: flex; flex-direction: column; gap: 4px;
      background: var(--surface2); border: 1px solid var(--border);
      border-radius: var(--r); padding: 7px;
      backdrop-filter: blur(12px);
      box-shadow: 0 4px 20px rgba(0,0,0,0.5);
    }
    .vp-btn {
      width: 30px; height: 30px; border-radius: var(--r-sm);
      border: 1px solid var(--border2); background: var(--glass);
      color: var(--cyan); cursor: pointer; font-size: 15px; font-weight: 600;
      display: flex; align-items: center; justify-content: center;
      transition: all 0.18s; font-family: var(--mono); line-height: 1;
    }
    .vp-btn:hover {
      background: rgba(0,229,255,0.15); border-color: var(--cyan);
      box-shadow: 0 0 10px rgba(0,229,255,0.3);
    }
    .vp-divider { height: 1px; background: var(--border); margin: 2px 0; }

    /* ── Minimap ─────────────────────────────────────────────────────────── */
    #minimap {
      position: absolute; right: 14px; top: 14px; z-index: 100;
      width: 150px; height: 90px;
      background: rgba(6,8,16,0.88); border: 1px solid var(--border);
      border-radius: var(--r); overflow: hidden; backdrop-filter: blur(8px);
    }
    #minimap-label {
      position: absolute; top: 5px; left: 8px;
      font-size: 7px; letter-spacing: 2px; color: var(--muted); pointer-events: none;
    }
    #minimap-svg { width: 100%; height: 100%; display: block; }

    /* ── Timeline Scrubber ───────────────────────────────────────────────── */
    #scrubber {
      position: fixed; left: var(--sidebar-w); right: 0; bottom: 0;
      height: var(--scrubber-h); z-index: 200;
      background: var(--surface2); border-top: 1px solid var(--border);
      display: flex; align-items: center; gap: 12px; padding: 0 14px;
    }
    #scrubber-label {
      font-size: 8px; letter-spacing: 2px; color: var(--muted); flex-shrink: 0; white-space: nowrap;
    }
    .live-dot {
      width: 6px; height: 6px; border-radius: 50%; background: var(--green);
      box-shadow: 0 0 6px var(--green); flex-shrink: 0;
      animation: pulse-ring 1.5s ease-in-out infinite;
    }
    #scrubber-track {
      flex: 1; display: flex; align-items: flex-end; gap: 2px;
      height: 28px; overflow: hidden;
    }
    .s-tick {
      width: 3px; min-width: 3px; min-height: 4px; height: 18px;
      border-radius: 2px; opacity: 0.75; flex-shrink: 0;
      transition: height 0.2s;
    }
    .s-tick:hover { height: 26px; opacity: 1; }

    /* ── Shadow Drawer ───────────────────────────────────────────────────── */
    #shadow-drawer {
      position: fixed; left: var(--sidebar-w); right: 0; bottom: var(--scrubber-h);
      height: var(--drawer-h); z-index: 400;
      background: var(--surface2); border-top: 1px solid var(--border);
      display: flex; flex-direction: column;
      transform: translateY(100%);
      transition: transform 0.35s var(--ease-out);
      backdrop-filter: blur(20px);
    }
    #shadow-drawer.open { transform: translateY(0); }
    #shadow-drawer-hdr {
      display: flex; align-items: center; gap: 12px; padding: 11px 18px;
      border-bottom: 1px solid var(--border3);
      background: rgba(0,229,255,0.03); flex-shrink: 0;
    }
    #shadow-title { font-size: 12px; color: var(--cyan); flex: 1; font-family: var(--mono); }
    .drawer-close {
      width: 26px; height: 26px; border-radius: 5px;
      border: 1px solid var(--border2); background: var(--glass);
      color: var(--text2); cursor: pointer; font-size: 13px;
      display: flex; align-items: center; justify-content: center;
      transition: all 0.2s;
    }
    .drawer-close:hover { border-color: var(--red); color: var(--red); }
    #shadow-body { flex: 1; overflow-y: auto; padding: 14px 18px; }
    .tabbar { display: flex; gap: 6px; margin-bottom: 12px; flex-wrap: wrap; }
    .stab {
      padding: 4px 12px; font-size: 9px; letter-spacing: 1.2px; border-radius: 4px;
      background: var(--glass); border: 1px solid var(--border2);
      color: var(--muted); cursor: pointer; font-family: var(--font); transition: all 0.18s; font-weight: 600;
    }
    .stab:hover { color: var(--text2); }
    .stab.stab-active {
      background: rgba(0,229,255,0.1); border-color: rgba(0,229,255,0.4); color: var(--cyan);
    }
    .shadow-pre {
      font-family: var(--mono); font-size: 11px; color: var(--text);
      white-space: pre-wrap; word-break: break-all; line-height: 1.65;
      background: rgba(0,0,0,0.3); border: 1px solid var(--border3);
      border-radius: 8px; padding: 12px; max-height: 220px; overflow-y: auto;
    }
    .empty-msg   { color: var(--muted); font-size: 11px; padding: 16px 0; }
    .loading     { color: var(--muted); font-size: 11px; padding: 16px 0; animation: pulse-ring 1s infinite; }
    .err         { color: var(--red); font-size: 11px; padding: 12px 0; }
    .agent-panel { display: flex; flex-direction: column; gap: 10px; }
    .ap-row      { display: flex; gap: 10px; align-items: baseline; }
    .ap-key      { font-size: 9px; letter-spacing: 1.5px; color: var(--muted); min-width: 80px; }
    .ap-val      { font-size: 11px; font-family: var(--mono); color: var(--text); }

    /* ── Query Modal ─────────────────────────────────────────────────────── */
    #modal-overlay {
      position: fixed; inset: 0; background: rgba(0,0,0,0.7); z-index: 900;
      display: none; align-items: flex-end; justify-content: center; padding-bottom: 58px;
      backdrop-filter: blur(4px);
    }
    #modal-overlay.open { display: flex; animation: fade-in 0.2s ease; }
    #modal-box {
      background: var(--surface3); border: 1px solid var(--border2);
      border-radius: var(--r-lg) var(--r-lg) 0 0;
      width: 100%; max-width: 900px; max-height: 56vh;
      display: flex; flex-direction: column;
      box-shadow: 0 -24px 80px rgba(0,0,0,0.6), 0 0 0 1px rgba(0,229,255,0.08);
      animation: slide-up 0.3s var(--ease-out);
    }
    #modal-hdr {
      display: flex; align-items: center; gap: 12px; padding: 14px 20px;
      border-bottom: 1px solid var(--border); flex-shrink: 0;
    }
    #modal-title { font-size: 13px; color: var(--cyan); flex: 1; font-family: var(--mono); }
    #modal-close {
      width: 28px; height: 28px; border-radius: 5px;
      border: 1px solid var(--border2); background: var(--glass);
      color: var(--text2); cursor: pointer; font-size: 14px;
      display: flex; align-items: center; justify-content: center;
      transition: all 0.2s;
    }
    #modal-close:hover { border-color: var(--red); color: var(--red); }
    #modal-body { flex: 1; overflow-y: auto; padding: 14px 20px; }
    .q-table { width: 100%; border-collapse: collapse; font-size: 11px; font-family: var(--mono); }
    .q-table th {
      text-align: left; color: var(--muted); font-size: 9px; letter-spacing: 1.5px;
      padding: 6px 8px; border-bottom: 1px solid var(--border); font-weight: 600;
    }
    .q-table td { padding: 6px 8px; border-bottom: 1px solid var(--border3); color: var(--text); }
    .q-table tr:hover td { background: rgba(0,229,255,0.04); }

    /* ── Empty State ─────────────────────────────────────────────────────── */
    #empty-state {
      position: absolute; inset: 0; z-index: 5;
      display: flex; flex-direction: column; align-items: center; justify-content: center;
      gap: 14px; pointer-events: none;
    }
    .es-hex {
      font-size: 56px; opacity: 0.08;
      filter: drop-shadow(0 0 24px rgba(0,229,255,0.5));
      animation: pulse-ring 3s ease-in-out infinite;
    }
    .es-title { font-size: 15px; color: var(--muted); letter-spacing: 3px; font-weight: 500; opacity: 0.7; }
    .es-sub   { font-size: 11px; color: var(--muted); letter-spacing: 1px; opacity: 0.5; }

    </style>
    </head>
    <body>

    <!-- ═══ TOPBAR ═══════════════════════════════════════════════════════════ -->
    <div id="topbar">
      <div class="tb-logo">
        <span class="tb-logo-icon">⬡</span>
        HSG PANOPTICON
      </div>
      <div class="tb-pulse"></div>
      <div class="tb-separator"></div>

      <div class="tb-metric" title="Total agent nodes in graph">
        <div class="val" id="m-nodes">0</div>
        <div class="lbl">NODES</div>
      </div>
      <div class="tb-metric metric-run" title="Currently running nodes">
        <div class="val" id="m-running">0</div>
        <div class="lbl">RUNNING</div>
      </div>
      <div class="tb-metric metric-done" title="Completed nodes">
        <div class="val" id="m-completed">0</div>
        <div class="lbl">DONE</div>
      </div>
      <div class="tb-metric metric-err" title="Failed/frozen nodes">
        <div class="val" id="m-errors">0</div>
        <div class="lbl">ERRORS</div>
      </div>
      <div class="tb-metric metric-ev" title="Total telemetry events received">
        <div class="val" id="m-events">0</div>
        <div class="lbl">EVENTS</div>
      </div>
      <div class="tb-metric metric-up" title="Dashboard uptime">
        <div class="val" id="m-uptime">00:00:00</div>
        <div class="lbl">UPTIME</div>
      </div>

      <div class="tb-spacer"></div>

      <button class="tb-icon-btn" onclick="requestSnapshot()" title="Refresh full snapshot">⟳</button>
      <button class="tb-icon-btn" onclick="vpFitAll()" title="Fit all nodes">⊡</button>
    </div>

    <!-- ═══ SIDEBAR ══════════════════════════════════════════════════════════ -->
    <div id="sidebar">
      <div class="sidebar-tabbar">
        <button class="stab-btn stab-active" data-tab="detail" id="stab-btn-detail"
          onclick="switchSidebarTab('detail')">◈ DETAIL</button>
        <button class="stab-btn" data-tab="log" id="stab-btn-log"
          onclick="switchSidebarTab('log')">▸ LOG</button>
        <button class="stab-btn" data-tab="vectors" id="stab-btn-vectors"
          onclick="switchSidebarTab('vectors')">⬡ QUERY</button>
      </div>

      <!-- Detail tab -->
      <div class="stab-panel panel-active" id="stab-detail" style="display:flex">
        <div id="detail-body" style="padding:16px;color:var(--muted);font-size:11px;line-height:1.8">
          <div style="opacity:0.5;margin-bottom:8px">Select a node to inspect it.</div>
          <div style="opacity:0.35;font-size:10px">• Single-click to select<br>• Double-click to collapse subtree<br>• Ctrl+scroll to zoom</div>
        </div>
      </div>

      <!-- Event Log tab -->
      <div class="stab-panel" id="stab-log" style="display:none">
        <div id="event-log-list"></div>
      </div>

      <!-- Vectors / Query tab -->
      <div class="stab-panel" id="stab-vectors" style="display:none">
        <button class="q-btn" onclick="runQuery('rejected_prompts')">🧠 &nbsp;REJECTED PROMPTS</button>
        <button class="q-btn" onclick="runQuery('stress_spikes')">⚡ &nbsp;STRESS SPIKES</button>
        <button class="q-btn" onclick="runQuery('unauthorized_ops', {node_id: window.__getSelectedPath()||'root'})">🔐 &nbsp;UNAUTHORIZED OPS</button>
        <button class="q-btn" onclick="runQuery('replay_physical', {node_id: window.__getSelectedPath()||'root'})">🗂 &nbsp;REPLAY PHYSICAL</button>
        <div style="height:1px;background:var(--border3);margin:4px 0"></div>
        <button class="q-btn" onclick="requestSnapshot()">♻ &nbsp;REFRESH SNAPSHOT</button>
      </div>
    </div>

    <!-- ═══ MAIN CANVAS ═══════════════════════════════════════════════════════ -->
    <div id="canvas-wrap">

      <!-- Viewport controls -->
      <div id="vp-controls">
        <button class="vp-btn" id="vp-zoom-in"  onclick="vpZoom(1.25)" title="Zoom in">+</button>
        <button class="vp-btn" id="vp-zoom-out" onclick="vpZoom(0.8)"  title="Zoom out">−</button>
        <div class="vp-divider"></div>
        <button class="vp-btn" id="vp-fit"   onclick="vpFitAll()" title="Fit all">⊡</button>
        <button class="vp-btn" id="vp-reset" onclick="vpReset()"  title="Reset view">⌂</button>
      </div>

      <!-- Minimap -->
      <div id="minimap">
        <div id="minimap-label">MINIMAP</div>
        <svg id="minimap-svg"></svg>
      </div>

      <!-- Empty state -->
      <div id="empty-state">
        <div class="es-hex">⬡</div>
        <div class="es-title">AWAITING TELEMETRY</div>
        <div class="es-sub">Nodes appear as they come online</div>
      </div>

      <!-- D3 Canvas -->
      <svg id="tree-svg"></svg>
    </div>

    <!-- ═══ TIMELINE SCRUBBER ══════════════════════════════════════════════════ -->
    <div id="scrubber">
      <div class="live-dot"></div>
      <div id="scrubber-label">▸ EVENTS</div>
      <div id="scrubber-track"></div>
    </div>

    <!-- ═══ SHADOW DRAWER ════════════════════════════════════════════════════ -->
    <div id="shadow-drawer">
      <div id="shadow-drawer-hdr">
        <div id="shadow-title">Shadow Files</div>
        <button class="drawer-close" onclick="closeShadowDrawer()" title="Close">✕</button>
      </div>
      <div id="shadow-body"></div>
    </div>

    <!-- ═══ QUERY MODAL ═══════════════════════════════════════════════════════ -->
    <div id="modal-overlay" onclick="if(event.target===this)closeModal()">
      <div id="modal-box">
        <div id="modal-hdr">
          <div id="modal-title">Query Results</div>
          <button id="modal-close" onclick="closeModal()">✕</button>
        </div>
        <div id="modal-body"></div>
      </div>
    </div>

    <script>
    // Wire up sidebar tab switching to show/hide panels manually
    // (bridges the inline onclick to hsg_dashboard.js)
    function switchSidebarTab(tab) {
      document.querySelectorAll('.stab-btn').forEach(b =>
        b.classList.toggle('stab-active', b.dataset.tab === tab)
      );
      document.querySelectorAll('.stab-panel').forEach(p => {
        const show = p.id === 'stab-' + tab;
        p.style.display = show ? 'flex' : 'none';
      });
    }
    window.switchSidebarTab = switchSidebarTab;
    </script>
    <script src="/js/hsg_dashboard.js"></script>
    </body>
    </html>
    """
  end
end
