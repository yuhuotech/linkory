import { useEffect, useState } from "react";
import { Cpu, MemoryStick, Plug } from "lucide-react";
import { api } from "./api";
import { bytes } from "./format";
import { Sparkline } from "./charts";

export type Sample = {
  at: string;
  cpu_percent: number;
  rss_bytes: number;
  heap_bytes: number;
  goroutines: number;
  connections: number;
  db_open: number;
  db_in_use: number;
  db_max: number;
  load1: number;
  load_known: boolean;
  host_mem_total: number;
  host_mem_available: number;
  host_mem_known: boolean;
  cpus: number;
};
export type Monitor = { current: Sample; history: Sample[] } | null;

/** Polls the server's own metrics while signed in; keeps the last reading if a poll fails. */
export function useMonitor(enabled: boolean): Monitor {
  const [data, setData] = useState<Monitor>(null);
  useEffect(() => {
    if (!enabled) {
      setData(null);
      return;
    }
    let live = true;
    const controller = new AbortController();
    const poll = () => {
      if (document.hidden) return;
      api<NonNullable<Monitor>>("monitor", { signal: controller.signal })
        .then((v) => live && setData(v))
        .catch(() => {});
    };
    poll();
    const timer = setInterval(poll, 5000);
    return () => {
      live = false;
      controller.abort();
      clearInterval(timer);
    };
  }, [enabled]);
  return data;
}

const pct = (v: number) => (v >= 10 ? v.toFixed(0) : v.toFixed(1)) + "%";
function hostMemUsed(s: Sample) {
  return s.host_mem_known && s.host_mem_total ? 1 - s.host_mem_available / s.host_mem_total : null;
}

/** Compact readings for the page header; shown on every page. */
export function MonitorChips({ monitor }: { monitor: Monitor }) {
  if (!monitor) return null;
  const s = monitor.current;
  const cpuLevel = s.cpu_percent / Math.max(s.cpus, 1) >= 80 ? "hot" : s.cpu_percent / Math.max(s.cpus, 1) >= 50 ? "warn" : "";
  const used = hostMemUsed(s);
  const memLevel = used !== null && used >= 0.9 ? "hot" : used !== null && used >= 0.8 ? "warn" : "";
  return (
    <div className="chips" aria-label="服务器实时状态">
      <span className={"chip " + cpuLevel} title={`服务进程 CPU 占用（占单核百分比，本机共 ${s.cpus} 核），每 5 秒刷新`}>
        <Cpu size={14} />
        CPU <b>{pct(s.cpu_percent)}</b>
      </span>
      <span
        className={"chip " + memLevel}
        title={`服务进程内存 ${bytes(s.rss_bytes)}（Go 堆 ${bytes(s.heap_bytes)}）` + (used !== null ? `；服务器内存已用 ${(used * 100).toFixed(0)}%` : "")}
      >
        <MemoryStick size={14} />
        内存 <b>{bytes(s.rss_bytes)}</b>
      </span>
      <span className="chip optional" title="当前保持 WebSocket 连接的设备数">
        <Plug size={14} />
        连接 <b>{s.connections}</b>
      </span>
    </div>
  );
}

/** Extra rows for the overview's "服务状态" panel. */
export function MonitorRows({ monitor }: { monitor: Monitor }) {
  if (!monitor) return null;
  const s = monitor.current;
  const h = monitor.history;
  const used = hostMemUsed(s);
  return (
    <>
      <div>
        <Cpu size={16} />
        <span>进程 CPU</span>
        <span className="mini">
          <Sparkline values={h.map((x) => x.cpu_percent)} color="var(--blue)" />
          <b>{pct(s.cpu_percent)}</b>
        </span>
      </div>
      <div>
        <MemoryStick size={16} />
        <span>进程内存</span>
        <span className="mini">
          <Sparkline values={h.map((x) => x.rss_bytes)} color="var(--violet)" />
          <b>{bytes(s.rss_bytes)}</b>
        </span>
      </div>
      <div>
        <Plug size={16} />
        <span title="在线 WebSocket 连接数 / Go 协程数">连接 / 协程</span>
        <b>
          {s.connections} · {s.goroutines}
        </b>
      </div>
      <div>
        <Plug size={16} />
        <span title="使用中 / 已建立 / 上限">数据库连接</span>
        <b>
          {s.db_in_use} / {s.db_open}
          {s.db_max ? ` / ${s.db_max}` : ""}
        </b>
      </div>
      {s.load_known && (
        <div>
          <Cpu size={16} />
          <span title="1 分钟平均负载 / CPU 核数">系统负载</span>
          <b>
            {s.load1.toFixed(2)} / {s.cpus} 核
          </b>
        </div>
      )}
      {used !== null && (
        <div>
          <MemoryStick size={16} />
          <span title="服务器整机内存使用比例">服务器内存</span>
          <span className="mini">
            <span className="bar" aria-hidden="true">
              <i style={{ width: `${Math.min(100, used * 100).toFixed(0)}%`, background: used >= 0.9 ? "var(--bad)" : used >= 0.8 ? "var(--amber)" : "var(--blue)" }} />
            </span>
            <b>{(used * 100).toFixed(0)}%</b>
          </span>
        </div>
      )}
    </>
  );
}
