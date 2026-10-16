import React, { useRef, useEffect, useState, useCallback } from 'react';

interface Slice {
  name: string;
  value: number;
  color: string;
}

interface DonutModelChartProps {
  /** 模型 -> 积分（credit）用量。 */
  data: Record<string, number>;
  height?: number;
  colors?: string[];
  /** 圆环中心标题。 */
  centerLabel?: string;
}

const DEFAULT_COLORS = [
  '#10b981', // Mint Emerald
  '#06b6d4', // Cyan
  '#3b82f6', // Blue
  '#8b5cf6', // Violet
  '#f59e0b', // Amber
  '#ec4899', // Pink
];

/** 积分数值格式化：小数值保留小数，大数值才压缩为 k/M，避免出现误导性的 "0k"。 */
export function formatCredits(value: number): string {
  if (!Number.isFinite(value)) return '0';
  const abs = Math.abs(value);
  if (abs >= 1_000_000) return `${(value / 1_000_000).toFixed(2)}M`;
  if (abs >= 10_000) return `${(value / 1000).toFixed(1)}k`;
  return value.toLocaleString('zh-CN', { maximumFractionDigits: 2 });
}

export const DonutModelChart: React.FC<DonutModelChartProps> = ({
  data,
  height = 220,
  colors = DEFAULT_COLORS,
  centerLabel = '总计积分',
}) => {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [hoverIdx, setHoverIdx] = useState<number | null>(null);

  const slices: Slice[] = Object.entries(data).map(([name, value], i) => ({
    name,
    value,
    color: colors[i % colors.length],
  }));

  const total = slices.reduce((acc, cur) => acc + cur.value, 0);

  const drawDonut = useCallback(() => {
    const canvas = canvasRef.current;
    const container = containerRef.current;
    if (!canvas || !container) return;

    const ctx = canvas.getContext('2d');
    if (!ctx) return;

    const dpr = window.devicePixelRatio || 1;
    // 注意：这里取的是 canvas 自身容器（220px 槽位）的宽度，而不是外层 flex 行，
    // 否则画布会被撑到整行宽度并与右侧图例重叠。
    const rect = container.getBoundingClientRect();
    const width = rect.width || 220;

    canvas.width = width * dpr;
    canvas.height = height * dpr;
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;

    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, width, height);

    if (total === 0) {
      ctx.fillStyle = '#64748b';
      ctx.font = '12px "JetBrains Mono", monospace';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.fillText('暂无模型用量数据', width / 2, height / 2);
      return;
    }

    const centerX = width / 2;
    const centerY = height / 2;
    const outerRadius = Math.min(centerX, centerY) - 16;
    const innerRadius = outerRadius * 0.65;

    let currentAngle = -Math.PI / 2;

    slices.forEach((slice, idx) => {
      const sliceAngle = (slice.value / total) * Math.PI * 2;
      const isHovered = hoverIdx === idx;
      const rOuter = isHovered ? outerRadius + 4 : outerRadius;

      ctx.beginPath();
      ctx.arc(centerX, centerY, rOuter, currentAngle, currentAngle + sliceAngle);
      ctx.arc(centerX, centerY, innerRadius, currentAngle + sliceAngle, currentAngle, true);
      ctx.closePath();

      ctx.fillStyle = slice.color;
      ctx.fill();

      // Border line separating slices
      ctx.lineWidth = 2;
      ctx.strokeStyle = '#10171d';
      ctx.stroke();

      currentAngle += sliceAngle;
    });

    // Center text
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillStyle = '#94a3b8';
    ctx.font = '11px sans-serif';
    ctx.fillText(centerLabel, centerX, centerY - 10);

    ctx.fillStyle = '#f1f5f9';
    ctx.font = '600 14px "JetBrains Mono", monospace';
    ctx.fillText(formatCredits(total), centerX, centerY + 10);
  }, [slices, total, height, hoverIdx, centerLabel]);

  useEffect(() => {
    drawDonut();
    const handleResize = () => drawDonut();
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, [drawDonut]);

  return (
    <div className="flex flex-col md:flex-row items-center gap-4 w-full">
      <div ref={containerRef} className="relative w-full max-w-[220px] shrink-0">
        <canvas ref={canvasRef} className="block mx-auto" />
      </div>

      {/* Legend */}
      <div className="flex-1 w-full flex flex-col gap-2 text-xs max-h-[200px] overflow-y-auto pr-1">
        {slices.map((slice, idx) => {
          const pct = total > 0 ? ((slice.value / total) * 100).toFixed(1) : '0';
          const isHovered = hoverIdx === idx;
          return (
            <div
              key={slice.name}
              onMouseEnter={() => setHoverIdx(idx)}
              onMouseLeave={() => setHoverIdx(null)}
              className={`flex items-center justify-between gap-2 p-2 rounded transition-colors cursor-pointer ${
                isHovered ? 'bg-[#18232c] text-white' : 'bg-[#121a20] text-slate-300 hover:bg-[#152028]'
              }`}
            >
              <div className="flex items-center gap-2 min-w-0">
                <span className="w-2.5 h-2.5 rounded-full shrink-0" style={{ backgroundColor: slice.color }} />
                <span className="truncate font-medium" title={slice.name}>{slice.name}</span>
              </div>
              <div className="flex items-center gap-2 font-mono ml-2 shrink-0">
                <span className="text-slate-400">{formatCredits(slice.value)}</span>
                <span className="text-emerald-400 font-semibold">{pct}%</span>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
};
