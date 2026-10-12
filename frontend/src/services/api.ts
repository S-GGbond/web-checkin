// 数据访问层：直接对接本项目 FastAPI 后端（替换原 zip 中的 localStorage mock）。

import {
  Account,
  LogEntry,
  SystemStats,
  WorkBuddyUsageRecord,
  TraeUsageAccount,
  Platform,
  LoginInitResponse,
  LoginStatusResponse,
  PlatformStatus,
} from '../types';

/** 后端返回的原始账号结构（见 /api/accounts）。 */
interface RawAccount {
  id: number;
  provider: Platform;
  external_id: string;
  display_name: string;
  label: string;
  enabled: boolean;
  schedule_enabled: boolean;
  schedule_time: string;
  created_at: number;
  updated_at: number;
  last_status_at: number | null;
  last_checkin_at: number | null;
  last_checkin_ok: boolean | null;
  last_checkin_message: string | null;
  last_status: Record<string, any> | null;
}

interface RawLog {
  id: number;
  account_id: number;
  display_name: string | null;
  label: string | null;
  provider: Platform;
  action: string;
  ok: boolean;
  message: string | null;
  created_at: number;
}

function toIso(epoch?: number | null): string | undefined {
  if (!epoch) return undefined;
  return new Date(epoch * 1000).toISOString();
}

function toLocalText(epoch?: number | null): string {
  if (!epoch) return '';
  const d = new Date(epoch * 1000);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(
    d.getMinutes()
  )}:${pad(d.getSeconds())}`;
}

function mapLastStatus(raw: RawAccount): PlatformStatus | undefined {
  const s = raw.last_status;
  if (!s) return undefined;
  const queryTime = toLocalText(raw.last_status_at);
  if (raw.provider === 'workbuddy') {
    return {
      checked_in_today: !!s.today_checked_in,
      credits_left: typeof s.credits_left === 'number' ? s.credits_left : 0,
      credits_total: typeof s.credits_total === 'number' ? s.credits_total : 0,
      streak_days: Number(s.streak_days) || 0,
      active: s.active,
      last_query_time: queryTime,
    };
  }
  if (raw.provider === 'trae') {
    return {
      checked_in_today: !!s.checked_in,
      credits_left: typeof s.credits_left === 'number' ? s.credits_left : 0,
      credits_total: typeof s.credits_total === 'number' ? s.credits_total : 0,
      extra_credits: Number(s.extra_credits) || 0,
      last_query_time: queryTime,
    };
  }
  return {
    campaignCount: Number(s.campaignCount) || 0,
    claimableCount: Number(s.claimableCount) || 0,
    claimedCount: Number(s.claimedCount) || 0,
    last_query_time: queryTime,
  };
}

function mapAccount(raw: RawAccount): Account {
  const time = raw.schedule_time || '09:00';
  const [h, m] = time.split(':');
  return {
    id: String(raw.id),
    platform: raw.provider,
    name: raw.display_name || raw.label || raw.external_id,
    external_id: raw.external_id,
    is_active: !!raw.enabled,
    schedule_enabled: !!raw.schedule_enabled,
    schedule_time: time,
    schedule_cron: `${parseInt(m || '0', 10)} ${parseInt(h || '9', 10)} * * *`,
    schedule_time_desc: `每日 ${time}`,
    created_at: toIso(raw.created_at) || new Date().toISOString(),
    updated_at: toIso(raw.updated_at) || new Date().toISOString(),
    last_run_at: toIso(raw.last_checkin_at),
    last_run_status:
      raw.last_checkin_ok === true
        ? 'success'
        : raw.last_checkin_ok === false
        ? 'failed'
        : 'pending',
    last_checkin_message: raw.last_checkin_message || undefined,
    last_status: mapLastStatus(raw),
  };
}

function mapLog(raw: RawLog): LogEntry {
  return {
    id: String(raw.id),
    account_id: String(raw.account_id),
    account_name: raw.display_name || raw.label || raw.provider,
    platform: raw.provider,
    action: raw.action,
    status: raw.ok ? 'success' : 'failed',
    timestamp: toLocalText(raw.created_at),
    message: raw.message || '无详细信息',
    duration_ms: 0,
  };
}

class ApiService {
  private async request<T>(
    path: string,
    options: Omit<RequestInit, 'body'> & { body?: unknown } = {}
  ): Promise<T> {
    const config: RequestInit = { ...options } as RequestInit;
    if (config.body !== undefined) {
      config.headers = { 'Content-Type': 'application/json', ...(config.headers || {}) };
      config.body = JSON.stringify(config.body);
    }
    const response = await fetch(path, config);
    const text = await response.text();
    let data: any = {};
    try {
      data = text ? JSON.parse(text) : {};
    } catch {
      data = { detail: text };
    }
    if (!response.ok) {
      throw new Error(data?.detail || data?.message || `HTTP ${response.status}`);
    }
    return data as T;
  }

  async getAccounts(): Promise<Account[]> {
    const data = await this.request<{ accounts: RawAccount[] }>('/api/accounts');
    return (data.accounts || []).map(mapAccount);
  }

  async getStats(): Promise<SystemStats> {
    const accounts = await this.getAccounts();
    const platform_counts = { workbuddy: 0, trae: 0, qoder: 0 };
    let checked_in_today = 0;
    let unchecked_today = 0;
    let scheduled_accounts = 0;
    let wb_left = 0;
    let wb_unlimited = false;
    let trae_left = 0;
    let trae_unlimited = false;

    for (const acc of accounts) {
      platform_counts[acc.platform] += 1;
      if (acc.schedule_enabled && acc.is_active) scheduled_accounts += 1;
      const s = acc.last_status as any;
      const checked =
        acc.platform === 'workbuddy'
          ? !!s?.checked_in_today
          : acc.platform === 'trae'
          ? !!s?.checked_in_today
          : !!s && (s.claimedCount > 0 || acc.last_run_status === 'success');
      if (checked) checked_in_today += 1;
      else unchecked_today += 1;

      if (acc.platform === 'workbuddy' && s) {
        if (s.credits_left === -1) wb_unlimited = true;
        else wb_left += s.credits_left || 0;
      }
      if (acc.platform === 'trae' && s) {
        if (s.credits_left === -1) trae_unlimited = true;
        else trae_left += s.credits_left || 0;
      }
    }

    return {
      total_accounts: accounts.length,
      checked_in_today,
      unchecked_today,
      scheduled_accounts,
      workbuddy_credits_left: wb_left,
      workbuddy_has_unlimited: wb_unlimited,
      trae_credits_left: trae_left,
      trae_has_unlimited: trae_unlimited,
      platform_counts,
    };
  }

  async checkInAccount(id: string): Promise<void> {
    const res = await this.request<{ ok: boolean; result: { ok: boolean; message?: string } }>(
      `/api/accounts/${id}/checkin`,
      { method: 'POST' }
    );
    if (!res.result?.ok) {
      throw new Error(res.result?.message || '签到失败');
    }
  }

  async checkInAll(): Promise<{
    total: number;
    success_count: number;
    failed_count: number;
    results: Array<{ id: string; name: string; success: boolean; message: string }>;
  }> {
    const res = await this.request<{
      results: Array<{ account_id: number; provider: Platform; display_name: string; ok: boolean; message?: string }>;
    }>('/api/checkin', { method: 'POST' });
    const results = (res.results || []).map((item) => ({
      id: String(item.account_id),
      name: item.display_name || String(item.account_id),
      success: !!item.ok,
      message: item.message || (item.ok ? '签到成功' : '签到失败'),
    }));
    const success_count = results.filter((r) => r.success).length;
    return {
      total: results.length,
      success_count,
      failed_count: results.length - success_count,
      results,
    };
  }

  async refreshAccount(id: string): Promise<void> {
    await this.request(`/api/accounts/${id}/status`, { method: 'POST' });
  }

  async updateAccount(
    id: string,
    data: { is_active?: boolean; schedule_enabled?: boolean; schedule_time?: string }
  ): Promise<void> {
    if (data.is_active !== undefined) {
      await this.request(`/api/accounts/${id}/enable?enabled=${data.is_active}`, { method: 'POST' });
    }
    if (data.schedule_enabled !== undefined || data.schedule_time !== undefined) {
      const accounts = await this.getAccounts();
      const current = accounts.find((a) => a.id === id);
      const enabled = data.schedule_enabled ?? current?.schedule_enabled ?? true;
      const time = data.schedule_time ?? current?.schedule_time ?? '09:00';
      await this.request(`/api/accounts/${id}/schedule`, {
        method: 'POST',
        body: { enabled, time },
      });
    }
  }

  async deleteAccount(id: string): Promise<void> {
    await this.request(`/api/accounts/${id}`, { method: 'DELETE' });
  }

  async getLogs(limit = 200): Promise<LogEntry[]> {
    const data = await this.request<{ logs: RawLog[] }>(`/api/logs?limit=${limit}`);
    return (data.logs || []).map(mapLog);
  }

  async getWorkBuddyUsage(
    start: string,
    end: string,
    cookie: string,
    userAgent: string
  ): Promise<{ records: WorkBuddyUsageRecord[]; count: number }> {
    const data = await this.request<{ count: number; records: any[] }>('/api/workbuddy/usage', {
      method: 'POST',
      body: { start, end, cookie, user_agent: userAgent },
    });
    const records: WorkBuddyUsageRecord[] = (data.records || []).map((r, index) => ({
      id: `wb_${index}`,
      requestTime: r.requestTime || '',
      requestName: r.requestName || '--',
      model: r.model || '未标记',
      client: r.client || '未标记',
      credit: Number(r.credit) || 0,
    }));
    return { records, count: data.count ?? records.length };
  }

  exportWorkBuddyCsv(records: WorkBuddyUsageRecord[]): string {
    const quote = (value: any) => `"${String(value ?? '').replace(/"/g, '""')}"`;
    const rows = [
      ['请求时间', '请求名', '模型', '客户端', '积分'],
      ...records.map((r) => [r.requestTime, r.requestName, r.model, r.client, r.credit]),
    ];
    return '\uFEFF' + rows.map((row) => row.map(quote).join(',')).join('\r\n');
  }

  async getTraeUsage(start: string, end: string): Promise<{
    start: string;
    end: string;
    total_credits: number;
    request_count: number;
    failed_count: number;
    accounts: TraeUsageAccount[];
  }> {
    const data = await this.request<{
      start: string;
      end: string;
      totalCredits: number;
      requestCount: number;
      failedCount: number;
      accounts: any[];
    }>('/api/trae/usage', { method: 'POST', body: { start, end } });

    const accounts: TraeUsageAccount[] = (data.accounts || []).map((acc) => {
      const daily = (acc.daily || []).map((d: any) => ({
        date: d.date,
        credits: Number(d.credits) || 0,
        requests: Number(d.requests) || 0,
      }));
      const modelList = (acc.models || []).map((m: any) => ({
        model: m.model || '未标记',
        credits: Number(m.credits) || 0,
        requests: Number(m.requests) || 0,
      }));
      const modelBreakdown: Record<string, number> = {};
      modelList.forEach((m: any) => {
        modelBreakdown[m.model] = m.credits;
      });
      const items = (acc.items || []).map((it: any) => ({
        time: it.time || '',
        model: it.model || '未标记',
        source: it.source || '--',
        credits: Number(it.credits) || 0,
        record: it.record || '',
      }));
      return {
        account_id: String(acc.accountId ?? ''),
        account_name: acc.name || acc.externalId || '未知账号',
        external_id: String(acc.externalId || ''),
        ok: !!acc.ok,
        message: acc.message,
        total_credits: Number(acc.totalCredits) || 0,
        request_count: Number(acc.requestCount) || 0,
        daily_trend: daily,
        model_breakdown: modelBreakdown,
        model_list: modelList,
        items,
      };
    });

    return {
      start: data.start,
      end: data.end,
      total_credits: Number(data.totalCredits) || 0,
      request_count: Number(data.requestCount) || 0,
      failed_count: Number(data.failedCount) || 0,
      accounts,
    };
  }

  async initLogin(platform: Platform): Promise<LoginInitResponse> {
    const data = await this.request<{
      id: string;
      auth_url: string;
      message: string;
      status: string;
    }>(`/api/login/${platform}`, {
      method: 'POST',
      body: { auto_browser: false, label: '' },
    });
    return {
      id: data.id,
      auth_url: data.auth_url,
      message: data.message || '请在打开的授权页面完成登录',
      status: data.status || 'waiting',
    };
  }

  async pollLoginStatus(platform: Platform, id: string): Promise<LoginStatusResponse> {
    const data = await this.request<{
      status: LoginStatusResponse['status'];
      message: string;
      account?: { id: number; name: string; external_id: string };
    }>(`/api/login/${platform}/${id}`);
    return { status: data.status, message: data.message, account: data.account };
  }
}

export const apiService = new ApiService();
