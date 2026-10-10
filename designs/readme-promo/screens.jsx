const { useEffect, useMemo, useState } = React;

function LibraryPage({ media, selectedId, setSelectedId, playing, setPlaying, search, setSearch, onImport, theme, setTheme }) {
  const selected = media.find((item) => item.id === selectedId) || media[0];
  const filtered = media.filter((item) => `${item.title}${item.subtitle}`.toLowerCase().includes(search.toLowerCase()));
  return (
    <main className="page library-page" data-screen-label="画面库">
      <Topbar title="画面库" subtitle={`${media.length} 段本地视频 · 不会上传`} search={search} setSearch={setSearch} onImport={onImport} theme={theme} setTheme={setTheme} />
      <div className="page-scroll">
        <section className="projection-stage">
          <MediaVisual item={selected} className="stage-image" />
          <div className="stage-vignette"></div>
          <div className="stage-status"><span className={`status-dot ${playing ? "" : "paused"}`}></span>{playing ? "正在 Studio Display 放映" : "已暂停"}</div>
          <div className="stage-caption">
            <div><span className="eyebrow">NOW PROJECTING</span><h2>{selected.title}</h2><p>{selected.subtitle} · {selected.meta}</p></div>
            <div className="stage-controls">
              <button className="circle-button"><Icon name="more" size={19} /></button>
              <button className="play-button" onClick={() => setPlaying(!playing)}><Icon name={playing ? "pause" : "play"} size={22} /></button>
            </div>
          </div>
        </section>

        <section className="media-section">
          <div className="section-heading"><div><h3>所有画面</h3><span>选择一段画面进行预览或投放</span></div><div className="view-control"><button className="active"><Icon name="library" size={15} /></button><button>≡</button></div></div>
          {filtered.length ? <div className="media-grid">{filtered.map((item, index) => (
            <button key={item.id} className={`media-card ${selectedId === item.id ? "selected" : ""}`} onClick={() => setSelectedId(item.id)} style={{ animationDelay: `${index * 35}ms` }}>
              <div className="media-card-image"><MediaVisual item={item} /><span className="duration">{item.duration}</span>{selectedId === item.id && <span className="selected-check"><Icon name="check" size={13} /></span>}</div>
              <div className="media-card-copy"><strong>{item.title}</strong><span>{item.subtitle}</span></div>
            </button>
          ))}</div> : <div className="empty-state"><Icon name="search" size={26} /><h3>没有匹配的画面</h3><p>换一个关键词，或导入新的视频。</p></div>}
        </section>
      </div>
    </main>
  );
}

function DisplaysPage({ media, displays, setDisplays, selectedId, theme, setTheme }) {
  const selected = media.find((item) => item.id === selectedId) || media[0];
  const [target, setTarget] = useState(null);
  const assign = (displayId, mediaId) => {
    setDisplays((items) => items.map((display) => display.id === displayId ? { ...display, mediaId, state: "正在放映" } : display));
    setTarget(null);
  };
  return (
    <main className="page displays-page" data-screen-label="显示器">
      <Topbar title="显示器" subtitle="每块屏幕都拥有自己的画面" theme={theme} setTheme={setTheme} />
      <div className="page-scroll displays-layout">
        <section className="room-overview">
          <div className="room-heading"><div><span className="eyebrow">YOUR SPACE</span><h2>当前空间</h2></div><Pill tone="success"><span className="status-dot"></span>全部在线</Pill></div>
          <div className="display-map">
            {displays.map((display, index) => {
              const item = media.find((m) => m.id === display.mediaId) || media[0];
              return <button key={display.id} className={`monitor-card monitor-${index + 1}`} onClick={() => setTarget(display.id)}>
                <div className="monitor-bezel"><MediaVisual item={item} /><span className="monitor-state"><i className={display.state === "已暂停" ? "paused" : ""}></i>{display.state}</span></div>
                <div className="monitor-stand"></div>
                <strong>{display.name}</strong><span>{display.detail}{display.main ? " · 主显示器" : ""}</span>
              </button>;
            })}
          </div>
          <div className="space-tip"><Icon name="spark" size={17} /><span>选择一块显示器即可更换画面。拔插或唤醒后，Wallume 会恢复这套配置。</span></div>
        </section>
        <aside className="assignment-rail">
          <span className="eyebrow">QUICK ASSIGN</span><h3>快速投放</h3><p>当前选中：<strong>{selected.title}</strong></p>
          <MediaVisual item={selected} className="assign-preview" />
          <div className="assign-list">{displays.map((display) => <button key={display.id} onClick={() => assign(display.id, selected.id)}><Icon name="monitor" size={17} /><span><strong>{display.name}</strong><small>{display.main ? "主显示器" : display.detail}</small></span><Icon name="chevron" size={15} /></button>)}</div>
        </aside>
      </div>
      {target && <div className="modal-backdrop" onMouseDown={() => setTarget(null)}><section className="picker-modal" onMouseDown={(e) => e.stopPropagation()}><div className="modal-head"><div><span className="eyebrow">CHANGE PROJECTION</span><h2>为 {displays.find((d) => d.id === target)?.name} 选择画面</h2></div><button className="icon-button" onClick={() => setTarget(null)}>×</button></div><div className="picker-grid">{media.map((item) => <button key={item.id} onClick={() => assign(target, item.id)}><MediaVisual item={item} /><strong>{item.title}</strong><span>{item.subtitle}</span></button>)}</div></section></div>}
    </main>
  );
}

function LockPage({ selected, theme, setTheme, demoStep }) {
  const [storedStep, setStep] = useState(1);
  const step = demoStep ?? storedStep;
  const steps = ["准备素材", "系统确认", "状态核验"];
  const flowIndex = demoStep === 2 ? 1 : step;
  return (
    <main className="page lock-page" data-screen-label="锁屏同步">
      <Topbar title="锁屏同步" subtitle="把当前画面交给 macOS，并保留最后确认权" theme={theme} setTheme={setTheme} />
      <div className="page-scroll lock-layout">
        <section className="lock-preview">
          <MediaVisual item={selected} className="lock-preview-image" />
          <div className="lock-screen-clock"><span>9:41</span><small>9月23日 星期三</small></div>
          <div className="lock-preview-label"><Icon name="lock" size={15} />锁屏预览</div>
        </section>
        <section className="sync-workflow">
          <span className="eyebrow">MACOS HANDOFF</span><h2>三步完成锁屏同步</h2><p>Wallume 只准备素材，最终选择始终在“系统设置 → 墙纸”中完成。</p>
          <div className="stepper">{steps.map((label, index) => <div key={label} className={flowIndex > index ? "done" : flowIndex === index ? "current" : ""}><span>{flowIndex > index ? <Icon name="check" size={14} /> : index + 1}</span><div><strong>{label}</strong><small>{index === 0 ? "创建系统专用副本" : index === 1 ? "在系统设置中选择 Wallume" : "读取系统实际选择状态"}</small></div></div>)}</div>
          <div className="sync-status"><div><span className={`status-dot ${step === 3 ? "" : "amber"}`}></span><strong>{step === 0 ? "等待准备" : step === 1 ? "素材已准备" : step === 2 ? "等待系统选择" : "锁屏已启用"}</strong></div><p>{step < 3 ? "不会覆盖原始视频，也不会在未确认时清理系统副本。" : `当前锁屏：${selected.title}`}</p></div>
          <button className="primary-button wide" onClick={() => setStep((value) => value >= 3 ? 0 : value + 1)}>{step === 0 ? "准备当前画面" : step === 1 ? "打开系统墙纸设置" : step === 2 ? "我已选择，重新检查" : "重新配置"}<Icon name="chevron" size={16} /></button>
        </section>
      </div>
    </main>
  );
}


Object.assign(window, { LibraryPage, DisplaysPage, LockPage });
