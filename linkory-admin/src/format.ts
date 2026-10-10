export function date(v: any) {
  if (!v) return "—";
  const d = new Date(v);
  return isNaN(d.getTime())
    ? String(v)
    : d.toLocaleString("zh-CN", { hour12: false });
}
export function bytes(n: any) {
  let x = Number(n) || 0;
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (x >= 1024 && i < 4) {
    x /= 1024;
    i++;
  }
  return `${x.toFixed(i ? 1 : 0)} ${units[i]}`;
}
