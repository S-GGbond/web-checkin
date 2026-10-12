import React, { useRef, useEffect, useState, useCallback } from 'react';

interface DataPoint {
  label: string; // Date or category
  value: number;
  secondaryValue?: number;
}

interface TrendLineChartProps {
  data: DataPoint[];
  height?: number;
  valueFormatter?: (val: number) => string;
  metricName?: string;
  secondaryMetricName?: string;
  color?: string; // e.g. '#10b981'
  secondaryColor?: string;
}

export const TrendLineChart: React.FC<TrendLineChartProps> = ({
  data,
  height = 240,
  valueFormatter = (v) => v.toLocaleString(),
  metricName = '消耗量',
  secondaryMetricName,
  color = '#10b981',
  secondaryColor = '#06b6d4',
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

    // Retina support
    const dpr = window.devicePixelRatio || 1;
    const rect = container.getBoundingClientRect();
    const width = rect.width;

    canvas.width = width * dpr;
    canvas.height = height * dpr;
    canvas.style.width = `${width}px`;
    canvas.style.height = `${height}px`;

    ctx.scale(dpr, dpr);
    ctx.clearRect(0, 0, width, height);

    const padding = { top: 24, right: 24, bottom: 36, left: 56 };
    const chartW = width - padding.left - padding.right;
    const chartH = height - padding.top - padding.bottom;

    if (chartW <= 0 || chartH <= 0) return;

    // Calculate bounds
    const maxVal = Math.max(...data.map((d) => d.value), 1);
    const yMax = Math.ceil(maxVal * 1.15);

    // Draw horizontal grid lines & Y labels
    const gridRows = 4;
    ctx.font = '11px "JetBrains Mono", monospace';
    ctx.fillStyle = '#64748b';
    ctx.textAlign = 'right';
    ctx.textBaseline = 'middle';

    for (let i = 0; i <= gridRows; i++) {
      const yVal = Math.round((yMax / gridRows) * (gridRows - i));
      const yPos = padding.top + (chartH / gridRows) * i;

      // Grid line
      ctx.beginPath();
      ctx.strokeStyle = i === gridRows ? '#1e293b' : '#141f27';
      ctx.lineWidth = 1;
      ctx.moveTo(padding.left, yPos);
      ctx.lineTo(width - padding.right, yPos);
      ctx.stroke();

      // Y Label
      ctx.fillText(valueFormatter(yVal), padding.left - 8, yPos);
    }

    // Points coordinates
    const points: Array<{ x: number; y: number; val: number }> = [];
    const stepX = chartW / Math.max(data.length - 1, 1);

    data.forEach((d, idx) => {
      const x = padding.left + idx * stepX;
      const y = padding.top + chartH - (d.value / yMax) * chartH;
      points.push({ x, y, val: d.value });
    });

    // Draw area fill
    ctx.beginPath();
    ctx.moveTo(points[0].x, padding.top + chartH);
    points.forEach((p) => ctx.lineTo(p.x, p.y));
    ctx.lineTo(points[points.length - 1].x, padding.top + chartH);
    ctx.closePath();

    const gradient = ctx.createLinearGradient(0, padding.top, 0, padding.top + chartH);
    gradient.addColorStop(0, 'rgba(16, 185, 129, 0.28)');
    gradient.addColorStop(1, 'rgba(16, 185, 129, 0.00)');
    ctx.fillStyle = gradient;
    ctx.fill();

    // Draw main trend line
    ctx.beginPath();
    ctx.strokeStyle = color;
    ctx.lineWidth = 2.5;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';

    points.forEach((p, idx) => {
      if (idx === 0) ctx.moveTo(p.x, p.y);
      else ctx.lineTo(p.x, p.y);
    });
    ctx.stroke();

    // Draw X-axis labels (sparse)
    ctx.fillStyle = '#64748b';
    ctx.textAlign = 'center';
    ctx.textBaseline = 'top';

    const labelInterval = Math.max(1, Math.floor(data.length / 7));
    data.forEach((d, idx) => {
      if (idx % labelInterval === 0 || idx === data.length - 1) {
        const x = padding.left + idx * stepX;
        // Truncate label to MM-DD if YYYY-MM-DD
        const shortLabel = d.label.length >= 10 ? d.label.slice(5) : d.label;
        ctx.fillText(shortLabel, x, height - padding.bottom + 10);
      }
    });

    // Hover effect
    if (hoverIndex !== null && points[hoverIndex]) {
      const p = points[hoverIndex];

      // Vertical guide line
      ctx.beginPath();
      ctx.strokeStyle = 'rgba(255, 255, 255, 0.2)';
      ctx.lineWidth = 1;
      ctx.setLineDash([3, 3]);
      ctx.moveTo(p.x, padding.top);
      ctx.lineTo(p.x, padding.top + chartH);
      ctx.stroke();
      ctx.setLineDash([]);

      // Glow circle
      ctx.beginPath();
      ctx.arc(p.x, p.y, 6, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
      ctx.strokeStyle = '#ffffff';
      ctx.lineWidth = 2;
      ctx.stroke();
    }
  }, [data, height, valueFormatter, color, hoverIndex]);

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

    const padding = { top: 24, right: 24, bottom: 36, left: 56 };
    const chartW = rect.width - padding.left - padding.right;

    if (x < padding.left || x > rect.width - padding.right) {
      setHoverIndex(null);
      setHoverPos(null);
      return;
    }

    const stepX = chartW / Math.max(data.length - 1, 1);
    const index = Math.round((x - padding.left) / stepX);
    const clampedIndex = Math.max(0, Math.min(data.length - 1, index));

    setHoverIndex(clampedIndex);
    setHoverPos({ x, y });
  };

  const handleMouseLeave = () => {
    setHoverIndex(null);
    setHoverPos(null);
  };

  const activePoint = hoverIndex !== null ? data[hoverIndex] : null;

  return (
    <div ref={containerRef} className="relative w-full overflow-hidden select-none">
      <canvas
        ref={canvasRef}
        onMouseMove={handleMouseMove}
        onMouseLeave={handleMouseLeave}
        className="w-full block cursor-crosshair"
      />

      {/* Floating Tooltip */}
      {activePoint && hoverPos && (
        <div
          className="absolute pointer-events-none z-20 bg-[#121c22] border border-[#233541] rounded px-3 py-2 text-xs shadow-xl backdrop-blur"
          style={{
            left: Math.min(Math.max(hoverPos.x - 60, 10), (containerRef.current?.clientWidth || 300) - 140),
            top: Math.max(hoverPos.y - 65, 8),
          }}
        >
          <div className="font-mono text-slate-400 text-[11px] mb-1">{activePoint.label}</div>
          <div className="flex items-center gap-1.5 font-medium text-emerald-400">
            <span className="w-1.5 h-1.5 rounded-full bg-emerald-400"></span>
            <span>{metricName}:</span>
            <span className="font-mono text-white ml-auto">{valueFormatter(activePoint.value)}</span>
          </div>
          {activePoint.secondaryValue !== undefined && secondaryMetricName && (
            <div className="flex items-center gap-1.5 font-medium text-cyan-400 mt-0.5">
              <span className="w-1.5 h-1.5 rounded-full bg-cyan-400"></span>
              <span>{secondaryMetricName}:</span>
              <span className="font-mono text-white ml-auto">{valueFormatter(activePoint.secondaryValue)}</span>
            </div>
          )}
        </div>
      )}
    </div>
  );
};
