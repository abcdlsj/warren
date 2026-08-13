import { defineConfig } from "vite";
import { fileURLToPath, URL } from "node:url";

export default defineConfig({
  base: "/",
  build: {
    outDir: fileURLToPath(new URL(
      "../Packages/WebRelay/Sources/WebRelay/Resources",
      import.meta.url,
    )),
    emptyOutDir: true,
    sourcemap: true,
    rollupOptions: {
      output: {
        entryFileNames: "assets/app.js",
        chunkFileNames: "assets/[name].js",
        assetFileNames: ({ names = [] }) => names.some(name => name.endsWith(".css"))
          ? "assets/app.css"
          : "assets/[name][extname]",
      },
    },
  },
  server: {
    port: 5173,
    strictPort: true,
  },
});
