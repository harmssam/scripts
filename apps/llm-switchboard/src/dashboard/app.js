/* LLM Switchboard dashboard — vanilla JS, no CDN */
(function () {
  const KEY_STORAGE = 'switchboard_gateway_key';

  const $ = (sel, root = document) => root.querySelector(sel);
  const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

  function getKey() {
    return sessionStorage.getItem(KEY_STORAGE) || '';
  }

  function setKey(k) {
    if (k) sessionStorage.setItem(KEY_STORAGE, k);
    else sessionStorage.removeItem(KEY_STORAGE);
  }

  async function api(path, options = {}) {
    const key = getKey();
    const headers = {
      ...(options.headers || {}),
      Authorization: `Bearer ${key}`,
    };
    if (options.body && !headers['Content-Type']) {
      headers['Content-Type'] = 'application/json';
    }
    const res = await fetch(`/admin/api${path}`, { ...options, headers });
    const text = await res.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      data = { raw: text };
    }
    if (!res.ok) {
      const msg =
        (data && data.error && data.error.message) ||
        (data && data.error) ||
        res.statusText ||
        'Request failed';
      const err = new Error(typeof msg === 'string' ? msg : JSON.stringify(msg));
      err.status = res.status;
      err.data = data;
      throw err;
    }
    return data;
  }

  function show(el, on = true) {
    if (!el) return;
    el.classList.toggle('hidden', !on);
  }

  function escapeHtml(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function fmtTs(ts) {
    try {
      return new Date(ts).toLocaleString();
    } catch {
      return String(ts);
    }
  }

  // ── Auth ──────────────────────────────────────────────────────────
  const authGate = $('#auth-gate');
  const appEl = $('#app');
  const authForm = $('#auth-form');
  const authError = $('#auth-error');

  async function tryUnlock(key) {
    setKey(key);
    try {
      await api('/meta');
      show(authGate, false);
      show(appEl, true);
      await boot();
      return true;
    } catch (e) {
      setKey('');
      show(appEl, false);
      show(authGate, true);
      authError.textContent = e.status === 401 ? 'Invalid gateway key' : e.message;
      show(authError, true);
      return false;
    }
  }

  authForm.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    show(authError, false);
    const key = $('#auth-key').value.trim();
    await tryUnlock(key);
  });

  $('#btn-logout').addEventListener('click', () => {
    setKey('');
    show(appEl, false);
    show(authGate, true);
    $('#auth-key').value = '';
  });

  // ── Navigation ────────────────────────────────────────────────────
  function showSection(name) {
    $$('.section').forEach((s) => show(s, false));
    show($(`#section-${name}`), true);
    $$('.tab').forEach((t) => t.classList.toggle('active', t.dataset.section === name));
    if (name === 'overview') loadOverview();
    if (name === 'plans') loadPlans();
    if (name === 'groups') loadGroups();
    if (name === 'routes') loadRoutes();
    if (name === 'activity') loadEvents();
    if (name === 'settings') loadSettings();
  }

  $('#nav').addEventListener('click', (ev) => {
    const btn = ev.target.closest('.tab');
    if (!btn) return;
    showSection(btn.dataset.section);
  });

  // ── Overview ──────────────────────────────────────────────────────
  async function loadOverview() {
    const data = await api('/overview');
    $('#stat-requests').textContent = data.stats.requests;
    $('#stat-successes').textContent = data.stats.successes;
    $('#stat-failures').textContent = data.stats.failures;
    $('#stat-failovers').textContent = data.stats.failovers;

    const chips = $('#health-chips');
    if (!data.plans || data.plans.length === 0) {
      chips.innerHTML = '<span class="muted">No plans configured</span>';
      return;
    }
    chips.innerHTML = data.plans
      .map((p) => {
        const status = p.status || 'ok';
        const dis = p.enabled ? '' : ' disabled';
        return `<span class="chip status-${escapeHtml(status)}${dis}" title="failures: ${p.failures}">
          <span class="dot"></span>
          <strong>${escapeHtml(p.name || p.id)}</strong>
          <span class="muted">${escapeHtml(status)}${p.enabled ? '' : ' · off'}</span>
        </span>`;
      })
      .join('');
  }

  // ── Plans ─────────────────────────────────────────────────────────
  const planForm = $('#plan-form');

  function hidePlanForm() {
    show(planForm, false);
    planForm.reset();
    $('#plan-edit-id').value = '';
    show($('#plan-form-error'), false);
  }

  function openPlanForm(plan) {
    show(planForm, true);
    show($('#plan-form-error'), false);
    if (plan) {
      $('#plan-form-title').textContent = 'Edit plan';
      $('#plan-edit-id').value = plan.id;
      $('#plan-id').value = plan.id;
      $('#plan-id').disabled = true;
      $('#plan-name').value = plan.name;
      $('#plan-baseUrl').value = plan.baseUrl;
      $('#plan-apiKey').value = '';
      $('#plan-apiKey').placeholder = plan.apiKeySet ? 'leave blank to keep existing' : 'api key';
      $('#plan-enabled').checked = plan.enabled !== false;
    } else {
      $('#plan-form-title').textContent = 'Add plan';
      $('#plan-edit-id').value = '';
      $('#plan-id').disabled = false;
      planForm.reset();
      $('#plan-enabled').checked = true;
      $('#plan-apiKey').placeholder = 'api key';
    }
  }

  async function loadPlans() {
    const plans = await api('/plans');
    const wrap = $('#plans-list');
    if (!plans.length) {
      wrap.innerHTML = '<div class="empty">No plans yet</div>';
      return;
    }
    wrap.innerHTML = `<table>
      <thead><tr>
        <th>ID</th><th>Name</th><th>Base URL</th><th>Key</th><th>Enabled</th><th></th>
      </tr></thead>
      <tbody>
        ${plans
          .map(
            (p) => `<tr data-id="${escapeHtml(p.id)}">
            <td><code>${escapeHtml(p.id)}</code></td>
            <td>${escapeHtml(p.name)}</td>
            <td class="mono">${escapeHtml(p.baseUrl)}</td>
            <td>${p.apiKeySet ? '••••' : '—'}</td>
            <td>${p.enabled ? 'yes' : 'no'}</td>
            <td class="actions">
              <button type="button" class="btn small ghost act-edit">Edit</button>
              <button type="button" class="btn small ghost act-test">Test</button>
              <button type="button" class="btn small danger act-del">Delete</button>
            </td>
          </tr>`
          )
          .join('')}
      </tbody>
    </table>`;

    wrap.querySelectorAll('.act-edit').forEach((btn) => {
      btn.addEventListener('click', () => {
        const id = btn.closest('tr').dataset.id;
        const plan = plans.find((x) => x.id === id);
        openPlanForm(plan);
      });
    });
    wrap.querySelectorAll('.act-del').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const id = btn.closest('tr').dataset.id;
        if (!confirm(`Delete plan "${id}"?`)) return;
        try {
          await api(`/plans/${encodeURIComponent(id)}`, { method: 'DELETE' });
          hidePlanForm();
          await loadPlans();
        } catch (e) {
          alert(e.message);
        }
      });
    });
    wrap.querySelectorAll('.act-test').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const id = btn.closest('tr').dataset.id;
        btn.disabled = true;
        btn.textContent = '…';
        try {
          const r = await api(`/plans/${encodeURIComponent(id)}/test`, { method: 'POST' });
          alert(
            r.ok
              ? `OK (${r.status}) ${r.url}`
              : `Failed (${r.status ?? '—'}): ${r.error || 'unknown'}\n${r.url || ''}`
          );
        } catch (e) {
          alert(e.message);
        } finally {
          btn.disabled = false;
          btn.textContent = 'Test';
        }
      });
    });
  }

  $('#btn-add-plan').addEventListener('click', () => openPlanForm(null));
  $('#plan-form-cancel').addEventListener('click', hidePlanForm);

  planForm.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const errEl = $('#plan-form-error');
    show(errEl, false);
    const editId = $('#plan-edit-id').value;
    const body = {
      id: $('#plan-id').value.trim(),
      name: $('#plan-name').value.trim(),
      baseUrl: $('#plan-baseUrl').value.trim(),
      providerType: 'openai-compat',
      enabled: $('#plan-enabled').checked,
    };
    const key = $('#plan-apiKey').value;
    if (key) body.apiKey = key;
    else if (!editId) body.apiKey = '';

    try {
      if (editId) {
        await api(`/plans/${encodeURIComponent(editId)}`, {
          method: 'PUT',
          body: JSON.stringify(body),
        });
      } else {
        await api('/plans', { method: 'POST', body: JSON.stringify(body) });
      }
      hidePlanForm();
      await loadPlans();
    } catch (e) {
      errEl.textContent = e.message;
      show(errEl, true);
    }
  });

  // ── Groups ────────────────────────────────────────────────────────
  const groupForm = $('#group-form');

  function hideGroupForm() {
    show(groupForm, false);
    groupForm.reset();
    $('#group-edit-id').value = '';
    show($('#group-form-error'), false);
  }

  function openGroupForm(g) {
    show(groupForm, true);
    show($('#group-form-error'), false);
    if (g) {
      $('#group-form-title').textContent = 'Edit group';
      $('#group-edit-id').value = g.id;
      $('#group-id').value = g.id;
      $('#group-id').disabled = true;
      $('#group-name').value = g.name;
      $('#group-strategy').value = g.strategy || 'equal';
      $('#group-cooldown').value = g.cooldownSeconds ?? 120;
      $('#group-planIds').value = (g.planIds || []).join(', ');
    } else {
      $('#group-form-title').textContent = 'Add group';
      $('#group-edit-id').value = '';
      $('#group-id').disabled = false;
      groupForm.reset();
      $('#group-strategy').value = 'equal';
      $('#group-cooldown').value = 120;
    }
  }

  async function loadGroups() {
    const groups = await api('/groups');
    const wrap = $('#groups-list');
    if (!groups.length) {
      wrap.innerHTML = '<div class="empty">No groups yet</div>';
      return;
    }
    wrap.innerHTML = `<table>
      <thead><tr>
        <th>ID</th><th>Name</th><th>Strategy</th><th>Plans</th><th>Cooldown</th><th></th>
      </tr></thead>
      <tbody>
        ${groups
          .map(
            (g) => `<tr data-id="${escapeHtml(g.id)}">
            <td><code>${escapeHtml(g.id)}</code></td>
            <td>${escapeHtml(g.name)}</td>
            <td>${escapeHtml(g.strategy)}</td>
            <td class="mono">${escapeHtml((g.planIds || []).join(', '))}</td>
            <td>${g.cooldownSeconds}s</td>
            <td class="actions">
              <button type="button" class="btn small ghost act-edit">Edit</button>
              <button type="button" class="btn small danger act-del">Delete</button>
            </td>
          </tr>`
          )
          .join('')}
      </tbody>
    </table>`;

    wrap.querySelectorAll('.act-edit').forEach((btn) => {
      btn.addEventListener('click', () => {
        const id = btn.closest('tr').dataset.id;
        openGroupForm(groups.find((x) => x.id === id));
      });
    });
    wrap.querySelectorAll('.act-del').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const id = btn.closest('tr').dataset.id;
        if (!confirm(`Delete group "${id}"?`)) return;
        try {
          await api(`/groups/${encodeURIComponent(id)}`, { method: 'DELETE' });
          hideGroupForm();
          await loadGroups();
        } catch (e) {
          alert(e.message);
        }
      });
    });
  }

  $('#btn-add-group').addEventListener('click', () => openGroupForm(null));
  $('#group-form-cancel').addEventListener('click', hideGroupForm);

  groupForm.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const errEl = $('#group-form-error');
    show(errEl, false);
    const editId = $('#group-edit-id').value;
    const planIds = $('#group-planIds')
      .value.split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    const body = {
      id: $('#group-id').value.trim(),
      name: $('#group-name').value.trim(),
      strategy: $('#group-strategy').value,
      planIds,
      cooldownSeconds: Number($('#group-cooldown').value) || 120,
    };
    try {
      if (editId) {
        await api(`/groups/${encodeURIComponent(editId)}`, {
          method: 'PUT',
          body: JSON.stringify(body),
        });
      } else {
        await api('/groups', { method: 'POST', body: JSON.stringify(body) });
      }
      hideGroupForm();
      await loadGroups();
    } catch (e) {
      errEl.textContent = e.message;
      show(errEl, true);
    }
  });

  // ── Routes ────────────────────────────────────────────────────────
  const routeForm = $('#route-form');

  function hideRouteForm() {
    show(routeForm, false);
    routeForm.reset();
    $('#route-edit-id').value = '';
    show($('#route-form-error'), false);
  }

  function openRouteForm(r) {
    show(routeForm, true);
    show($('#route-form-error'), false);
    if (r) {
      $('#route-form-title').textContent = 'Edit route';
      $('#route-edit-id').value = r.id;
      $('#route-id').value = r.id;
      $('#route-id').disabled = true;
      $('#route-model').value = r.model;
      $('#route-targetType').value = r.targetType;
      $('#route-targetId').value = r.targetId;
      $('#route-upstreamModel').value = r.upstreamModel || '';
    } else {
      $('#route-form-title').textContent = 'Add route';
      $('#route-edit-id').value = '';
      $('#route-id').disabled = false;
      routeForm.reset();
      $('#route-targetType').value = 'group';
    }
  }

  async function loadRoutes() {
    const routes = await api('/routes');
    const wrap = $('#routes-list');
    if (!routes.length) {
      wrap.innerHTML = '<div class="empty">No routes yet</div>';
      return;
    }
    wrap.innerHTML = `<table>
      <thead><tr>
        <th>ID</th><th>Model</th><th>Target</th><th>Upstream</th><th></th>
      </tr></thead>
      <tbody>
        ${routes
          .map(
            (r) => `<tr data-id="${escapeHtml(r.id)}">
            <td><code>${escapeHtml(r.id)}</code></td>
            <td><code>${escapeHtml(r.model)}</code></td>
            <td>${escapeHtml(r.targetType)}:<code>${escapeHtml(r.targetId)}</code></td>
            <td class="mono">${escapeHtml(r.upstreamModel || '—')}</td>
            <td class="actions">
              <button type="button" class="btn small ghost act-edit">Edit</button>
              <button type="button" class="btn small danger act-del">Delete</button>
            </td>
          </tr>`
          )
          .join('')}
      </tbody>
    </table>`;

    wrap.querySelectorAll('.act-edit').forEach((btn) => {
      btn.addEventListener('click', () => {
        const id = btn.closest('tr').dataset.id;
        openRouteForm(routes.find((x) => x.id === id));
      });
    });
    wrap.querySelectorAll('.act-del').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const id = btn.closest('tr').dataset.id;
        if (!confirm(`Delete route "${id}"?`)) return;
        try {
          await api(`/routes/${encodeURIComponent(id)}`, { method: 'DELETE' });
          hideRouteForm();
          await loadRoutes();
        } catch (e) {
          alert(e.message);
        }
      });
    });
  }

  $('#btn-add-route').addEventListener('click', () => openRouteForm(null));
  $('#route-form-cancel').addEventListener('click', hideRouteForm);

  routeForm.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const errEl = $('#route-form-error');
    show(errEl, false);
    const editId = $('#route-edit-id').value;
    const upstream = $('#route-upstreamModel').value.trim();
    const body = {
      id: $('#route-id').value.trim(),
      model: $('#route-model').value.trim(),
      targetType: $('#route-targetType').value,
      targetId: $('#route-targetId').value.trim(),
    };
    if (upstream) body.upstreamModel = upstream;
    try {
      if (editId) {
        if (!upstream) body.upstreamModel = '';
        await api(`/routes/${encodeURIComponent(editId)}`, {
          method: 'PUT',
          body: JSON.stringify(body),
        });
      } else {
        await api('/routes', { method: 'POST', body: JSON.stringify(body) });
      }
      hideRouteForm();
      await loadRoutes();
    } catch (e) {
      errEl.textContent = e.message;
      show(errEl, true);
    }
  });

  // ── Activity ──────────────────────────────────────────────────────
  async function loadEvents() {
    const events = await api('/events?limit=100');
    const wrap = $('#events-list');
    if (!events.length) {
      wrap.innerHTML = '<div class="empty">No events yet</div>';
      return;
    }
    wrap.innerHTML = events
      .map((e) => {
        const isFailover = e.type === 'failover';
        const isError = String(e.type).includes('error');
        const cls = [
          'event-row',
          isFailover ? 'failover' : '',
          isError ? 'error-type' : '',
        ]
          .filter(Boolean)
          .join(' ');
        const parts = [
          e.virtualModel && `model=${e.virtualModel}`,
          e.planId && `plan=${e.planId}`,
          e.statusCode != null && `status=${e.statusCode}`,
          e.latencyMs != null && `${e.latencyMs}ms`,
          e.message,
        ].filter(Boolean);
        return `<div class="${cls}">
          <span class="ts">${escapeHtml(fmtTs(e.ts))}</span>
          <span class="type">${escapeHtml(e.type)}</span>
          <span class="detail">${escapeHtml(parts.join(' · ') || e.requestId || '')}</span>
        </div>`;
      })
      .join('');
  }

  $('#btn-refresh-events').addEventListener('click', () => loadEvents().catch(console.error));

  // ── Settings ──────────────────────────────────────────────────────
  async function loadSettings() {
    const [cfg, meta] = await Promise.all([api('/config'), api('/meta')]);
    $('#settings-gatewayKey').value = '';
    $('#settings-gatewayKey').placeholder = cfg.settings.gatewayKeySet
      ? 'leave blank to keep existing'
      : 'gateway key';
    $('#settings-timeout').value = cfg.settings.requestTimeoutMs;
    $('#settings-maxFailover').value = cfg.settings.maxFailoverAttempts;
    $('#settings-host').value = cfg.settings.host;
    $('#settings-port').value = cfg.settings.port;
    $('#settings-config-path').textContent = meta.configPath || '—';
    $('#config-path').textContent = meta.configPath || '';
    show($('#settings-msg'), false);
    show($('#settings-error'), false);
  }

  $('#settings-form').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const msg = $('#settings-msg');
    const err = $('#settings-error');
    show(msg, false);
    show(err, false);
    const body = {
      requestTimeoutMs: Number($('#settings-timeout').value),
      maxFailoverAttempts: Number($('#settings-maxFailover').value),
      host: $('#settings-host').value.trim(),
      port: Number($('#settings-port').value),
    };
    const gk = $('#settings-gatewayKey').value;
    if (gk) body.gatewayKey = gk;
    try {
      await api('/settings', { method: 'PUT', body: JSON.stringify(body) });
      msg.textContent = 'Settings saved.';
      show(msg, true);
      $('#settings-gatewayKey').value = '';
    } catch (e) {
      err.textContent = e.message;
      show(err, true);
    }
  });

  $('#btn-export-config').addEventListener('click', async () => {
    try {
      const cfg = await api('/config');
      const blob = new Blob([JSON.stringify(cfg, null, 2)], { type: 'application/json' });
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'switchboard-config.json';
      a.click();
      URL.revokeObjectURL(a.href);
    } catch (e) {
      alert(e.message);
    }
  });

  // ── Boot ──────────────────────────────────────────────────────────
  async function boot() {
    try {
      const meta = await api('/meta');
      $('#config-path').textContent = meta.configPath || '';
    } catch {
      /* ignore */
    }
    showSection('overview');
  }

  // Auto-unlock if key already in session
  const existing = getKey();
  if (existing) {
    tryUnlock(existing);
  } else {
    show(authGate, true);
    show(appEl, false);
  }
})();
