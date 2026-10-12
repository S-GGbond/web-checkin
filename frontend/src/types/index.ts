// 类型定义：对齐本项目 FastAPI 后端的数据契约（WorkBuddy / Trae / Qoder）。

export type Platform = 'workbuddy' | 'trae' | 'qoder';

export type RunStatus = 'success' | 'failed' | 'pending' | 'running';

/** WorkBuddy 平台状态（credits_left / credits_total 为 -1 表示不限）。 */
export interface WorkBuddyStatus {
  checked_in_today: boolean;
  credits_left: number;
  credits_total: number;
  streak_days: number;
  active?: boolean;
  last_query_time?: string;
}

/** Trae 平台状态。 */
export interface TraeStatus {
  checked_in_today: boolean;
  credits_left: number;
  credits_total: number;
  extra_credits: number;
  last_query_time?: string;
}

/** Qoder 平台状态：平台没有明确的“今日已签”字段，只有活动领取计数。 */
export interface QoderStatus {
  campaignCount: number;
  claimableCount: number;
  claimedCount: number;
  last_query_time?: string;
}

export type PlatformStatus = WorkBuddyStatus | TraeStatus | QoderStatus;

export interface Account {
  id: string;
  platform: Platform;
  name: string;
  external_id: string;
  /** 账号启用状态（停用后不参与定时）。 */
  is_active: boolean;
  /** 独立定时开关。 */
  schedule_enabled: boolean;
  /** 每日签到时间 "HH:MM"。 */
  schedule_time: string;
  /** 由 schedule_time 派生，仅用于展示。 */
  schedule_cron: string;
  schedule_time_desc: string;
  created_at: string;
  updated_at: string;
  last_run_at?: string;
  last_run_status?: RunStatus;
  last_checkin_message?: string;
  last_status?: PlatformStatus;
}

export interface LogEntry {
  id: string;
  account_id?: string;
  account_name?: string;
  platform: Platform | 'system';
  action: string;
  status: 'success' | 'failed' | 'running' | 'warn' | 'info';
  timestamp: string;
  message: string;
  duration_ms: number;
  details?: Record<string, any>;
}

/** WorkBuddy 用量为逐条请求明细（单位：积分 credit）。 */
export interface WorkBuddyUsageRecord {
  id: string;
  requestTime: string;
  requestName: string;
  model: string;
  client: string;
  credit: number;
}

export interface TraeUsageDaily {
  date: string;
  credits: number;
  requests: number;
}

export interface TraeUsageModel {
  model: string;
  credits: number;
  requests: number;
}

export interface TraeUsageItem {
  time: string;
  model: string;
  source: string;
  credits: number;
  record: string;
}

export interface TraeUsageAccount {
  account_id: string;
  account_name: string;
  external_id: string;
  ok: boolean;
  message?: string;
  total_credits: number;
  request_count: number;
  daily_trend: TraeUsageDaily[];
  model_breakdown: Record<string, number>;
  model_list: TraeUsageModel[];
  items: TraeUsageItem[];
}

export interface SystemStats {
  total_accounts: number;
  checked_in_today: number;
  unchecked_today: number;
  scheduled_accounts: number;
  workbuddy_credits_left: number;
  workbuddy_has_unlimited: boolean;
  trae_credits_left: number;
  trae_has_unlimited: boolean;
  platform_counts: { workbuddy: number; trae: number; qoder: number };
}

export interface LoginInitResponse {
  id: string;
  auth_url: string;
  message: string;
  status: string;
}

export interface LoginStatusResponse {
  status: 'waiting' | 'exchanging' | 'success' | 'failed';
  message: string;
  account?: { id: number; name: string; external_id: string };
}

function isSameLocalDay(iso?: string): boolean {
  if (!iso) return false;
  const value = new Date(iso);
  if (Number.isNaN(value.getTime())) return false;
  const today = new Date();
  return (
    value.getFullYear() === today.getFullYear() &&
    value.getMonth() === today.getMonth() &&
    value.getDate() === today.getDate()
  );
}

/**
 * 判定某平台账号“今日是否已签到”。
 * Qoder 平台未提供明确字段：只有存在已领取活动，或本地当天成功领取，才算已签。
 */
export function isAccountCheckedInToday(account: Account): boolean {
  const status = account.last_status;
  if (!status) return false;
  if (account.platform === 'workbuddy') {
    return !!(status as WorkBuddyStatus).checked_in_today;
  }
  if (account.platform === 'trae') {
    return !!(status as TraeStatus).checked_in_today;
  }
  if (account.platform === 'qoder') {
    const q = status as QoderStatus;
    if (q.claimedCount > 0) return true;
    return account.last_run_status === 'success' && isSameLocalDay(account.last_run_at);
  }
  return false;
}

/** 格式化积分显示，-1 表示不限。 */
export function formatCredits(value: number, unit = '积分'): string {
  if (value === -1) return '不限';
  return `${(value ?? 0).toLocaleString()} ${unit}`;
}
