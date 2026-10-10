import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { act } from "react";
import { App } from "./App";

type Call = { method: string; path: string; body: any; csrf: string | null };
let calls: Call[];
let role: "admin" | "readonly";
let sessionAlive: boolean;
let loginFails: boolean;

const me = () => ({ id: 1, username: "owner", role, csrf_token: "csrf-1", expires_at: "2099-01-01T00:00:00Z" });
const overview = {
  users: 7, devices: 9, online_devices: 2, messages_today: 3, pending_messages: 1, failed_transfers_today: 0,
  disabled_users: 1, database_healthy: true, started_at: "2026-01-01T00:00:00Z", uptime_seconds: 120,
  relayed_bytes_since_start: 2048,
  transfer_groups: [{ status: "COMPLETED", mode: "relay", count: 3 }, { status: "FAILED", mode: "relay", count: 1 }],
  trend: [{ date: "2026-01-01", users: 1, messages: 5, transfer_tasks: 0 }, { date: "2026-01-02", users: 0, messages: 9, transfer_tasks: 2 }],
};
const sample = {
  at: "2026-01-01T00:00:00Z", cpu_percent: 3.2, rss_bytes: 52428800, heap_bytes: 10485760, goroutines: 41, connections: 5,
  db_open: 3, db_in_use: 1, db_max: 20, load1: 0.42, load_known: true, host_mem_total: 8589934592, host_mem_available: 4294967296,
  host_mem_known: true, cpus: 4,
};
const page = (items: any[]) => ({ items, total: items.length, page: 1, page_size: 20 });
const alice = { id: 11, username: "alice", created_at: "2026-01-01T00:00:00Z", disabled_at: null, device_count: 2 };

function handle(method: string, path: string): [number, any] {
  if (path === "auth/me") return sessionAlive ? [200, me()] : [401, { code: "unauthorized" }];
  if (path === "auth/login") return loginFails ? [401, { code: "invalid_credentials", message: "账号或密码不正确" }] : [200, me()];
  if (path.startsWith("overview")) return [200, overview];
  if (path === "monitor") return [200, { current: sample, history: [sample, { ...sample, cpu_percent: 7.5 }] }];
  if (path.startsWith("users?")) return [200, page([alice])];
  if (path.startsWith("users/") && method === "POST") return [204, null];
  return [200, page([])];
}

beforeEach(() => {
  calls = [];
  role = "admin";
  sessionAlive = true;
  loginFails = false;
  vi.stubGlobal("fetch", vi.fn(async (url: string, init: RequestInit = {}) => {
    const path = url.replace("/api/admin/v1/", "");
    const headers = (init.headers || {}) as Record<string, string>;
    calls.push({ method: init.method || "GET", path, body: init.body ? JSON.parse(init.body as string) : undefined, csrf: headers["X-CSRF-Token"] ?? null });
    const [status, body] = handle(init.method || "GET", path);
    return status === 204 ? new Response(null, { status }) : new Response(JSON.stringify(body), { status });
  }));
});
afterEach(() => vi.unstubAllGlobals());

describe("login", () => {
  beforeEach(() => { sessionAlive = false; });

  it("shows the sign-in form when there is no session, then the overview after a good login", async () => {
    const user = userEvent.setup();
    render(<App />);
    await user.type(await screen.findByLabelText("管理员账号"), "owner");
    await user.type(screen.getByLabelText("密码"), "a-long-password");
    await user.click(screen.getByRole("button", { name: "登录后台" }));
    expect(await screen.findByText("运行概览", { selector: "h1" })).toBeInTheDocument();
    const login = calls.find((c) => c.path === "auth/login")!;
    expect(login.body).toEqual({ username: "owner", password: "a-long-password" });
    expect(await screen.findByText("7")).toBeInTheDocument();
  });

  it("reports wrong credentials without leaving the form", async () => {
    loginFails = true;
    const user = userEvent.setup();
    render(<App />);
    await user.type(await screen.findByLabelText("管理员账号"), "owner");
    await user.type(screen.getByLabelText("密码"), "wrong-password-1");
    await user.click(screen.getByRole("button", { name: "登录后台" }));
    expect(await screen.findByRole("alert")).toHaveTextContent("账号或密码不正确");
    expect(screen.getByRole("button", { name: "登录后台" })).toBeEnabled();
  });
});

describe("overview", () => {
  it("shows icon cards, a trend chart, health and the transfer distribution", async () => {
    render(<App />);
    await screen.findByText("运行概览", { selector: "h1" });
    expect(await screen.findByText("数据库健康")).toBeInTheDocument();
    expect(screen.getByRole("img", { name: "最近 7 天趋势" })).toBeInTheDocument();
    expect(screen.getByText("01-02")).toBeInTheDocument();
    const chart = screen.getByRole("img", { name: "最近 7 天趋势" });
    expect(chart).toHaveTextContent("9"); // value label on the 01-02 message bar
    expect(screen.getByRole("img", { name: "传输状态占比" })).toBeInTheDocument();
    expect(screen.getByText("任务总数")).toBeInTheDocument();
    expect(screen.getByText("局域网直连")).toBeInTheDocument(); // zero rows stay visible
    expect(screen.getAllByText("75%").length).toBeGreaterThan(0); // success rate tile and the share row
    expect(screen.getByText("3 成功 / 1 失败")).toBeInTheDocument();
    expect(screen.getByText("封禁 1 · 近 7 天新增 1")).toBeInTheDocument();
  });

  it("shows a tooltip with every series when hovering a day", async () => {
    const user = userEvent.setup();
    render(<App />);
    const chart = await screen.findByRole("img", { name: "最近 7 天趋势" });
    expect(screen.queryByRole("tooltip")).toBeNull();
    const hit = Array.from(chart.querySelectorAll("rect")).filter((r) => r.getAttribute("fill") === "transparent")[1];
    await user.hover(hit);
    const tip = await screen.findByRole("tooltip");
    expect(tip).toHaveTextContent("2026-01-02");
    expect(tip).toHaveTextContent("消息数量9");
    expect(tip).toHaveTextContent("新增传输任务2");
    await user.unhover(hit);
    await user.hover(chart.closest(".chart-plot")!);
    await user.unhover(chart.closest(".chart-plot")!);
    expect(screen.queryByRole("tooltip")).toBeNull();
  });

  it("shows live server metrics in the header and the status panel", async () => {
    render(<App />);
    const chips = await screen.findByLabelText("服务器实时状态");
    expect(chips).toHaveTextContent("CPU 3.2%");
    expect(chips).toHaveTextContent("内存 50.0 MB");
    expect(chips).toHaveTextContent("连接 5");
    expect(await screen.findByText("进程 CPU")).toBeInTheDocument();
    expect(screen.getByText("1 / 3 / 20")).toBeInTheDocument();
    expect(screen.getByText("0.42 / 4 核")).toBeInTheDocument();
    expect(screen.getByText("50%")).toBeInTheDocument();
  });
});

describe("console", () => {
  it("restores a live session on load and returns to sign-in when it expires", async () => {
    render(<App />);
    expect(await screen.findByText("运行概览", { selector: "h1" })).toBeInTheDocument();
    act(() => { window.dispatchEvent(new Event("admin-expired")); });
    expect(await screen.findByRole("button", { name: "登录后台" })).toBeInTheDocument();
  });

  it("lets an admin ban a user only with a reason, sending the CSRF token", async () => {
    location.hash = "users";
    const user = userEvent.setup();
    render(<App />);
    await screen.findByText("alice");
    await user.click(screen.getByRole("button", { name: "更多操作" }));
    await user.click(await screen.findByText("封禁账号"));
    const dialog = await screen.findByRole("dialog");
    const confirm = within(dialog).getByRole("button", { name: "确认执行" });
    await user.click(confirm);
    expect(calls.some((c) => c.path === "users/11/disable")).toBe(false);
    await user.type(within(dialog).getByRole("textbox"), "违反使用条款");
    await user.click(confirm);
    await waitFor(() => expect(calls.some((c) => c.path === "users/11/disable")).toBe(true));
    const call = calls.find((c) => c.path === "users/11/disable")!;
    expect(call.method).toBe("POST");
    expect(call.csrf).toBe("csrf-1");
    expect(call.body).toEqual({ reason: "违反使用条款" });
    expect(await screen.findByText("操作已完成")).toBeInTheDocument();
  });

  it("hides every write control from the readonly role", async () => {
    role = "readonly";
    location.hash = "users";
    render(<App />);
    await screen.findByText("alice");
    expect(screen.getByText(/只读运维角色/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "更多操作" })).toBeNull();
    expect(screen.getByRole("button", { name: /查看 alice/ })).toBeInTheDocument();
  });

  it("puts the signed-in name and role together at the foot of the menu", async () => {
    render(<App />);
    const name = await screen.findByTitle("owner");
    expect(name.closest(".who")).toHaveTextContent("管理员");
    expect(name.closest(".who")!.querySelector(".avatar")).toHaveTextContent("o");
  });

  it("switches and remembers the theme", async () => {
    const user = userEvent.setup();
    render(<App />);
    await user.click(await screen.findByRole("button", { name: /切换主题/ }));
    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(localStorage.getItem("linkory-admin-theme")).toBe("dark");
  });
});
