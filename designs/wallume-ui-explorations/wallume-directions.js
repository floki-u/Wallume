const body = document.body;
const themeToggle = document.querySelector('.theme-toggle');
const focusToggle = document.querySelector('.focus-toggle');
const dialog = document.querySelector('.focus-dialog');
const focusContent = document.querySelector('.focus-content');
const closeFocus = document.querySelector('.close-focus');

function setTheme(theme) {
  const dark = theme === 'dark';
  body.dataset.theme = theme;
  themeToggle.textContent = dark ? '☀ 浅色主题' : '☾ 深色主题';
  themeToggle.setAttribute('aria-pressed', String(dark));
  localStorage.setItem('wallume-exploration-theme', theme);
}

setTheme(localStorage.getItem('wallume-exploration-theme') || 'light');
themeToggle.addEventListener('click', () => setTheme(body.dataset.theme === 'dark' ? 'light' : 'dark'));

function openFocus(artboard) {
  focusContent.replaceChildren(artboard.cloneNode(true));
  dialog.showModal();
}

document.querySelectorAll('.artboard').forEach((artboard) => {
  artboard.addEventListener('click', () => openFocus(artboard));
  artboard.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      openFocus(artboard);
    }
  });
});

closeFocus.addEventListener('click', () => dialog.close());
dialog.addEventListener('click', (event) => {
  if (event.target === dialog) dialog.close();
});

focusToggle.addEventListener('click', () => {
  const isFocused = body.classList.toggle('focus-mode');
  focusToggle.textContent = isFocused ? '显示全部方案' : '专注查看';
  focusToggle.setAttribute('aria-pressed', String(isFocused));
  if (isFocused) document.querySelector('.concept').classList.add('is-focused');
  else document.querySelectorAll('.concept').forEach((concept) => concept.classList.remove('is-focused'));
});
