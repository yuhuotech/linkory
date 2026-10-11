import React, { useEffect, useState, useRef } from "react";
import { createPortal } from "react-dom";
import {
  MoreHorizontal,
  X,
  AlertCircle,
} from "lucide-react";
import { bytes, date } from "./format";
import { api } from "./api";

export type Row = Record<string, any>;
export type Page = { items: Row[]; total: number; page: number; page_size: number };
export const statusNames: Record<string, string> = {
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
export const active = [
  "CREATED",
  "WAITING_ACCEPT",
  "ACCEPTED",
  "TRANSFERRING",
  "VERIFYING",
];
export function Badge({ value }: { value: string }) {
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
export function useLoad<T>(path: string) {
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
export function Modal({
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
export function ErrorBox({ message }: { message: string }) {
  return message ? (
    <div className="error" role="alert">
      <AlertCircle size={16} />
      <span>{message}</span>
    </div>
  ) : null;
}
export function Load({
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
export function RowMenu({ children }: { children: React.ReactNode }) {
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
export function Table({
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
export function Detail({ data }: { data: Row }) {
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

export const labels: Row = {
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
