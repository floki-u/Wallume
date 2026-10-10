const MOTION = {
  enter: (t, start, end) => animate({from:0,to:1,start,end,ease:Easing.easeInOutCubic})(t),
  draw: (t, start, end) => animate({from:0,to:1,start,end,ease:Easing.easeOutCubic})(t),
  pop: (t, start, end) => animate({from:0,to:1,start,end,ease:Easing.easeOutQuad})(t)
};
const noop = () => {};

function BrowseShot({selectedId}) {
  return <LibraryPage media={wallumeMedia} selectedId={selectedId} setSelectedId={noop} playing={true} setPlaying={noop} search="" setSearch={noop} onImport={noop} theme="dark" setTheme={noop} />;
}
function AssignShot({assigned,selectedId}) {
  const displays = wallumeDisplays.map((display,index) => ({...display,mediaId:index === 0 && assigned ? "last-train" : display.mediaId}));
  return <DisplaysPage media={wallumeMedia} displays={displays} setDisplays={noop} selectedId={selectedId} theme="dark" setTheme={noop} />;
}
function HandoffShot({waiting}) {
  return <LockPage selected={wallumeMedia[1]} demoStep={waiting ? 2 : 1} theme="dark" setTheme={noop} />;
}

function ProductPiece() {
  const {T,CUES,authoredTotal} = useComposition();
  const root = React.useRef(null);
  const [points,setPoints] = React.useState(null);
  const selectors = ['.library-page .media-card:nth-child(2)', '.sidebar nav button[title="显示器"]', '.displays-page .assign-list button:nth-child(1)', '.sidebar nav button[title="锁屏同步"]', '.lock-page .primary-button.wide'];
  React.useLayoutEffect(() => {
    const bounds = root.current.getBoundingClientRect();
    setPoints(selectors.map(selector => {
      const target = root.current.querySelector(selector).getBoundingClientRect();
      return [(target.left+target.width/2-bounds.left)*1600/bounds.width,(target.top+target.height/2-bounds.top)*1100/bounds.height];
    }));
  },[]);
  const browseEnd = CUES.Assign;
  const assignEnd = CUES.Handoff;
  const handoffEnd = CUES.Return;
  const page = T < browseEnd || T >= handoffEnd ? 'library' : T < assignEnd ? 'displays' : 'lock';
  const selectedId = T < CUES.Browse+1.65 || T >= handoffEnd ? 'silent-orbit' : 'last-train';
  const times = [CUES.Browse+1.65,CUES.Assign-.15,CUES.Assign+2.3,CUES.Handoff-.15,CUES.Handoff+1.65];
  let pointer = points ? points[0] : [1280,730];
  if(points) {
    for(let i=0;i<times.length-1;i++) {
      if(T >= times[i]) {
        const movement = MOTION.draw(T,times[i]+.35,times[i+1]-.05);
        pointer = [points[i][0]+(points[i+1][0]-points[i][0])*movement,points[i][1]+(points[i+1][1]-points[i][1])*movement];
      }
    }
  }
  const visible = MOTION.enter(T,CUES.Browse+.4,CUES.Browse+.7)*(1-MOTION.enter(T,CUES.Handoff+2.2,CUES.Handoff+2.7));
  let click = 0;
  for(const time of times) if(T >= time && T < time+.42) click = 1-MOTION.pop(T,time,time+.42);
  const zoom = 1+.018*MOTION.enter(T,CUES.Assign+.25,CUES.Assign+1)*(1-MOTION.enter(T,CUES.Return-.7,CUES.Return));
  return <div className={`promo-piece ${new URLSearchParams(location.search).has('poster') ? 'poster' : ''}`} ref={root} data-screen-label={`Wallume 模拟操作演示 · ${T.toFixed(1)}s`}>
    <div className="promo-brand"><img src="assets/wallume-icon.svg" alt="" /><span>Wallume</span></div>
    <div className="promo-kicker">LOCAL WALLPAPERS · macOS</div>
    <h1>让桌面，有自己的画面。</h1>
    <p className="promo-subtitle">本地图片与视频 · 每块屏幕独立选择 · 锁屏由你确认</p>
    <div className="promo-window" style={{transform:`scale(${zoom})`}}>
      <MacWindow direction="cinema" onDirection={noop} reviewOpen={false} onReviewOpen={noop}>
        <div className="app-body">
          <Sidebar page={page} setPage={noop} collapsed={true} setCollapsed={noop} />
          <div className="page-host">
            <Shot from={CUES.Browse} to={browseEnd}><BrowseShot selectedId={selectedId} /></Shot>
            <Shot from={CUES.Assign} to={assignEnd}><AssignShot assigned={T >= CUES.Assign+2.3} selectedId={selectedId} /></Shot>
            <Shot from={CUES.Handoff} to={handoffEnd}><HandoffShot waiting={T >= CUES.Handoff+1.65} /></Shot>
            <Shot from={CUES.Return} to={authoredTotal+.01}><BrowseShot selectedId="silent-orbit" /></Shot>
          </div>
        </div>
      </MacWindow>
    </div>
    <div className="promo-label">界面模拟演示</div>
    <div className="promo-local">素材保存在本机</div>
    <Captions style={{color:'#34312b',font:'500 24px -apple-system, PingFang SC, sans-serif',textShadow:'none',bottom:'31px'}} items={[
      {at:CUES.Browse-.2,until:browseEnd-.1,text:'01  浏览素材，选择喜欢的画面'},
      {at:CUES.Assign,until:assignEnd-.1,text:'02  为每块显示器分别选择画面'},
      {at:CUES.Handoff,until:handoffEnd-.1,text:'03  锁屏素材准备后，在系统设置中确认'},
      {at:CUES.Return,until:authoredTotal+.1,text:'01  浏览素材，选择喜欢的画面'}
    ]} />
    <div className="promo-cursor" style={{left:pointer[0],top:pointer[1],opacity:visible}}>
      <svg viewBox="0 0 28 36"><path d="M3 2L3 27L10 21L16 33L21 30L15 19L24 19Z" fill="white" stroke="#282824" strokeWidth="2" strokeLinejoin="round" /></svg>
    </div>
    <div className="promo-click" style={{left:pointer[0]-24,top:pointer[1]-24,opacity:click*.6,transform:`scale(${1.5-click*.6})`}}></div>
  </div>;
}

function PromoApp() {
  const [tweaks,setTweak] = useTweaks(window.TWEAK_DEFAULTS);
  const capture = new URLSearchParams(location.search).has('capture');
  React.useEffect(() => {
    if(capture) document.querySelector('[data-om-exportable-video-with-duration-secs]').dispatchEvent(new CustomEvent('data-om-seek-to-time-frame',{detail:{time:0}}));
  },[capture]);
  return <React.Fragment>
    <CompositionStage width={1600} height={1100} scenes={window.OM_SCENES} playback={window.OM_PLAYBACK} bg="#f3f0e9" autoplay={!capture}><ProductPiece /></CompositionStage>
    {capture && <input className="capture-control" aria-label="演示时间" type="number" min="0" max="14" step="0.01" defaultValue="0" onChange={e => {
      document.querySelector('[data-om-exportable-video-with-duration-secs]').dispatchEvent(new CustomEvent('data-om-seek-to-time-frame',{detail:{time:Number(e.target.value),sync:true}}));
    }} />}
    {!capture && <TweaksPanel title="演示设置"><TweakToggle label="Motion editor" value={tweaks.motionEditor} onChange={v => setTweak('motionEditor',v)} /></TweaksPanel>}
  </React.Fragment>;
}
ReactDOM.createRoot(document.getElementById('root')).render(<PromoApp />);
