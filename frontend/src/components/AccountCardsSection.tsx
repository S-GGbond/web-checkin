import React, { useState } from 'react';
import {
  Account,
  WorkBuddyStatus,
  TraeStatus,
  QoderStatus,
  isAccountCheckedInToday,
} from '../types';
import {
  Zap,
  RefreshCw,
  Clock,
  Trash2,
  CheckCircle,
  AlertCircle,
  Filter,
} from 'lucide-react';
import { useToast } from './ui/Toast';

interface AccountCardsSectionProps {
  accounts: Account[];
  onCheckIn: (id: string) => Promise<void>;
  onRefresh: (id: string) => Promise<void>;
  onToggleActive: (id: string, active: boolean) => Promise<void>;
  onEditSchedule: (account: Account) => void;
  onDeleteAccount: (id: string, name: string) => void;
}

function formatNumber(value: number | undefined): string {
  if (value === -1) return '不限';
  return (value ?? 0).toLocaleString();
}

export const AccountCardsSection: React.FC<AccountCardsSectionProps> = ({
  accounts,
  onCheckIn,
  onRefresh,
  onToggleActive,
  onEditSchedule,
  onDeleteAccount,
}) => {
  const [filterPlatform, setFilterPlatform] = useState<string>('all');
  const [filterStatus, setFilterStatus] = useState<string>('all');
  const [loadingAction, setLoadingAction] = useState<Record<string, string>>({});
  const { success, error, info } = useToast();

  const withLoading = async (key: string, fn: () => Promise<void>) => {
    setLoadingAction((prev) => ({ ...prev, [key]: 'loading' }));
    try {
      await fn();
    } finally {
      setLoadingAction((prev) => {
        const next = { ...prev };
        delete next[key];
        return next;
      });
    }
  };

  const handleSingleCheckin = (acc: Account) =>
    withLoading(`${acc.id}_checkin`, async () => {
      try {
        await onCheckIn(acc.id);
        success('签到完成', `[${acc.name}] 今日签到状态已同步`);
      } catch (err: any) {
        error('签到失败', err.message || '网络异常');
      }
    });

  const handleSingleRefresh = (acc: Account) =>
    withLoading(`${acc.id}_refresh`, async () => {
      try {
        await onRefresh(acc.id);
        info('状态已同步', `[${acc.name}] 最新余额与授权状态已拉取`);
      } catch (err: any) {
        error('刷新状态失败', err.message || '未知错误');
      }
    });

  const handleToggleActive = (acc: Account) =>
    withLoading(`${acc.id}_toggle`, async () => {
      try {
        await onToggleActive(acc.id, !acc.is_active);
        info('账号状态已更新', `[${acc.name}] 已${acc.is_active ? '停用' : '启用'}`);
      } catch (err: any) {
        error('更新账号状态失败', err.message || '未知错误');
      }
    });

  const filteredAccounts = accounts.filter((acc) => {
    if (filterPlatform !== 'all' && acc.platform !== filterPlatform) return false;
    if (filterStatus === 'active' && !(acc.is_active && acc.schedule_enabled)) return false;
    if (filterStatus === 'inactive' && acc.is_active && acc.schedule_enabled) return false;
    if (filterStatus === 'checked' && !isAccountCheckedInToday(acc)) return false;
    if (filterStatus === 'unchecked' && isAccountCheckedInToday(acc)) return false;
    return true;
  });

  return (
    <section aria-label="托管账号管理" className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <h2 className="text-base font-semibold text-white">托管账号列表</h2>
          <span className="text-xs text-slate-400 font-mono">
            (共 {accounts.length} 个，显示 {filteredAccounts.length} 个)
          </span>
        </div>

        <div className="flex items-center flex-wrap gap-2 text-xs">
          <div className="flex items-center bg-[#10171d] border border-[#1e2a34] rounded p-0.5">
            <span className="px-2 text-slate-400 text-[11px] flex items-center gap-1">
              <Filter className="w-3 h-3" /> 平台:
            </span>
            {['all', 'workbuddy', 'trae', 'qoder'].map((p) => (
              <button
                key={p}
                onClick={() => setFilterPlatform(p)}
                className={`px-2.5 py-1 rounded text-xs transition-colors ${
                  filterPlatform === p
                    ? 'bg-emerald-500/20 text-emerald-300 font-medium'
                    : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                {p === 'all' ? '全部' : p}
              </button>
            ))}
          </div>

          <div className="flex items-center bg-[#10171d] border border-[#1e2a34] rounded p-0.5">
            <span className="px-2 text-slate-400 text-[11px]">状态:</span>
            {[
              { id: 'all', label: '全部' },
              { id: 'checked', label: '今日已签' },
              { id: 'unchecked', label: '今日未签' },
              { id: 'active', label: '定时启用' },
            ].map((s) => (
              <button
                key={s.id}
                onClick={() => setFilterStatus(s.id)}
                className={`px-2 py-1 rounded text-xs transition-colors ${
                  filterStatus === s.id
                    ? 'bg-emerald-500/20 text-emerald-300 font-medium'
                    : 'text-slate-400 hover:text-slate-200'
                }`}
              >
                {s.label}
              </button>
            ))}
          </div>
        </div>
      </div>

      {filteredAccounts.length === 0 ? (
        <div className="p-12 text-center bg-[#10171d] border border-[#1e2a34] rounded-lg text-slate-400">
          <p className="text-sm">暂无符合条件的账号</p>
          <p className="text-xs text-slate-500 mt-1">请重置筛选条件，或在上方添加账号</p>
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
          {filteredAccounts.map((acc) => {
            const isChecked = isAccountCheckedInToday(acc);
            const isChecking = loadingAction[`${acc.id}_checkin`] === 'loading';
            const isRefreshing = loadingAction[`${acc.id}_refresh`] === 'loading';

            let platformBadge = 'text-emerald-400';
            if (acc.platform === 'trae') platformBadge = 'text-cyan-400';
            if (acc.platform === 'qoder') platformBadge = 'text-purple-400';

            return (
              <div
                key={acc.id}
                className={`bg-[#10171d] border rounded-lg p-4 flex flex-col justify-between transition-all hover:border-[#2a3c4a] ${
                  acc.is_active ? 'border-[#1e2a34]' : 'border-[#1e2a34]/60 opacity-75'
                }`}
              >
                <div>
                  <div className="flex items-start justify-between gap-2 mb-2">
                    <div className="min-w-0">
                      <div className="flex items-center gap-2">
                        <span className={`text-xs font-mono font-bold uppercase ${platformBadge}`}>
                          {acc.platform}
                        </span>
                        <span className="text-slate-600">·</span>
                        <h3 className="text-sm font-semibold text-white truncate max-w-[160px]" title={acc.name}>
                          {acc.name}
                        </h3>
                      </div>
                      <div className="text-[11px] font-mono text-slate-500 mt-0.5 truncate" title={acc.external_id}>
                        ID: {acc.external_id}
                      </div>
                    </div>

                    <div className="shrink-0 flex flex-col items-end gap-1 text-xs font-medium">
                      {isChecked ? (
                        <span className="flex items-center gap-1 text-emerald-400">
                          <CheckCircle className="w-3.5 h-3.5" />
                          <span>今日已签</span>
                        </span>
                      ) : (
                        <span className="flex items-center gap-1 text-amber-400">
                          <AlertCircle className="w-3.5 h-3.5" />
                          <span>今日未签</span>
                        </span>
                      )}
                      <span className={`text-[10px] ${acc.is_active ? 'text-slate-400' : 'text-rose-400'}`}>
                        {acc.is_active ? '运行中' : '已停用'}
                      </span>
                    </div>
                  </div>

                  <div className="my-3 p-2.5 rounded bg-[#131d24] border border-[#1b2631] text-xs space-y-1.5 font-mono">
                    {acc.platform === 'workbuddy' && acc.last_status && (
                      <>
                        <div className="flex justify-between">
                          <span className="text-slate-400 font-sans">剩余积分:</span>
                          <span className="text-emerald-400 font-bold">
                            {formatNumber((acc.last_status as WorkBuddyStatus).credits_left)}
                          </span>
                        </div>
                        <div className="flex justify-between">
                          <span className="text-slate-400 font-sans">积分总额:</span>
                          <span className="text-slate-200">
                            {formatNumber((acc.last_status as WorkBuddyStatus).credits_total)}
                          </span>
                        </div>
                        <div className="flex justify-between">
                          <span className="text-slate-400 font-sans">连续签到:</span>
                          <span className="text-emerald-400 font-bold">
                            {(acc.last_status as WorkBuddyStatus).streak_days || 0} 天
                          </span>
                        </div>
                      </>
                    )}

                    {acc.platform === 'trae' && acc.last_status && (
                      <>
                        <div className="flex justify-between">
                          <span className="text-slate-400 font-sans">剩余积分:</span>
                          <span className="text-cyan-400 font-bold">
                            {formatNumber((acc.last_status as TraeStatus).credits_left)}
                          </span>
                        </div>
                        <div className="flex justify-between">
                          <span className="text-slate-400 font-sans">积分总额:</span>
                          <span className="text-slate-200">
                            {formatNumber((acc.last_status as TraeStatus).credits_total)}
                          </span>
                        </div>
                        <div className="flex justify-between">
                          <span className="text-slate-400 font-sans">次日基础积分:</span>
                          <span className="text-slate-200">
                            {(acc.last_status as TraeStatus).extra_credits ?? 0}
                          </span>
                        </div>
                      </>
                    )}

                    {acc.platform === 'qoder' && acc.last_status && (
                      <>
                        <div className="flex justify-between">
                          <span className="text-slate-400 font-sans">可领取活动:</span>
                          <span className="text-purple-400 font-bold">
                            {(acc.last_status as QoderStatus).claimableCount ?? 0}
                          </span>
                        </div>
                        <div className="flex justify-between">
                          <span className="text-slate-400 font-sans">活动总数:</span>
                          <span className="text-slate-200">{(acc.last_status as QoderStatus).campaignCount ?? 0}</span>
                        </div>
                        <div className="flex justify-between">
                          <span className="text-slate-400 font-sans">已领取:</span>
                          <span className="text-emerald-400">{(acc.last_status as QoderStatus).claimedCount ?? 0}</span>
                        </div>
                      </>
                    )}

                    {!acc.last_status && (
                      <div className="text-slate-500 text-[11px] font-sans">
                        尚未获取平台状态，点击下方「刷新」拉取实时数据。
                      </div>
                    )}
                  </div>

                  <div className="flex items-center justify-between text-xs py-1.5 border-t border-[#1c2832]">
                    <button
                      onClick={() => onEditSchedule(acc)}
                      className="flex items-center gap-1.5 text-slate-300 hover:text-emerald-400 transition-colors"
                      title="编辑独立定时"
                    >
                      <Clock className="w-3.5 h-3.5 text-emerald-400" />
                      <span className="font-mono">{acc.schedule_time_desc}</span>
                      <span className={`text-[10px] px-1.5 py-0.5 rounded ${acc.schedule_enabled ? 'bg-emerald-500/10 text-emerald-300' : 'bg-slate-700/40 text-slate-400'}`}>
                        {acc.schedule_enabled ? '定时开' : '定时关'}
                      </span>
                    </button>

                    <label className="flex items-center cursor-pointer gap-1.5">
                      <span className="text-[11px] text-slate-400">{acc.is_active ? '账号启用' : '账号停用'}</span>
                      <input
                        type="checkbox"
                        checked={acc.is_active}
                        onChange={() => handleToggleActive(acc)}
                        className="sr-only peer"
                        aria-label="启用或停用账号"
                      />
                      <span className="w-7 h-4 bg-slate-700 rounded-full relative peer-checked:bg-emerald-500 after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:bg-white after:rounded-full after:h-3 after:w-3 after:transition-all peer-checked:after:translate-x-3" />
                    </label>
                  </div>
                </div>

                <div className="mt-3 pt-2.5 border-t border-[#1c2832] grid grid-cols-4 gap-1.5 text-xs">
                  <button
                    onClick={() => handleSingleCheckin(acc)}
                    disabled={isChecking}
                    className="flex flex-col items-center justify-center p-1.5 rounded bg-emerald-500/10 hover:bg-emerald-500/20 text-emerald-300 border border-emerald-500/20 transition-colors disabled:opacity-50"
                    title="立即签到"
                  >
                    <Zap className={`w-3.5 h-3.5 mb-0.5 ${isChecking ? 'animate-spin' : ''}`} />
                    <span className="text-[10px]">签到</span>
                  </button>

                  <button
                    onClick={() => handleSingleRefresh(acc)}
                    disabled={isRefreshing}
                    className="flex flex-col items-center justify-center p-1.5 rounded bg-[#131d24] hover:bg-[#1a2731] text-slate-300 border border-[#233543] transition-colors disabled:opacity-50"
                    title="刷新平台余额与状态"
                  >
                    <RefreshCw className={`w-3.5 h-3.5 mb-0.5 ${isRefreshing ? 'animate-spin' : ''}`} />
                    <span className="text-[10px]">刷新</span>
                  </button>

                  <button
                    onClick={() => onEditSchedule(acc)}
                    className="flex flex-col items-center justify-center p-1.5 rounded bg-[#131d24] hover:bg-[#1a2731] text-slate-300 border border-[#233543] transition-colors"
                    title="编辑独立定时"
                  >
                    <Clock className="w-3.5 h-3.5 mb-0.5 text-cyan-400" />
                    <span className="text-[10px]">定时</span>
                  </button>

                  <button
                    onClick={() => onDeleteAccount(acc.id, acc.name)}
                    className="flex flex-col items-center justify-center p-1.5 rounded bg-rose-500/10 hover:bg-rose-500/20 text-rose-400 border border-rose-500/20 transition-colors"
                    title="删除账号"
                  >
                    <Trash2 className="w-3.5 h-3.5 mb-0.5" />
                    <span className="text-[10px]">删除</span>
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </section>
  );
};
