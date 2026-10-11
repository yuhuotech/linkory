import React, { useEffect } from "react";
import {
  Users,
  Laptop,
  ArrowLeftRight,
  CheckCircle,
  Wifi,
  MessageSquare,
  Clock,
  AlertTriangle,
  Timer,
} from "lucide-react";
import { Sparkline, StackBar, TrendChart } from "./charts";
import { bytes, date } from "./format";
import { MonitorRows, type Monitor } from "./monitor";
import { Row, useLoad, ErrorBox, Load, Table } from "./shared";

export function Metric({
  icon: Icon,
  tone,
  label,
  value,
  hint,
  spark,
}: {
  icon: React.ComponentType<{ size?: number }>;
  tone: keyof typeof tones;
  label: string;
  value: React.ReactNode;
  hint?: string;
  spark?: number[];
}) {
  return (
    <div className="metric" style={{ "--tone": tones[tone] } as React.CSSProperties}>
      <div className="metric-top">
        <span className="metric-icon">
          <Icon size={18} />
        </span>
        <span className="metric-label">{label}</span>
      </div>
      <div className="metric-main">
        <strong>{value}</strong>
        {spark && <Sparkline values={spark} color={tones[tone]} />}
      </div>
      {hint && <small>{hint}</small>}
    </div>
  );
}
export function Overview({ version, monitor = null }: { version: number; monitor?: Monitor }) {
  const { data, error, loading, reload } = useLoad<Row>(
    "overview?revision=" + version,
  );
  useEffect(() => {
    const timer = setInterval(() => {
      if (!document.hidden) reload();
    }, 30000);
    return () => clearInterval(timer);
  }, []);
  if (!data) return <Load loading={loading} error={error} retry={reload} />;
  const trend: Row[] = data.trend || [];
  const groups: Row[] = data.transfer_groups || [];
  const series = (key: string) => trend.map((r) => Number(r[key]) || 0);
  const totalTasks = groups.reduce((a, g) => a + Number(g.count), 0);
  const countOf = (status: string) => groups.filter((g) => g.status === status).reduce((a, g) => a + Number(g.count), 0);
  const completed = countOf("COMPLETED"),
    finished = completed + countOf("FAILED");
  // Fixed rows (zero included) so the card keeps its shape, and reads sensibly, while there is little data.
  const sum = (pred: (g: Row) => boolean) => groups.filter(pred).reduce((a, g) => a + Number(g.count), 0);
  const inFlight = ["CREATED", "WAITING_ACCEPT", "ACCEPTED", "TRANSFERRING", "VERIFYING"];
  const buckets = [
    { label: "已完成", color: "var(--good)", count: completed },
    { label: "进行中", color: "var(--blue)", count: sum((g) => inFlight.includes(g.status)) },
    { label: "失败", color: "var(--bad)", count: countOf("FAILED") },
    { label: "已取消 / 拒绝 / 过期", color: "var(--muted)", count: countOf("CANCELLED") + countOf("REJECTED") + countOf("EXPIRED") },
  ];
  const modes = [
    { label: modeNames.relay, color: "var(--blue)", count: sum((g) => g.mode === "relay") },
    { label: modeNames.lan, color: "var(--violet)", count: sum((g) => g.mode === "lan") },
  ];
  const online = Number(data.online_devices) || 0,
    devices = Number(data.devices) || 0;
  const hours = Math.floor(data.uptime_seconds / 3600),
    minutes = Math.floor((data.uptime_seconds % 3600) / 60);
  const healthy = !!data.database_healthy;
  return (
    <>
      <ErrorBox message={error} />
      <div className="metric-grid">
        <Metric icon={Users} tone="blue" label="用户" value={data.users} hint={`封禁 ${data.disabled_users} · 近 7 天新增 ${series("users").reduce((a, b) => a + b, 0)}`} spark={series("users")} />
        <Metric icon={Laptop} tone="violet" label="已关联设备" value={data.devices} hint={devices ? `${Math.round((online / devices) * 100)}% 设备在线` : "暂无设备"} />
        <Metric icon={Wifi} tone="green" label="在线设备" value={data.online_devices} hint="当前与服务器保持连接" />
        <Metric icon={MessageSquare} tone="orange" label="今日消息" value={data.messages_today} hint={`累计 ${data.messages ?? "—"} 条（UTC 今日）`} spark={series("messages")} />
        <Metric icon={Clock} tone="amber" label="待送达消息" value={data.pending_messages} hint="接收设备离线时暂存" />
        <Metric icon={AlertTriangle} tone="red" label="今日失败任务" value={data.failed_transfers_today} hint={Number(data.failed_transfers_today) ? "请到「文件传输」查看原因" : "运行良好"} />
      </div>
      <section className="panel">
        <div className="panel-title">
          <h2>
            最近 7 天 <small>UTC 自然日</small>
          </h2>
        </div>
        {trend.length ? (
          <TrendChart
            rows={trend}
            series={[
              { key: "users", label: "新增账号", color: tones.blue },
              { key: "messages", label: "消息数量", color: tones.orange },
              { key: "transfer_tasks", label: "新增传输任务", color: tones.violet },
            ]}
          />
        ) : (
          <p className="muted">暂无趋势数据</p>
        )}
        <details className="data-table">
          <summary>查看数据表</summary>
          <Table
            columns={[
              ["date", "日期"],
              ["users", "新增账号"],
              ["messages", "消息数量"],
              ["transfer_tasks", "新增传输任务"],
            ]}
            rows={trend}
          />
        </details>
        <p className="muted">基于当前数据库保留记录计算，历史清理后相应数量会减少。</p>
      </section>
      <div className="two-col">
        <section className="panel">
          <div className="panel-title">
            <h2>服务状态</h2>
            <span className={"health " + (healthy ? "ok" : "down")}>
              <i />
              {healthy ? "数据库健康" : "数据库异常"}
            </span>
          </div>
          <div className="stat-list">
            <MonitorRows monitor={monitor} />
          </div>
          <div className="tiles">
            <div>
              <Timer size={16} />
              <span>运行时长</span>
              <b>
                {hours} 小时 {minutes} 分钟
              </b>
              <small>自 {date(data.started_at)}</small>
            </div>
            <div>
              <ArrowLeftRight size={16} />
              <span>本进程中转量</span>
              <b>{bytes(data.relayed_bytes_since_start)}</b>
              <small>重启归零，不含局域网直连</small>
            </div>
          </div>
          <p className="muted">
            资源读数来自服务进程自身，每 5 秒刷新；折线为最近 5 分钟。
          </p>
        </section>
        <section className="panel">
          <div className="panel-title">
            <h2>传输与运行</h2>
            <span className="muted-inline">历史任务统计</span>
          </div>
          <div className="tiles">
            <div>
              <CheckCircle size={16} />
              <span>传输成功率</span>
              <b>{finished ? Math.round((completed / finished) * 100) + "%" : "—"}</b>
              <small>{finished ? `${completed} 成功 / ${finished - completed} 失败` : "还没有已结束的任务"}</small>
            </div>
            <div>
              <ArrowLeftRight size={16} />
              <span>任务总数</span>
              <b>{totalTasks}</b>
              <small>今日新增 {trend.length ? Number(trend[trend.length - 1].transfer_tasks) || 0 : 0}</small>
            </div>
          </div>
          <StackBar label="传输状态占比" parts={buckets.map((x) => ({ label: x.label, value: x.count, color: x.color }))} />
          <ul className="dist">
            {buckets.map((x) => (
              <li key={x.label} className={x.count ? "" : "zero"}>
                <i style={{ background: x.color }} />
                <span>{x.label}</span>
                <em />
                <b>{x.count}</b>
                <small>{totalTasks ? Math.round((x.count / totalTasks) * 100) : 0}%</small>
              </li>
            ))}
            {modes.map((x) => (
              <li key={x.label} className={"mode" + (x.count ? "" : " zero")}>
                <i style={{ background: x.color }} />
                <span>{x.label}</span>
                <em>按方式</em>
                <b>{x.count}</b>
                <small>{totalTasks ? Math.round((x.count / totalTasks) * 100) : 0}%</small>
              </li>
            ))}
          </ul>
          <p className="muted">历史任务数量，不等于实时并发或流量。</p>
        </section>
      </div>
    </>
  );
}

const tones = {
  blue: "var(--blue)",
  violet: "var(--violet)",
  green: "var(--good)",
  orange: "var(--orange)",
  amber: "var(--amber)",
  red: "var(--bad)",
};

const modeNames: Record<string, string> = { relay: "服务器中转", lan: "局域网直连" };
const statusTone: Record<string, string> = {
  COMPLETED: "var(--good)",
  TRANSFERRING: "var(--blue)",
  VERIFYING: "var(--blue)",
  ACCEPTED: "var(--blue)",
  WAITING_ACCEPT: "var(--amber)",
  CREATED: "var(--amber)",
  FAILED: "var(--bad)",
  REJECTED: "var(--muted)",
  CANCELLED: "var(--muted)",
  EXPIRED: "var(--muted)",
};
