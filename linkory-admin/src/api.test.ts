import { afterEach, describe, expect, it, vi } from "vitest";
import { api, ApiError, setSession } from "./api";

function reply(status: number, body?: unknown) {
  const fetchMock = vi.fn(async (_url: string, _init?: RequestInit) =>
    status === 204
      ? new Response(null, { status })
      : new Response(JSON.stringify(body ?? {}), { status }),
  );
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}
afterEach(() => {
  vi.unstubAllGlobals();
  setSession(null);
});

describe("api", () => {
  it("sends no CSRF headers on reads", async () => {
    const f = reply(200, { ok: true });
    await api("overview");
    const [url, init] = f.mock.calls[0];
    expect(url).toBe("/api/admin/v1/overview");
    expect(init!.credentials).toBe("same-origin");
    expect(init!.headers).not.toHaveProperty("X-CSRF-Token");
  });
  it("sends the session CSRF token and admin marker on writes", async () => {
    setSession({ id: 1, username: "o", role: "admin", csrf_token: "tok", expires_at: "" });
    const f = reply(204);
    await expect(api("users/1/disable", { method: "POST", body: { reason: "测试" } })).resolves.toBeNull();
    const init = f.mock.calls[0][1]!;
    expect(init.headers).toMatchObject({ "X-CSRF-Token": "tok", "X-Linkory-Admin": "1" });
    expect(init.body).toBe(JSON.stringify({ reason: "测试" }));
  });
  it("maps server error codes to Chinese messages", async () => {
    reply(403, { code: "forbidden", message: "forbidden" });
    await expect(api("x")).rejects.toMatchObject({ status: 403, message: "权限不足或请求校验失败" });
    reply(409, { code: "preview_expired", message: "预览已过期" });
    await expect(api("x")).rejects.toMatchObject({ message: "预览已过期" });
    reply(502);
    await expect(api("x")).rejects.toMatchObject({ message: "请求失败 (502)" });
  });
  it("announces an expired session only when one was active", async () => {
    const listener = vi.fn();
    window.addEventListener("admin-expired", listener);
    reply(401, { code: "unauthorized" });
    await expect(api("overview")).rejects.toBeInstanceOf(ApiError);
    expect(listener).not.toHaveBeenCalled();
    setSession({ id: 1, username: "o", role: "admin", csrf_token: "tok", expires_at: "" });
    await expect(api("overview")).rejects.toBeInstanceOf(ApiError);
    expect(listener).toHaveBeenCalledTimes(1);
    reply(401, { code: "invalid_credentials", message: "账号或密码不正确" });
    await expect(api("auth/login", { method: "POST", body: {} })).rejects.toMatchObject({ message: "账号或密码不正确" });
    expect(listener).toHaveBeenCalledTimes(1);
    window.removeEventListener("admin-expired", listener);
  });
  it("tells the operator to verify after a failed write but to retry a failed read", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => { throw new TypeError("offline"); }));
    await expect(api("overview")).rejects.toMatchObject({ status: 0, message: "网络请求未完成，请检查连接后重试" });
    await expect(api("jobs", { method: "POST", body: {} })).rejects.toMatchObject({ message: "未收到操作响应，请先刷新核对结果再重试" });
  });
});
