import React, { useEffect, useState, useRef } from "react";
import { createPortal } from "react-dom";
import {
  LayoutDashboard,
  Users,
  Laptop,
  ArrowLeftRight,
  Database,
  ScrollText,
  ShieldCheck,
  RefreshCw,
  LogOut,
  Eye,
  MoreHorizontal,
  Sun,
  Moon,
  X,
  Search,
  ChevronLeft,
  ChevronRight,
  AlertCircle,
  CheckCircle,
  KeyRound,
  Wifi,
  MessageSquare,
  Clock,
  AlertTriangle,
  Timer,
  Server,
  Ban,
} from "lucide-react";
import { Sparkline, StackBar, TrendChart } from "./charts";
import { bytes, date } from "./format";
import { MonitorChips, MonitorRows, useMonitor, type Monitor } from "./monitor";

export { bytes, date };
import { api, ApiError, setSession, type Me } from "./api";
import "./style.css";

type Row = Record<string, any>;
type Page = { items: Row[]; total: number; page: number; page_size: number };
const sections = [
  ["overview", "运行概览", LayoutDashboard],
  ["users", "用户管理", Users],
  ["devices", "设备管理", Laptop],
  ["transfers", "文件传输", ArrowLeftRight],
  ["retention", "数据保留", Database],
  ["audit", "操作审计", ScrollText],
  ["account", "管理账号", ShieldCheck],
] as const;
const statusNames: Record<string, string> = {
  WAITING_ACCEPT: "等待接收",
  ACCEPTED: "已接受",
  TRANSFERRING: "传输中",
  VERIFYING: "校验中",
  COMPLETED: "已完成",
  REJECTED: "已拒绝",
  CANCELLED: "已取消",
  FAILED: "失败",
  EXPIRED: "已过期",
  QUEUED: "排队中",
  RUNNING: "执行中",
  CREATED: "已创建",
  success: "成功",
  failure: "失败",
  denied: "拒绝",
  queued: "已排队",
  online: "在线",
  offline: "离线",
  revoked: "已移除",
};
const active = [
  "CREATED",
  "WAITING_ACCEPT",
  "ACCEPTED",
  "TRANSFERRING",
  "VERIFYING",
];
function Badge({ value }: { value: string }) {
  return (
    <span
      className={
        "badge " +
        (["FAILED", "failure", "denied", "revoked"].includes(value)
          ? "bad"
          : ["COMPLETED", "success", "online"].includes(value)
            ? "good"
            : "")
      }
    >
      {statusNames[value] || value}
    </span>
  );
}
function useLoad<T>(path: string) {
  const [data, setData] = useState<T | null>(null),
    [error, setError] = useState(""),
    [loading, setLoading] = useState(true),
    [revision, setRevision] = useState(0);
  useEffect(() => {
    let live = true;
    const controller = new AbortController();
    setLoading(true);
    setError("");
    api<T>(path, { signal: controller.signal })
      .then((v) => {
        if (live) setData(v);
      })
      .catch((e) => {
        if (live && e.name !== "AbortError")
          setError(e.message || "网络连接失败");
      })
      .finally(() => {
        if (live) setLoading(false);
      });
    return () => {
      live = false;
      controller.abort();
    };
  }, [path, revision]);
  return { data, error, loading, reload: () => setRevision((v) => v + 1) };
}
function Modal({
  title,
  children,
  close,
}: {
  title: string;
  children: React.ReactNode;
  close: () => void;
}) {
  const panel = useRef<HTMLElement>(null),
    closeRef = useRef(close);
  useEffect(() => {
    closeRef.current = close;
  }, [close]);
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    const focusable = () =>
      Array.from(
        panel.current?.querySelectorAll<HTMLElement>(
          'button:not(:disabled),input:not(:disabled),textarea:not(:disabled),select:not(:disabled),a[href],[tabindex="0"]',
        ) || [],
      ).filter((el) => el.offsetParent !== null);
    if (!panel.current?.contains(document.activeElement)) {
      (
        panel.current?.querySelector<HTMLElement>("input,textarea") ||
        focusable()[0] ||
        panel.current
      )?.focus();
    }
    const listener = (e: KeyboardEvent) => {
      if (e.key === "Escape") closeRef.current();
      if (e.key === "Tab") {
        const nodes = focusable(),
          first = nodes[0],
          last = nodes[nodes.length - 1];
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault();
          last?.focus();
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault();
          first?.focus();
        }
      }
    };
    document.addEventListener("keydown", listener);
    return () => {
      document.removeEventListener("keydown", listener);
      if (previous && document.contains(previous)) previous.focus();
    };
  }, []);
  return (
    <div
      className="overlay"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) close();
      }}
    >
      <section
        className="dialog"
        ref={panel}
        tabIndex={-1}
        role="dialog"
        aria-modal="true"
        aria-label={title}
      >
        <div className="dialog-title">
          <h2>{title}</h2>
          <button className="icon" aria-label="关闭" onClick={close}>
            <X size={18} />
          </button>
        </div>
        {children}
      </section>
    </div>
  );
}
function ErrorBox({ message }: { message: string }) {
  return message ? (
    <div className="error" role="alert">
      <AlertCircle size={16} />
      <span>{message}</span>
    </div>
  ) : null;
}
export function Login({ done }: { done: (me: Me) => void }) {
  const [user, setUser] = useState(""),
    [password, setPassword] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState("");
  const busyRef = useRef(false);
  return (
    <main className="login">
      <form
        className="login-card"
        onSubmit={async (e) => {
          e.preventDefault();
          if (busy) return;
          if (busyRef.current) return;
          busyRef.current = true;
          setBusy(true);
          setError("");
          try {
            done(
              await api<Me>("auth/login", {
                method: "POST",
                body: { username: user, password },
              }),
            );
          } catch (e) {
            setError(e instanceof Error ? e.message : "网络连接失败");
          } finally {
            busyRef.current = false;
            setBusy(false);
          }
        }}
      >
        <div className="brand">
          <img src={import.meta.env.BASE_URL + "logo.png"} alt="" />
          <div>
            <h1>连信管理后台</h1>
            <p>与或科技 · 服务运营与管理</p>
          </div>
        </div>
        <label>
          管理员账号
          <input
            value={user}
            onChange={(e) => setUser(e.target.value)}
            autoComplete="username"
            required
            maxLength={64}
            autoFocus
          />
        </label>
        <label>
          密码
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="current-password"
            required
            maxLength={128}
          />
        </label>
        <ErrorBox message={error} />
        <button className="primary full" disabled={busy}>
          {busy ? "正在登录…" : "登录后台"}
        </button>
        <p className="muted">使用独立管理员账号。普通连信账号不能登录后台。</p>
        <a href="/">返回连信官网</a>
      </form>
    </main>
  );
}

type Pending = { title: string; path: string; body?: Row };
export function App() {
  const [me, setMe] = useState<Me | null>(null),
    [boot, setBoot] = useState(true),
    [bootError, setBootError] = useState(""),
    [section, setSection] = useState(location.hash.slice(1) || "overview"),
    [theme, setTheme] = useState(
      localStorage.getItem("linkory-admin-theme") || "light",
    ),
    [pending, setPending] = useState<Pending | null>(null),
    [reason, setReason] = useState(""),
    [busy, setBusy] = useState(false),
    [error, setError] = useState(""),
    [notice, setNotice] = useState(""),
    [detail, setDetail] = useState<Row | null>(null),
    [detailTitle, setDetailTitle] = useState(""),
    [preview, setPreview] = useState<Row | null>(null),
    [confirm, setConfirm] = useState(""),
    [version, setVersion] = useState(0);
  const busyRef = useRef(false);
  const write = me?.role === "admin";
  const monitor = useMonitor(!!me);
  const login = (value: Me | null) => {
    if (value) {
      setNotice("");
      setBootError("");
      setError("");
    }
    setSession(value);
    setMe(value);
  };
  useEffect(() => {
    api<Me>("auth/me")
      .then(login)
      .catch((e) => {
        if (!(e instanceof ApiError && e.status === 401))
          setBootError(e.message || "无法连接服务器");
      })
      .finally(() => setBoot(false));
    const expire = () => {
      login(null);
      setPending(null);
      setDetail(null);
      setPreview(null);
      setNotice("登录已失效，请重新登录");
    };
    window.addEventListener("admin-expired", expire);
    return () => window.removeEventListener("admin-expired", expire);
  }, []);
  useEffect(() => {
    const change = () => {
      setSection(location.hash.slice(1) || "overview");
      setError("");
      setNotice("");
    };
    window.addEventListener("hashchange", change);
    return () => window.removeEventListener("hashchange", change);
  }, []);
  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    localStorage.setItem("linkory-admin-theme", theme);
  }, [theme]);
  function action(title: string, path: string, body?: Row) {
    setReason("");
    setError("");
    setPending({ title, path, body });
  }
  async function inspect(title: string, path: string) {
    setError("");
    try {
      const d = await api(path);
      setDetailTitle(title);
      setDetail(d);
    } catch (e) {
      setError((e as Error).message);
    }
  }
  async function startPreview(kind: string, user_id?: number) {
    setError("");
    if (busyRef.current) return;
    busyRef.current = true;
    setBusy(true);
    try {
      setPreview(
        await api("retention/preview", {
          method: "POST",
          body: { kind, user_id },
        }),
      );
      setReason("");
      setConfirm("");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      busyRef.current = false;
      setBusy(false);
    }
  }
  const refresh = () => setVersion((v) => v + 1);
  if (boot) return <div className="loading">正在确认管理会话…</div>;
  if (!me)
    return (
      <>
        <ErrorBox message={bootError} />
        <Login done={login} />
      </>
    );
  const current = sections.find((s) => s[0] === section) || sections[0];
  return (
    <div className="shell">
      <aside className="sidebar">
        <a className="brand" href="#overview">
          <img src={import.meta.env.BASE_URL + "logo.png"} alt="" />
          <div>
            <strong>连信 Linkory</strong>
            <small>管理后台</small>
          </div>
        </a>
        <nav>
          {sections.map(([id, title, Icon]) => (
            <a
              key={id}
              className={current[0] === id ? "selected" : ""}
              href={"#" + id}
            >
              <Icon size={17} />
              {title}
            </a>
          ))}
        </nav>
        <div className="sidebar-foot">
          <div className="who">
            <span className="avatar" aria-hidden="true">
              {me.username.slice(0, 1)}
            </span>
            <div>
              <b title={me.username}>{me.username}</b>
              <Badge value={write ? "管理员" : "只读运维"} />
            </div>
          </div>
          <button
            className="quiet"
            onClick={() => setTheme(theme === "dark" ? "light" : "dark")}
          >
            {theme === "dark" ? <Sun size={16} /> : <Moon size={16} />}切换主题
          </button>
          <button
            className="quiet"
            onClick={async () => {
              try {
                await api("auth/logout", { method: "POST" });
                login(null);
              } catch (e) {
                setError((e as Error).message);
              }
            }}
          >
            <LogOut size={16} />
            退出登录
          </button>
        </div>
      </aside>
      <main className="workspace">
        <header className="page-header">
          <div>
            <h1>{current[1]}</h1>
            <span>连信服务管理</span>
          </div>
          <MonitorChips monitor={monitor} />
          <button onClick={refresh}>
            <RefreshCw size={15} />
            刷新
          </button>
        </header>
        <div className="content">
          <ErrorBox message={error} />
          {notice && (
            <div className="notice" role="status">
              <CheckCircle size={16} />
              {notice}
            </div>
          )}
          {!write && (
            <p className="readonly">
              当前为只读运维角色，可查看运行信息，不能修改账号、设备或数据。
            </p>
          )}
          {current[0] === "overview" ? (
            <Overview version={version} monitor={monitor} />
          ) : current[0] === "retention" ? (
            <Retention
              version={version}
              write={!!write}
              preview={() => startPreview("retention")}
              action={action}
              inspect={inspect}
            />
          ) : current[0] === "account" ? (
            <Account
              me={me}
              changed={() => setNotice("密码已修改，其他管理会话已撤销")}
            />
          ) : (
            <Listing
              key={current[0]}
              kind={current[0]}
              version={version}
              write={!!write}
              action={action}
              inspect={inspect}
              preview={startPreview}
            />
          )}
        </div>
        <footer className="workspace-footer">
          与或科技 · 管理操作留有审计记录 · 不提供用户消息正文或文件内容浏览
        </footer>
      </main>
      {pending && (
        <Modal title={pending.title} close={() => !busy && setPending(null)}>
          <p className="muted">
            此操作将记录操作者、目标和理由。请核对目标后执行。
          </p>
          <label>
            操作理由
            <textarea
              autoFocus
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              minLength={2}
              maxLength={300}
              placeholder="说明操作原因，例如用户申请或故障排查"
            />
          </label>
          <ErrorBox message={error} />
          <div className="dialog-actions">
            <button disabled={busy} onClick={() => setPending(null)}>
              取消
            </button>
            <button
              className="primary"
              disabled={busy || reason.trim().length < 2}
              onClick={async () => {
                if (busyRef.current) return;
                busyRef.current = true;
                setBusy(true);
                setError("");
                try {
                  await api(pending.path, {
                    method: pending.path === "retention" ? "PUT" : "POST",
                    body: { ...pending.body, reason },
                  });
                  setPending(null);
                  setNotice("操作已完成");
                  refresh();
                } catch (e) {
                  setError((e as Error).message);
                } finally {
                  busyRef.current = false;
                  setBusy(false);
                }
              }}
            >
              {busy ? "正在执行…" : "确认执行"}
            </button>
          </div>
        </Modal>
      )}
      {detail && (
        <Modal title={detailTitle} close={() => setDetail(null)}>
          <Detail data={detail} />
          <div className="dialog-actions">
            <button onClick={() => setDetail(null)}>关闭</button>
          </div>
        </Modal>
      )}
      {preview && (
        <Modal title="确认数据清理范围" close={() => !busy && setPreview(null)}>
          <p className="danger-text">
            数据删除不可撤销。注销账号还会冻结账号、撤销会话并删除关联数据；客户端本地文件不会被删除。
          </p>
          <div className="preview-grid">
            {Object.entries(preview.counts).map(([name, n]) => (
              <div key={name}>
                <span>
                  {
                    (
                      {
                        messages: "消息记录",
                        transfer_tasks: "传输记录",
                        devices: "关联设备",
                        users: "账号",
                      } as Row
                    )[name]
                  }
                </span>
                <strong>{String(n)}</strong>
              </div>
            ))}
          </div>
          <p className="muted">
            固定范围：
            {
              (
                {
                  retention: "按数据保留策略清理",
                  user_messages: "清理指定账号消息",
                  user_transfers: "清理指定账号传输历史",
                  user_delete: "注销并删除指定账号",
                } as Row
              )[preview.spec.kind]
            }{" "}
            {preview.spec.user_id > 0 && " · 账号 ID " + preview.spec.user_id} ·
            截止 {date(preview.spec.cutoff)}
            <br />
            预览有效至 {date(preview.expires_at)}。
            {preview.spec.kind === "user_delete"
              ? "注销包含该账号全部关联数据，排队时立即冻结账号。"
              : "历史清理不会包含截止时间之后新增的记录。"}
          </p>
          <label>
            操作理由
            <textarea
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              maxLength={300}
            />
          </label>
          <label>
            输入“删除”确认
            <input
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
            />
          </label>
          <ErrorBox message={error} />
          <div className="dialog-actions">
            <button disabled={busy} onClick={() => setPreview(null)}>
              取消
            </button>
            <button
              className="primary"
              disabled={busy || confirm !== "删除" || reason.trim().length < 2}
              onClick={async () => {
                if (busyRef.current) return;
                busyRef.current = true;
                setBusy(true);
                setError("");
                try {
                  await api("jobs", {
                    method: "POST",
                    body: { preview_id: preview.preview_id, confirm, reason },
                  });
                  setPreview(null);
                  setNotice("清理任务已排队，可在数据保留页面查看进度");
                  location.hash = "retention";
                  refresh();
                } catch (e) {
                  setError((e as Error).message);
                } finally {
                  busyRef.current = false;
                  setBusy(false);
                }
              }}
            >
              {busy ? "正在创建…" : "创建删除任务"}
            </button>
          </div>
        </Modal>
      )}
    </div>
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
function Metric({
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
function Load({
  loading,
  error,
  retry,
}: {
  loading: boolean;
  error: string;
  retry: () => void;
}) {
  return (
    <div className="empty">
      {loading ? (
        "正在读取数据…"
      ) : (
        <>
          <ErrorBox message={error} />
          <button onClick={retry}>重新加载</button>
        </>
      )}
    </div>
  );
}
function RowMenu({ children }: { children: React.ReactNode }) {
  const [position, setPosition] = useState<{
    top: number;
    right: number;
  } | null>(null);
  const button = useRef<HTMLButtonElement>(null),
    menu = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!position) return;
    const outside = (e: PointerEvent) => {
      if (
        !menu.current?.contains(e.target as Node) &&
        !button.current?.contains(e.target as Node)
      )
        setPosition(null);
    };
    const key = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        setPosition(null);
        button.current?.focus();
      }
    };
    document.addEventListener("pointerdown", outside);
    document.addEventListener("keydown", key);
    return () => {
      document.removeEventListener("pointerdown", outside);
      document.removeEventListener("keydown", key);
    };
  }, [position]);
  return (
    <>
      <button
        ref={button}
        className="icon"
        aria-label="更多操作"
        aria-expanded={!!position}
        onClick={() => {
          const rect = button.current!.getBoundingClientRect();
          setPosition({
            top: Math.min(rect.bottom + 4, window.innerHeight - 190),
            right: Math.max(12, window.innerWidth - rect.right),
          });
        }}
      >
        <MoreHorizontal size={16} />
      </button>
      {position &&
        createPortal(
          <div
            ref={menu}
            className="action-popup"
            style={position}
            onClick={() => setPosition(null)}
          >
            {children}
          </div>,
          document.body,
        )}
    </>
  );
}

function Table({
  columns,
  rows,
  actions,
}: {
  columns: readonly (readonly [string, string])[];
  rows: Row[];
  actions?: (r: Row) => React.ReactNode;
}) {
  return (
    <div className="table-scroll">
      <table>
        <thead>
          <tr>
            {columns.map(([k, label]) => (
              <th key={k}>{label}</th>
            ))}
            {actions && <th>操作</th>}
          </tr>
        </thead>
        <tbody>
          {rows.length ? (
            rows.map((r, i) => (
              <tr key={r.id || i}>
                {columns.map(([k]) => (
                  <td key={k}>
                    {k.endsWith("_at") ? (
                      date(r[k])
                    ) : k === "size" ? (
                      bytes(r[k])
                    ) : k === "disabled_at" ? (
                      r[k] ? (
                        "已封禁"
                      ) : (
                        "正常"
                      )
                    ) : k === "revoked_at" ? (
                      r[k] ? (
                        "已移除"
                      ) : (
                        "有效"
                      )
                    ) : k === "status" || k === "result" ? (
                      <Badge value={r[k]} />
                    ) : k === "mode" ? (
                      r[k] === "lan" ? (
                        "局域网直连"
                      ) : (
                        "服务器中转"
                      )
                    ) : typeof r[k] === "object" ? (
                      JSON.stringify(r[k])
                    ) : (
                      String(r[k] ?? "—")
                    )}
                  </td>
                ))}
                {actions && <td className="row-actions">{actions(r)}</td>}
              </tr>
            ))
          ) : (
            <tr>
              <td
                colSpan={columns.length + (actions ? 1 : 0)}
                className="empty"
              >
                没有匹配的记录
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
const columns: Record<string, [string, string][]> = {
  users: [
    ["id", "账号 ID"],
    ["username", "用户名"],
    ["device_count", "设备数"],
    ["disabled_at", "封禁时间"],
    ["created_at", "注册时间"],
  ],
  devices: [
    ["name", "设备名称"],
    ["username", "所属账号"],
    ["device_type", "平台"],
    ["app_version", "客户端"],
    ["status", "状态"],
    ["last_seen_at", "最近在线"],
  ],
  transfers: [
    ["file_name", "文件名"],
    ["username", "所属账号"],
    ["size", "文件大小"],
    ["status", "状态"],
    ["mode", "方式"],
    ["created_at", "创建时间"],
  ],
  audit: [
    ["created_at", "时间"],
    ["actor", "操作者"],
    ["action", "动作"],
    ["target", "目标"],
    ["reason", "理由"],
    ["result", "结果"],
  ],
};
function Listing({
  kind,
  version,
  write,
  action,
  inspect,
  preview,
}: {
  kind: string;
  version: number;
  write: boolean;
  action: (title: string, path: string, body?: Row) => void;
  inspect: (title: string, path: string) => void;
  preview: (kind: string, user?: number) => void;
}) {
  const [filter, setFilter] = useState<Row>({}),
    [query, setQuery] = useState<Row>({}),
    [page, setPage] = useState(1);
  const params = new URLSearchParams({
    ...query,
    page: String(page),
    revision: String(version),
  });
  const { data, error, loading, reload } = useLoad<Page>(kind + "?" + params);
  const options: Record<string, string[]> = {
    users: ["active", "disabled"],
    devices: ["online", "offline", "revoked"],
    transfers: [
      ...active,
      "COMPLETED",
      "REJECTED",
      "CANCELLED",
      "FAILED",
      "EXPIRED",
    ],
  };
  const change = (key: string, value: string) =>
    setFilter((v) => ({ ...v, [key]: value }));
  return (
    <section className="panel">
      <form
        className="filters"
        onSubmit={(e) => {
          e.preventDefault();
          setPage(1);
          setQuery(filter);
        }}
      >
        <div className="search">
          <Search size={15} />
          <input
            aria-label="搜索"
            placeholder={kind === "audit" ? "操作者" : "搜索名称或 ID"}
            value={filter[kind === "audit" ? "actor" : "q"] || ""}
            onChange={(e) =>
              change(kind === "audit" ? "actor" : "q", e.target.value)
            }
          />
        </div>
        {options[kind] && (
          <select
            aria-label="状态筛选"
            value={filter.status || ""}
            onChange={(e) => change("status", e.target.value)}
          >
            <option value="">全部状态</option>
            {options[kind].map((v) => (
              <option key={v} value={v}>
                {statusNames[v] ||
                  ({ active: "正常", disabled: "已封禁" } as Row)[v] ||
                  v}
              </option>
            ))}
          </select>
        )}
        {kind === "devices" && (
          <select
            aria-label="平台筛选"
            value={filter.type || ""}
            onChange={(e) => change("type", e.target.value)}
          >
            <option value="">全部平台</option>
            {["macos", "windows", "linux", "android", "ios", "web"].map((v) => (
              <option key={v}>{v}</option>
            ))}
          </select>
        )}
        {(kind === "devices" || kind === "transfers") && (
          <input
            aria-label="账号 ID"
            placeholder="账号 ID"
            className="short"
            value={filter.user_id || ""}
            onChange={(e) => change("user_id", e.target.value)}
          />
        )}{" "}
        {kind === "transfers" && (
          <>
            <select
              aria-label="传输方式"
              value={filter.mode || ""}
              onChange={(e) => change("mode", e.target.value)}
            >
              <option value="">全部方式</option>
              <option value="lan">局域网直连</option>
              <option value="relay">服务器中转</option>
            </select>
            <input
              type="date"
              aria-label="起始日期"
              value={filter.from || ""}
              onChange={(e) => change("from", e.target.value)}
            />
            <input
              type="date"
              aria-label="结束日期"
              value={filter.to || ""}
              onChange={(e) => change("to", e.target.value)}
            />
          </>
        )}
        {kind === "audit" && (
          <>
            <input
              placeholder="动作"
              aria-label="审计动作"
              className="short"
              value={filter.action || ""}
              onChange={(e) => change("action", e.target.value)}
            />
            <input
              placeholder="目标 ID"
              aria-label="审计目标"
              className="short"
              value={filter.target || ""}
              onChange={(e) => change("target", e.target.value)}
            />
          </>
        )}
        <button type="submit">筛选</button>
        <button
          type="button"
          className="quiet"
          onClick={() => {
            setFilter({});
            setQuery({});
            setPage(1);
          }}
        >
          重置
        </button>
      </form>
      <ErrorBox message={error} />
      {!data ? (
        <Load loading={loading} error={error} retry={reload} />
      ) : (
        <>
          <Table
            columns={columns[kind]}
            rows={data.items}
            actions={
              kind === "audit"
                ? undefined
                : (r) => (
                    <>
                      <button
                        className="icon"
                        title="查看详情"
                        aria-label={
                          "查看 " +
                          (r.name || r.file_name || r.username || r.id)
                        }
                        onClick={() => inspect("查看详情", kind + "/" + r.id)}
                      >
                        <Eye size={16} />
                      </button>
                      {write && (
                        <RowMenu>
                          <div>
                            {kind === "users" ? (
                              <>
                                <button
                                  onClick={() =>
                                    action(
                                      r.disabled_at
                                        ? "解封 " + r.username
                                        : "封禁 " + r.username,
                                      `users/${r.id}/${r.disabled_at ? "enable" : "disable"}`,
                                    )
                                  }
                                >
                                  {r.disabled_at ? "解封账号" : "封禁账号"}
                                </button>
                                <button
                                  onClick={() =>
                                    action(
                                      "撤销 " + r.username + " 的全部会话",
                                      `users/${r.id}/revoke`,
                                    )
                                  }
                                >
                                  撤销全部会话
                                </button>
                                <button
                                  onClick={() => preview("user_messages", r.id)}
                                >
                                  清理消息记录…
                                </button>
                                <button
                                  onClick={() =>
                                    preview("user_transfers", r.id)
                                  }
                                >
                                  清理传输历史…
                                </button>
                                <button
                                  className="danger-text"
                                  onClick={() => preview("user_delete", r.id)}
                                >
                                  注销并删除账号…
                                </button>
                              </>
                            ) : kind === "devices" ? (
                              <>
                                <button
                                  disabled={!!r.revoked_at}
                                  onClick={() =>
                                    action(
                                      "强制下线 " + r.name,
                                      `devices/${r.id}/disconnect`,
                                    )
                                  }
                                >
                                  强制下线
                                </button>
                                <button
                                  disabled={!!r.revoked_at}
                                  className="danger-text"
                                  onClick={() =>
                                    action(
                                      "移除设备 " + r.name,
                                      `devices/${r.id}/remove`,
                                    )
                                  }
                                >
                                  移除设备
                                </button>
                              </>
                            ) : (
                              <button
                                disabled={!active.includes(r.status)}
                                onClick={() =>
                                  action(
                                    "取消传输 " + r.file_name,
                                    `transfers/${r.id}/cancel`,
                                  )
                                }
                              >
                                取消传输
                              </button>
                            )}
                          </div>
                        </RowMenu>
                      )}
                    </>
                  )
            }
          />
          <div className="pagination">
            <span>
              共 {data.total} 条 · 第 {page} /{" "}
              {Math.max(1, Math.ceil(data.total / data.page_size))} 页
            </span>
            <button
              aria-label="上一页"
              disabled={page === 1}
              onClick={() => setPage((p) => p - 1)}
            >
              <ChevronLeft size={15} />
            </button>
            <button
              aria-label="下一页"
              disabled={page * data.page_size >= data.total}
              onClick={() => setPage((p) => p + 1)}
            >
              <ChevronRight size={15} />
            </button>
          </div>
        </>
      )}
    </section>
  );
}
function Retention({
  version,
  write,
  preview,
  action,
  inspect,
}: {
  version: number;
  write: boolean;
  preview: () => void;
  action: (title: string, path: string, body?: Row) => void;
  inspect: (title: string, path: string) => void;
}) {
  const policy = useLoad<Row>("retention?revision=" + version),
    [jobPage, setJobPage] = useState(1),
    jobs = useLoad<Page>("jobs?page=" + jobPage + "&revision=" + version),
    [form, setForm] = useState<Row>({
      offline_days: 30,
      delivered_days: 0,
      transfer_days: 0,
    });
  useEffect(() => {
    if (policy.data) setForm(policy.data);
  }, [policy.data]);
  useEffect(() => {
    const id = setInterval(() => {
      if (!document.hidden) jobs.reload();
    }, 5000);
    return () => clearInterval(id);
  }, []);
  return (
    <>
      <section className="panel">
        <h2>保留策略</h2>
        <p className="muted">
          参数保存到数据库，定期按创建时间清理；已送达消息与终态传输记录的 0
          表示不自动清理。不会删除活动文件任务。
        </p>
        <ErrorBox message={policy.error} />
        <div className="policy-fields">
          {[
            ["offline_days", "未送达消息（1–365 天）"],
            ["delivered_days", "已送达历史（0–3650 天）"],
            ["transfer_days", "终态传输记录（0–3650 天）"],
          ].map(([k, label]) => (
            <label key={k}>
              {label}
              <input
                type="number"
                min={k === "offline_days" ? 1 : 0}
                max={k === "offline_days" ? 365 : 3650}
                disabled={!write || !policy.data}
                value={form[k]}
                onChange={(e) =>
                  setForm((v) => ({ ...v, [k]: Number(e.target.value) }))
                }
              />
            </label>
          ))}
        </div>
        {write && (
          <div className="button-row">
            <button
              className="primary"
              disabled={!policy.data}
              onClick={() => action("修改数据保留策略", "retention", form)}
            >
              保存策略
            </button>
            <button onClick={preview}>预览并立即清理…</button>
          </div>
        )}
      </section>
      <section className="panel">
        <h2>后台清理任务</h2>
        <p className="muted">
          每 5
          秒刷新。累计删除行数包括消息、任务和账号关联数据；失败任务保留固定范围，可继续重试。
        </p>
        <ErrorBox message={jobs.error} />
        {!jobs.data && (
          <Load loading={jobs.loading} error={jobs.error} retry={jobs.reload} />
        )}
        {jobs.data && (
          <>
            <Table
              columns={[
                ["id", "任务 ID"],
                ["actor", "创建者"],
                ["status", "状态"],
                ["deleted_rows", "已删除行数"],
                ["created_at", "创建时间"],
              ]}
              rows={jobs.data.items}
              actions={(r) => (
                <>
                  <button
                    className="icon"
                    aria-label="查看任务"
                    onClick={() => inspect("清理任务", "jobs/" + r.id)}
                  >
                    <Eye size={16} />
                  </button>
                  {write && r.status === "FAILED" && (
                    <button
                      onClick={() =>
                        action("重试清理任务", "jobs/" + r.id + "/retry")
                      }
                    >
                      重试
                    </button>
                  )}
                </>
              )}
            />
            <div className="pagination">
              <span>
                共 {jobs.data.total} 个任务 · 第 {jobPage} 页
              </span>
              <button
                aria-label="上一页任务"
                disabled={jobPage === 1}
                onClick={() => setJobPage((p) => p - 1)}
              >
                <ChevronLeft size={15} />
              </button>
              <button
                aria-label="下一页任务"
                disabled={jobPage * jobs.data.page_size >= jobs.data.total}
                onClick={() => setJobPage((p) => p + 1)}
              >
                <ChevronRight size={15} />
              </button>
            </div>
          </>
        )}
      </section>
    </>
  );
}
const labels: Row = {
  id: "ID",
  username: "账号",
  name: "设备名称",
  user_id: "用户 ID",
  created_at: "创建时间",
  updated_at: "更新时间",
  disabled_at: "封禁时间",
  device_type: "设备类型",
  os_version: "系统版本",
  app_version: "客户端版本",
  status: "状态",
  last_seen_at: "最近在线",
  revoked_at: "移除时间",
  online: "实时在线",
  file_name: "文件名",
  size: "文件大小",
  mode: "传输方式",
  error: "错误",
  sender_device_id: "发送设备",
  receiver_device_id: "接收设备",
  elapsed_seconds: "任务耗时（秒）",
  actor: "操作者",
  spec_json: "固定范围",
  counts_json: "预览数量",
  reason: "操作理由",
  deleted_rows: "累计删除行数",
};
function Detail({ data }: { data: Row }) {
  return (
    <div className="detail-scroll">
      <dl>
        {Object.entries(data)
          .filter(([k]) => k !== "devices")
          .map(([k, v]) => (
            <React.Fragment key={k}>
              <dt>{labels[k] || k}</dt>
              <dd>
                {k.endsWith("_at") ? (
                  date(v)
                ) : k === "size" ? (
                  bytes(v)
                ) : k === "spec_json" || k === "counts_json" ? (
                  <pre>
                    {JSON.stringify(
                      typeof v === "string" ? JSON.parse(v) : v,
                      null,
                      2,
                    )}
                  </pre>
                ) : typeof v === "boolean" ? (
                  v ? (
                    "是"
                  ) : (
                    "否"
                  )
                ) : (
                  statusNames[v] || String(v ?? "—")
                )}
              </dd>
            </React.Fragment>
          ))}
      </dl>
      {data.devices && (
        <>
          <h3>关联设备</h3>
          <Table
            columns={[
              ["name", "名称"],
              ["device_type", "平台"],
              ["app_version", "版本"],
              ["status", "状态"],
              ["last_seen_at", "最近在线"],
            ]}
            rows={data.devices}
          />
        </>
      )}
    </div>
  );
}
function Account({ me, changed }: { me: Me; changed: () => void }) {
  const [old, setOld] = useState(""),
    [password, setPassword] = useState(""),
    [again, setAgain] = useState(""),
    [error, setError] = useState(""),
    [busy, setBusy] = useState(false);
  const busyRef = useRef(false);
  return (
    <section className="panel">
      <h2>当前管理账号</h2>
      <dl>
        <dt>用户名</dt>
        <dd>{me.username}</dd>
        <dt>角色</dt>
        <dd>{me.role === "admin" ? "管理员" : "只读运维"}</dd>
        <dt>会话到期</dt>
        <dd>{date(me.expires_at)}</dd>
      </dl>
      <p className="muted">
        管理账号与普通用户账号分离。新增和禁用管理员需在服务器执行管理命令。
      </p>
      <form
        className="password-form"
        onSubmit={async (e) => {
          e.preventDefault();
          if (busy) return;
          setError("");
          if (password !== again) {
            setError("两次输入的新密码不一致");
            return;
          }
          if (busyRef.current) return;
          busyRef.current = true;
          setBusy(true);
          try {
            await api("auth/password", {
              method: "POST",
              body: { old_password: old, new_password: password },
            });
            setOld("");
            setPassword("");
            setAgain("");
            changed();
          } catch (e) {
            setError((e as Error).message);
          } finally {
            busyRef.current = false;
            setBusy(false);
          }
        }}
      >
        <h3>
          <KeyRound size={16} />
          修改管理密码
        </h3>
        <label>
          原密码
          <input
            required
            type="password"
            autoComplete="current-password"
            value={old}
            onChange={(e) => setOld(e.target.value)}
          />
        </label>
        <label>
          新密码
          <input
            required
            minLength={12}
            maxLength={128}
            type="password"
            autoComplete="new-password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </label>
        <label>
          确认新密码
          <input
            required
            type="password"
            autoComplete="new-password"
            value={again}
            onChange={(e) => setAgain(e.target.value)}
          />
        </label>
        <ErrorBox message={error} />
        <button className="primary" disabled={busy}>
          {busy ? "正在保存…" : "修改密码"}
        </button>
        <p className="muted">修改后其他管理会话立即失效，本次会话保留。</p>
      </form>
    </section>
  );
}
