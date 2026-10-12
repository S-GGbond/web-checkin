import React, { useState } from 'react';
import { WorkBuddyUsageRecord } from '../types';
import { apiService } from '../services/api';
import { TrendLineChart } from './canvas/TrendLineChart';
import { BarUsageChart } from './canvas/BarUsageChart';
import { Download, ShieldCheck, ChevronLeft, ChevronRight, BarChart2, TrendingUp, Search } from 'lucide-react';
import { useToast } from './ui/Toast';

function localDate(offsetDays = 0): string {
  const d = new Date();
  d.setDate(d.getDate() + offsetDays);
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function dayOf(requestTime: string): string {
  const match = /^\d{4}-\d{2}-\d{2}/.exec(requestTime || '');
  return match ? match[0] : '';
}

export const WorkBuddyUsageSection: React.FC = () => {
  const [records, setRecords] = useState<WorkBuddyUsageRecord[]>([]);
  const [start, setStart] = useState(localDate(-6));
  const [end, setEnd] = useState(localDate(0));
  const [cookie, setCookie] = useState('');
  const [currentPage, setCurrentPage] = useState(1);
  const [chartView, setChartView] = useState<'line' | 'bar'>('line');
  const [isLoading, setIsLoading] = useState(false);
  const [hasQueried, setHasQueried] = useState(false);
  const pageSize = 20;
  const { success, error, warn } = useToast();

  const handleQuery = async (e: React.FormEvent) => {
    e.preventDefault();
    const trimmed = cookie.trim();
    setCookie(''); // Cookie 仅用于当次查询，提交后立即清空
    if (!trimmed) {
      warn('请先粘贴 Cookie', '从 WorkBuddy 浏览器开发者工具复制请求头 Cookie');
      return;
    }
    setIsLoading(true);
    setCurrentPage(1);
    try {
      const res = await apiService.getWorkBuddyUsage(start, end, trimmed, navigator.userAgent);
      setRecords(res.records);
      setHasQueried(true);
      success('查询完成', `共获取 ${res.count} 条用量明细`);
    } catch (err: any) {
      setRecords([]);
      setHasQueried(true);
      error('查询 WorkBuddy 用量失败', err.message);
    } finally {
      setCookie('');
      setIsLoading(false);
    }
  };

  const handleExportCsv = () => {
    if (!records.length) return;
    const csvText = apiService.exportWorkBuddyCsv(records);
    const blob = new Blob([csvText], { type: 'text/csv;charset=utf-8;' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `workbuddy-usage-${start}-${end}.csv`;
    a.click();
    URL.revokeObjectURL(url);
    success('CSV 导出成功', '已按当前查询结果生成明细报表');
  };

  const dateMap = new Map<string, { requests: number; credits: number }>();
  records.forEach((r) => {
    const day = dayOf(r.requestTime);
    if (!day) return;
    const item = dateMap.get(day) || { requests: 0, credits: 0 };
    item.requests += 1;
    item.credits += Number(r.credit) || 0;
    dateMap.set(day, item);
  });
  const chartData = Array.from(dateMap.entries())
    .map(([date, data]) => ({ label: date, value: data.credits, secondaryValue: data.requests }))
    .sort((a, b) => a.label.localeCompare(b.label));

  const totalCredits = records.reduce((sum, r) => sum + (Number(r.credit) || 0), 0);
  const totalPages = Math.max(1, Math.ceil(records.length / pageSize));
  const safePage = Math.min(Math.max(1, currentPage), totalPages);
  const displayedRecords = records.slice((safePage - 1) * pageSize, safePage * pageSize);

  return (
    <section aria-label="WorkBuddy 用量" className="bg-[#10171d] border border-[#1e2a34] rounded-lg p-5 space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <h2 className="text-base font-semibold text-white">WorkBuddy 积分消耗明细</h2>
            <span className="text-xs font-mono text-emerald-400">单次最多 31 天</span>
          </div>
          <p className="text-xs text-slate-400 mt-0.5">按请求明细统计积分消耗，临时 Cookie 仅用于本次查询</p>
        </div>

        <div className="flex items-center gap-2.5">
          <div className="flex items-center bg-[#131d24] border border-[#233543] rounded p-0.5 text-xs">
            <button
              onClick={() => setChartView('line')}
              className={`flex items-center gap-1 px-2.5 py-1 rounded transition-colors ${
                chartView === 'line' ? 'bg-emerald-500/20 text-emerald-300 font-medium' : 'text-slate-400 hover:text-white'
              }`}
            >
              <TrendingUp className="w-3.5 h-3.5" />
              <span>积分趋势</span>
            </button>
            <button
              onClick={() => setChartView('bar')}
              className={`flex items-center gap-1 px-2.5 py-1 rounded transition-colors ${
                chartView === 'bar' ? 'bg-emerald-500/20 text-emerald-300 font-medium' : 'text-slate-400 hover:text-white'
              }`}
            >
              <BarChart2 className="w-3.5 h-3.5" />
              <span>请求频次</span>
            </button>
          </div>

          <button
            onClick={handleExportCsv}
            disabled={!records.length}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-medium rounded bg-[#131d24] hover:bg-[#1a2731] border border-[#233543] text-slate-200 transition-colors disabled:opacity-40"
          >
            <Download className="w-3.5 h-3.5 text-emerald-400" />
            <span>导出 CSV</span>
          </button>
        </div>
      </div>

      {/* 查询表单 */}
      <form onSubmit={handleQuery} className="grid grid-cols-1 md:grid-cols-12 gap-3 items-end p-3 rounded-lg bg-[#131d24] border border-[#1b2631]">
        <label className="md:col-span-3 text-xs text-slate-400">
          开始日期
          <input
            type="date"
            value={start}
            onChange={(e) => setStart(e.target.value)}
            required
            className="mt-1 w-full px-2.5 py-1.5 bg-[#0d1419] border border-[#233543] rounded text-xs text-white focus:outline-none focus:border-emerald-500"
          />
        </label>
        <label className="md:col-span-3 text-xs text-slate-400">
          结束日期
          <input
            type="date"
            value={end}
            onChange={(e) => setEnd(e.target.value)}
            required
            className="mt-1 w-full px-2.5 py-1.5 bg-[#0d1419] border border-[#233543] rounded text-xs text-white focus:outline-none focus:border-emerald-500"
          />
        </label>
        <label className="md:col-span-4 text-xs text-slate-400">
          浏览器 Cookie
          <textarea
            rows={1}
            value={cookie}
            onChange={(e) => setCookie(e.target.value)}
            placeholder="从 WorkBuddy 开发者工具复制 Cookie 请求头"
            spellCheck={false}
            className="mt-1 w-full px-2.5 py-1.5 bg-[#0d1419] border border-[#233543] rounded text-xs font-mono text-white placeholder-slate-500 focus:outline-none focus:border-emerald-500 resize-none"
          />
        </label>
        <button
          type="submit"
          disabled={isLoading}
          className="md:col-span-2 px-3 py-1.5 text-xs font-semibold rounded bg-emerald-500 hover:bg-emerald-400 text-[#090d10] flex items-center justify-center gap-1.5 disabled:opacity-50"
        >
          <Search className="w-3.5 h-3.5" />
          <span>{isLoading ? '查询中...' : '查询明细'}</span>
        </button>
      </form>

      {/* 汇总 */}
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3 p-3 rounded-lg bg-[#131d24] border border-[#1b2631] text-xs font-mono">
        <div>
          <span className="text-slate-400 font-sans block text-[11px]">查询时间段请求数</span>
          <span className="text-base font-bold text-white">{records.length.toLocaleString()} 次</span>
        </div>
        <div>
          <span className="text-slate-400 font-sans block text-[11px]">积分消耗合计</span>
          <span className="text-base font-bold text-emerald-400">{totalCredits.toLocaleString()}</span>
        </div>
        <div>
          <span className="text-slate-400 font-sans block text-[11px]">覆盖天数</span>
          <span className="text-base font-bold text-cyan-400">{chartData.length} 天</span>
        </div>
      </div>

      {/* 图表 */}
      <div className="bg-[#0b1014] border border-[#18232c] rounded-lg p-3">
        <div className="flex items-center justify-between text-xs text-slate-400 px-2 mb-2 font-mono">
          <span>{chartView === 'line' ? '每日积分消耗趋势' : '每日请求次数'}</span>
          <span className="text-emerald-400 font-sans">原生 Canvas · Retina 渲染</span>
        </div>
        {isLoading ? (
          <div className="h-48 flex items-center justify-center text-xs text-slate-500">正在查询用量...</div>
        ) : !records.length ? (
          <div className="h-48 flex items-center justify-center text-xs text-slate-500">
            {hasQueried ? '该时间段没有明细' : '选择日期、提交 Cookie 后查询'}
          </div>
        ) : chartView === 'line' ? (
          <TrendLineChart
            data={chartData}
            height={220}
            metricName="积分消耗"
            secondaryMetricName="请求次数"
            color="#10b981"
            valueFormatter={(v) => (v >= 1000 ? `${(v / 1000).toFixed(0)}k` : `${v}`)}
          />
        ) : (
          <BarUsageChart
            data={chartData.map((d) => ({ label: d.label, value: d.secondaryValue || 0 }))}
            height={200}
            metricName="请求次数"
            barColor="#10b981"
            valueFormatter={(v) => `${v} 次`}
          />
        )}
      </div>

      {/* 明细表 */}
      <div className="space-y-3">
        <div className="flex items-center justify-between text-xs">
          <span className="font-semibold text-slate-200">
            请求明细 <span className="font-mono text-slate-400 font-normal">({records.length} 条，每页 {pageSize} 条)</span>
          </span>
          <span className="text-[11px] text-slate-500">第 {safePage} / {totalPages} 页</span>
        </div>

        <div className="overflow-x-auto rounded border border-[#1e2a34]">
          <table className="w-full text-left text-xs border-collapse">
            <thead>
              <tr className="bg-[#131d24] text-slate-400 border-b border-[#1e2a34] font-mono text-[11px]">
                <th className="py-2.5 px-3">请求时间</th>
                <th className="py-2.5 px-3">请求名</th>
                <th className="py-2.5 px-3">模型</th>
                <th className="py-2.5 px-3">客户端</th>
                <th className="py-2.5 px-3 text-right">积分</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-[#18232c] font-mono">
              {displayedRecords.length ? (
                displayedRecords.map((item) => (
                  <tr key={item.id} className="hover:bg-[#141e26] transition-colors">
                    <td className="py-2 px-3 text-slate-300">{item.requestTime || '--'}</td>
                    <td className="py-2 px-3 text-white font-sans font-medium max-w-[220px] truncate" title={item.requestName}>
                      {item.requestName || '--'}
                    </td>
                    <td className="py-2 px-3 text-slate-300">{item.model}</td>
                    <td className="py-2 px-3 text-slate-300">{item.client}</td>
                    <td className="py-2 px-3 text-right text-emerald-400 font-semibold">{item.credit}</td>
                  </tr>
                ))
              ) : (
                <tr>
                  <td colSpan={5} className="py-8 text-center text-slate-500">
                    {hasQueried ? '该时间段没有明细' : '查询后展示请求明细'}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>

        <div className="flex items-center justify-between text-xs pt-1">
          <div className="text-slate-400">
            {records.length ? `显示第 ${(safePage - 1) * pageSize + 1} 至 ${Math.min(safePage * pageSize, records.length)} 项` : ''}
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

      <div className="p-3.5 rounded-lg bg-[#0d1419] border border-[#1b2732] flex items-start gap-3 text-xs text-slate-400 leading-relaxed">
        <ShieldCheck className="w-4 h-4 text-emerald-400 shrink-0 mt-0.5" />
        <div className="space-y-1">
          <div className="font-medium text-slate-300">Cookie 安全说明：</div>
          <p>Cookie 仅保存在本次查询请求的内存中，不会写入账号库或日志；提交后输入框立即清空。</p>
        </div>
      </div>
    </section>
  );
};
