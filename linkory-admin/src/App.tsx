import { useEffect, useState, useRef } from "react";
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
  Sun,
  Moon,
  CheckCircle,
} from "lucide-react";
import { date } from "./format";
import { MonitorChips, useMonitor } from "./monitor";
import { api, ApiError, setSession, type Me } from "./api";
import { Row, Badge, Modal, ErrorBox, Detail } from "./shared";
import { Login } from "./Login";
import { Overview } from "./Overview";
import { Listing } from "./Listing";
import { Retention } from "./Retention";
import { Account } from "./Account";
import "./style.css";

export { bytes, date } from "./format";

const sections = [
  ["overview", "运行概览", LayoutDashboard],
  ["users", "用户管理", Users],
  ["devices", "设备管理", Laptop],
  ["transfers", "文件传输", ArrowLeftRight],
  ["retention", "数据保留", Database],
  ["audit", "操作审计", ScrollText],
  ["account", "管理账号", ShieldCheck],
] as const;
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

