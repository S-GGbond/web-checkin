import React, { useEffect, useState } from 'react';
import { Account } from '../../types';
import { Clock, X, Check } from 'lucide-react';
import { useToast } from '../ui/Toast';

interface ScheduleModalProps {
  account: Account | null;
  isOpen: boolean;
  onClose: () => void;
  onSave: (accountId: string, scheduleTime: string, scheduleEnabled: boolean) => Promise<void>;
}

const TIME_PATTERN = /^([01]\d|2[0-3]):([0-5]\d)$/;

export const ScheduleModal: React.FC<ScheduleModalProps> = ({ account, isOpen, onClose, onSave }) => {
  const [time, setTime] = useState('09:00');
  const [enabled, setEnabled] = useState(true);
  const [isSaving, setIsSaving] = useState(false);
  const { success, error, warn } = useToast();

  useEffect(() => {
    if (account) {
      setTime(account.schedule_time || '09:00');
      setEnabled(account.schedule_enabled);
    }
  }, [account]);

  if (!isOpen || !account) return null;

  const handleSave = async () => {
    if (!TIME_PATTERN.test(time)) {
      warn('时间格式不正确', '请使用 HH:MM 的 24 小时制时间');
      return;
    }
    setIsSaving(true);
    try {
      await onSave(account.id, time, enabled);
      success(
        '定时已更新',
        enabled ? `[${account.name}] 将于每天 ${time} 自动签到` : `[${account.name}] 已关闭自动签到`
      );
      onClose();
    } catch (err: any) {
      error('更新定时失败', err.message);
    } finally {
      setIsSaving(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/70 backdrop-blur-sm animate-in fade-in">
      <div className="bg-[#10171d] border border-[#233543] rounded-xl max-w-md w-full p-6 shadow-2xl relative">
        <button
          onClick={onClose}
          className="absolute top-4 right-4 text-slate-500 hover:text-white"
          aria-label="关闭"
        >
          <X className="w-5 h-5" />
        </button>

        <div className="flex items-center gap-2 mb-4">
          <Clock className="w-5 h-5 text-emerald-400" />
          <h3 className="text-base font-bold text-white">配置账号独立定时</h3>
        </div>

        <div className="text-xs text-slate-400 mb-4">
          针对 <span className="text-white font-semibold">[{account.name}]</span>{' '}
          设置每日自动签到时刻，与其他账号错峰执行。
        </div>

        <div className="space-y-4">
          <div>
            <label className="block text-xs font-medium text-slate-300 mb-1.5">
              每日执行时间 (24 小时制):
            </label>
            <input
              type="time"
              value={time}
              onChange={(e) => setTime(e.target.value)}
              aria-label="每日签到时间"
              className="w-full px-3 py-2 bg-[#131d24] border border-[#233543] rounded text-sm text-white font-mono focus:outline-none focus:border-emerald-500"
            />
            <div className="text-[11px] text-slate-500 mt-1">
              平台实际执行时间以本机时区为准；错过时间后当日会补跑一次。
            </div>
          </div>

          <label className="flex items-center justify-between p-3 rounded bg-[#131d24] border border-[#233543] cursor-pointer">
            <span className="text-xs text-slate-300">开启每日自动签到</span>
            <span className="flex items-center gap-2">
              <input
                type="checkbox"
                checked={enabled}
                onChange={(e) => setEnabled(e.target.checked)}
                className="sr-only peer"
              />
              <span className="text-[11px] text-slate-400">{enabled ? '已开启' : '已关闭'}</span>
              <span className="w-8 h-4 rounded-full bg-slate-700 relative after:content-[''] after:absolute after:top-[2px] after:left-[2px] after:w-3 after:h-3 after:rounded-full after:bg-white after:transition-all peer-checked:bg-emerald-500 peer-checked:after:translate-x-4" />
            </span>
          </label>

          {!account.is_active && (
            <div className="text-[11px] text-amber-400/90">
              注意：该账号当前处于停用状态，启用账号后定时才会生效。
            </div>
          )}
        </div>

        <div className="mt-6 flex justify-end gap-2.5 pt-3 border-t border-[#1e2a34]">
          <button
            onClick={onClose}
            className="px-3.5 py-1.5 text-xs rounded bg-[#131d24] hover:bg-[#1a2731] text-slate-300 border border-[#233543]"
          >
            取消
          </button>
          <button
            onClick={handleSave}
            disabled={isSaving}
            className="px-4 py-1.5 text-xs font-semibold rounded bg-emerald-500 hover:bg-emerald-400 text-[#090d10] flex items-center gap-1 disabled:opacity-50"
          >
            <Check className="w-3.5 h-3.5" />
            <span>{isSaving ? '正在保存...' : '确认生效'}</span>
          </button>
        </div>
      </div>
    </div>
  );
};
