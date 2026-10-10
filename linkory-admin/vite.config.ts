import { defineConfig } from "vitest/config";
export default defineConfig({
  base: "/admin/",
  server: {
    proxy: {
      "/api": {
        target: process.env.LINKORY_ADMIN_API || "http://127.0.0.1:8090",
        changeOrigin: false,
      },
    },
  },
  build: {
    rollupOptions: {
      onwarn(warning, warn) {
        // lucide-react ships "use client" for React Server Components; a client-only bundle can ignore it.
        if (warning.code === "MODULE_LEVEL_DIRECTIVE") return;
        warn(warning);
      },
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test-setup.ts"],
    css: false,
  },
});
