import React, { useState, useEffect, useCallback } from 'react';
import { Account, SystemStats, Platform } from './types';
import { apiService } from './services/api';
import { ToastProvider, useToast } from './components/ui/Toast';
import { Header } from './components/Header';
import { StatsCards } from './components/StatsCards';
import { AddAccountSection } from './components/AddAccountSection';
import { AccountCardsSection } from './components/AccountCardsSection';
import { WorkBuddyUsageSection } from './components/WorkBuddyUsageSection';
import { TraeUsageSection } from './components/TraeUsageSection';
import { ExecutionLogsSection } from './components/ExecutionLogsSection';
import { LoginModal } from './components/modals/LoginModal';
import { ScheduleModal } from './components/modals/ScheduleModal';

function DashboardContent() {
  const emptyStats: SystemStats = {
    total_accounts: 0,
    checked_in_today: 0,
    unchecked_today: 0,
    scheduled_accounts: 0,
    workbuddy_credits_left: 0,
    workbuddy_has_unlimited: false,
    trae_credits_left: 0,
    trae_has_unlimited: false,
    platform_counts: { workbuddy: 0, trae: 0, qoder: 0 },
  };

  const [stats, setStats] = useState<SystemStats>(emptyStats);
  const [accounts, setAccounts] = useState<Account[]>([]);
  const [refreshInterval, setRefreshInterval] = useState<number>(60);
  const [isGlobalChecking, setIsGlobalChecking] = useState(false);
  const [loginModalOpen, setLoginModalOpen] = useState(false);
  const [loginPlatform, setLoginPlatform] = useState<Platform>('workbuddy');
  const [scheduleModalAccount, setScheduleModalAccount] = useState<Account | null>(null);

  const { success, error } = useToast();

  const loadAllData = useCallback(async () => {
    try {
      const [accs, newStats] = await Promise.all([apiService.getAccounts(), apiService.getStats()]);
      setAccounts(accs);
      setStats(newStats);
    } catch (err: any) {
      console.error('Failed to load data:', err);
    }
  }, []);

  useEffect(() => {
    loadAllData();
  }, [loadAllData]);

  const handleRefreshBalances = useCallback(async () => {
    const { failed } = await apiService.refreshAllAccounts();
    await loadAllData();
    if (failed > 0) {
      throw new Error(`${failed} 个账号刷新失败，详见执行日志`);
    }
  }, [loadAllData]);

  const handleCheckInAll = async () => {
    try {
      setIsGlobalChecking(true);
      const res = await apiService.checkInAll();
      await loadAllData();
      if (res.failed_count === 0) {
        success('一键全部签到成功', `全部 ${res.success_count} 个启用账号已完成签到`);
      } else {
        success('批量签到执行完毕', `成功 ${res.success_count} 个，失败 ${res.failed_count} 个，详见执行日志`);
      }
    } catch (err: any) {
      error('批量签到异常', err.message);
    } finally {
      setIsGlobalChecking(false);
    }
  };

  const handleSingleCheckin = async (id: string) => {
    await apiService.checkInAccount(id);
    await loadAllData();
  };

  const handleSingleRefresh = async (id: string) => {
    await apiService.refreshAccount(id);
    await loadAllData();
  };

  const handleToggleActive = async (id: string, active: boolean) => {
    await apiService.updateAccount(id, { is_active: active });
    await loadAllData();
  };

  const handleSaveSchedule = async (id: string, time: string, enabled: boolean) => {
    await apiService.updateAccount(id, { schedule_enabled: enabled, schedule_time: time });
    await loadAllData();
  };

  const handleDeleteAccount = async (id: string, name: string) => {
    if (window.confirm(`确定要删除账号 [${name}] 吗？此操作将停止其独立定时签到。`)) {
      try {
        await apiService.deleteAccount(id);
        success('账号已删除', `账号 [${name}] 已从调度池移除`);
        await loadAllData();
      } catch (err: any) {
        error('删除账号失败', err.message);
      }
    }
  };

  const handleOpenLogin = (platform: Platform) => {
    setLoginPlatform(platform);
    setLoginModalOpen(true);
  };

  return (
    <div className="min-h-screen bg-[#090d10] text-[#e2e8f0] flex flex-col font-sans selection:bg-emerald-500/20 selection:text-emerald-300">
      <Header
        onRefreshAll={loadAllData}
        onRefreshBalances={handleRefreshBalances}
        refreshInterval={refreshInterval}
        setRefreshInterval={setRefreshInterval}
        isGlobalChecking={isGlobalChecking}
        onCheckInAll={handleCheckInAll}
      />

      <main className="flex-1 max-w-7xl w-full mx-auto px-4 sm:px-6 lg:px-8 py-6 space-y-6">
        <StatsCards stats={stats} />

        <AddAccountSection onLogin={handleOpenLogin} />

        <AccountCardsSection
          accounts={accounts}
          onCheckIn={handleSingleCheckin}
          onRefresh={handleSingleRefresh}
          onToggleActive={handleToggleActive}
          onEditSchedule={(acc) => setScheduleModalAccount(acc)}
          onDeleteAccount={handleDeleteAccount}
        />

        <WorkBuddyUsageSection />

        <TraeUsageSection />

        <ExecutionLogsSection />
      </main>

      <footer className="border-t border-[#18232c] bg-[#0c1217] py-4 text-center text-xs text-slate-500">
        <div className="max-w-7xl mx-auto px-4 flex flex-wrap items-center justify-between gap-2">
          <span>签到中枢 · WorkBuddy / Trae / Qoder 多平台自动签到与用量看板</span>
          <span className="font-mono text-[11px] text-slate-400">
            WorkBuddy (31天) · Trae (91天) · Qoder 活动领取 · 纯静态 Canvas
          </span>
        </div>
      </footer>

      <LoginModal
        isOpen={loginModalOpen}
        initialPlatform={loginPlatform}
        onClose={() => setLoginModalOpen(false)}
        onAccountCreated={loadAllData}
      />

      <ScheduleModal
        account={scheduleModalAccount}
        isOpen={!!scheduleModalAccount}
        onClose={() => setScheduleModalAccount(null)}
        onSave={handleSaveSchedule}
      />
    </div>
  );
}

export default function App() {
  return (
    <ToastProvider>
      <DashboardContent />
    </ToastProvider>
  );
}
