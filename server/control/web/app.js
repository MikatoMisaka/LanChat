(() => {
  'use strict';

  const state = {
    adminToken: sessionStorage.getItem('lanchat.adminToken') || '',
    info: null,
    config: null,
    stats: null,
    requests: [],
    users: [],
    pendingDevices: [],
    toastTimer: null,
  };

  const $ = (id) => document.getElementById(id);
  const escapeHtml = (value) => String(value ?? '').replace(/[&<>'"]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
  }[character]));

  async function api(path, options = {}) {
    const headers = new Headers(options.headers || {});
    if (options.body && !headers.has('content-type')) headers.set('content-type', 'application/json');
    if (state.adminToken) headers.set('authorization', `Bearer ${state.adminToken}`);
    const response = await fetch(path, { ...options, headers });
    const text = await response.text();
    let body = {};
    if (text) {
      try { body = JSON.parse(text); } catch (_) { body = { message: text }; }
    }
    if (response.status === 401 && state.adminToken && !path.includes('/admin/login')) {
      clearSession();
      throw new Error('管理员会话已过期，请重新登录。');
    }
    if (!response.ok) throw new Error(body.error || body.message || `请求失败（${response.status}）`);
    return body;
  }

  function clearSession() {
    state.adminToken = '';
    sessionStorage.removeItem('lanchat.adminToken');
  }

  function showToast(message, error = false) {
    const toast = $('toast');
    toast.textContent = message;
    toast.classList.toggle('error', error);
    toast.classList.add('visible');
    clearTimeout(state.toastTimer);
    state.toastTimer = setTimeout(() => toast.classList.remove('visible'), 3200);
  }

  function showAuthStatus(message, error = true) {
    const node = $('auth-status');
    node.textContent = message || '';
    node.classList.toggle('success', !error && Boolean(message));
  }

  function setGlobalStatus(message) {
    $('global-status').textContent = message || '';
  }

  function formatBytes(bytes) {
    const value = Number(bytes) || 0;
    if (value < 1024) return `${value} B`;
    if (value < 1024 * 1024) return `${(value / 1024).toFixed(value > 10240 ? 0 : 1)} KB`;
    if (value < 1024 * 1024 * 1024) return `${(value / 1024 / 1024).toFixed(value > 100 * 1024 * 1024 ? 0 : 1)} MB`;
    return `${(value / 1024 / 1024 / 1024).toFixed(1)} GB`;
  }

  function formatDate(value, withTime = false) {
    if (!value) return '未知时间';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return '未知时间';
    return new Intl.DateTimeFormat('zh-CN', withTime
      ? { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' }
      : { month: 'long', day: 'numeric', weekday: 'short' }).format(date);
  }

  function initials(name) {
    const value = String(name || '?').trim();
    return value.slice(0, 1).toUpperCase();
  }

  async function loadServerInfo() {
    state.info = await api('/api/v1/server/info');
    const name = state.info.serverName || 'LanChat Server';
    $('auth-server-status').textContent = state.info.setupRequired ? '等待首次设置' : '服务器在线';
    $('sidebar-server-name').textContent = name;
    $('footer-server-name').textContent = name;
    if (state.info.setupRequired) {
      $('setup-panel').classList.remove('hidden');
      $('login-panel').classList.add('hidden');
    } else {
      $('setup-panel').classList.add('hidden');
      $('login-panel').classList.remove('hidden');
    }
  }

  function openApp() {
    $('auth-screen').classList.add('hidden');
    $('app-shell').classList.remove('hidden');
    setGlobalStatus('');
  }

  async function refresh() {
    if (!state.adminToken) return;
    $('refresh-button').classList.add('is-loading');
    setGlobalStatus('正在同步控制室数据…');
    try {
      const [config, stats, requests, users, pendingDevices] = await Promise.all([
        api('/api/v1/admin/config'),
        api('/api/v1/admin/stats'),
        api('/api/v1/admin/requests'),
        api('/api/v1/admin/users'),
        api('/api/v1/admin/devices/pending'),
      ]);
      state.config = config;
      state.stats = stats;
      state.requests = requests.requests || [];
      state.users = users.users || [];
      state.pendingDevices = pendingDevices.devices || [];
      renderAll();
      $('last-sync').textContent = `已同步 ${new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}`;
      setGlobalStatus('');
    } catch (error) {
      setGlobalStatus(error.message);
      showToast(error.message, true);
    } finally {
      $('refresh-button').classList.remove('is-loading');
    }
  }

  function renderAll() {
    const name = state.config?.serverName || state.info?.serverName || 'LanChat Server';
    const stats = state.stats || {};
    const pending = state.requests.length + state.pendingDevices.length;
    $('server-name').textContent = name;
    $('sidebar-server-name').textContent = name;
    $('footer-server-name').textContent = name;
    $('server-address').textContent = window.location.host || '当前控制室';
    $('hero-retention').textContent = `${state.config?.retentionDays || 30} 天`;
    $('hero-media-limit').textContent = `${Math.round((state.config?.maxImageBytes || 0) / 1024 / 1024)} MB / 图片`;
    $('security-copy').textContent = state.config?.encryptionMode === 'e2ee'
      ? '端到端加密已启用。控制室只观察连接、设备和容量，不读取聊天内容。'
      : '当前服务器允许可读消息。建议切回客户端端到端加密。';
    $('metric-pending').textContent = pending;
    $('metric-online').textContent = stats.onlineDevices || 0;
    $('metric-users').textContent = stats.userCount || 0;
    $('metric-traffic').textContent = formatBytes(stats.imageBytes || 0);
    $('metric-day').textContent = stats.day ? `${stats.day} UTC` : 'UTC today';
    $('queue-count').textContent = pending;
    $('nav-pending-count').textContent = pending;
    $('nav-pending-count').classList.toggle('hidden', pending === 0);
    $('today-date').textContent = formatDate(new Date(), false);
    renderRequests();
    renderPendingDevices();
    renderPeople();
    populateConfig();
  }

  function renderRequests() {
    const target = $('approval-list');
    if (!state.requests.length) {
      target.innerHTML = '<div class="empty-state"><span class="empty-orbit"></span><strong>队列是空的</strong><small>新的入群申请会出现在这里。</small></div>';
      return;
    }
    target.innerHTML = state.requests.map((request) => `
      <div class="approval-row">
        <div class="person-line"><span class="avatar">${escapeHtml(initials(request.displayName))}</span><div><strong>${escapeHtml(request.displayName)}</strong><small>@${escapeHtml(request.username)} · ${escapeHtml(request.deviceId)} · ${escapeHtml(formatDate(request.createdAt, true))}</small></div></div>
        <div class="row-actions"><button class="mini-button danger" data-action="reject-request" data-id="${escapeHtml(request.id)}">拒绝</button><button class="mini-button confirm" data-action="approve-request" data-id="${escapeHtml(request.id)}">通过</button></div>
      </div>`).join('');
  }

  function renderPendingDevices() {
    const target = $('device-approval-list');
    if (!state.pendingDevices.length) { target.innerHTML = ''; return; }
    target.innerHTML = state.pendingDevices.map((device) => `
      <div class="device-row"><div class="person-line"><span class="avatar">⌁</span><div><strong>${escapeHtml(device.userId)} 的新设备</strong><small>${escapeHtml(device.deviceId)} · ${escapeHtml(formatDate(device.createdAt, true))}</small></div></div><div class="row-actions"><button class="mini-button danger" data-action="revoke-device" data-user="${escapeHtml(device.userId)}" data-device="${escapeHtml(device.deviceId)}">拒绝</button><button class="mini-button confirm" data-action="approve-device" data-user="${escapeHtml(device.userId)}" data-device="${escapeHtml(device.deviceId)}">通过</button></div></div>`).join('');
  }

  function renderPeople() {
    const query = ($('people-search').value || '').trim().toLowerCase();
    const people = state.users.filter((user) => !query || `${user.username} ${user.displayName}`.toLowerCase().includes(query));
    $('people-count').textContent = `${people.length} 位成员`;
    if (!people.length) {
      $('people-list').innerHTML = '<div class="empty-state"><span class="empty-orbit"></span><strong>没有匹配的成员</strong><small>换一个用户名或昵称试试。</small></div>';
      return;
    }
    $('people-list').innerHTML = people.map((user) => {
      const devices = user.devices || [];
      const chips = devices.map((device) => `<span class="device-chip ${escapeHtml(device.status)}">${device.online ? '● ' : ''}${escapeHtml(device.deviceId)}</span>`).join('');
      return `<article class="person-card"><div class="person-card-head"><div class="person-line"><span class="avatar">${escapeHtml(initials(user.displayName))}</span><div><h3 class="person-card-name">${escapeHtml(user.displayName)}</h3><p class="person-card-handle">@${escapeHtml(user.username)}</p></div></div><span class="presence ${user.online ? 'online' : ''}"><i></i>${user.online ? 'ONLINE' : 'OFFLINE'}</span></div><div>${chips || '<span class="device-chip">暂无设备</span>'}</div><div class="device-summary"><span>加入于 ${escapeHtml(formatDate(user.createdAt))}</span><strong>${devices.length} 台设备</strong></div><div class="user-actions"><button class="mini-button" data-action="show-devices" data-user="${escapeHtml(user.username)}">查看设备</button><button class="mini-button danger" data-action="disable-user" data-user="${escapeHtml(user.username)}" data-disabled="${user.disabled ? 'true' : 'false'}">${user.disabled ? '恢复用户' : '禁用用户'}</button></div></article>`;
    }).join('');
  }

  function populateConfig() {
    if (!state.config) return;
    $('retention-days').value = state.config.retentionDays || 30;
    $('max-image-mb').value = Math.max(1, Math.round((state.config.maxImageBytes || 20 * 1024 * 1024) / 1024 / 1024));
    $('user-quota-gb').value = ((state.config.perUserDailyImageBytes || 512 * 1024 * 1024) / 1024 / 1024 / 1024).toFixed(1);
    $('global-quota-gb').value = ((state.config.globalDailyImageBytes || 5 * 1024 * 1024 * 1024) / 1024 / 1024 / 1024).toFixed(1);
  }

  async function handleSetup(event) {
    event.preventDefault();
    const password = $('setup-password').value;
    if (password !== $('setup-password-confirm').value) { showAuthStatus('两次输入的密码不一致。'); return; }
    try {
      const result = await api('/api/v1/admin/setup', { method: 'POST', body: JSON.stringify({ bootstrapCode: $('bootstrap-code').value, password }) });
      state.adminToken = result.token;
      sessionStorage.setItem('lanchat.adminToken', state.adminToken);
      showAuthStatus('控制室已建立，正在进入…', false);
      openApp();
      await refresh();
    } catch (error) { showAuthStatus(error.message); }
  }

  async function handleLogin(event) {
    event.preventDefault();
    try {
      const result = await api('/api/v1/admin/login', { method: 'POST', body: JSON.stringify({ password: $('admin-password-login').value }) });
      state.adminToken = result.token;
      sessionStorage.setItem('lanchat.adminToken', state.adminToken);
      openApp();
      await refresh();
    } catch (error) { showAuthStatus(error.message); }
  }

  async function handleInvite(event) {
    event.preventDefault();
    try {
      const result = await api('/api/v1/admin/invitations', { method: 'POST', body: JSON.stringify({ singleUse: $('invite-single-use').checked, lifetimeDays: Number($('invite-lifetime').value) }) });
      $('last-code-value').textContent = result.code;
      $('last-code').classList.remove('hidden');
      showToast('邀请码已生成，请现在复制并发送。');
    } catch (error) { showToast(error.message, true); }
  }

  async function rotateGroupInvite() {
    if (!window.confirm('轮换后，旧的群组邀请码会立即失效。继续吗？')) return;
    try {
      const result = await api('/api/v1/admin/access-code/rotate', { method: 'POST', body: JSON.stringify({}) });
      $('last-group-code-value').textContent = result.accessCode;
      $('last-group-code').classList.remove('hidden');
      showToast('群组邀请码已轮换。');
    } catch (error) { showToast(error.message, true); }
  }

  async function handleConfig(event) {
    event.preventDefault();
    try {
      await api('/api/v1/admin/config', { method: 'PUT', body: JSON.stringify({
        encryptionMode: 'e2ee',
        retentionDays: Number($('retention-days').value),
        maxImageBytes: Number($('max-image-mb').value) * 1024 * 1024,
        perUserDailyImageBytes: Number($('user-quota-gb').value) * 1024 * 1024 * 1024,
        globalDailyImageBytes: Number($('global-quota-gb').value) * 1024 * 1024 * 1024,
      }) });
      showToast('容量设置已保存。');
      await refresh();
    } catch (error) { showToast(error.message, true); }
  }

  async function handlePassword(event) {
    event.preventDefault();
    if ($('new-admin-password').value !== $('new-admin-password-confirm').value) { showToast('两次输入的密码不一致。', true); return; }
    try {
      await api('/api/v1/admin/password', { method: 'POST', body: JSON.stringify({ password: $('new-admin-password').value }) });
      event.target.reset();
      showToast('管理员密码已更新。');
    } catch (error) { showToast(error.message, true); }
  }

  async function reviewRequest(requestId, approved) {
    try {
      await api(`/api/v1/admin/requests/${encodeURIComponent(requestId)}/${approved ? 'approve' : 'reject'}`, { method: 'POST' });
      showToast(approved ? '成员申请已通过。' : '成员申请已拒绝。');
      await refresh();
    } catch (error) { showToast(error.message, true); }
  }

  async function reviewDevice(user, device, approved) {
    const encodedUser = encodeURIComponent(user);
    const encodedDevice = encodeURIComponent(device);
    try {
      const path = `/api/v1/admin/users/${encodedUser}/devices/${encodedDevice}`;
      await api(approved ? `${path}/approve` : path, { method: approved ? 'POST' : 'DELETE' });
      showToast(approved ? '设备已批准。' : '设备已拒绝。');
      await refresh();
    } catch (error) { showToast(error.message, true); }
  }

  async function toggleUser(user, disabled) {
    const action = disabled ? '恢复' : '禁用';
    if (!window.confirm(`${action} ${user}？${disabled ? '' : '该用户的现有会话会立即失效。'}`)) return;
    try {
      await api(`/api/v1/admin/users/${encodeURIComponent(user)}/disable`, { method: 'POST', body: JSON.stringify({ disabled: !disabled }) });
      showToast(`用户已${action}。`);
      await refresh();
    } catch (error) { showToast(error.message, true); }
  }

  async function showDevices(username) {
    try {
      const result = await api(`/api/v1/admin/users/${encodeURIComponent(username)}/devices`);
      $('dialog-user-name').textContent = `@${username}`;
      $('dialog-devices').innerHTML = (result.devices || []).map((device) => `<div class="dialog-device"><div><strong>${escapeHtml(device.deviceId)}</strong><small>${escapeHtml(device.status)} · ${device.online ? '最近在线' : '未在线'}</small></div><button class="mini-button danger" data-action="revoke-device" data-user="${escapeHtml(username)}" data-device="${escapeHtml(device.deviceId)}">撤销</button></div>`).join('') || '<div class="empty-state"><strong>还没有设备</strong></div>';
      $('device-dialog').showModal();
    } catch (error) { showToast(error.message, true); }
  }

  async function copyText(value) {
    try {
      await navigator.clipboard.writeText(value);
      showToast('已复制到剪贴板。');
    } catch (_) { showToast('浏览器拒绝访问剪贴板，请手动复制。', true); }
  }

  function switchView(view) {
    document.querySelectorAll('.nav-item').forEach((item) => item.classList.toggle('active', item.dataset.view === view));
    document.querySelectorAll('.view').forEach((item) => item.classList.toggle('active', item.dataset.view === view));
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  function handleAction(event) {
    const actionButton = event.target.closest('[data-action]');
    if (!actionButton) return;
    const action = actionButton.dataset.action;
    if (action === 'approve-request') reviewRequest(actionButton.dataset.id, true);
    if (action === 'reject-request') reviewRequest(actionButton.dataset.id, false);
    if (action === 'approve-device') reviewDevice(actionButton.dataset.user, actionButton.dataset.device, true);
    if (action === 'revoke-device') reviewDevice(actionButton.dataset.user, actionButton.dataset.device, false);
    if (action === 'disable-user') toggleUser(actionButton.dataset.user, actionButton.dataset.disabled === 'true');
    if (action === 'show-devices') showDevices(actionButton.dataset.user);
    if (action === 'copy-code') copyText($('last-code-value').textContent);
    if (action === 'copy-group-code') copyText($('last-group-code-value').textContent);
    if (action === 'close-dialog') $('device-dialog').close();
  }

  function logout() {
    clearSession();
    window.location.reload();
  }

  async function init() {
    $('setup-form').addEventListener('submit', handleSetup);
    $('login-form').addEventListener('submit', handleLogin);
    $('invite-form').addEventListener('submit', handleInvite);
    $('config-form').addEventListener('submit', handleConfig);
    $('admin-password-form').addEventListener('submit', handlePassword);
    $('rotate-group-invite').addEventListener('click', rotateGroupInvite);
    $('refresh-button').addEventListener('click', refresh);
    $('people-refresh').addEventListener('click', refresh);
    $('people-search').addEventListener('input', renderPeople);
    $('logout-button').addEventListener('click', logout);
    $('mobile-logout-button').addEventListener('click', logout);
    document.addEventListener('click', handleAction);
    document.querySelectorAll('.nav-item').forEach((item) => item.addEventListener('click', () => switchView(item.dataset.view)));
    try {
      await loadServerInfo();
      if (state.adminToken && !state.info.setupRequired) { openApp(); await refresh(); }
    } catch (error) {
      $('auth-server-status').textContent = '服务器暂不可用';
      showAuthStatus(error.message);
    }
  }

  window.addEventListener('DOMContentLoaded', init);
})();
