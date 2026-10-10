import { useEffect, useRef, useState } from "react";

// Dependency-free SVG charts. Colors come from CSS variables so light and dark themes both work.

export type Series = { key: string; label: string; color: string };

export function Sparkline({ values, color }: { values: number[]; color: string }) {
  const w = 96,
    h = 32,
    max = Math.max(1, ...values),
    step = values.length > 1 ? w / (values.length - 1) : w;
  const pts = values.map((v, i) => [i * step, h - 3 - (v / max) * (h - 8)] as const);
  const line = pts.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(" ");
  return (
    <svg className="sparkline" viewBox={`0 0 ${w} ${h}`} aria-hidden="true">
      {pts.length > 1 && (
        <>
          <polygon points={`0,${h} ${line} ${w},${h}`} fill={color} opacity="0.12" />
          <polyline points={line} fill="none" stroke={color} strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" />
        </>
      )}
      {pts.length > 0 && <circle cx={pts[pts.length - 1][0]} cy={pts[pts.length - 1][1]} r="2.5" fill={color} />}
    </svg>
  );
}

/** Grouped bars: one group per day, one bar per series, value labels on the bars and a hover tooltip per day. */
export function TrendChart({ rows, series }: { rows: Record<string, any>[]; series: Series[] }) {
  const box = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(720);
  const [hover, setHover] = useState<number | null>(null);
  useEffect(() => {
    const el = box.current;
    if (!el || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(([entry]) => {
      const w = Math.floor(entry.contentRect.width);
      if (w > 0) setWidth(w);
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, []);
  // Drawn at the real pixel width (no scaling), so text stays crisp and the height stays fixed.
  const W = width,
    H = 172,
    L = 32,
    R = 6,
    T = 18,
    B = 24;
  const raw = Math.max(0, ...rows.flatMap((r) => series.map((s) => Number(r[s.key]) || 0)));
  // Four grid steps of 1/2/5 × 10^n keep every label an integer (min step 1).
  const rough = Math.max(raw, 4) / 4,
    pow = Math.pow(10, Math.floor(Math.log10(rough))),
    step = [1, 2, 5, 10].map((m) => m * pow).find((v) => v >= rough) || 10 * pow,
    max = step * 4;
  const plotW = W - L - R,
    plotH = H - T - B,
    group = plotW / Math.max(rows.length, 1),
    barW = Math.max(6, Math.min(26, (group * 0.72) / series.length - 2));
  const y = (v: number) => T + plotH - (v / max) * plotH;
  const ticks = [0, 1, 2, 3, 4].map((i) => i * step);
  const groupX = (i: number) => L + i * group;
  const barX = (i: number, j: number) => groupX(i) + (group - (barW * series.length + 2 * (series.length - 1))) / 2 + j * (barW + 2);
  const tip = hover === null ? null : rows[hover];
  // Sit beside the hovered day, never on top of its bars: to the right on the left half, to the left on the right half.
  const tipOnLeft = hover !== null && groupX(hover) + group / 2 > W / 2;
  const tipLeft = hover === null ? 0 : tipOnLeft ? groupX(hover) - 6 : groupX(hover) + group + 6;
  return (
    <div className="chart" ref={box}>
      <div className="legend">
        {series.map((s) => (
          <span key={s.key}>
            <i style={{ background: s.color }} />
            {s.label}
          </span>
        ))}
      </div>
      <div className="chart-plot" onMouseLeave={() => setHover(null)}>
        <svg width={W} height={H} role="img" aria-label="最近 7 天趋势">
          {ticks.map((t) => (
            <g key={t}>
              <line x1={L} x2={W - R} y1={y(t)} y2={y(t)} className="grid" />
              <text x={L - 6} y={y(t) + 4} textAnchor="end" className="axis">
                {t}
              </text>
            </g>
          ))}
          {rows.map((r, i) => (
            <g key={String(r.date)}>
              {hover === i && <rect x={groupX(i) + 2} y={T - 6} width={group - 4} height={plotH + 6} rx="6" className="hover-band" />}
              {series.map((s, j) => {
                const v = Number(r[s.key]) || 0;
                return (
                  <g key={s.key}>
                    <rect x={barX(i, j)} y={y(v)} width={barW} height={Math.max(v ? 2 : 0, T + plotH - y(v))} rx="3" fill={s.color} />
                    {v > 0 && (
                      <text x={barX(i, j) + barW / 2} y={y(v) - 4} textAnchor="middle" className="bar-value">
                        {v}
                      </text>
                    )}
                  </g>
                );
              })}
              <text x={groupX(i) + group / 2} y={H - 7} textAnchor="middle" className={"axis" + (hover === i ? " on" : "")}>
                {String(r.date).slice(5)}
              </text>
              <rect x={groupX(i)} y={0} width={group} height={H} fill="transparent" onMouseEnter={() => setHover(i)} onMouseMove={() => setHover(i)} />
            </g>
          ))}
        </svg>
        {tip && (
          <div className={"chart-tip" + (tipOnLeft ? " left" : "")} style={{ left: tipLeft }} role="tooltip">
            <strong>{String(tip.date)}</strong>
            {series.map((s) => (
              <div key={s.key}>
                <i style={{ background: s.color }} />
                <span>{s.label}</span>
                <b>{Number(tip[s.key]) || 0}</b>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

/** One horizontal bar split into segments, for share-of-total. */
export function StackBar({ parts, label = "占比" }: { parts: { label: string; value: number; color: string }[]; label?: string }) {
  const total = parts.reduce((a, p) => a + p.value, 0);
  if (!total) return <div className="stackbar empty" />;
  return (
    <div className="stackbar" role="img" aria-label={label}>
      {parts
        .filter((p) => p.value > 0)
        .map((p) => (
          <span key={p.label} style={{ flexGrow: p.value, background: p.color }} title={`${p.label} ${p.value}`} />
        ))}
    </div>
  );
}
