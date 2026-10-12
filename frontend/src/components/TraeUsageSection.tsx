import React, { useState } from 'react';
import { TraeUsageAccount } from '../types';
import { apiService } from '../services/api';
import { TrendLineChart } from './canvas/TrendLineChart';
import { DonutModelChart } from './canvas/DonutModelChart';
import { Activity, ChevronLeft, ChevronRight, Cpu, Search } from 'lucide-react';
import { useToast } from './ui/Toast';

function localDate(offsetDays = 0): string {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

export const TraeUsageSection: React.FC = () => {
  const [accounts, setAccounts] = useState<TraeUsageAccount[]>([]);
  const [selectedIdx, setSelectedIdx] = useState(0);
  const [start, setStart] = useState(localDate(-6));
  const [end, setEnd] = useState(localDate(0));
  const [summary, setSummary] = useState({ total_credits: 0, request_count: 0, failed_count: 0 });
  const [currentPage, setCurrentPage] = useState(1);
  const [isLoading, setIsLoading] = useState(false);
  const [hasQueried, setHasQueried] = useState(false);
  const pageSize = 20;
  const { success, error } = useToast();

  const handleQuery = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsLoading(true);
    setCurrentPage(1);
    try {
      const res = await apiService.getTraeUsage(start, end);
      setAccounts(res.accounts);
      setSummary({
        total_credits: res.total_credits,
        request_count: res.request_count,
        failed_count: res.failed_count,
      });
      setSelectedIdx(0);
      setHasQueried(true);
      success(
        'Trae 用量查询完成',
        res.failed_count ? `${res.failed_count} 个账号查询失败` : `${res.accounts.length} 个账号查询成功`
      );
    } catch (err: any) {
      setAccounts([]);
      setHasQueried(true);
      error('查询 Trae 用量失败', err.message);
    } finally {
      setIsLoading(false);
    }
  };

  const okAccounts = accounts.filter((a) => a.ok);
  const activeAccount = okAccounts[selectedIdx] || okAccounts[0];
  const activeDays = activeAccount ? activeAccount.daily_trend.filter((d) => d.credits > 0 || d.requests > 0).length : 0;

  const items = activeAccount?.items || [];
  const totalPages = Math.max(1, Math.ceil(items.length / pageSize));
  const safePage = Math.min(Math.max(1, currentPage), totalPages);
  const displayedItems = items.slice((safePage - 1) * pageSize, safePage * pageSize);

  return (
    <section aria-label="Trae 用量监控" className="bg-[#10171d] border border-[#1e2a34] rounded-lg p-5 space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-white">Trae 积分用量</h2>
            <span className="text-xs font-mono text-cyan-400">单次最多 91 天</span>
          </div>
          <p className="text-xs text-slate-400 mt-0.5">复用统一账号库中的 Trae 登录态查询积分明细与模型分布</p>
        </div>

        {okAccounts.length > 1 && (
          <div className="flex items-center bg-[#131d24] border border-[#233543] rounded p-1 text-xs flex-wrap">
            <span className="text-slate-400 px-2 text-[11px]">切换账号:</span>
            {okAccounts.map((acc, idx) => (
              <button
                key={acc.account_id}
                onClick={() => {
                  setSelectedIdx(idx);
                  setCurrentPage(1);
                }}
                className={`px-2.5 py-1 rounded text-xs transition-colors ${
                  selectedIdx === idx ? 'bg-cyan-500/20 text-cyan-300 font-medium' : 'text-slate-400 hover:text-white'
                }`}
              >
                {acc.account_name}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* 查询表单 */}
      <form onSubmit={handleQuery} className="flex flex-wrap items-end gap-3 p-3 rounded-lg bg-[#131d24] border border-[#1b2631]">
        <label className="text-xs text-slate-400">
          开始日期
          <input
            type="date"
            value={start}
            onChange={(e) => setStart(e.target.value)}
            required
            className="mt-1 block px-2.5 py-1.5 bg-[#0d1419] border border-[#233543] rounded text-xs text-white focus:outline-none focus:border-emerald-500"
          />
        </label>
        <label className="text-xs text-slate-400">
          结束日期
          <input
            type="date"
            value={end}
            onChange={(e) => setEnd(e.target.value)}
            required
            className="mt-1 block px-2.5 py-1.5 bg-[#0d1419] border border-[#233543] rounded text-xs text-white focus:outline-none focus:border-emerald-500"
          />
        </label>
        <button
          type="submit"
          disabled={isLoading}
          className="px-3 py-1.5 text-xs font-semibold rounded bg-emerald-500 hover:bg-emerald-400 text-[#090d10] flex items-center gap-1.5 disabled:opacity-50"
        >
          <Search className="w-3.5 h-3.5" />
          <span>{isLoading ? '查询中...' : '查询用量'}</span>
        </button>
        {hasQueried && (
          <span className="text-[11px] text-slate-400 ml-auto">
            {okAccounts.length} / {accounts.length} 个账号成功 · {summary.request_count} 次请求
            {summary.failed_count > 0 && <span className="text-amber-400 ml-2">{summary.failed_count} 个失败</span>}
          </span>
        )}
      </form>

      {/* 汇总 */}
      <div className="grid grid-cols-1 sm:grid-cols-4 gap-3 p-3 rounded-lg bg-[#131d24] border border-[#1b2631] text-xs font-mono">
        <div>
          <span className="text-slate-400 font-sans block text-[11px]">区间积分消耗</span>
          <span className="text-base font-bold text-cyan-400">{summary.total_credits.toLocaleString()}</span>
        </div>
        <div>
          <span className="text-slate-400 font-sans block text-[11px]">请求次数</span>
          <span className="text-base font-bold text-white">{summary.request_count.toLocaleString()}</span>
        </div>
        <div>
          <span className="text-slate-400 font-sans block text-[11px]">活跃天数</span>
          <span className="text-base font-bold text-emerald-400">{activeDays} 天</span>
        </div>
        <div>
          <span className="text-slate-400 font-sans block text-[11px]">接入模型类型</span>
          <span className="text-base font-bold text-purple-400">{activeAccount?.model_list.length || 0} 种</span>
        </div>
      </div>

      {/* 失败账号提示 */}
      {accounts.some((a) => !a.ok) && (
        <div className="space-y-1.5">
          {accounts
            .filter((a) => !a.ok)
            .map((a) => (
              <div key={a.account_id} className="text-xs text-amber-300/90 bg-amber-500/5 border border-amber-500/20 rounded px-3 py-2">
                [{a.account_name}] 查询失败：{a.message || '未知错误'}
              </div>
            ))}
        </div>
      )}

      {isLoading ? (
        <div className="h-48 flex items-center justify-center text-xs text-slate-500">正在查询 Trae 用量...</div>
      ) : !activeAccount ? (
        <div className="h-40 flex items-center justify-center text-xs text-slate-500">
          {hasQueried ? (accounts.length ? '所选时间段没有可用数据' : '当前没有 Trae 授权账号') : '选择日期范围后查询 Trae 用量'}
        </div>
      ) : (
        <>
          <div className="grid grid-cols-1 lg:grid-cols-12 gap-4">
            <div className="lg:col-span-7 bg-[#0b1014] border border-[#18232c] rounded-lg p-3">
              <div className="flex items-center justify-between text-xs text-slate-400 px-2 mb-2">
                <span className="font-mono flex items-center gap-1.5">
                  <Activity className="w-3.5 h-3.5 text-cyan-400" />
                  <span>{activeAccount.account_name} 每日积分消耗走势</span>
                </span>
                <span className="text-cyan-400 font-mono text-[11px]">Canvas 折线图</span>
              </div>
              <TrendLineChart
                data={activeAccount.daily_trend.map((d) => ({
                  label: d.date,
                  value: d.credits,
                  secondaryValue: d.requests,
                }))}
                height={220}
                metricName="积分消耗"
                secondaryMetricName="请求次数"
                color="#06b6d4"
                valueFormatter={(v) => (v >= 1000 ? `${(v / 1000).toFixed(1)}k` : `${Number(v).toFixed(2)}`)}
              />
            </div>

            <div className="lg:col-span-5 bg-[#0b1014] border border-[#18232c] rounded-lg p-3 flex flex-col justify-between">
              <div className="flex items-center justify-between text-xs text-slate-400 px-2 mb-2">
                <span className="font-mono flex items-center gap-1.5">
                  <Cpu className="w-3.5 h-3.5 text-emerald-400" />
                  <span>模型积分占比</span>
                </span>
                <span className="text-emerald-400 font-mono text-[11px]">占比分析</span>
              </div>
              <div className="py-2 flex-1 flex items-center">
                {Object.keys(activeAccount.model_breakdown).length ? (
                  <DonutModelChart data={activeAccount.model_breakdown} height={200} />
                ) : (
                  <div className="w-full text-center text-xs text-slate-500">暂无模型明细</div>
                )}
              </div>
            </div>
          </div>

          <div className="space-y-3">
            <div className="flex items-center justify-between text-xs">
              <span className="font-semibold text-slate-200">
                {activeAccount.account_name} 用量明细{' '}
                <span className="font-mono text-slate-400 font-normal">({items.length} 条，每页 {pageSize} 条)</span>
              </span>
              <span className="text-[11px] text-slate-500">第 {safePage} / {totalPages} 页</span>
            </div>

            <div className="overflow-x-auto rounded border border-[#1e2a34]">
              <table className="w-full text-left text-xs border-collapse font-mono">
                <thead>
                  <tr className="bg-[#131d24] text-slate-400 border-b border-[#1e2a34] text-[11px]">
                    <th className="py-2.5 px-3">时间</th>
                    <th className="py-2.5 px-3 font-sans">模型</th>
                    <th className="py-2.5 px-3">客户端</th>
                    <th className="py-2.5 px-3 text-right">积分</th>
                    <th className="py-2.5 px-3 font-sans">使用记录</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-[#18232c]">
                  {displayedItems.length ? (
                    displayedItems.map((row, i) => (
                      <tr key={`${row.time}_${i}`} className="hover:bg-[#141e26] transition-colors">
                        <td className="py-2 px-3 text-slate-300">{row.time || '--'}</td>
                        <td className="py-2 px-3 text-white font-sans max-w-[180px] truncate" title={row.model}>
                          {row.model}
                        </td>
                        <td className="py-2 px-3 text-slate-400">{row.source}</td>
                        <td className="py-2 px-3 text-right text-cyan-400 font-semibold">
                          {Number(row.credits || 0).toLocaleString('zh-CN', { maximumFractionDigits: 4 })}
                        </td>
                        <td className="py-2 px-3 text-slate-400 max-w-[260px] truncate font-sans" title={row.record}>
                          {row.record || '无使用记录'}
                        </td>
                      </tr>
                    ))
                  ) : (
                    <tr>
                      <td colSpan={5} className="py-8 text-center text-slate-500">该时间段没有明细</td>
                    </tr>
                  )}
                </tbody>
              </table>
            </div>

            <div className="flex items-center justify-between text-xs pt-1">
              <div className="text-slate-400">
                {items.length ? `显示第 ${(safePage - 1) * pageSize + 1} 至 ${Math.min(safePage * pageSize, items.length)} 条` : ''}
              </div>
              <div className="flex items-center gap-1.5">
                <button
                  onClick={() => setCurrentPage((p) => Math.max(p - 1, 1))}
                  disabled={safePage <= 1}
                  className="p-1.5 rounded bg-[#131d24] hover:bg-[#1a2731] border border-[#233543] text-slate-300 disabled:opacity-40 disabled:cursor-not-allowed"
                >
                  <ChevronLeft className="w-4 h-4" />
                </button>
                <span className="font-mono px-2 text-slate-300">{safePage} / {totalPages}</span>
                <button
                  onClick={() => setCurrentPage((p) => Math.min(p + 1, totalPages))}
                  disabled={safePage >= totalPages}
                  className="p-1.5 rounded bg-[#131d24] hover:bg-[#1a2731] border border-[#233543] text-slate-300 disabled:opacity-40 disabled:cursor-not-allowed"
                >
                  <ChevronRight className="w-4 h-4" />
                </button>
              </div>
            </div>
          </div>
        </>
      )}
    </section>
  );
};
