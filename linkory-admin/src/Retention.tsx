import { useEffect, useState } from "react";
import {
  Eye,
  ChevronLeft,
  ChevronRight,
} from "lucide-react";
import { Row, Page, useLoad, ErrorBox, Load, Table } from "./shared";

export function Retention({
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
