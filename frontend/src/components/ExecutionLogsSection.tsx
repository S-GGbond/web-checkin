import React, { useState, useEffect } from 'react';
import { LogEntry } from '../types';
import { apiService } from '../services/api';
import { Terminal, RefreshCw, CheckCircle, XCircle, Search } from 'lucide-react';
import { useToast } from './ui/Toast';

export const ExecutionLogsSection: React.FC = () => {
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [filterPlatform, setFilterPlatform] = useState<string>('all');
  const [filterStatus, setFilterStatus] = useState<string>('all');
  const [searchKeyword, setSearchKeyword] = useState<string>('');
  const [isRefreshing, setIsRefreshing] = useState(false);
  const { error } = useToast();

  const fetchLogs = async () => {
    try {
      setIsRefreshing(true);
      const res = await apiService.getLogs();
      setLogs(res);
    } catch (err: any) {
      error('获取日志失败', err.message);
    } finally {
      setIsRefreshing(false);
    }
  };

  useEffect(() => {
    fetchLogs();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const filteredLogs = logs.filter((l) => {
    if (filterPlatform !== 'all' && l.platform !== filterPlatform) return false;
    if (filterStatus !== 'all' && l.status !== filterStatus) return false;
    if (searchKeyword.trim()) {
      const q = searchKeyword.toLowerCase();
      const matchName = l.account_name?.toLowerCase().includes(q);
      const matchMsg = l.message.toLowerCase().includes(q);
      if (!matchName && !matchMsg) return false;
    }
    return true;
  });

  return (
    <section aria-label="执行日志" className="bg-[#10171d] border border-[#1e2a34] rounded-lg p-5 space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-2">
          <Terminal className="w-5 h-5 text-emerald-400" />
          <h2 className="text-base font-semibold text-white">执行日志</h2>
          <span className="text-xs font-mono text-slate-400">(最新 {logs.length} 条记录)</span>
        </div>

        <button
          onClick={fetchLogs}
          disabled={isRefreshing}
          className="flex items-center gap-1.5 px-2.5 py-1.5 text-xs rounded bg-[#131d24] hover:bg-[#1a2731] border border-[#233543] text-slate-300 transition-colors disabled:opacity-50"
        >
          <RefreshCw className={`w-3.5 h-3.5 ${isRefreshing ? 'animate-spin text-emerald-400' : ''}`} />
          <span>刷新日志</span>
        </button>
      </div>

      <div className="flex flex-wrap items-center gap-2 text-xs">
        <div className="relative flex-1 min-w-[200px]">
          <Search className="w-3.5 h-3.5 text-slate-500 absolute left-2.5 top-1/2 -translate-y-1/2" />
          <input
            type="text"
            value={searchKeyword}
            onChange={(e) => setSearchKeyword(e.target.value)}
            placeholder="搜索日志关键字、账号名称..."
            className="w-full pl-8 pr-3 py-1.5 bg-[#131d24] border border-[#233543] rounded text-slate-200 placeholder-slate-500 focus:outline-none focus:border-emerald-500"
          />
        </div>

        <div className="flex items-center bg-[#131d24] border border-[#233543] rounded p-0.5">
          <span className="px-2 text-slate-500 text-[11px]">平台:</span>
          {['all', 'workbuddy', 'trae', 'qoder'].map((p) => (
            <button
              key={p}
              onClick={() => setFilterPlatform(p)}
              className={`px-2 py-1 rounded text-xs transition-colors ${
                filterPlatform === p ? 'bg-emerald-500/20 text-emerald-300 font-medium' : 'text-slate-400 hover:text-white'
              }`}
            >
              {p === 'all' ? '全部' : p}
            </button>
          ))}
        </div>

        <div className="flex items-center bg-[#131d24] border border-[#233543] rounded p-0.5">
          <span className="px-2 text-slate-500 text-[11px]">状态:</span>
          {[
            { id: 'all', label: '全部' },
            { id: 'success', label: '成功' },
            { id: 'failed', label: '失败' },
          ].map((s) => (
            <button
              key={s.id}
              onClick={() => setFilterStatus(s.id)}
              className={`px-2 py-1 rounded text-xs transition-colors ${
                filterStatus === s.id ? 'bg-emerald-500/20 text-emerald-300 font-medium' : 'text-slate-400 hover:text-white'
              }`}
            >
              {s.label}
            </button>
          ))}
        </div>
      </div>

      <div className="bg-[#090d10] border border-[#1b2631] rounded-lg font-mono text-xs overflow-hidden shadow-inner">
        <div className="flex items-center justify-between px-3 py-2 bg-[#0d1419] border-b border-[#1b2631] text-[11px] text-slate-500">
          <div className="flex items-center gap-2">
            <div className="flex gap-1.5">
              <span className="w-2.5 h-2.5 rounded-full bg-rose-500/80 inline-block" />
              <span className="w-2.5 h-2.5 rounded-full bg-amber-500/80 inline-block" />
              <span className="w-2.5 h-2.5 rounded-full bg-emerald-500/80 inline-block" />
            </div>
            <span className="text-slate-400 font-medium">checkin_hub.scheduler // log_stream</span>
          </div>
          <span>显示 {filteredLogs.length} 条</span>
        </div>

        <div className="max-h-[380px] overflow-y-auto divide-y divide-[#131b22] p-2 space-y-1">
          {filteredLogs.length === 0 ? (
            <div className="py-12 text-center text-slate-500 text-xs">暂无日志记录</div>
          ) : (
            filteredLogs.map((log) => {
              const StatusIcon = log.status === 'failed' ? XCircle : CheckCircle;
              const statusColor = log.status === 'failed' ? 'text-rose-400' : 'text-emerald-400';
              return (
                <div key={log.id} className="py-1.5 px-2 hover:bg-[#10171d] rounded transition-colors">
                  <div className="flex items-start gap-2">
                    <StatusIcon className={`w-3.5 h-3.5 mt-0.5 shrink-0 ${statusColor}`} />
                    <span className="text-slate-500 shrink-0 text-[11px]">{log.timestamp}</span>
                    <span className="text-slate-400 shrink-0 uppercase text-[10px] px-1 rounded bg-[#131d24]">
                      {log.platform}
                    </span>
                    <span className="text-slate-500 shrink-0 text-[10px]">{log.action}</span>
                    <span className="text-slate-300 font-sans font-medium shrink-0">[{log.account_name}]</span>
                    <span className="text-slate-200 break-words flex-1 leading-relaxed">{log.message}</span>
                  </div>
                </div>
              );
            })
          )}
        </div>
      </div>
    </section>
  );
};
