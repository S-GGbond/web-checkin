import React, { useRef, useEffect, useState, useCallback } from 'react';

interface BarData {
  label: string;
  value: number;
  highlight?: boolean;
}

interface BarUsageChartProps {
  data: BarData[];
  height?: number;
  valueFormatter?: (val: number) => string;
  metricName?: string;
  barColor?: string;
}

export const BarUsageChart: React.FC<BarUsageChartProps> = ({
  data,
  height = 200,
  valueFormatter = (v) => v.toLocaleString(),
  metricName = '请求次数',
  barColor = '#10b981',
}) => {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [hoverIndex, setHoverIndex] = useState<number | null>(null);
  const [hoverPos, setHoverPos] = useState<{ x: number; y: number } | null>(null);

  const drawChart = useCallback(() => {
    const canvas = canvasRef.current;
    const container = containerRef.current;
    if (!canvas || !container || data.length === 0) return;

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

    const padding = { top: 20, right: 16, bottom: 32, left: 44 };
    const chartW = width - padding.left - padding.right;
    const chartH = height - padding.top - padding.bottom;

    if (chartW <= 0 || chartH <= 0) return;

    const maxVal = Math.max(...data.map((d) => d.value), 1);
    const yMax = Math.ceil(maxVal * 1.15);

    // Draw baseline and background lines
    ctx.font = '10px "JetBrains Mono", monospace';
    ctx.fillStyle = '#64748b';
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';

    const rows = 3;
    for (let i = 0; i <= rows; i++) {
      const yVal = Math.round((yMax / rows) * (rows - i));
      const yPos = padding.top + (chartH / rows) * i;

      ctx.beginPath();
      ctx.strokeStyle = '#15212a';
      ctx.lineWidth = 1;
      ctx.moveTo(padding.left, yPos);
      ctx.lineTo(width - padding.right, yPos);
      ctx.stroke();

      ctx.fillText(valueFormatter(yVal), padding.left - 6, yPos);
    }

    // Draw bars
    const totalBars = data.length;
    const slotW = chartW / totalBars;
    const barW = Math.max(2, Math.min(slotW * 0.7, 16));

    data.forEach((d, idx) => {
      const barH = (d.value / yMax) * chartH;
      const x = padding.left + idx * slotW + (slotW - barW) / 2;
      const y = padding.top + chartH - barH;

      const isHovered = hoverIndex === idx;

      ctx.beginPath();
      ctx.rect(x, y, barW, Math.max(barH, 2));

      if (isHovered) {
        ctx.fillStyle = '#34d399';
        ctx.shadowColor = 'rgba(52, 211, 153, 0.4)';
        ctx.shadowBlur = 8;
      } else {
        ctx.fillStyle = barColor;
        ctx.shadowBlur = 0;
      }
      ctx.fill();
      ctx.shadowBlur = 0;

      // X labels sparsely
      if (idx % Math.max(1, Math.floor(totalBars / 8)) === 0 || idx === totalBars - 1) {
        ctx.fillStyle = '#64748b';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'top';
        const shortLabel = d.label.length >= 10 ? d.label.slice(5) : d.label;
        ctx.fillText(shortLabel, x + barW / 2, height - padding.bottom + 8);
      }
    });
  }, [data, height, valueFormatter, barColor, hoverIndex]);

  useEffect(() => {
    drawChart();
    const handleResize = () => drawChart();
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, [drawChart]);

  const handleMouseMove = (e: React.MouseEvent<HTMLCanvasElement>) => {
    const canvas = canvasRef.current;
    if (!canvas || data.length === 0) return;

    const rect = canvas.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;

    const padding = { top: 20, right: 16, bottom: 32, left: 44 };
    const chartW = rect.width - padding.left - padding.right;

    if (x < padding.left || x > rect.width - padding.right) {
      setHoverIndex(null);
      setHoverPos(null);
      return;
    }

    const slotW = chartW / data.length;
    const index = Math.floor((x - padding.left) / slotW);
    const clampedIndex = Math.max(0, Math.min(data.length - 1, index));

    setHoverIndex(clampedIndex);
    setHoverPos({ x, y });
  };

  const handleMouseLeave = () => {
    setHoverIndex(null);
    setHoverPos(null);
  };

  const active = hoverIndex !== null ? data[hoverIndex] : null;

  return (
    <div ref={containerRef} className="relative w-full overflow-hidden select-none">
      <canvas
        ref={canvasRef}
        onMouseMove={handleMouseMove}
        onMouseLeave={handleMouseLeave}
        className="w-full block cursor-pointer"
      />
      {active && hoverPos && (
        <div
          className="absolute pointer-events-none z-20 bg-[#121c22] border border-[#233541] rounded px-3 py-1.5 text-xs shadow-xl"
          style={{
            left: Math.min(Math.max(hoverPos.x - 50, 8), (containerRef.current?.clientWidth || 300) - 130),
            top: Math.max(hoverPos.y - 50, 4),
          }}
        >
          <div className="text-slate-400 font-mono text-[11px]">{active.label}</div>
          <div className="text-emerald-400 font-semibold flex items-center gap-1.5">
            <span>{metricName}:</span>
            <span className="font-mono text-white">{valueFormatter(active.value)}</span>
          </div>
        </div>
      )}
    </div>
  );
};
