import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  base: "/",
  plugins: [react()],
  build: {
    outDir: "dist",
    emptyOutDir: true,
    sourcemap: true,
    cssCodeSplit: false,
    rollupOptions: {
      output: {
        entryFileNames: "assets/app.js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: ({ names = [] }) => names.some(name => name.endsWith(".css"))
          ? "assets/app.css"
          : "assets/[name][extname]",
        manualChunks(id) {
          if (!id.includes("/node_modules/")) return;
          if (id.includes("/@xterm/")) return "xterm";
          if (id.includes("/react/") || id.includes("/react-dom/")) return "react";
        },
      },
    },
  },
  server: {
    port: 5173,
    strictPort: true,
  },
});
