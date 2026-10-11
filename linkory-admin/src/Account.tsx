import { useState, useRef } from "react";
import {
  KeyRound,
} from "lucide-react";
import { date } from "./format";
import { api, type Me } from "./api";
import { ErrorBox } from "./shared";

export function Account({ me, changed }: { me: Me; changed: () => void }) {
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
