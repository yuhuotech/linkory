import { useState, useRef } from "react";
import { api, type Me } from "./api";
import { ErrorBox } from "./shared";

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
