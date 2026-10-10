import { describe, expect, it } from "vitest";
import { bytes, date } from "./App";

describe("formatting", () => {
  it("formats sizes", () => {
    expect(bytes(0)).toBe("0 B");
    expect(bytes(1023)).toBe("1023 B");
    expect(bytes(1536)).toBe("1.5 KB");
    expect(bytes(5 * 1024 ** 4)).toBe("5.0 TB");
    expect(bytes(1024 ** 6)).toBe("1048576.0 TB");
    expect(bytes("junk")).toBe("0 B");
  });
  it("formats dates", () => {
    expect(date(null)).toBe("—");
    expect(date("not a date")).toBe("not a date");
    expect(date("2026-01-02T03:04:05Z")).toMatch(/2026/);
  });
});
