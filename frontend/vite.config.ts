import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import { defineConfig } from 'vite';

// 构建产物直接输出到 web_checkin/static/，由 FastAPI 在 /static 下托管。
// 这样 `web-checkin` 命令无需 Node 也能直接运行构建好的界面。
export default defineConfig(() => ({
  base: '/static/',
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: { '@': path.resolve(import.meta.dirname, '.') },
  },
  build: {
    outDir: '../web_checkin/static',
    emptyOutDir: true,
    chunkSizeWarningLimit: 1500,
  },
  server: {
    port: 3000,
    proxy: {
      // 本地开发时把接口转发到 FastAPI，避免跨域。
      '/api': 'http://127.0.0.1:8320',
    },
  },
}));
