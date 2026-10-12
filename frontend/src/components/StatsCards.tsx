import React from 'react';
import { SystemStats } from '../types';
import { Users, CheckCircle, Flame, Layers, Clock } from 'lucide-react';

interface StatsCardsProps {
  stats: SystemStats;
}

export const StatsCards: React.FC<StatsCardsProps> = ({ stats }) => {
  const completionRate =
    stats.total_accounts > 0 ? Math.round((stats.checked_in_today / stats.total_accounts) * 100) : 0;

  return (
    <section aria-label="核心概览指标" className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
      {/* 1: 托管账号总数 */}
      <div className="bg-[#10171d] border border-[#1e2a34] rounded-lg p-4 shadow-sm hover:border-[#2a3c4a] transition-colors">
        <div className="flex items-center justify-between mb-2">
          <span className="text-xs font-medium text-slate-400">托管账号总数</span>
          <Users className="w-4 h-4 text-emerald-400" />
        </div>
        <div className="flex items-baseline gap-2">
          <span className="text-2xl font-bold font-mono text-white tracking-tight">{stats.total_accounts}</span>
          <span className="text-xs text-slate-400">个已登记</span>
        </div>
        <div className="mt-3 text-xs text-slate-400 flex items-center gap-1.5 font-mono">
          <span>WorkBuddy {stats.platform_counts.workbuddy}</span>
          <span aria-hidden="true" className="text-slate-600">·</span>
          <span>Trae {stats.platform_counts.trae}</span>
          <span aria-hidden="true" className="text-slate-600">·</span>
          <span>Qoder {stats.platform_counts.qoder}</span>
        </div>
      </div>

      {/* 2: 今日签到进度 */}
      <div className="bg-[#10171d] border border-[#1e2a34] rounded-lg p-4 shadow-sm hover:border-[#2a3c4a] transition-colors">
        <div className="flex items-center justify-between mb-2">
          <span className="text-xs font-medium text-slate-400">今日签到完成率</span>
          <CheckCircle className={`w-4 h-4 ${completionRate === 100 && stats.total_accounts > 0 ? 'text-emerald-400' : 'text-amber-400'}`} />
        </div>
        <div className="flex items-baseline gap-2">
          <span className="text-2xl font-bold font-mono text-emerald-400 tracking-tight">{completionRate}%</span>
          <span className="text-xs text-slate-400 font-mono">
            ({stats.checked_in_today}/{stats.total_accounts} 已签)
          </span>
        </div>
        <div className="mt-3">
          <div className="w-full bg-[#162129] rounded-full h-1.5 overflow-hidden">
            <div
              className={`h-full transition-all duration-500 ${
                completionRate === 100 && stats.total_accounts > 0 ? 'bg-emerald-400 shadow-[0_0_8px_#10b981]' : 'bg-amber-400'
              }`}
              style={{ width: `${completionRate}%` }}
            />
          </div>
          <div className="flex justify-between items-center mt-1.5 text-[11px] text-slate-400">
            <span>{stats.unchecked_today > 0 ? `待签到 ${stats.unchecked_today} 个` : '今日已全部完成'}</span>
            <span className="font-mono text-slate-500 flex items-center gap-1">
              <Clock className="w-3 h-3" />
              {stats.scheduled_accounts} 个已设定时
            </span>
          </div>
        </div>
      </div>

      {/* 3: WorkBuddy 剩余积分 */}
      <div className="bg-[#10171d] border border-[#1e2a34] rounded-lg p-4 shadow-sm hover:border-[#2a3c4a] transition-colors">
        <div className="flex items-center justify-between mb-2">
          <span className="text-xs font-medium text-slate-400">WorkBuddy 剩余积分</span>
          <Flame className="w-4 h-4 text-emerald-400" />
        </div>
        <div className="flex items-baseline gap-2">
          <span className="text-2xl font-bold font-mono text-white tracking-tight">
            {stats.workbuddy_has_unlimited ? '不限' : stats.workbuddy_credits_left.toLocaleString()}
          </span>
          <span className="text-xs text-slate-400 font-mono">credits</span>
        </div>
        <div className="mt-3 text-xs text-slate-400 flex items-center justify-between font-mono">
          <span>{stats.workbuddy_has_unlimited ? '含不限额度账号' : '已授权账号合计'}</span>
          <span className="text-slate-500">实时平台额度</span>
        </div>
      </div>

      {/* 4: Trae 剩余积分 */}
      <div className="bg-[#10171d] border border-[#1e2a34] rounded-lg p-4 shadow-sm hover:border-[#2a3c4a] transition-colors">
        <div className="flex items-center justify-between mb-2">
          <span className="text-xs font-medium text-slate-400">Trae 剩余积分</span>
          <Layers className="w-4 h-4 text-cyan-400" />
        </div>
        <div className="flex items-baseline gap-2">
          <span className="text-2xl font-bold font-mono text-cyan-400 tracking-tight">
            {stats.trae_has_unlimited ? '不限' : stats.trae_credits_left.toLocaleString()}
          </span>
          <span className="text-xs text-slate-400">credits</span>
        </div>
        <div className="mt-3 text-xs text-slate-400 flex items-center justify-between font-mono">
          <span>91 天用量明细可查</span>
          <span className="text-emerald-400">{stats.platform_counts.trae} 个 Trae 账号</span>
        </div>
      </div>
    </section>
  );
};
