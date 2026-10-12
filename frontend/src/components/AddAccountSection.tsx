import React, { useState } from 'react';
import { Platform } from '../types';
import { UserPlus, ShieldCheck, Clock, HelpCircle, ChevronDown, ChevronUp, LogIn } from 'lucide-react';

interface AddAccountSectionProps {
  /** 点击平台卡片后启动该平台的官方授权登录流程。 */
  onLogin: (platform: Platform) => void;
}

const PLATFORMS: Array<{ id: Platform; label: string; hint: string; auth: string; accent: string }> = [
  {
    id: 'workbuddy',
    label: 'WorkBuddy',
    hint: '支持每日签到与 31 天用量明细',
    auth: '浏览器 OAuth 授权',
    accent: 'emerald',
  },
  {
    id: 'trae',
    label: 'Trae',
    hint: '支持签到与 91 天积分用量明细',
    auth: 'Web PKCE 授权',
    accent: 'cyan',
  },
  {
    id: 'qoder',
    label: 'Qoder',
    hint: '支持多活动领取与每日签到',
    auth: '设备码 PKCE 授权',
    accent: 'purple',
  },
];

export const AddAccountSection: React.FC<AddAccountSectionProps> = ({ onLogin }) => {
  const [showScheduleInfo, setShowScheduleInfo] = useState(false);

  return (
    <section aria-label="添加托管账号" className="bg-[#10171d] border border-[#1e2a34] rounded-lg p-5">
      <div className="flex flex-wrap items-center justify-between gap-2 mb-4">
        <div className="flex items-center gap-2">
          <UserPlus className="w-5 h-5 text-emerald-400" />
          <h2 className="text-base font-semibold text-white">添加托管账号</h2>
          <span className="text-xs text-slate-400">· 通过平台官方授权登录，登录态写入本地 SQLite</span>
        </div>

        <button
          type="button"
          onClick={() => setShowScheduleInfo(!showScheduleInfo)}
          className="flex items-center gap-1.5 text-xs text-slate-400 hover:text-emerald-400 transition-colors"
        >
          <HelpCircle className="w-3.5 h-3.5" />
          <span>为什么每个账号独立定时？</span>
          {showScheduleInfo ? <ChevronUp className="w-3.5 h-3.5" /> : <ChevronDown className="w-3.5 h-3.5" />}
        </button>
      </div>

      {showScheduleInfo && (
        <div className="mb-5 p-4 rounded bg-[#131d24] border border-[#233543] text-xs text-slate-300 leading-relaxed">
          <div className="flex items-start gap-2.5">
            <Clock className="w-4 h-4 text-cyan-400 shrink-0 mt-0.5" />
            <div className="space-y-1.5">
              <div className="font-semibold text-slate-200">
                独立定时设计原理与风控隔离说明 (Independent Schedule Architecture)：
              </div>
              <ul className="list-disc list-inside space-y-1 text-slate-400">
                <li>
                  <strong className="text-slate-300">错峰请求 (Traffic Staggering)：</strong>
                  多个账号在同一秒发起签到与配额查询，容易触发平台频率限制与风控校验。
                </li>
                <li>
                  <strong className="text-slate-300">账号隔离 (Failure Isolation)：</strong>
                  每个账号拥有各自的定时与重试策略，单一账号登录态失效不会阻塞其他账号。
                </li>
                <li>
                  <strong className="text-slate-300">精准生命周期跟踪：</strong>
                  各平台每日任务刷新时间不同，独立定时可分别设定打卡时刻。
                </li>
                <li className="text-emerald-300/90">
                  定时时间在下方「托管账号列表」的每张账号卡片中单独设置。
                </li>
              </ul>
            </div>
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
        {PLATFORMS.map((p) => (
          <button
            key={p.id}
            type="button"
            onClick={() => onLogin(p.id)}
            aria-label={`登录 ${p.label}`}
            className="group p-4 rounded-lg border border-[#1e2a34] bg-[#121a20] text-left transition-all hover:border-[#2a3c4a] hover:bg-[#141e26] cursor-pointer"
          >
            <div className="flex items-center justify-between">
              <span className="font-semibold text-sm text-white">{p.label}</span>
              <LogIn className="w-4 h-4 text-slate-500 group-hover:text-emerald-400 transition-colors" />
            </div>
            <div className="text-[11px] text-slate-400 mt-1">{p.hint}</div>
            <div className="mt-3 flex items-center gap-1.5 text-[11px] text-emerald-400/90">
              <ShieldCheck className="w-3.5 h-3.5" />
              <span>{p.auth}</span>
            </div>
          </button>
        ))}
      </div>
    </section>
  );
};
