const dictionaries = {
  zh: {
    'nav.library':'画面库','nav.screens':'显示器','nav.lock':'锁屏同步','nav.status':'状态','theme.label':'夜幕','import':'导入画面',
    'library.kicker':'01 / 本地画面库','library.title':'选一段画面，<br>留住此刻的空间。','library.lede':'6 段本地素材，未上传任何内容。点击画面即可预览，并将它投放到指定显示器。','library.preview':'预览 Studio Tide','library.collection':'管理收藏集 →','library.nowPlaying':'正在主显示器播放','library.assign':'投放到屏幕','library.local':'本地画面','filter.all':'全部','filter.active':'正在使用','filter.favorites':'收藏',
    'screens.kicker':'02 / 显示器','screens.title':'两块屏幕，<br>两种气氛。','screens.lede':'每块显示器独立播放；更改任意画面不会影响另一块屏幕。','screens.primary':'主显示器','screens.external':'外接显示器','screens.fill':'填充 · 静音 · 正在播放','screens.fit':'适应 · 静音 · 正在播放','screens.change':'更换画面','screens.playback':'播放控制','screens.playbackDetail':'暂停会保留每块屏幕当前的画面与设置。','screens.pause':'暂停全部',
    'lock.kicker':'03 / 锁屏同步','lock.title':'让画面<br>自然延续。','lock.preview':'锁屏预览','lock.ready':'已准备同步','lock.readyDetail':'Studio Tide 可安全提供给系统锁屏。','lock.lede':'Wallume 仅会写入你确认的专属资源槽，并保留可验证的恢复锚点。','lock.sync':'同步到锁屏','lock.safety':'查看安全说明 →',
    'status.kicker':'04 / 运行状态','status.title':'安静地，<br>保持运行。','status.lede':'实时数据只留在内存中；诊断报告只在你手动导出时落盘。','status.realtime':'实时采样','status.displays':'块显示器活动','status.cpu':'当前 CPU','status.memory':'常驻内存','status.diagnostic':'运行 30 秒诊断',
    'theme.kicker':'外观','theme.title':'选择放映氛围','theme.lede':'主题会保存到这台 Mac；默认跟随夜幕。','theme.nocturne':'夜幕','theme.nocturneDetail':'深黑幕布与暖金','theme.dawn':'晨雾','theme.dawnDetail':'柔白与青蓝','theme.ember':'余烬','theme.emberDetail':'深褐与橘红','theme.system':'跟随系统','theme.systemDetail':'自动适配 macOS','search.go':'前往','search.action':'操作'
  },
  en: {
    'nav.library':'Library','nav.screens':'Screens','nav.lock':'Lock Screen','nav.status':'Status','theme.label':'Nocturne','import':'Import',
    'library.kicker':'01 / LOCAL LIBRARY','library.title':'Choose a scene,<br>keep the moment.','library.lede':'Six local scenes. Nothing is uploaded. Preview a scene, then project it to a chosen screen.','library.preview':'Preview Studio Tide','library.collection':'Manage collections →','library.nowPlaying':'Playing on main display','library.assign':'Project to screen','library.local':'LOCAL SCENES','filter.all':'All','filter.active':'In use','filter.favorites':'Favorites',
    'screens.kicker':'02 / SCREENS','screens.title':'Two screens,<br>two moods.','screens.lede':'Each display plays independently. Changing one never affects the other.','screens.primary':'MAIN DISPLAY','screens.external':'EXTERNAL DISPLAY','screens.fill':'Fill · muted · playing','screens.fit':'Fit · muted · playing','screens.change':'Change scene','screens.playback':'Playback control','screens.playbackDetail':'Pausing keeps every screen’s current scene and settings.','screens.pause':'Pause all',
    'lock.kicker':'03 / LOCK SCREEN','lock.title':'Let the scene<br>continue.','lock.preview':'LOCK SCREEN PREVIEW','lock.ready':'Ready to sync','lock.readyDetail':'Studio Tide can safely serve the system lock screen.','lock.lede':'Wallume writes only to your confirmed dedicated slot and keeps a verified recovery anchor.','lock.sync':'Sync to lock screen','lock.safety':'View safety notes →',
    'status.kicker':'04 / STATUS','status.title':'Quietly,<br>running.','status.lede':'Live data stays in memory. A report is only written when you export it.','status.realtime':'LIVE SAMPLE','status.displays':'active displays','status.cpu':'CPU right now','status.memory':'resident memory','status.diagnostic':'Run 30-second check',
    'theme.kicker':'APPEARANCE','theme.title':'Choose a screening mood','theme.lede':'The selection stays on this Mac. Nocturne is the default.','theme.nocturne':'Nocturne','theme.nocturneDetail':'Black screen & warm gold','theme.dawn':'Dawn','theme.dawnDetail':'Soft white & teal','theme.ember':'Ember','theme.emberDetail':'Deep umber & orange','theme.system':'System','theme.systemDetail':'Follows macOS automatically','search.go':'GO TO','search.action':'ACTIONS'
  }
};
const app = document.getElementById('app');
const body = document.body;
const toast = document.getElementById('toast');
let language = localStorage.getItem('wallume-prototype-language') || 'zh';
let activeTheme = localStorage.getItem('wallume-prototype-theme') || 'nocturne';
let toastTimer;

function say(key, fallback) { return dictionaries[language][key] || fallback || key; }
function showToast(message) { toast.textContent = message; toast.classList.add('show'); clearTimeout(toastTimer); toastTimer = setTimeout(() => toast.classList.remove('show'), 2600); }
function setLanguage(next) {
  language = next; body.dataset.language = next; document.documentElement.lang = next === 'zh' ? 'zh-CN' : 'en';
  document.querySelectorAll('[data-i18n]').forEach((node) => { node.textContent = say(node.dataset.i18n, node.textContent); });
  document.querySelectorAll('[data-i18n-html]').forEach((node) => { node.innerHTML = say(node.dataset.i18nHtml, node.innerHTML); });
  document.getElementById('languageButton').textContent = next === 'zh' ? 'EN' : '中文';
  document.getElementById('searchInput').placeholder = next === 'zh' ? '搜索画面、显示器或操作…' : 'Search scenes, screens or actions…';
  localStorage.setItem('wallume-prototype-language', next);
}
function setTheme(next) {
  activeTheme = next;
  const resolved = next === 'system' ? (matchMedia('(prefers-color-scheme: dark)').matches ? 'nocturne' : 'dawn') : next;
  body.dataset.theme = resolved;
  document.querySelectorAll('.theme-option').forEach((button) => button.classList.toggle('selected', button.dataset.themeChoice === next));
  const labels = {nocturne:'theme.nocturne',dawn:'theme.dawn',ember:'theme.ember',system:'theme.system'};
  document.querySelector('#themeButton [data-i18n="theme.label"]').textContent = say(labels[next]);
  localStorage.setItem('wallume-prototype-theme', next);
}
function route(next) {
  document.querySelectorAll('.view').forEach((view) => view.classList.toggle('active', view.dataset.view === next));
  document.querySelectorAll('[data-route]').forEach((button) => button.classList.toggle('active', button.dataset.route === next && button.classList.contains('nav-link')));
  document.querySelectorAll('.modal').forEach((modal) => modal.classList.remove('open'));
  window.scrollTo({top:0,behavior:'smooth'});
}
function openModal(id) { document.getElementById(id).classList.add('open'); document.getElementById(id).setAttribute('aria-hidden','false'); }
function closeModal(id) { document.getElementById(id).classList.remove('open'); document.getElementById(id).setAttribute('aria-hidden','true'); }

setLanguage(language); setTheme(activeTheme);
document.getElementById('languageButton').addEventListener('click', () => setLanguage(language === 'zh' ? 'en' : 'zh'));
document.getElementById('themeButton').addEventListener('click', () => openModal('themeModal'));
document.getElementById('searchButton').addEventListener('click', () => { openModal('searchModal'); setTimeout(() => document.getElementById('searchInput').focus(), 0); });
document.getElementById('importButton').addEventListener('click', () => showToast(language === 'zh' ? '已打开导入面板（原型示意）' : 'Import panel opened (prototype)'));
document.getElementById('previewButton').addEventListener('click', () => showToast(language === 'zh' ? '正在预览 Studio Tide' : 'Previewing Studio Tide'));
document.getElementById('collectionButton').addEventListener('click', () => showToast(language === 'zh' ? '收藏集将在下一步提供' : 'Collections are coming next'));
document.getElementById('syncButton').addEventListener('click', () => showToast(language === 'zh' ? '同步任务已开始；完成后将重新验证。' : 'Sync started; it will be verified when complete.'));
document.getElementById('safetyButton').addEventListener('click', () => showToast(language === 'zh' ? '恢复锚点与专属资源槽均已就绪。' : 'Recovery anchor and dedicated slot are ready.'));
document.getElementById('diagnosticButton').addEventListener('click', () => showToast(language === 'zh' ? '正在采样：0 / 30 秒' : 'Sampling: 0 / 30 seconds'));
document.getElementById('pauseAll').addEventListener('click', (event) => { const paused = event.currentTarget.dataset.paused === 'true'; event.currentTarget.dataset.paused = String(!paused); event.currentTarget.textContent = paused ? say('screens.pause') : (language === 'zh' ? '继续全部' : 'Resume all'); showToast(paused ? (language === 'zh' ? '已恢复播放' : 'Playback resumed') : (language === 'zh' ? '已暂停全部显示器' : 'All displays paused')); });
document.querySelectorAll('[data-route]').forEach((button) => button.addEventListener('click', () => route(button.dataset.route)));
document.querySelectorAll('[data-close]').forEach((button) => button.addEventListener('click', () => closeModal(button.dataset.close)));
document.querySelectorAll('.theme-option').forEach((button) => button.addEventListener('click', () => { setTheme(button.dataset.themeChoice); closeModal('themeModal'); }));
document.getElementById('commandImport').addEventListener('click', () => { closeModal('searchModal'); showToast(language === 'zh' ? '已打开导入面板（原型示意）' : 'Import panel opened (prototype)'); });
document.getElementById('commandSync').addEventListener('click', () => { closeModal('searchModal'); route('lock'); });
document.querySelectorAll('.modal').forEach((modal) => modal.addEventListener('click', (event) => { if (event.target === modal) closeModal(modal.id); }));
document.addEventListener('keydown', (event) => { if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); openModal('searchModal'); } if (event.key === 'Escape') document.querySelectorAll('.modal.open').forEach((modal) => closeModal(modal.id)); });
