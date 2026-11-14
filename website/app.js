import { selectDownloads, detectOS, fetchReleases } from './releases.mjs';

const copy = {
  en: { headline1:'More agents.', headline2:'One Pad.', intro:'Your agents work across machines. Keep your attention in one place.', recommendation:'Recommended: an Omarchy tablet.', download:'Download for', choose:'Choose your download', macos:'macOS', linux:'Omarchy / Arch', windows:'Windows', apple:'Apple silicon', linuxArch:'x86_64', unavailable:'No build yet', all:'All releases ↗', relayTitle:'Your relay. Your rules.', e2e:'End-to-end encrypted. Your relay only sees ciphertext.', relayNote:'rapp 0.6+ on both devices · Open UDP 22026 · Save the key printed at install', script:'View script ↗', releases:'Releases ↗', theme:'Theme', copied:'Copied', copy:'Copy install command', legacy:'Linux v0.5.2 uses legacy connections. The E2E relay requires rapp 0.6+ on both devices.', cached:'Saved release list', unsupported:'Choose a supported platform below.' },
  ja: { headline1:'エージェントが増えても。', headline2:'One Pad.', intro:'エージェントは複数のマシンで。あなたの集中は、ひとつの場所に。', recommendation:'おすすめ：Omarchy 搭載のタブレット。', download:'ダウンロード：', choose:'ダウンロードを選択', macos:'macOS', linux:'Omarchy / Arch', windows:'Windows', apple:'Apple シリコン', linuxArch:'x86_64', unavailable:'未提供', all:'すべてのリリース ↗', relayTitle:'自分の中継サーバーを、自由に。', e2e:'エンドツーエンド暗号化。中継サーバーが扱うのは暗号文だけ。', relayNote:'両端に rapp 0.6 以降が必要 · UDP 22026 を開放 · インストール時のキーを保存', script:'スクリプト ↗', releases:'リリース ↗', theme:'テーマ', copied:'コピーしました', copy:'インストールコマンドをコピー', legacy:'Linux v0.5.2 は旧接続方式です。E2E 中継には両端で rapp 0.6 以降が必要です。', cached:'保存済みリリース一覧', unsupported:'下から対応プラットフォームを選択してください。' },
  zh: { headline1:'更多 Agent。', headline2:'一个 Pad。', intro:'Agent 分布在不同机器，你的注意力，留在一处。', recommendation:'推荐使用 Omarchy 平板电脑。', download:'下载', choose:'选择下载版本', macos:'macOS', linux:'Omarchy / Arch', windows:'Windows', apple:'Apple 芯片', linuxArch:'x86_64', unavailable:'暂未提供', all:'全部版本 ↗', relayTitle:'自己的中继，自己掌握。', e2e:'端到端加密，中继只转发密文。', relayNote:'两端均需 rapp 0.6+ · 开放 UDP 22026 · 保存安装时显示的 key', script:'查看脚本 ↗', releases:'发布记录 ↗', theme:'主题', copied:'已复制', copy:'复制安装命令', legacy:'Linux v0.5.2 使用旧连接方式；E2E 新中继需要两端均为 rapp 0.6+。', cached:'已保存的版本列表', unsupported:'请从下方选择支持的平台。' },
};
const sceneCopy = {
  en: { sceneTitle:'A command pad for your agents', sceneDescription:'Terminal runs on cloud Linux and Claude on a remote Mac. View and control both in One Pad on Omarchy. A note labeled Context sits beside the sessions.', sceneCloud:'LINUX IN THE CLOUD', sceneMac2:'MAC AT WORK', sceneHere:'OMARCHY', sceneCloudTab:'cloud', sceneWork:'work', sceneInput:'Reply from here…', sceneCaption:'A command pad for your agents.' },
  ja: { sceneTitle:'エージェントを操作する、一枚のパッド', sceneDescription:'クラウドの Linux で動く Terminal と、別の Mac で動く Claude を、Omarchy の One Pad で表示し、操作できます。セッションの横には Context と書かれたメモがあります。', sceneCloud:'クラウド LINUX', sceneMac2:'職場の MAC', sceneHere:'OMARCHY', sceneCloudTab:'クラウド', sceneWork:'職場', sceneInput:'ここから返信…', sceneCaption:'エージェントを操作する、一枚のパッド。' },
  zh: { sceneTitle:'你的 Agent 指挥台', sceneDescription:'Terminal 在云端 Linux 上运行，Claude 在远程 Mac 上运行。在 Omarchy 的 One Pad 中查看和操作这两个会话。会话旁有一张写着 Context 的便签。', sceneCloud:'云端 LINUX', sceneMac2:'办公室的 MAC', sceneHere:'OMARCHY', sceneCloudTab:'云端', sceneWork:'办公室', sceneInput:'在这里回复…', sceneCaption:'你的 Agent 指挥台。' },
};
for (const language of Object.keys(copy)) Object.assign(copy[language], sceneCopy[language]);
const params = new URLSearchParams(location.search);
let language = Object.hasOwn(copy, params.get('lang')) ? params.get('lang') : 'en';
let downloads = {};
let cached = false;
let selectedOS = detectOS(navigator.userAgent, navigator.userAgentData?.platform);
if (navigator.maxTouchPoints > 1 && /Macintosh/.test(navigator.userAgent)) selectedOS = null;
const $ = s => document.querySelector(s);

function render() {
  const t = copy[language];
  document.documentElement.lang = language === 'zh' ? 'zh-Hans' : language;
  document.title = `rapp — ${t.headline1} ${t.headline2}`;
  document.querySelector('meta[name=description]').content = t.intro;
  document.querySelectorAll('[data-i18n]').forEach(el => el.textContent = t[el.dataset.i18n]);
  document.querySelectorAll('[data-language]').forEach(el => {
    if (el.dataset.language === language) el.setAttribute('aria-current', 'page');
    else el.removeAttribute('aria-current');
  });
  $('#theme').setAttribute('aria-label', t.theme);
  $('#copy').setAttribute('aria-label', t.copy);
  $('#copy-label').textContent = t.copy;
  const os = selectedOS;
  const asset = downloads[os];
  $('#download-label').textContent = asset ? `${t.download} ${t[os]}` : t.choose;
  $('#download').href = asset?.browser_download_url ?? 'https://github.com/wizlijun/rapp/releases';
  $('#download-meta').textContent = asset ? `${asset.version} · ${os === 'macos' ? t.apple : t.linuxArch} · ${(asset.size / 1e6).toFixed(1)} MB${cached ? ` · ${t.cached}` : ''}` : t.unsupported;
  $('#platforms').replaceChildren();
  for (const name of ['macos', 'linux', 'windows']) {
    const available = downloads[name];
    const el = document.createElement(available ? 'a' : 'span');
    if (available) {
      el.href = available.browser_download_url;
      el.textContent = `${t[name]} ${available.version} ↗`;
      el.addEventListener('click', event => { if (event.shiftKey) return; selectedOS = name; });
      el.title = `${t[name]} · ${name === 'macos' ? t.apple : t.linuxArch}`;
    } else { el.className = 'unavailable'; el.textContent = `${t[name]} — ${t.unavailable}`; }
    $('#platforms').append(el);
  }
  const note = $('#compatibility');
  note.hidden = !(downloads.linux && /^v?0\.[0-5]\./.test(downloads.linux.version));
  note.textContent = t.legacy;
}
document.querySelectorAll('[data-language]').forEach(el => el.addEventListener('click', event => {
  event.preventDefault(); language = el.dataset.language;
  const url = new URL(location.href); url.searchParams.set('lang', language);
  history.replaceState(null, '', url); render();
}));
$('#theme').addEventListener('change', event => document.documentElement.dataset.theme = event.target.value);
$('#copy').addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText($('#install-command').textContent);
    $('#copy').setAttribute('aria-label', copy[language].copied);
    $('#copy').innerHTML = '<span aria-live="polite">✓</span>';
    setTimeout(() => { $('#copy').innerHTML = '<svg aria-hidden="true" viewBox="0 0 20 20"><rect x="7" y="6" width="9" height="11" rx="1"/><path d="M12 6V3H3v11h4"/></svg>'; $('#copy').setAttribute('aria-label', copy[language].copy); }, 1800);
  } catch { const range = document.createRange(); range.selectNodeContents($('#install-command')); getSelection().removeAllRanges(); getSelection().addRange(range); }
});
render();
try { const response = await fetch('./releases.json'); if (response.ok) { downloads = selectDownloads(await response.json()); cached = true; render(); } } catch {}
try { downloads = selectDownloads(await fetchReleases()); cached = false; render(); } catch { /* Keep the last verified per-platform links. */ }
