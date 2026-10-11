import { useState } from "react";
import {
  Eye,
  Search,
  ChevronLeft,
  ChevronRight,
} from "lucide-react";
import { date } from "./format";
import { Row, Page, statusNames, active, useLoad, ErrorBox, Load, RowMenu, Table } from "./shared";

export function Listing({
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

export const columns: Record<string, [string, string][]> = {
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
