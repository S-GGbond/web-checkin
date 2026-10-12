(function () {
  const $ = (id) => document.getElementById(id);
  const state = { accounts: [], refreshing: false, usageRecords: [], usagePage: 1, usagePageSize: 20, traeUsage: null, traeDetailPages: {}, traeDetailPageSize: 20 };

  function toast(message, type = "ok") {
    const item = document.createElement("div");
    item.className = `toast ${type}`;
    item.textContent = message;
    $("toasts").appendChild(item);
    setTimeout(() => item.remove(), 3600);
  }

  async function api(path, options = {}) {
    const config = { headers: {}, ...options };
    if (config.body) {
      config.headers["Content-Type"] = "application/json";
      config.body = JSON.stringify(config.body);
    }
    const response = await fetch(path, config);
    const text = await response.text();
    let data;
    try { data = text ? JSON.parse(text) : {}; } catch { data = { detail: text }; }
    if (!response.ok) throw new Error(data.detail || data.message || `HTTP ${response.status}`);
    return data;
  }

  function formatTime(value) {
    if (!value) return "--";
    const date = value > 1e12 ? new Date(value) : new Date(value * 1000);
    if (Number.isNaN(date.getTime())) return String(value);
    return date.toLocaleString("zh-CN", { hour12: false });
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
  }

  function isSameLocalDay(timestamp) {
    if (!timestamp) return false;
    const value = new Date(timestamp * 1000);
    const today = new Date();
    return value.getFullYear() === today.getFullYear() && value.getMonth() === today.getMonth() && value.getDate() === today.getDate();
  }

  function statusInfo(account) {
    const status = account.last_status || {};
    if (account.provider === "workbuddy") {
      const usage = status.usage || {};
      const credits = status.credits_left === -1 ? "不限" : status.credits_left;
      const total = status.credits_total === -1 ? "" : ` / ${status.credits_total ?? "--"}`;
      return { checked: !!status.today_checked_in, credits: credits == null ? "--" : `${credits}${total}`, extra: status.streak_days, label: "连续天数" };
    }
    if (account.provider === "qoder") {
      // 平台未提供明确“今日已签”字段；本地今天的成功领取也可作为补充状态。
      const claimedToday = account.last_checkin_ok === true && isSameLocalDay(account.last_checkin_at);
      const checked = status.claimedCount > 0 || claimedToday ? true : false;
      let checkedText = status.claimedCount > 0 || claimedToday ? "今日已签到" : "今日未签到";
      if (!status.claimedCount && !claimedToday && status.campaignCount === 0) checkedText = "暂无签到活动";
      else if (!status.claimedCount && !claimedToday && status.claimableCount === 0) checkedText = "无可领取活动";
      return { checked, checkedText, credits: null, extra: status.claimableCount ?? "--", label: "可领取" };
    }
    const credits = status.credits_left === -1 ? "不限" : status.credits_left;
    const total = status.credits_total === -1 ? "" : ` / ${status.credits_total ?? "--"}`;
    return { checked: !!status.checked_in, credits: credits == null ? "--" : `${credits}${total}`, extra: status.extra_credits, label: "明日基础" };
  }

  function providerIcon(provider) {
    const icons = {
      workbuddy: `<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M5 5.5h14a2.5 2.5 0 0 1 2.5 2.5v7a2.5 2.5 0 0 1-2.5 2.5h-6.3L8 21.5v-4H5A2.5 2.5 0 0 1 2.5 15V8A2.5 2.5 0 0 1 5 5.5Z" fill="currentColor"/><path d="M8.2 12.2h7.6" stroke="#0b1115" stroke-width="2" stroke-linecap="round"/></svg>`,
      trae: `<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M13.2 2.5 5.4 14.1h4.4L8.4 21.5l9.2-12.4h-4.6l.2-6.6Z" fill="currentColor"/></svg>`,
      qoder: `<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="4.5" stroke="currentColor" stroke-width="1.8"/><path d="m7.6 9.8 2.7 2.4-2.7 2.4" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/><path d="M12.9 14.6h3.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/></svg>`,
    };
    return icons[provider] || `<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><circle cx="12" cy="12" r="7.5" stroke="currentColor" stroke-width="1.8"/></svg>`;
  }

  function providerLabel(provider) {
    return { workbuddy: "WORKBUDDY", trae: "TRAE", qoder: "QODER" }[provider] || provider.toUpperCase();
  }

  function checkinText(account) {
    if (account.last_checkin_message) return account.last_checkin_message;
    if (account.last_checkin_at) return "已执行";
    return "今日未执行";
  }

  function renderAccounts() {
    const grid = $("accountGrid");
    $("accountCount").textContent = `${state.accounts.length} 个账号`;
    if (!state.accounts.length) {
      grid.innerHTML = `<div class="empty" style="grid-column:1/-1"><span class="empty-mark">＋</span><strong>还没有授权账号</strong><span>使用上方官方授权登录 WorkBuddy、Trae 或 Qoder</span></div>`;
      return;
    }
    const providerOrder = ["workbuddy", "trae", "qoder"];
    const groups = providerOrder.map((provider) => ({
      provider,
      accounts: state.accounts.filter((account) => account.provider === provider),
    })).filter((group) => group.accounts.length);
    grid.innerHTML = groups.map((group) => {
      const cards = group.accounts.map((account) => {
      const info = statusInfo(account);
      const checkedClass = info.checked === true ? "ok" : info.checked === false ? "warn" : "";
      const checkedText = info.checkedText || (info.checked ? "今日已签到" : "今日未签到");
      const checkinClass = account.last_checkin_ok === true ? "ok" : account.last_checkin_ok === false ? "err" : "";
      const time = account.schedule_time || "09:00";
      const isQoder = account.provider === "qoder";
      const qoderStatus = account.last_status || {};
      return `
        <article class="account-card ${account.provider} ${account.enabled ? "" : "is-disabled"}" data-id="${account.id}">
          <div class="account-top">
            <div class="account-identity">
              <span class="provider-mark">${providerIcon(account.provider)}</span>
              <div><h3 class="account-name">${escapeHtml(account.display_name || account.label || account.external_id)}</h3>
                <p class="account-id">${providerLabel(account.provider)} · ${escapeHtml(account.external_id)}</p></div>
            </div>
            <span class="provider-badge">${account.enabled ? "运行中" : "已停用"}</span>
          </div>
          <div class="balance-block ${!account.last_status && state.refreshing ? "is-loading" : ""}">
            <span>${isQoder ? "活动状态" : "当前可用余额"}</span>
            <div><strong>${isQoder ? `${escapeHtml(qoderStatus.claimableCount ?? "--")} 可领取` : escapeHtml(info.credits ?? "--")}</strong><small>${isQoder ? ` / ${escapeHtml(qoderStatus.campaignCount ?? "--")} 活动` : " credits"}</small></div>
            <span class="balance-caption">${account.last_status_at ? `更新于 ${formatTime(account.last_status_at)}` : state.refreshing ? "正在获取平台实时额度…" : "点击刷新余额获取最新数据"}</span>
          </div>
          <div class="account-metrics">
            <div><span>签到状态</span><strong class="metric-state ${info.checked ? "is-ok" : ""}">${checkedText}</strong></div>
            <div><span>连续/奖励</span><strong>${escapeHtml(info.extra ?? "--")}${info.label === "连续天数" ? " 天" : ""}</strong></div>
            <div><span>最近签到</span><strong>${account.last_checkin_at ? formatTime(account.last_checkin_at) : "暂无记录"}</strong></div>
          </div>
          <div class="schedule-control">
            <div><span class="schedule-label">每日自动签到</span><span class="schedule-subtitle">${account.schedule_enabled ? `每天 ${escapeHtml(time)} 执行` : "当前未启用"}</span></div>
            <label class="time-control"><span class="sr-only">每日签到时间</span><input type="time" value="${escapeHtml(time)}" data-schedule-time="${account.id}" aria-label="设置每日签到时间"></label>
            <button class="schedule-toggle ${account.schedule_enabled ? "active" : ""}" data-action="schedule-toggle" data-id="${account.id}" aria-label="${account.schedule_enabled ? "关闭" : "开启"}该账号定时签到">${account.schedule_enabled ? "定时开" : "定时关"}</button>
            <button class="schedule-toggle schedule-save" data-action="schedule" data-id="${account.id}" aria-label="保存每日签到时间">保存</button>
          </div>
          <div class="account-actions">
            <button class="btn ghost" data-action="refresh" data-id="${account.id}">${isQoder ? "刷新状态" : "刷新余额"}</button>
            <button class="btn primary" data-action="checkin" data-id="${account.id}">立即签到</button>
            <button class="btn ghost" data-action="toggle" data-id="${account.id}">${account.enabled ? "暂停账号" : "启用账号"}</button>
            <button class="btn danger" data-action="delete" data-id="${account.id}">移除</button>
          </div>
        </article>`;
      }).join("");
      return `
        <section class="provider-group">
          <header class="provider-group-head">
            <span class="provider-group-mark ${group.provider}">${providerIcon(group.provider)}</span>
            <div><h3>${escapeHtml(providerLabel(group.provider))}</h3><p>${group.accounts.length} 个账号</p></div>
          </header>
          <div class="provider-group-grid">${cards}</div>
        </section>`;
    }).join("");
  }

  function renderLogs(logs) {
    $("logList").innerHTML = logs.length ? logs.map((log) => `
      <div class="log-item">
        <div class="log-icon ${log.ok ? "ok" : "err"}">${log.ok ? "✓" : "✕"}</div>
        <div>
          <div class="log-title">${escapeHtml(log.display_name || log.label || log.provider)} · ${escapeHtml(log.action)}</div>
          <div class="log-message">${escapeHtml(log.message || "无详细信息")}</div>
        </div>
        <div class="log-time">${formatTime(log.created_at)}</div>
      </div>
    `).join("") : `<div class="empty">暂无日志</div>`;
  }

  function renderUsage(records) {
    state.usageRecords = records;
    state.usagePage = 1;
    $("usageCount").textContent = `${records.length} 条`;
    $("exportUsageBtn").disabled = records.length === 0;
    renderUsagePage();
    drawWorkBuddyUsageChart();
  }

  function usageTotalPages() {
    return Math.max(1, Math.ceil(state.usageRecords.length / state.usagePageSize));
  }

  function renderUsagePage() {
    const totalPages = usageTotalPages();
    state.usagePage = Math.min(Math.max(1, state.usagePage), totalPages);
    const start = (state.usagePage - 1) * state.usagePageSize;
    const records = state.usageRecords.slice(start, start + state.usagePageSize);
    $("usageRows").innerHTML = records.length ? records.map((record) => `
      <tr><td>${escapeHtml(record.requestTime || "--")}</td><td title="${escapeHtml(record.requestName)}">${escapeHtml(record.requestName || "--")}</td>
      <td>${escapeHtml(record.model || "未标记")}</td><td>${escapeHtml(record.client || "未标记")}</td>
      <td class="usage-credit">${escapeHtml(record.credit ?? 0)}</td></tr>
    `).join("") : `<tr><td colspan="5" class="usage-empty">该日期范围没有明细</td></tr>`;
    $("usagePageInfo").textContent = `第 ${state.usagePage} / ${totalPages} 页`;
    $("usagePrevPage").disabled = state.usagePage <= 1;
    $("usageNextPage").disabled = state.usagePage >= totalPages;
  }

  function aggregateDailyUsage(records) {
    const byDay = new Map();
    records.forEach((record) => {
      const raw = String(record.requestTime || "");
      const date = new Date(raw.includes("T") ? raw : raw.replace(" ", "T"));
      if (Number.isNaN(date.getTime())) return;
      const day = /^\d{4}-\d{2}-\d{2}/.exec(raw)?.[0] || date.toISOString().slice(0, 10);
      const item = byDay.get(day) || { date: day, credits: 0, requests: 0 };
      item.credits += Number(record.credit) || 0;
      item.requests += 1;
      byDay.set(day, item);
    });
    return [...byDay.values()].sort((left, right) => left.date.localeCompare(right.date));
  }

  function exportUsageCsv() {
    const quote = (value) => `"${String(value ?? "").replace(/"/g, '""')}"`;
    const rows = [["请求时间", "请求名", "模型", "客户端", "积分"], ...state.usageRecords.map((record) => [record.requestTime, record.requestName, record.model, record.client, record.credit])];
    const csv = "\ufeff" + rows.map((row) => row.map(quote).join(",")).join("\r\n");
    const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = `workbuddy-usage-${$("usageStart").value}-${$("usageEnd").value}.csv`;
    link.click();
    URL.revokeObjectURL(url);
  }

  function traeDetailRows(records) {
    if (!records.length) return `<tr><td colspan="5" class="usage-empty">没有更多明细</td></tr>`;
    return records.map((record) => `
      <tr>
        <td>${escapeHtml(record.time || "--")}</td>
        <td title="${escapeHtml(record.model || "未标记")}">${escapeHtml(record.model || "未标记")}</td>
        <td>${escapeHtml(record.source || "--")}</td>
        <td class="usage-credit">${Number(record.credits || 0).toLocaleString("zh-CN", { maximumFractionDigits: 4 })}</td>
        <td title="${escapeHtml(record.record || "无使用记录")}">${escapeHtml(record.record || "无使用记录")}</td>
      </tr>`).join("");
  }

  function updateTraeDetailControls(card, accountId) {
    const account = state.traeUsage?.accounts?.find((item) => String(item.accountId) === accountId);
    const items = account?.items || [];
    const totalPages = Math.max(1, Math.ceil(items.length / state.traeDetailPageSize));
    const page = Math.min(Math.max(1, state.traeDetailPages[accountId] || 1), totalPages);
    const start = (page - 1) * state.traeDetailPageSize;
    card.querySelector("[data-trae-detail-body]").innerHTML = traeDetailRows(items.slice(start, start + state.traeDetailPageSize));
    card.querySelector("[data-trae-page-info]").textContent = `第 ${page} / ${totalPages} 页`;
    card.querySelector('[data-trae-detail="prev"]').disabled = page <= 1;
    card.querySelector('[data-trae-detail="next"]').disabled = page >= totalPages;
  }

  function renderTraeUsage(data) {
    state.traeUsage = data;
    state.traeDetailPages = {};
    const successful = data.accounts.filter((account) => account.ok);
    const requestLabel = `${data.requestCount} 次请求`;
    $("traeUsageCount").textContent = `${successful.length} / ${data.accounts.length} 个账号 · ${requestLabel}`;
    $("traeUsageSummary").innerHTML = successful.length ? `
      <div class="trae-total"><span>区间积分消耗</span><strong>${Number(data.totalCredits).toLocaleString("zh-CN", { maximumFractionDigits: 4 })}</strong><small>credits</small></div>
      <div class="trae-summary-meta"><span><strong>${data.requestCount}</strong> 次请求</span><span><strong>${successful.length}</strong> 个账号成功</span>${data.failedCount ? `<span class="usage-error-text"><strong>${data.failedCount}</strong> 个账号失败</span>` : ""}</div>
    ` : `<div class="usage-placeholder">${data.accounts.length ? "所选日期范围内没有用量记录" : "当前没有 Trae 授权账号"}</div>`;
    $("traeUsageAccounts").innerHTML = data.accounts.length ? data.accounts.map((account) => {
      if (!account.ok) return `<article class="trae-account-usage is-error"><div><h3>${escapeHtml(account.name)}</h3><p>${escapeHtml(account.externalId)}</p></div><div class="usage-account-error">${escapeHtml(account.message || "查询失败")}</div></article>`;
      const daily = account.daily || [];
      const modelRows = (account.models || []).slice(0, 5).map((model) => `<li><span>${escapeHtml(model.model)}</span><strong>${Number(model.credits).toLocaleString("zh-CN", { maximumFractionDigits: 4 })}</strong><small>${model.requests} 次</small></li>`).join("");
      const items = account.items || [];
      const totalPages = Math.max(1, Math.ceil(items.length / state.traeDetailPageSize));
      const page = Math.min(1, totalPages);
      state.traeDetailPages[account.accountId] = page;
      const detailRows = traeDetailRows(items.slice(0, state.traeDetailPageSize));
      return `<article class="trae-account-usage" data-account="${account.accountId}">
        <header class="trae-account-head"><div><h3>${escapeHtml(account.name)}</h3><p>${escapeHtml(account.externalId)} · ${account.requestCount} 次请求</p></div><div class="trae-account-total"><strong>${Number(account.totalCredits).toLocaleString("zh-CN", { maximumFractionDigits: 4 })}</strong><span>credits</span></div></header>
        <div class="usage-chart-wrap"><canvas class="usage-chart trae-usage-chart" role="img" aria-label="${escapeHtml(account.name)} 每日积分消耗曲线" data-points='${escapeHtml(JSON.stringify(daily))}'></canvas></div>
        <div class="usage-account-bottom"><div><span class="usage-subhead">模型消耗</span>${modelRows ? `<ul class="usage-model-list">${modelRows}</ul>` : `<p class="usage-no-data">暂无模型明细</p>`}</div><div class="usage-subhead">${data.start} 至 ${data.end}</div></div>
        ${items.length ? `<details class="usage-details"><summary>查看 ${account.requestCount} 条用量明细</summary><div class="usage-detail-pagination"><button class="btn ghost small" type="button" data-trae-detail="prev" data-account="${account.accountId}" ${page <= 1 ? "disabled" : ""}>上一页</button><span data-trae-page-info>第 ${page} / ${totalPages} 页</span><button class="btn ghost small" type="button" data-trae-detail="next" data-account="${account.accountId}" ${page >= totalPages ? "disabled" : ""}>下一页</button></div><div class="usage-detail-table-wrap"><table><thead><tr><th>时间</th><th>模型</th><th>客户端</th><th>积分</th><th>使用记录</th></tr></thead><tbody>${detailRows}</tbody></table></div></details>` : ""}
      </article>`;
    }).join("") : "";
    drawUsageCharts();
  }

  $("traeUsageAccounts").addEventListener("click", (event) => {
    const button = event.target.closest("[data-trae-detail]");
    if (!button || button.disabled) return;
    const card = button.closest(".trae-account-usage");
    const accountId = button.dataset.account;
    const direction = button.dataset.traeDetail === "next" ? 1 : -1;
    state.traeDetailPages[accountId] = (state.traeDetailPages[accountId] || 1) + direction;
    updateTraeDetailControls(card, accountId);
  });

  function drawUsageCharts() {
    document.querySelectorAll(".trae-usage-chart").forEach((canvas) => {
      const points = JSON.parse(canvas.dataset.points || "[]");
      const width = Math.max(280, Math.floor(canvas.clientWidth));
      const height = 170;
      const ratio = window.devicePixelRatio || 1;
      canvas.width = width * ratio;
      canvas.height = height * ratio;
      canvas.style.height = `${height}px`;
      const ctx = canvas.getContext("2d");
      ctx.scale(ratio, ratio);
      const left = 42, right = 12, top = 15, bottom = 28;
      const plotWidth = width - left - right, plotHeight = height - top - bottom;
      const max = Math.max(1, ...points.map((point) => Number(point.credits) || 0));
      ctx.font = "11px system-ui, sans-serif";
      ctx.lineWidth = 1;
      for (let tick = 0; tick < 4; tick += 1) {
        const y = top + plotHeight * tick / 3;
        ctx.strokeStyle = "rgba(211,225,225,.1)";
        ctx.beginPath(); ctx.moveTo(left, y); ctx.lineTo(width - right, y); ctx.stroke();
        ctx.fillStyle = "#829396";
        ctx.textAlign = "right";
        ctx.fillText((max * (1 - tick / 3)).toLocaleString("zh-CN", { maximumFractionDigits: 1 }), left - 8, y + 4);
      }
      if (!points.length) return;
      const coords = points.map((point, index) => ({
        x: left + (points.length === 1 ? plotWidth / 2 : plotWidth * index / (points.length - 1)),
        y: top + plotHeight * (1 - (Number(point.credits) || 0) / max),
        point,
      }));
      ctx.beginPath();
      coords.forEach(({ x, y }, index) => index ? ctx.lineTo(x, y) : ctx.moveTo(x, y));
      ctx.strokeStyle = "#70c9a5"; ctx.lineWidth = 2; ctx.stroke();
      coords.forEach(({ x, y, point }) => {
        ctx.beginPath(); ctx.arc(x, y, 3, 0, Math.PI * 2); ctx.fillStyle = "#a5ebca"; ctx.fill();
        if (points.length <= 10 || x === coords[coords.length - 1].x || x === coords[0].x) {
          ctx.fillStyle = "#829396"; ctx.textAlign = "center";
          ctx.fillText(point.date.slice(5), x, height - 8);
        }
      });
    });
  }

  function drawWorkBuddyUsageChart() {
    const canvas = $("usageChart");
    const points = aggregateDailyUsage(state.usageRecords);
    const width = Math.max(280, Math.floor(canvas.clientWidth));
    const height = Math.max(220, Math.floor(canvas.clientHeight));
    const ratio = window.devicePixelRatio || 1;
    canvas.width = width * ratio;
    canvas.height = height * ratio;
    const ctx = canvas.getContext("2d");
    ctx.scale(ratio, ratio);
    const left = 42, right = 12, top = 15, bottom = 28;
    const plotWidth = width - left - right, plotHeight = height - top - bottom;
    const max = Math.max(1, ...points.map((point) => Number(point.credits) || 0));
    ctx.font = "11px system-ui, sans-serif";
    ctx.lineWidth = 1;
    for (let tick = 0; tick < 4; tick += 1) {
      const y = top + plotHeight * tick / 3;
      ctx.strokeStyle = "rgba(211,225,225,.1)";
      ctx.beginPath(); ctx.moveTo(left, y); ctx.lineTo(width - right, y); ctx.stroke();
      ctx.fillStyle = "#829396";
      ctx.textAlign = "right";
      ctx.fillText((max * (1 - tick / 3)).toLocaleString("zh-CN", { maximumFractionDigits: 1 }), left - 8, y + 4);
    }
    if (!points.length) {
      $("usageChartMeta").textContent = "暂无数据";
      return;
    }
    const coords = points.map((point, index) => ({
      x: left + (points.length === 1 ? plotWidth / 2 : plotWidth * index / (points.length - 1)),
      y: top + plotHeight * (1 - (Number(point.credits) || 0) / max),
      point,
    }));
    ctx.beginPath();
    coords.forEach(({ x, y }, index) => index ? ctx.lineTo(x, y) : ctx.moveTo(x, y));
    ctx.strokeStyle = "#70c9a5"; ctx.lineWidth = 2; ctx.stroke();
    coords.forEach(({ x, y, point }) => {
      ctx.beginPath(); ctx.arc(x, y, 3, 0, Math.PI * 2); ctx.fillStyle = "#a5ebca"; ctx.fill();
      if (points.length <= 10 || x === coords[coords.length - 1].x || x === coords[0].x) {
        ctx.fillStyle = "#829396"; ctx.textAlign = "center";
        ctx.fillText(point.date.slice(5), x, height - 8);
      }
    });
    $("usageChartMeta").textContent = `${points.length} 天 · ${Number(points.reduce((sum, point) => sum + point.credits, 0)).toLocaleString("zh-CN", { maximumFractionDigits: 4 })} credits`;
  }

  $("traeUsageForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = $("queryTraeUsageBtn");
    button.disabled = true;
    button.textContent = "查询中…";
    $("traeUsageCount").textContent = "正在查询各 Trae 账号";
    $("traeUsageSummary").innerHTML = `<div class="usage-placeholder is-loading" role="status">正在加载用量数据…</div>`;
    $("traeUsageAccounts").innerHTML = "";
    try {
      const result = await api("/api/trae/usage", {
        method: "POST",
        body: { start: $("traeUsageStart").value, end: $("traeUsageEnd").value },
      });
      renderTraeUsage(result);
      toast(result.failedCount ? `查询完成，${result.failedCount} 个账号失败` : "Trae 用量查询完成", result.failedCount ? "warn" : "ok");
    } catch (error) {
      $("traeUsageCount").textContent = "";
      $("traeUsageSummary").innerHTML = `<div class="usage-placeholder usage-error-text" role="alert">${escapeHtml(error.message)}</div>`;
      toast(`Trae 用量查询失败：${error.message}`, "err");
    } finally {
      button.disabled = false;
      button.textContent = "查询用量";
    }
  });

  window.addEventListener("resize", () => {
    drawUsageCharts();
    drawWorkBuddyUsageChart();
  });

  $("usageForm").addEventListener("submit", async (event) => {
    event.preventDefault();
    const button = $("queryUsageBtn");
    const cookie = $("usageCookie").value.trim();
    $("usageCookie").value = "";
    button.disabled = true;
    button.textContent = "查询中…";
    try {
      const result = await api("/api/workbuddy/usage", {
        method: "POST",
        body: {
          start: $("usageStart").value,
          end: $("usageEnd").value,
          cookie,
          user_agent: navigator.userAgent,
        },
      });
      renderUsage(result.records || []);
      toast(`查询完成，共 ${result.count ?? 0} 条`);
    } catch (error) {
      toast(error.message, "err");
    } finally {
      $("usageCookie").value = "";
      button.disabled = false;
      button.textContent = "查询明细";
    }
  });
  $("exportUsageBtn").addEventListener("click", exportUsageCsv);
  $("usagePrevPage").addEventListener("click", () => {
    state.usagePage -= 1;
    renderUsagePage();
  });
  $("usageNextPage").addEventListener("click", () => {
    state.usagePage += 1;
    renderUsagePage();
  });
  $("usagePageSize").addEventListener("change", (event) => {
    state.usagePageSize = Number(event.target.value) || 20;
    state.usagePage = 1;
    renderUsagePage();
  });
  const today = new Date();
  const weekAgo = new Date(today);
  weekAgo.setDate(today.getDate() - 6);
  const localDate = (date) => `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
  $("usageStart").value = localDate(weekAgo);
  $("usageEnd").value = localDate(today);
  const traeWeekStart = new Date(today);
  traeWeekStart.setDate(today.getDate() - 6);
  $("traeUsageStart").value = localDate(traeWeekStart);
  $("traeUsageEnd").value = localDate(today);
  drawWorkBuddyUsageChart();

  function renderStats() {
    $("statTotal").textContent = state.accounts.length;
    $("statEnabled").textContent = state.accounts.filter((item) => item.enabled).length;
    $("statChecked").textContent = state.accounts.filter((item) => statusInfo(item).checked).length;
    $("statScheduled").textContent = state.accounts.filter((item) => item.schedule_enabled).length;
  }

  async function loadAccounts() {
    const data = await api("/api/accounts");
    state.accounts = data.accounts || [];
    renderAccounts();
    renderStats();
  }

  async function loadLogs() {
    const data = await api("/api/logs?limit=80");
    renderLogs(data.logs || []);
  }

  async function loadAll() {
    await Promise.all([loadAccounts(), loadLogs()]);
  }

  async function refreshBalancesOnOpen() {
    if (!state.accounts.length) return;
    state.refreshing = true;
    renderAccounts();
    try {
      await api("/api/status", { method: "POST" });
    } catch (error) {
      toast(`余额刷新未完成：${error.message}`, "warn");
    } finally {
      state.refreshing = false;
      await Promise.all([loadAccounts(), loadLogs()]);
    }
  }

  const modal = $("loginModal");
  let polling = null;
  function showLoginModal(provider, data) {
    $("loginTitle").textContent = { workbuddy: "WorkBuddy 登录", trae: "Trae 登录", qoder: "Qoder 登录" }[provider] || "登录中";
    $("loginMessage").textContent = data.message || "等待授权";
    $("loginUrl").textContent = data.auth_url || "";
    $("openLoginUrl").href = data.auth_url || "#";
    modal.classList.remove("hidden");
    if (polling) clearInterval(polling);
    polling = setInterval(async () => {
      try {
        const status = await api(`/api/login/${provider}/${data.id}`);
        $("loginMessage").textContent = status.message || status.status;
        if (["success", "failed"].includes(status.status)) {
          clearInterval(polling);
          polling = null;
          setTimeout(() => modal.classList.add("hidden"), 500);
          toast(status.message, status.status === "success" ? "ok" : "err");
          await loadAll();
          if (status.status === "success") await refreshBalancesOnOpen();
        }
      } catch (error) {
        clearInterval(polling);
        polling = null;
        modal.classList.add("hidden");
        toast(error.message, "err");
      }
    }, 1200);
  }

  async function startLogin(provider) {
    try {
      const data = await api(`/api/login/${provider}`, { method: "POST", body: { auto_browser: false, label: "" } });
      showLoginModal(provider, data);
      window.open(data.auth_url, "_blank", "noopener");
    } catch (error) {
      toast(error.message, "err");
    }
  }

  $("accountGrid").addEventListener("click", async (event) => {
    const button = event.target.closest("button[data-action]");
    if (!button) return;
    const id = button.dataset.id;
    const action = button.dataset.action;
    button.disabled = true;
    try {
      if (action === "refresh") {
        await api(`/api/accounts/${id}/status`, { method: "POST" });
        toast("平台余额已刷新");
      } else if (action === "schedule") {
        const card = button.closest(".account-card");
        const account = state.accounts.find((item) => String(item.id) === id);
        const time = card.querySelector(`[data-schedule-time="${id}"]`).value;
        await api(`/api/accounts/${id}/schedule`, { method: "POST", body: { enabled: account.schedule_enabled, time } });
        toast(account.schedule_enabled ? `每日签到时间已更新为 ${time}` : `已保存时间 ${time}，开启定时后生效`);
      } else if (action === "schedule-toggle") {
        const card = button.closest(".account-card");
        const account = state.accounts.find((item) => String(item.id) === id);
        const time = card.querySelector(`[data-schedule-time="${id}"]`).value;
        await api(`/api/accounts/${id}/schedule`, { method: "POST", body: { enabled: !account.schedule_enabled, time } });
        toast(account.schedule_enabled ? "已关闭该账号的定时签到" : `已开启每日 ${time} 自动签到`);
      } else if (action === "checkin") {
        const result = await api(`/api/accounts/${id}/checkin`, { method: "POST" });
        toast(result.result.message || "签到完成", result.ok ? "ok" : "err");
      } else if (action === "toggle") {
        const account = state.accounts.find((item) => String(item.id) === id);
        await api(`/api/accounts/${id}/enable?enabled=${!account.enabled}`, { method: "POST" });
        toast("已更新启用状态");
      } else if (action === "delete") {
        if (!confirm("确定删除该账号登录态吗？")) return;
        await api(`/api/accounts/${id}`, { method: "DELETE" });
        toast("账号已删除");
      }
      await loadAll();
    } catch (error) {
      toast(error.message, "err");
    } finally {
      button.disabled = false;
    }
  });

  $("refreshAllBtn").addEventListener("click", async (event) => {
    const button = event.currentTarget;
    button.disabled = true;
    try {
      const result = await api("/api/status", { method: "POST" });
      const failed = result.results.filter((item) => !item.ok).length;
      toast(failed ? `刷新完成，${failed} 个失败` : "全部状态已刷新", failed ? "warn" : "ok");
      await loadAll();
    } catch (error) {
      toast(error.message, "err");
    } finally {
      button.disabled = false;
    }
  });

  $("checkinAllBtn").addEventListener("click", async (event) => {
    const button = event.currentTarget;
    button.disabled = true;
    try {
      const result = await api("/api/checkin", { method: "POST" });
      const failed = result.results.filter((item) => !item.ok).length;
      toast(failed ? `签到完成，${failed} 个失败` : "全部签到成功", failed ? "warn" : "ok");
      await loadAll();
    } catch (error) {
      toast(error.message, "err");
    } finally {
      button.disabled = false;
    }
  });

  document.querySelectorAll("[data-login]").forEach((button) => button.addEventListener("click", () => startLogin(button.dataset.login)));
  $("reloadLogsBtn").addEventListener("click", loadLogs);
  $("closeLoginModal").addEventListener("click", () => { if (polling) clearInterval(polling); modal.classList.add("hidden"); });
  $("copyLoginUrl").addEventListener("click", async () => {
    try { await navigator.clipboard.writeText($("loginUrl").textContent); toast("链接已复制"); } catch { toast("复制失败", "err"); }
  });

  loadAll().then(refreshBalancesOnOpen).catch((error) => toast(error.message, "err"));
})();
