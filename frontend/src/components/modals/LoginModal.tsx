import React, { useState, useEffect, useRef } from 'react';
import { Platform, LoginInitResponse } from '../../types';
import { apiService } from '../../services/api';
import { ShieldCheck, RefreshCw, CheckCircle2, X, ExternalLink, Copy, Loader2 } from 'lucide-react';
import { useToast } from '../ui/Toast';

interface LoginModalProps {
  isOpen: boolean;
  initialPlatform?: Platform;
  onClose: () => void;
  onAccountCreated: () => void;
}

const PLATFORM_LABEL: Record<Platform, string> = {
  workbuddy: 'WorkBuddy',
  trae: 'Trae',
  qoder: 'Qoder',
};

export const LoginModal: React.FC<LoginModalProps> = ({
  isOpen,
  initialPlatform = 'workbuddy',
  onClose,
  onAccountCreated,
}) => {
  // 平台由外层「添加账号」卡片选定，弹窗内不再提供切换。
  const platform = initialPlatform;
  const [session, setSession] = useState<LoginInitResponse | null>(null);
  const [statusText, setStatusText] = useState('正在创建授权会话…');
  const [authUrl, setAuthUrl] = useState('');
  const [isFinal, setIsFinal] = useState(false);
  const [isInitializing, setIsInitializing] = useState(false);
  const pollTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const { success, error } = useToast();

  const stopPolling = () => {
    if (pollTimerRef.current) {
      clearInterval(pollTimerRef.current);
      pollTimerRef.current = null;
    }
  };

  const startLogin = async (target: Platform) => {
    stopPolling();
    setIsInitializing(true);
    setIsFinal(false);
    setSession(null);
    setAuthUrl('');
    setStatusText('正在创建授权会话…');
    try {
      const res = await apiService.initLogin(target);
      setSession(res);
      setAuthUrl(res.auth_url || '');
      setStatusText(res.message || '请在打开的授权页面完成登录');
      // 自动打开授权页（浏览器可能拦截，用户仍可点击按钮手动打开）
      if (res.auth_url) {
        window.open(res.auth_url, '_blank', 'noopener');
      }
    } catch (err: any) {
      setStatusText('创建授权会话失败');
      error('启动登录失败', err.message);
    } finally {
      setIsInitializing(false);
    }
  };

  useEffect(() => {
    if (isOpen) {
      startLogin(platform);
    } else {
      stopPolling();
    }
    return stopPolling;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen, platform]);

  // 轮询登录状态
  useEffect(() => {
    if (!isOpen || !session) return;
    stopPolling();
    pollTimerRef.current = setInterval(async () => {
      try {
        const res = await apiService.pollLoginStatus(platform, session.id);
        setStatusText(res.message || res.status);
        if (res.status === 'success' || res.status === 'failed') {
          stopPolling();
          setIsFinal(true);
          if (res.status === 'success') {
            success('登录成功', res.message || '账号已写入本地 SQLite');
            onAccountCreated();
            setTimeout(onClose, 600);
          } else {
            error('登录失败', res.message || '授权未完成');
          }
        }
      } catch (err: any) {
        stopPolling();
        setIsFinal(true);
        setStatusText(err.message || '登录会话已失效');
        error('登录会话异常', err.message);
      }
    }, 1500);
    return stopPolling;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isOpen, session, platform]);

  const handleCopy = async () => {
    if (!authUrl) return;
    try {
      await navigator.clipboard.writeText(authUrl);
      success('链接已复制', '请在浏览器中粘贴打开完成授权');
    } catch {
      error('复制失败', '请手动选中链接复制');
    }
  };

  if (!isOpen) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/70 backdrop-blur-sm animate-in fade-in">
      <div className="bg-[#10171d] border border-[#233543] rounded-xl max-w-md w-full p-6 shadow-2xl relative">
        <button
          onClick={onClose}
          className="absolute top-4 right-4 text-slate-500 hover:text-white transition-colors"
          aria-label="关闭弹窗"
        >
          <X className="w-5 h-5" />
        </button>

        <div className="flex items-center gap-2 mb-5">
          <ShieldCheck className="w-5 h-5 text-emerald-400" />
          <h3 className="text-base font-bold text-white">{PLATFORM_LABEL[platform]} 官方授权登录</h3>
        </div>

        <div className="p-4 bg-[#090d10] border border-[#1b2732] rounded-lg">
          <div className="flex items-center gap-2 text-xs text-slate-300">
            {isFinal ? (
              <CheckCircle2 className="w-4 h-4 text-emerald-400" />
            ) : (
              <Loader2 className="w-4 h-4 text-emerald-400 animate-spin" />
            )}
            <span>{statusText}</span>
          </div>

          <div className="mt-3">
            <div className="text-[11px] text-slate-500 mb-1">授权链接：</div>
            <div className="p-2 rounded bg-[#0d1419] border border-[#1e2a34] text-[11px] text-emerald-300/90 font-mono break-all max-h-24 overflow-y-auto">
              {authUrl || '（等待生成）'}
            </div>
          </div>

          <div className="mt-3 flex items-center gap-2">
            <a
              href={authUrl || '#'}
              target="_blank"
              rel="noopener noreferrer"
              className={`flex items-center gap-1.5 px-3 py-1.5 text-xs font-semibold rounded ${
                authUrl ? 'bg-emerald-500 hover:bg-emerald-400 text-[#090d10]' : 'bg-slate-700 text-slate-400 pointer-events-none'
              }`}
            >
              <ExternalLink className="w-3.5 h-3.5" />
              <span>打开授权页</span>
            </a>
            <button
              onClick={handleCopy}
              disabled={!authUrl}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded bg-[#131d24] hover:bg-[#1a2731] text-slate-300 border border-[#233543] disabled:opacity-50"
            >
              <Copy className="w-3.5 h-3.5" />
              <span>复制链接</span>
            </button>
            <button
              onClick={() => startLogin(platform)}
              disabled={isInitializing}
              className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded bg-[#131d24] hover:bg-[#1a2731] text-slate-300 border border-[#233543] disabled:opacity-50 ml-auto"
            >
              <RefreshCw className={`w-3.5 h-3.5 ${isInitializing ? 'animate-spin' : ''}`} />
              <span>重新生成</span>
            </button>
          </div>
        </div>

        <div className="mt-4 text-[11px] text-slate-500 leading-relaxed">
          登录在平台官方页面完成，本项目不会接触你的账号密码。授权成功后登录态会加密写入本地 SQLite，用于后续签到与用量查询。
        </div>

        <div className="mt-5 flex justify-end gap-2.5 pt-3 border-t border-[#1e2a34]">
          <button
            onClick={onClose}
            className="px-3.5 py-1.5 text-xs rounded bg-[#131d24] hover:bg-[#1a2731] text-slate-300 border border-[#233543]"
          >
            关闭
          </button>
        </div>
      </div>
    </div>
  );
};
