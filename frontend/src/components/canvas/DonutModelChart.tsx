import React, { useRef, useEffect, useState, useCallback } from 'react';

interface Slice {
  name: string;
  value: number;
  color: string;
}

interface DonutModelChartProps {
  data: Record<string, number>;
  height?: number;
  colors?: string[];
}

const DEFAULT_COLORS = [
  '#10b981', // Mint Emerald
  '#06b6d4', // Cyan
  '#3b82f6', // Blue
  '#8b5cf6', // Violet
  '#f59e0b', // Amber
  '#ec4899', // Pink
];

export const DonutModelChart: React.FC<DonutModelChartProps> = ({
  data,
  height = 220,
  colors = DEFAULT_COLORS,
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
    const rect = container.getBoundingClientRect();
    const width = rect.width;

    canvas.width = width * dpr;
    canvas.height = height * dpr;
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;

    ctx.scale(dpr, dpr);
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
    ctx.fillText('总计 Token', centerX, centerY - 10);

    ctx.fillStyle = '#f1f5f9';
    ctx.font = '600 14px "JetBrains Mono", monospace';
    const totalDisplay =
      total > 1000000 ? `${(total / 1000000).toFixed(1)}M` : `${(total / 1000).toFixed(0)}k`;
    ctx.fillText(totalDisplay, centerX, centerY + 10);
  }, [slices, total, height, hoverIdx]);

  useEffect(() => {
    drawDonut();
    const handleResize = () => drawDonut();
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, [drawDonut]);

  return (
    <div ref={containerRef} className="flex flex-col md:flex-row items-center gap-4 w-full">
      <div className="relative w-full max-w-[220px]">
        <canvas ref={canvasRef} className="block mx-auto" />
      </div>

      {/* Legend */}
      <div className="flex-1 w-full grid grid-cols-1 sm:grid-cols-2 gap-2 text-xs">
        {slices.map((slice, idx) => {
          const pct = total > 0 ? ((slice.value / total) * 100).toFixed(1) : '0';
          const isHovered = hoverIdx === idx;
          return (
            <div
              key={slice.name}
              onMouseEnter={() => setHoverIdx(idx)}
              onMouseLeave={() => setHoverIdx(null)}
              className={`flex items-center justify-between p-2 rounded transition-colors cursor-pointer ${
                isHovered ? 'bg-[#18232c] text-white' : 'bg-[#121a20] text-slate-300 hover:bg-[#152028]'
              }`}
            >
              <div className="flex items-center gap-2 truncate">
                <span className="w-2.5 h-2.5 rounded-full shrink-0" style={{ backgroundColor: slice.color }} />
                <span className="truncate font-medium">{slice.name}</span>
              </div>
              <div className="flex items-center gap-2 font-mono ml-2 shrink-0">
                <span className="text-slate-400">{(slice.value / 1000).toFixed(0)}k</span>
                <span className="text-emerald-400 font-semibold">{pct}%</span>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
};
