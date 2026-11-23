'use strict';

/*
 * PID Checker web UI.
 * Loaded synchronously from <head> so the theme is applied before first paint;
 * everything else waits for DOMContentLoaded. No inline scripts/styles (strict CSP).
 */
(() => {
  const THEME_KEY = 'pkc.theme';
  const TOKEN_KEY = 'pkc.token';
  const REMEMBER_KEY = 'pkc.remember';
  const REQUEST_TIMEOUT_MS = 120000;
  const HEALTH_INTERVAL_MS = 30000;

  // localStorage may be unavailable (private mode, blocked site data): never throw.
  const store = {
    get(key) { try { return window.localStorage.getItem(key); } catch { return null; } },
    set(key, value) { try { window.localStorage.setItem(key, value); } catch { /* ignore */ } },
    remove(key) { try { window.localStorage.removeItem(key); } catch { /* ignore */ } },
  };

  // ---------------------------------------------------------------- theme
  const systemLight = window.matchMedia ? window.matchMedia('(prefers-color-scheme: light)') : null;
  const storedTheme = () => { const t = store.get(THEME_KEY); return t === 'light' || t === 'dark' ? t : null; };
  const resolvedTheme = () => storedTheme() || (systemLight && systemLight.matches ? 'light' : 'dark');

  function applyTheme(theme) {
    document.documentElement.dataset.theme = theme;
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', theme === 'light' ? '#f3f6fb' : '#080d17');
    const toggle = document.getElementById('theme-toggle');
    if (toggle) toggle.setAttribute('aria-label', theme === 'light' ? '切换到暗色主题' : '切换到亮色主题');
  }
  applyTheme(resolvedTheme());
  if (systemLight) {
    const onSystemChange = () => { if (!storedTheme()) applyTheme(resolvedTheme()); };
    if (systemLight.addEventListener) systemLight.addEventListener('change', onSystemChange);
    else if (systemLight.addListener) systemLight.addListener(onSystemChange);
  }

  // ---------------------------------------------------------------- helpers
  const STATUS_LABELS = {
    valid: '有效', invalid_format: '格式错误', invalid_checksum: '校验失败',
    unknown_product: '未识别', revoked_range: '已撤销', unsupported: '不支持', invalid: '无效',
  };
  const KEY_PATTERN = /(?<![A-Z0-9])(?:[A-Z0-9]{5}-){4}[A-Z0-9]{5}(?![A-Z0-9])/g;

  function batchKeys(text) {
    const upper = text.toUpperCase();
    const dashed = upper.match(KEY_PATTERN) || [];
    const compact = upper.split(/\r?\n/).map((line) => line.trim())
      .filter((line) => /^[A-Z0-9]{25}$/.test(line))
      .map((line) => line.match(/.{5}/g).join('-'));
    return [...new Set([...dashed, ...compact])];
  }

  function el(tag, text, className) {
    const node = document.createElement(tag);
    if (text != null && text !== '') node.textContent = text;
    if (className) node.className = className;
    return node;
  }

  function timeoutSignal(ms) {
    if (window.AbortSignal && typeof AbortSignal.timeout === 'function') return AbortSignal.timeout(ms);
    const controller = new AbortController();
    setTimeout(() => controller.abort(), ms);
    return controller.signal;
  }

  const fmt = (n) => (typeof n === 'number' ? n.toLocaleString('zh-CN') : String(n));

  function httpMessage(status, body) {
    const detail = body && typeof body.error === 'string' ? body.error : '';
    if (status === 401) return 'API 密钥缺失、无效或已过期，请在「服务设置」中检查。';
    if (status === 403) return 'API 密钥权限不足。';
    if (status === 413) return detail || '提交的数据过大，请减少密钥数量后重试。';
    if (status === 429) {
      const wait = body && body.retry_after_secs;
      return wait ? `请求过于频繁，请在 ${wait} 秒后重试。` : '请求过于频繁，请稍后再试。';
    }
    if (status === 404) return '接口不存在（HTTP 404），请确认服务地址与版本。';
    if (status >= 502 && status <= 504) return `网关无法连接检测服务（HTTP ${status}），请稍后重试。`;
    if (status >= 500) return '服务器内部错误，请稍后重试。';
    return detail || `请求失败（HTTP ${status}）。`;
  }

  /** fetch + robust JSON handling (proxies may answer with HTML error pages). */
  async function request(path, options = {}) {
    const response = await fetch(`/api/v1${path}`, { cache: 'no-store', credentials: 'same-origin', ...options });
    const text = await response.text();
    let body = null;
    if (text) {
      try { body = JSON.parse(text); } catch { body = null; }
    }
    if (!response.ok) {
      const error = new Error(httpMessage(response.status, body));
      error.status = response.status;
      throw error;
    }
    if (!body || typeof body !== 'object') {
      const error = new Error('服务器返回了无法识别的响应（可能是反向代理或网关的错误页面）。');
      error.status = response.status;
      throw error;
    }
    return body;
  }

  function csvCell(value) {
    let s = value == null ? '' : String(value);
    if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`; // spreadsheet formula injection guard
    return /[",\r\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  }
  const tsvCell = (value) => (value == null ? '' : String(value)).replace(/[\t\r\n]+/g, ' ');

  async function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      try { await navigator.clipboard.writeText(text); return true; } catch { /* fall back */ }
    }
    // Plain-HTTP deployments (http://ip:8675) have no async clipboard API.
    const area = document.createElement('textarea');
    area.value = text;
    area.setAttribute('readonly', '');
    area.className = 'clipboard-proxy';
    document.body.append(area);
    area.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch { ok = false; }
    area.remove();
    return ok;
  }

  // ---------------------------------------------------------------- app
  function init() {
    const $ = (id) => document.getElementById(id);
    const form = $('check-form');
    const input = $('keys');
    const token = $('token');
    const remember = $('remember');
    const online = $('online');
    const submit = $('submit');
    const cancel = $('cancel');
    const reports = $('reports');
    const resultsPanel = $('results');
    const modes = [...document.querySelectorAll('[data-mode]')];
    const filters = [...document.querySelectorAll('[data-filter]')];
    const isMac = /Mac|iPhone|iPad|iPod/i.test(navigator.platform || navigator.userAgent || '');

    const state = {
      mode: 'single', service: null, busy: false, controller: null,
      results: [], filter: 'all', started: 0, tick: null, connecting: false,
      noticeKind: '', toastTimer: null,
    };

    applyTheme(resolvedTheme());
    $('kbd-hint').textContent = isMac ? '⌘ ↵' : 'Ctrl ↵';
    submit.title = `开始检测（${isMac ? '⌘' : 'Ctrl'} + Enter）`;

    // ---- notices
    function setNotice(message, { kind = 'error', retry = false } = {}) {
      $('notice-text').textContent = message || '';
      $('notice-retry').hidden = !retry;
      $('notice').hidden = !message;
      state.noticeKind = message ? kind : '';
      if (message) $('info').hidden = true;
    }
    function setInfo(message) {
      $('info').textContent = message || '';
      $('info').hidden = !message;
    }
    function clearMessages() { setNotice(''); setInfo(''); }

    function toast(message) {
      const node = $('toast');
      node.textContent = message;
      node.hidden = false;
      clearTimeout(state.toastTimer);
      state.toastTimer = setTimeout(() => { node.hidden = true; }, 2200);
    }

    function setStatus(kind, text) {
      $('server-status').dataset.state = kind;
      $('server-status-text').textContent = text;
      $('retry').hidden = kind !== 'error';
    }

    // ---- API key persistence
    if (store.get(REMEMBER_KEY) === '1') {
      remember.checked = true;
      token.value = store.get(TOKEN_KEY) || '';
    }
    function persistToken() {
      if (remember.checked && token.value.trim()) {
        store.set(REMEMBER_KEY, '1');
        store.set(TOKEN_KEY, token.value.trim());
      } else if (!remember.checked) {
        store.remove(REMEMBER_KEY);
        store.remove(TOKEN_KEY);
      }
    }
    remember.addEventListener('change', () => {
      persistToken();
      toast(remember.checked ? '将在此设备记住 API 密钥' : '已从此设备移除 API 密钥');
    });
    token.addEventListener('input', () => { if (remember.checked) persistToken(); syncForm(); });
    $('toggle-token').addEventListener('click', (event) => {
      const show = token.type === 'password';
      token.type = show ? 'text' : 'password';
      event.currentTarget.setAttribute('aria-pressed', String(show));
      event.currentTarget.setAttribute('aria-label', show ? '隐藏 API 密钥' : '显示 API 密钥');
    });

    // ---- form state
    function syncForm() {
      const text = input.value.trim();
      const count = text ? batchKeys(text).length : 0;
      if (state.mode === 'single') {
        $('input-hint').textContent = '输入 25 位产品密钥。';
        const multiple = count > 1;
        $('paste-hint').hidden = !multiple || state.busy;
        if (multiple) $('paste-hint-text').textContent = `检测到 ${count} 条密钥，单条模式只会检测整段文本。`;
      } else {
        const max = state.service ? state.service.max_batch_size : null;
        $('input-hint').textContent = max && count > max
          ? `已识别 ${count} 条密钥，超过每批 ${max} 条的上限。`
          : `已识别 ${count} 条不同的密钥。可以直接粘贴多行或包含密钥的文本。`;
        $('paste-hint').hidden = true;
      }
      submit.disabled = state.busy || !state.service || !text;
      $('clear').disabled = state.busy || !input.value;
      input.readOnly = state.busy;
      token.readOnly = state.busy;
      online.disabled = state.busy;
      for (const button of modes) button.disabled = state.busy;
    }

    function setMode(value) {
      state.mode = value;
      for (const button of modes) button.setAttribute('aria-pressed', String(button.dataset.mode === value));
      $('key-label').textContent = value === 'batch' ? '产品密钥列表' : '产品密钥';
      input.placeholder = value === 'batch' ? '粘贴多条密钥，每行一条，或直接粘贴包含密钥的文本' : 'XXXXX-XXXXX-XXXXX-XXXXX-XXXXX';
      input.rows = value === 'batch' ? 8 : 4;
      renderLimit();
      if (state.noticeKind !== 'connection') setNotice('');
      syncForm();
    }

    function renderLimit() {
      $('limit').textContent = state.mode === 'batch' && state.service ? `每批最多 ${fmt(state.service.max_batch_size)} 条` : '';
    }

    // ---- progress
    function startProgress(count, withOnline) {
      state.started = performance.now();
      $('progress-text').textContent = count > 1
        ? `正在检测 ${fmt(count)} 条密钥${withOnline ? '（含 MAK 在线查询）' : ''}…`
        : `正在检测密钥${withOnline ? '（含 MAK 在线查询）' : ''}…`;
      $('elapsed').textContent = '0.0 s';
      $('progress').hidden = false;
      clearInterval(state.tick);
      state.tick = setInterval(() => {
        $('elapsed').textContent = `${((performance.now() - state.started) / 1000).toFixed(1)} s`;
      }, 100);
    }
    function stopProgress() {
      clearInterval(state.tick);
      state.tick = null;
      $('progress').hidden = true;
      return (performance.now() - state.started) / 1000;
    }

    function setBusy(busy) {
      state.busy = busy;
      cancel.hidden = !busy;
      resultsPanel.setAttribute('aria-busy', String(busy));
      syncForm();
    }

    // ---- results
    const category = (r) => (r.blocked ? 'blocked' : r.valid ? 'valid' : 'invalid');

    function clearResults(message = '提交密钥后，结果会显示在这里') {
      state.results = [];
      reports.replaceChildren();
      $('summary').textContent = '';
      $('empty-text').textContent = message;
      $('empty').hidden = false;
      $('result-tools').hidden = true;
      $('filter-empty').hidden = true;
    }

    function maskKey(key) {
      const clean = (key || '').replace(/[^a-z0-9]/gi, '').toUpperCase();
      if (clean.length !== 25) return clean ? `尾号 ${clean.slice(-5)}` : '';
      return `•••••-•••••-•••••-•••••-${clean.slice(-5)}`;
    }

    function actionButton(label, onClick) {
      const button = el('button', label, 'ghost');
      button.type = 'button';
      button.addEventListener('click', onClick);
      return button;
    }

    function renderReport(report, index, open) {
      const details = report.details || {};
      const activation = report.activation || {};
      const cat = category(report);
      const node = el('details', '', 'report');
      node.dataset.cat = cat;
      node.open = open;

      const summary = el('summary');
      const badge = el('span', report.blocked ? '已封禁' : STATUS_LABELS[report.status] || '未知', 'badge');
      badge.dataset.state = report.blocked ? 'blocked' : report.status || 'invalid';
      const name = el('span', '', 'report-name');
      name.append(
        el('strong', details.product || details.description || `密钥 ${index + 1}`),
        el('small', maskKey(report.key || report.input) || `#${index + 1}`),
      );
      const tags = el('span', '', 'report-tags');
      if (activation.remaining != null) {
        const mak = el('span', `MAK 剩余 ${fmt(activation.remaining)}`, 'badge mak');
        mak.dataset.level = activation.remaining <= 0 ? 'zero' : activation.remaining < 10 ? 'low' : 'ok';
        tags.append(mak);
      }
      if (report.cached) tags.append(el('span', '缓存', 'badge cached'));
      summary.append(badge, name, tags);

      const body = el('div', '', 'report-body');
      const notes = el('div', '', 'report-notes');
      const seen = new Set();
      for (const note of [report.message, report.blocked_reason, activation.error_message, report.activation_error, details.license_note]) {
        if (note && !seen.has(note)) { seen.add(note); notes.append(el('p', note)); }
      }
      if (notes.childElementCount) body.append(notes);

      const fields = [
        ['产品说明', details.description], ['版本', details.edition_id],
        ['密钥类型', details.key_type], ['授权渠道', details.channel],
        ['剩余激活次数', activation.remaining != null ? fmt(activation.remaining) : null, 'highlight'],
        ['激活错误代码', activation.error_code, 'mono'],
        ['产品 ID', details.product_id, 'mono'], ['扩展 PID', details.extended_pid, 'mono'],
        ['SKU ID', details.sku_id, 'mono'], ['零件编号', details.part_number, 'mono'],
        ['Crypto ID', details.crypto_id_hex, 'mono'], ['密钥格式', report.format],
        ['产品目录文件', details.pkeyconfig, 'mono'],
      ];
      const list = el('dl');
      for (const [label, value, cls] of fields) {
        if (value == null || value === '') continue;
        const pair = el('div');
        pair.append(el('dt', label), el('dd', String(value), cls));
        list.append(pair);
      }
      if (list.childElementCount) body.append(list);

      const actions = el('div', '', 'report-actions');
      const fullKey = report.key || report.input;
      if (fullKey) {
        actions.append(actionButton('复制密钥', async () => toast(await copyText(fullKey) ? '已复制密钥' : '复制失败，请手动选择复制')));
      }
      if (details.product_id) {
        actions.append(actionButton('复制产品 ID', async () => toast(await copyText(details.product_id) ? '已复制产品 ID' : '复制失败，请手动选择复制')));
      }
      if (actions.childElementCount) body.append(actions);

      node.append(summary, body);
      return node;
    }

    function showResults(results, elapsedSecs) {
      state.results = results;
      const counts = { all: results.length, valid: 0, blocked: 0, invalid: 0 };
      for (const r of results) counts[category(r)] += 1;
      for (const key of Object.keys(counts)) $(`count-${key}`).textContent = fmt(counts[key]);
      $('summary').textContent = `${fmt(counts.all)} 条 · 用时 ${elapsedSecs.toFixed(1)} s`;
      const open = results.length === 1;
      reports.replaceChildren(...results.map((r, i) => renderReport(r, i, open)));
      $('empty').hidden = results.length > 0;
      if (!results.length) $('empty-text').textContent = '服务器没有返回任何结果';
      $('result-tools').hidden = results.length < 1;
      applyFilter('all');
    }

    function applyFilter(value) {
      state.filter = value;
      for (const button of filters) button.setAttribute('aria-pressed', String(button.dataset.filter === value));
      let visible = 0;
      for (const node of reports.children) {
        const show = value === 'all' || node.dataset.cat === value;
        node.hidden = !show;
        if (show) visible += 1;
      }
      $('filter-empty').hidden = visible > 0 || !state.results.length;
    }

    function visibleResults() {
      return state.results.filter((r) => state.filter === 'all' || category(r) === state.filter);
    }

    const EXPORT_HEADER = ['序号', '输入', '密钥', '状态', '封禁', '产品', '产品说明', '版本', '密钥类型', '授权渠道', 'MAK 剩余', '激活错误代码', '产品 ID', '扩展 PID', 'SKU ID', '说明'];
    function exportRows() {
      return visibleResults().map((r) => {
        const d = r.details || {};
        const a = r.activation || {};
        return [
          state.results.indexOf(r) + 1, r.input, r.key, STATUS_LABELS[r.status] || r.status, r.blocked ? '是' : '否',
          d.product, d.description, d.edition_id, d.key_type, d.channel,
          a.remaining, a.error_code, d.product_id, d.extended_pid, d.sku_id,
          r.blocked_reason || r.message,
        ];
      });
    }

    // ---- connection
    async function connect({ quiet = false } = {}) {
      if (state.connecting) return;
      state.connecting = true;
      if (!quiet || !state.service) setStatus('pending', '正在连接');
      try {
        const health = await request('/health', { signal: timeoutSignal(10000) });
        const wasDown = !state.service;
        state.service = health;
        renderService();
        setStatus('ready', '服务在线');
        if (state.noticeKind === 'connection') setNotice('');
        if (wasDown) setMode(state.mode);
      } catch (error) {
        state.service = null;
        setStatus('error', '连接失败');
        const detail = error && error.status ? error.message : '无法连接到检测服务。';
        if (!state.busy) setNotice(`${detail} 请检查网络或稍后重试。`, { kind: 'connection', retry: true });
      } finally {
        state.connecting = false;
        syncForm();
      }
    }

    function renderService() {
      const s = state.service;
      const authNeeded = !!s.auth_required;
      $('auth-area').hidden = !authNeeded && !token.value;
      $('public-note').hidden = !s.public_check;
      const configs = s.database && s.database.configurations;
      $('catalog').textContent = configs != null ? `${fmt(configs)} 项` : '—';
      $('blocklist').textContent = s.blocklist != null ? `${fmt(s.blocklist)} 条` : '—';
      $('legacy').textContent = s.legacy_keys_supported ? '支持' : '当前服务器不支持';
      $('version').textContent = s.version || '—';
      $('footer-version').textContent = s.version ? `v${s.version}` : '';
      renderLimit();
    }

    // ---- check
    async function runCheck() {
      if (!state.service || state.busy) return;
      const raw = input.value.trim();
      if (!raw) return;
      const withOnline = online.checked;
      const batch = state.mode === 'batch';
      const keys = batch ? batchKeys(raw) : [];
      const credential = token.value.trim();
      const max = state.service.max_batch_size;
      clearMessages();
      if (state.service.auth_required && !credential) {
        $('auth-area').hidden = false;
        setNotice('请先在「服务设置」中输入 API 密钥。');
        token.focus();
        return;
      }
      if (batch && (!keys.length || keys.length > max)) {
        setNotice(keys.length ? `每次最多检测 ${fmt(max)} 条密钥，当前 ${fmt(keys.length)} 条。` : '没有识别到产品密钥，请检查输入格式。');
        input.focus();
        return;
      }
      persistToken();

      const controller = new AbortController();
      let timedOut = false;
      const timer = setTimeout(() => { timedOut = true; controller.abort(); }, REQUEST_TIMEOUT_MS);
      state.controller = controller;
      setBusy(true);
      clearResults('正在检测密钥…');
      startProgress(batch ? keys.length : 1, withOnline);
      try {
        const headers = { 'Content-Type': 'application/json' };
        if (credential) headers.Authorization = `Bearer ${credential}`;
        const response = await request(batch ? '/check/batch' : '/check', {
          method: 'POST', headers, signal: controller.signal,
          body: JSON.stringify(batch ? { keys, online: withOnline } : { key: raw, online: withOnline }),
        });
        const results = batch ? (Array.isArray(response.results) ? response.results : []) : [response];
        showResults(results, stopProgress());
      } catch (error) {
        stopProgress();
        clearResults('检测未完成');
        if (error && error.name === 'AbortError') {
          if (timedOut) setNotice(`检测超时（超过 ${REQUEST_TIMEOUT_MS / 1000} 秒），请减少密钥数量或关闭 MAK 查询后重试。`, { retry: true });
          else setInfo('已取消检测。服务器可能仍会完成本次请求，但结果不会显示。');
        } else if (error instanceof TypeError) {
          setNotice('无法连接到检测服务，请检查网络后重试。', { retry: true });
          connect({ quiet: true });
        } else {
          setNotice(error.message || '检测失败，请稍后再试。');
          if (error.status === 401 || error.status === 403) {
            $('auth-area').hidden = false;
            token.focus();
          }
        }
      } finally {
        clearTimeout(timer);
        state.controller = null;
        setBusy(false);
      }
    }

    // ---- events
    form.addEventListener('submit', (event) => { event.preventDefault(); runCheck(); });
    cancel.addEventListener('click', () => { if (state.controller) state.controller.abort(); });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) {
        event.preventDefault();
        if (!submit.disabled) runCheck();
      } else if (event.key === 'Escape' && state.controller) {
        state.controller.abort();
      }
    });
    for (const button of modes) button.addEventListener('click', () => setMode(button.dataset.mode));
    input.addEventListener('input', syncForm);
    $('switch-batch').addEventListener('click', () => { setMode('batch'); input.focus(); });
    $('clear').addEventListener('click', () => {
      input.value = '';
      clearMessages();
      clearResults();
      syncForm();
      input.focus();
    });
    $('notice-retry').addEventListener('click', () => {
      if (state.noticeKind === 'connection' || !state.service) connect();
      else { setNotice(''); runCheck(); }
    });
    $('retry').addEventListener('click', () => connect());
    $('theme-toggle').addEventListener('click', () => {
      const next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
      store.set(THEME_KEY, next);
      applyTheme(next);
    });
    for (const button of filters) button.addEventListener('click', () => applyFilter(button.dataset.filter));
    $('expand-all').addEventListener('click', () => { for (const n of reports.children) if (!n.hidden) n.open = true; });
    $('collapse-all').addEventListener('click', () => { for (const n of reports.children) n.open = false; });
    $('copy-all').addEventListener('click', async () => {
      const rows = exportRows();
      if (!rows.length) return toast('没有可复制的结果');
      const text = [EXPORT_HEADER, ...rows].map((row) => row.map(tsvCell).join('\t')).join('\n');
      toast(await copyText(text) ? `已复制 ${fmt(rows.length)} 条结果（TSV）` : '复制失败，请改用导出 CSV');
    });
    $('export-csv').addEventListener('click', () => {
      const rows = exportRows();
      if (!rows.length) return toast('没有可导出的结果');
      const csv = '﻿' + [EXPORT_HEADER, ...rows].map((row) => row.map(csvCell).join(',')).join('\r\n');
      const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
      const stamp = new Date().toISOString().replace(/[-:]/g, '').replace('T', '-').slice(0, 15);
      const link = document.createElement('a');
      link.href = url;
      link.download = `pidchecker-results-${stamp}.csv`;
      document.body.append(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      toast(`已导出 ${fmt(rows.length)} 条结果`);
    });

    // Periodic health checks keep the status pill honest.
    setInterval(() => { if (!document.hidden && !state.busy) connect({ quiet: true }); }, HEALTH_INTERVAL_MS);
    document.addEventListener('visibilitychange', () => { if (!document.hidden && !state.busy) connect({ quiet: true }); });
    window.addEventListener('online', () => connect({ quiet: true }));
    window.addEventListener('offline', () => setStatus('error', '网络已断开'));

    syncForm();
    connect();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
