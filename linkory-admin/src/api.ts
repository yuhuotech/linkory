export type Me = {
  id: number;
  username: string;
  role: "admin" | "readonly";
  csrf_token: string;
  expires_at: string;
};
let csrf = "";
export function setSession(me: Me | null) {
  csrf = me?.csrf_token || "";
}
export class ApiError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}
export async function api<T = any>(
  path: string,
  options: { method?: string; body?: unknown; signal?: AbortSignal } = {},
): Promise<T> {
  const method = options.method || "GET";
  const controller = new AbortController();
  const cancel = () => controller.abort();
  if (options.signal?.aborted) cancel();
  options.signal?.addEventListener("abort", cancel, { once: true });
  const timeout = setTimeout(() => controller.abort(), 15000);
  let response: Response;
  try {
    response = await fetch("/api/admin/v1/" + path, {
      method,
      credentials: "same-origin",
      signal: controller.signal,
      headers: {
        Accept: "application/json",
        ...(method !== "GET"
          ? {
              "Content-Type": "application/json",
              "X-CSRF-Token": csrf,
              "X-Linkory-Admin": "1",
            }
          : {}),
      },
      body:
        options.body === undefined ? undefined : JSON.stringify(options.body),
    });
  } catch (error) {
    if (options.signal?.aborted) throw error;
    throw new ApiError(
      0,
      method === "GET"
        ? "网络请求未完成，请检查连接后重试"
        : "未收到操作响应，请先刷新核对结果再重试",
    );
  } finally {
    clearTimeout(timeout);
    options.signal?.removeEventListener("abort", cancel);
  }
  const data =
    response.status === 204 ? null : await response.json().catch(() => null);
  if (!response.ok) {
    if (response.status === 401 && csrf && !path.includes("auth/login"))
      window.dispatchEvent(new Event("admin-expired"));
    throw new ApiError(
      response.status,
      (
        {
          internal: "服务暂时不可用，请稍后重试",
          unauthorized: "管理会话已失效，请重新登录",
          forbidden: "权限不足或请求校验失败",
          not_found: "记录不存在或已被删除",
          bad_request: "输入格式不正确，请检查后重试",
        } as Record<string, string>
      )[data?.code] ||
        data?.message ||
        `请求失败 (${response.status})`,
    );
  }
  return data as T;
}
