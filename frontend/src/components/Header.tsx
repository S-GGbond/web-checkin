import React, { useState, useEffect } from 'react';
import { RefreshCw, Zap, Clock, CalendarCheck } from 'lucide-react';
import { useToast } from './ui/Toast';

interface HeaderProps {
  /** 轻量刷新：只重新读取本地缓存数据（供自动刷新定时器调用）。 */
  onRefreshAll: () => Promise<void>;
  /** 重量刷新：让后端重新拉取各平台真实余额（供“刷新余额”按钮调用）。 */
  onRefreshBalances: () => Promise<void>;
  refreshInterval: number; // 0 表示关闭，否则为秒数
  setRefreshInterval: (sec: number) => void;
  isGlobalChecking: boolean;
  onCheckInAll: () => Promise<void>;
}

export const Header: React.FC<HeaderProps> = ({
  onRefreshAll,
  onRefreshBalances,
  refreshInterval,
  setRefreshInterval,
  isGlobalChecking,
  onCheckInAll,
}) => {
  const [currentTime, setCurrentTime] = useState<string>('');
  const [countdown, setCountdown] = useState<number>(refreshInterval);
  const [isRefreshing, setIsRefreshing] = useState(false);
  const { info, error } = useToast();

  useEffect(() => {
    const updateTime = () => {
      setCurrentTime(
        new Date().toLocaleTimeString('zh-CN', {
          hour12: false,
          hour: '2-digit',
          minute: '2-digit',
          second: '2-digit',
        })
      );
    };
    updateTime();
    const interval = setInterval(updateTime, 1000);
    return () => clearInterval(interval);
  }, []);

  useEffect(() => {
    if (refreshInterval === 0) {
      setCountdown(0);
      return;
    }
    setCountdown(refreshInterval);
    const timer = setInterval(() => {
      setCountdown((prev) => {
        if (prev <= 1) {
          onRefreshAll();
          return refreshInterval;
        }
        return prev - 1;
      });
    }, 1000);
    return () => clearInterval(timer);
  }, [refreshInterval, onRefreshAll]);

  const handleManualRefresh = async () => {
    setIsRefreshing(true);
    try {
      await onRefreshBalances();
      info('已同步最新状态', '账号状态、签到结果与用量统计已刷新');
    } catch (err: any) {
      error('刷新余额失败', err?.message || '请稍后重试');
    } finally {
      setIsRefreshing(false);
    }
  };

  return (
    <header className="border-b border-[#1c2933] bg-[#0c1217]/95 backdrop-blur sticky top-0 z-40">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-3.5 flex flex-wrap items-center justify-between gap-4">
        <div className="flex items-center gap-3.5">
          <div className="w-10 h-10 rounded-lg bg-emerald-500/10 border border-emerald-500/30 flex items-center justify-center text-emerald-400 shadow-[0_0_15px_rgba(16,185,129,0.15)]">
            <CalendarCheck className="w-5 h-5" />
          </div>
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-base sm:text-lg font-bold text-white tracking-tight">签到中枢</h1>
              <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded text-[11px] font-mono font-medium bg-emerald-500/10 text-emerald-300 border border-emerald-500/20">
                <span className="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse" />
                本机授权账号
              </span>
            </div>
            <p className="text-xs text-slate-400 hidden sm:block">
              WorkBuddy · Trae · Qoder 三平台自动签到与用量监控看板
            </p>
          </div>
        </div>

        <div className="flex items-center flex-wrap gap-2.5">
          <div className="hidden sm:flex items-center gap-1.5 px-2.5 py-1.5 text-xs rounded bg-[#131d24] border border-[#233543] text-slate-300 font-mono">
            <Clock className="w-3.5 h-3.5 text-slate-400" />
            <span>{currentTime || '--:--:--'}</span>
          </div>

          <div className="flex items-center bg-[#131d24] border border-[#233543] rounded px-2.5 py-1.5 text-xs text-slate-300">
            <span className="text-[11px] text-slate-400 mr-2">自动刷新:</span>
            <select
              value={refreshInterval}
              onChange={(e) => setRefreshInterval(Number(e.target.value))}
              aria-label="自动刷新频率选择"
              className="bg-transparent text-emerald-400 font-mono text-xs focus:outline-none cursor-pointer"
            >
              <option value={0} className="bg-[#121c22] text-slate-300">已关闭</option>
              <option value={30} className="bg-[#121c22] text-slate-300">30秒</option>
              <option value={60} className="bg-[#121c22] text-slate-300">60秒</option>
              <option value={120} className="bg-[#121c22] text-slate-300">120秒</option>
            </select>
            {refreshInterval > 0 && (
              <span className="ml-1.5 text-[11px] font-mono text-slate-500">({countdown}s)</span>
            )}
          </div>

          <button
            onClick={handleManualRefresh}
            disabled={isRefreshing}
            className="flex items-center gap-1.5 px-2.5 py-1.5 text-xs rounded bg-[#131d24] hover:bg-[#1a2731] border border-[#233543] text-slate-300 transition-colors disabled:opacity-50"
            title="刷新账号状态与余额"
          >
            <RefreshCw className={`w-3.5 h-3.5 text-slate-400 ${isRefreshing ? 'animate-spin text-emerald-400' : ''}`} />
            <span>刷新余额</span>
          </button>

          <button
            onClick={onCheckInAll}
            disabled={isGlobalChecking}
            className="flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold rounded bg-emerald-500 hover:bg-emerald-400 text-[#090d10] shadow-[0_0_15px_rgba(16,185,129,0.3)] transition-all disabled:opacity-60 disabled:cursor-not-allowed"
          >
            <Zap className={`w-3.5 h-3.5 fill-current ${isGlobalChecking ? 'animate-bounce' : ''}`} />
            <span>{isGlobalChecking ? '正在全部签到...' : '全部签到'}</span>
          </button>
        </div>
      </div>
    </header>
  );
};
