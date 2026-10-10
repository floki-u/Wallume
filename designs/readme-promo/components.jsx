const { useState } = React;

function Icon({ name, size = 18, stroke = 1.8 }) {
  const paths = {
    library: <><rect x="3" y="3" width="7" height="7" rx="1.5"></rect><rect x="14" y="3" width="7" height="7" rx="1.5"></rect><rect x="3" y="14" width="7" height="7" rx="1.5"></rect><rect x="14" y="14" width="7" height="7" rx="1.5"></rect></>,
    display: <><rect x="2.5" y="4" width="19" height="13" rx="2.5"></rect><path d="M8 21h8M12 17v4"></path></>,
    lock: <><rect x="5" y="10" width="14" height="11" rx="2.5"></rect><path d="M8 10V7a4 4 0 0 1 8 0v3"></path></>,
    pulse: <path d="M3 12h4l2.1-6 4.2 12 2.2-6H21"></path>,
    gear: <><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.86 2.86-.06-.06A1.7 1.7 0 0 0 15 19.4a1.7 1.7 0 0 0-1 .6 1.7 1.7 0 0 0-.4 1.1V21H9.55v-.1A1.7 1.7 0 0 0 8.5 19.4a1.7 1.7 0 0 0-1.88.34l-.06.06-2.86-2.86.06-.06A1.7 1.7 0 0 0 4.1 15a1.7 1.7 0 0 0-.6-1 1.7 1.7 0 0 0-1.1-.4H2.3V9.55h.1A1.7 1.7 0 0 0 4.1 8.5a1.7 1.7 0 0 0-.34-1.88l-.06-.06L6.56 3.7l.06.06A1.7 1.7 0 0 0 8.5 4.1a1.7 1.7 0 0 0 1-.6 1.7 1.7 0 0 0 .4-1.1v-.1h4.05v.1A1.7 1.7 0 0 0 15 4.1a1.7 1.7 0 0 0 1.88-.34l.06-.06 2.86 2.86-.06.06A1.7 1.7 0 0 0 19.4 8.5a1.7 1.7 0 0 0 .6 1 1.7 1.7 0 0 0 1.1.4h.1v4.05h-.1A1.7 1.7 0 0 0 19.4 15Z"></path></>,
    search: <><circle cx="11" cy="11" r="7"></circle><path d="m20 20-4-4"></path></>,
    plus: <><path d="M12 5v14M5 12h14"></path></>,
    play: <path d="m9 7 8 5-8 5Z"></path>,
    pause: <><path d="M9 7v10M15 7v10"></path></>,
    chevron: <path d="m9 18 6-6-6-6"></path>,
    check: <path d="m5 12 4 4 10-10"></path>,
    monitor: <><rect x="3" y="4" width="18" height="13" rx="2"></rect><path d="M9 21h6M12 17v4"></path></>,
    spark: <><path d="m12 3 1.2 4.1L17 9l-3.8 1.9L12 15l-1.2-4.1L7 9l3.8-1.9Z"></path><path d="m19 15 .6 2.2L22 18.5l-2.4 1.3L19 22l-.6-2.2-2.4-1.3 2.4-1.3Z"></path></>,
    more: <><circle cx="5" cy="12" r="1"></circle><circle cx="12" cy="12" r="1"></circle><circle cx="19" cy="12" r="1"></circle></>,
    info: <><circle cx="12" cy="12" r="9"></circle><path d="M12 10v6M12 7.2h.01"></path></>,
    moon: <path d="M20 15.5A8 8 0 0 1 8.5 4 8.2 8.2 0 1 0 20 15.5Z"></path>,
    sun: <><circle cx="12" cy="12" r="4"></circle><path d="M12 2v2M12 20v2M4.93 4.93l1.42 1.42M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.42-1.42M17.66 6.34l1.41-1.41"></path></>
  };
  return <svg className="icon" width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name]}</svg>;
}

function MacWindow({ children, direction, onDirection, reviewOpen, onReviewOpen }) {
  return (
    <div className={`prototype-shell direction-${direction}`}>
      <div className="review-strip">
        <div className="review-copy">
          <span className="eyebrow">WALLUME / REDESIGN 01</span>
          <strong>高保真交互原型</strong>
        </div>
        <div className="direction-switcher" role="group" aria-label="设计方向">
          <button className={direction === "studio" ? "active" : ""} onClick={() => onDirection("studio")}>A · 放映工作台</button>
          <button className={direction === "cinema" ? "active" : ""} onClick={() => onDirection("cinema")}>B · 沉浸影院</button>
          <button className={direction === "native" ? "active" : ""} onClick={() => onDirection("native")}>C · 原生工具</button>
        </div>
        <button className={`review-button ${reviewOpen ? "active" : ""}`} onClick={() => onReviewOpen(!reviewOpen)}><Icon name="info" size={16} /> 设计说明</button>
      </div>
      <div className="mac-window">
        <div className="titlebar">
          <div className="traffic-lights"><i></i><i></i><i></i></div>
          <div className="window-title">Wallume</div>
          <div className="titlebar-status"><span className="status-dot"></span> 3 块显示器在线</div>
        </div>
        {children}
      </div>
    </div>
  );
}

function Sidebar({ page, setPage, collapsed, setCollapsed }) {
  const nav = [
    ["library", "画面库", "library"],
    ["displays", "显示器", "display"],
    ["lock", "锁屏同步", "lock"],
    ["status", "运行状态", "pulse"]
  ];
  return (
    <aside className={`sidebar ${collapsed ? "collapsed" : ""}`}>
      <button className="brand" onClick={() => setCollapsed(!collapsed)} aria-label="收起侧边栏">
        <img src="assets/wallume-icon.svg" alt="" />
        {!collapsed && <div><strong>Wallume</strong><span>Private projection</span></div>}
      </button>
      <nav>
        <span className="nav-label">{!collapsed && "放映空间"}</span>
        {nav.map(([id, label, icon]) => (
          <button key={id} className={page === id ? "active" : ""} onClick={() => setPage(id)} title={label}>
            <Icon name={icon} size={18} />{!collapsed && <span>{label}</span>}
            {!collapsed && id === "status" && <i className="live-dot"></i>}
          </button>
        ))}
      </nav>
      <div className="sidebar-spacer"></div>
      <div className="now-playing-mini">
        <span className="live-dot"></span>
        {!collapsed && <div><small>正在放映</small><strong>Silent Orbit</strong></div>}
      </div>
      <button className={page === "settings" ? "sidebar-settings active" : "sidebar-settings"} onClick={() => setPage("settings")} title="设置">
        <Icon name="gear" size={18} />{!collapsed && <span>设置</span>}
      </button>
    </aside>
  );
}

function Topbar({ title, subtitle, search, setSearch, onImport, theme, setTheme }) {
  return (
    <header className="topbar">
      <div className="topbar-title"><h1>{title}</h1><span>{subtitle}</span></div>
      <div className="topbar-actions">
        {setSearch && <label className="search"><Icon name="search" size={16} /><input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="搜索本地画面" /><kbd>⌘K</kbd></label>}
        <button className="icon-button" onClick={() => setTheme(theme === "dark" ? "light" : "dark")} title="切换明暗外观"><Icon name={theme === "dark" ? "sun" : "moon"} size={17} /></button>
        {onImport && <button className="primary-button" onClick={onImport}><Icon name="plus" size={17} />导入</button>}
      </div>
    </header>
  );
}

function MediaVisual({ item, className = "" }) {
  return <div className={`media-visual tone-${item.tone} ${item.atlas ? "atlas-tile" : ""} ${className}`} style={{ backgroundImage: `url(${item.image})`, backgroundPosition: item.position }}></div>;
}

function Pill({ children, tone = "neutral" }) {
  return <span className={`pill pill-${tone}`}>{children}</span>;
}

function Toggle({ value, onChange, label }) {
  return <button className={`toggle ${value ? "on" : ""}`} onClick={() => onChange(!value)} role="switch" aria-checked={value} aria-label={label}><span></span></button>;
}

function ReviewPanel({ open, onClose }) {
  if (!open) return null;
  return (
    <div className="review-panel-backdrop" onMouseDown={onClose}>
      <section className="review-panel" onMouseDown={(e) => e.stopPropagation()}>
        <div className="review-panel-head"><div><span className="eyebrow">DESIGN RATIONALE</span><h2>从“壁纸工具”到“私人放映空间”</h2></div><button className="icon-button" onClick={onClose}>×</button></div>
        <div className="rationale-grid">
          <article><span>01</span><h3>内容优先</h3><p>进入应用立即看到正在使用的画面与显示器，不再先阅读营销式标题。</p></article>
          <article><span>02</span><h3>空间映射</h3><p>把显示器视为放映空间，素材分配与播放状态在同一视觉语言中表达。</p></article>
          <article><span>03</span><h3>系统边界</h3><p>锁屏流程明确区分“Wallume 已准备”和“macOS 已确认”，减少假成功。</p></article>
        </div>
        <div className="direction-notes">
          <div><strong>A · 放映工作台（推荐）</strong><p>内容与工具平衡，适合日常管理；暖色高光只用于当前放映与主操作。</p></div>
          <div><strong>B · 沉浸影院</strong><p>更深的黑色舞台和更大的影像占比，适合素材预览，但信息密度较低。</p></div>
          <div><strong>C · 原生工具</strong><p>更接近 Finder / Photos，学习成本最低，但品牌识别相对克制。</p></div>
        </div>
        <div className="references"><h3>参考来源</h3>{wallumeReferences.map((ref) => <a key={ref.name} href={ref.url} target="_blank" rel="noreferrer"><strong>{ref.name}</strong><span>{ref.role}</span><Icon name="chevron" size={14} /></a>)}</div>
      </section>
    </div>
  );
}

Object.assign(window, { Icon, MacWindow, Sidebar, Topbar, MediaVisual, Pill, Toggle, ReviewPanel });
