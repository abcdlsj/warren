import { createContext, useContext, useEffect, useMemo, useState } from "react";

const messages = {
  en: {
    "nav.overview": "Overview",
    "nav.terminal": "Terminal",
    "nav.why": "Why",
    "nav.source": "Source",
    "hero.kicker": "Local-first development workbench",
    "hero.titleA": "Your terminal,",
    "hero.titleB": "kept alive.",
    "hero.lede":
      "Warren is a local-first workbench for people who live in the terminal. Sessions run on a host — your Mac or a VPS — and survive app quits, network drops, and closing the laptop.",
    "hero.ctaTerminal": "Try the terminal",
    "hero.ctaDocs": "Read the source",
    "hero.ctaDownload": "Download",
    "hero.downloading": "Getting latest…",
    "hero.downloadReady": "Downloading…",
    "hero.downloadFallback": "Open releases",
    "hero.status": "Phase one · open source",
    "hero.platform": "macOS · Web · CLI",
    "ticker.items": ["Detach", "Reconnect", "Resume", "Workspaces", "Sessions", "Agent views"],
    "product.kicker": "Today",
    "product.title": "This is the desktop app.",
    "product.caption": "Projects and workspaces on the left; terminal tabs, sessions and agent views in the middle.",
    "product.alt": "Warren desktop with project sidebar, terminal tabs and an agent view",
    "terminal.kicker": "Interactive demo",
    "terminal.title": "The desktop's terminal engine, try it here",
    "terminal.lede":
      "This demo runs Ghostty's VT parser, compiled to WASM — the same engine that powers the desktop app. It talks to a fake host, but the terminal behavior is real. Type help, then try sessions or detach.",
    "terminal.badge": "ghostty-wasm",
    "terminal.hint": "Click inside and type help",
    "terminal.engineNote": "Demo engine: Ghostty WASM · Warren Web client: xterm.js",
    "features.kicker": "Why Warren",
    "features.title": "Sessions belong to the host.",
    "features.lede": "Everything else in Warren is built around that.",
    "features.items": [
      {
        title: "Durable sessions",
        body: "Quit the app, switch networks, close the laptop. Your session stays on the host and is still there when you come back.",
      },
      {
        title: "One resource model",
        body: "Projects, workspaces, sessions and runtimes are the same objects on desktop, web and CLI. No parallel universes.",
      },
      {
        title: "Local and remote",
        body: "SSH just gets you to the host. After that, all clients speak the same WebSocket protocol to the same daemon.",
      },
      {
        title: "Real terminal fidelity",
        body: "The desktop uses Ghostty, the web uses xterm.js. ANSI, OSC, Unicode and TUI colors keep working.",
      },
      {
        title: "Agent views",
        body: "Codex and Claude transcripts show up as readable conversations, and the raw terminal is still one tab away.",
      },
      {
        title: "Workspace-first Git",
        body: "Projects, main checkouts and worktrees are real resources. Import your existing Superset projects once and move on.",
      },
    ],
    "architecture.kicker": "How it fits together",
    "architecture.title": "One host, every surface",
    "architecture.lede":
      "Desktop, web and CLI all talk to the same warren-headless daemon over one WebSocket protocol. The host owns sessions and runtimes.",
    "architecture.clients": "Clients",
    "architecture.host": "Host",
    "architecture.runtime": "Runtime",
    "architecture.clientLine": "macOS app · Web/PWA · CLI",
    "architecture.hostLine": "warren-headless",
    "architecture.runtimeLine": "ghostline / tmux",
    "architecture.note": "SSH, Tailscale and Cloudflare Tunnel only get you there. They are not the product model.",
    "principle.quote":
      "Closing a tab is the only way to end a session. Quitting, switching workspaces, losing Wi-Fi — that's just walking away.",
    "principle.cite": "Warren product design, §5",
    "footer.line": "Sessions belong to the host.",
    "footer.servedBy": "Served by a Cloudflare Worker",
    "footer.source": "Source",
    "footer.domain": "wareenai.xyz",
  },
  zh: {
    "nav.overview": "概览",
    "nav.terminal": "终端",
    "nav.why": "为什么",
    "nav.source": "源码",
    "hero.kicker": "本地优先的开发工作台",
    "hero.titleA": "你的终端，",
    "hero.titleB": "一直在。",
    "hero.lede":
      "Warren 是一个本地优先的开发工作台，给那些住在终端里的人。会话跑在 Host 上——你的 Mac 或一台 VPS——退出应用、网络断开、合上电脑，它都还在。",
    "hero.ctaTerminal": "试试终端",
    "hero.ctaDocs": "查看源码",
    "hero.ctaDownload": "下载",
    "hero.downloading": "获取最新版…",
    "hero.downloadReady": "开始下载…",
    "hero.downloadFallback": "打开 Releases",
    "hero.status": "Phase one · 开源",
    "hero.platform": "macOS · Web · CLI",
    "ticker.items": ["断开", "重连", "恢复", "工作区", "会话", "Agent 视图"],
    "product.kicker": "现在",
    "product.title": "这是现在的桌面端。",
    "product.caption": "左边是 Project 和 Workspace，中间是终端 Tab、会话和 Agent 视图。",
    "product.alt": "Warren 桌面端截图：项目侧栏、终端 Tab 和 Agent 视图",
    "terminal.kicker": "可交互演示",
    "terminal.title": "桌面端同一个终端引擎，这里就能试",
    "terminal.lede":
      "这个演示用的就是 Ghostty 的 VT 解析器，编译成 WASM——和桌面端同一个引擎。它连的是一个假 Host，但终端行为是真的。输入 help，然后试试 sessions 或 detach。",
    "terminal.badge": "ghostty-wasm",
    "terminal.hint": "点击终端，输入 help",
    "terminal.engineNote": "演示引擎：Ghostty WASM · Warren Web 客户端：xterm.js",
    "features.kicker": "为什么是 Warren",
    "features.title": "会话属于 Host。",
    "features.lede": "Warren 里的一切都围绕这句话展开。",
    "features.items": [
      {
        title: "持久会话",
        body: "退出应用、切换网络、合上电脑。会话留在 Host 上，你回来时它还在。",
      },
      {
        title: "统一的资源模型",
        body: "Project、Workspace、Session、Runtime 在桌面端、Web 和 CLI 上是同一套对象，没有平行宇宙。",
      },
      {
        title: "本地与远程",
        body: "SSH 只负责把你带到 Host。之后所有客户端都通过同一条 WebSocket 协议连同一个 daemon。",
      },
      {
        title: "真正的终端保真",
        body: "桌面端用 Ghostty，Web 用 xterm.js。ANSI、OSC、Unicode、TUI 颜色都照常工作。",
      },
      {
        title: "Agent 会话视图",
        body: "Codex 和 Claude 的转写会变成可读的对话，原始终端也还在旁边。",
      },
      {
        title: "以 Workspace 为先的 Git",
        body: "Project、主检出、worktree 都是真实资源。已有的 Superset 项目导一次就行。",
      },
    ],
    "architecture.kicker": "它如何拼起来",
    "architecture.title": "一个 Host，所有入口",
    "architecture.lede":
      "桌面端、Web 和 CLI 都通过同一条 WebSocket 协议连接同一个 warren-headless daemon。会话和运行时归 Host 所有。",
    "architecture.clients": "客户端",
    "architecture.host": "Host",
    "architecture.runtime": "运行时",
    "architecture.clientLine": "macOS 应用 · Web/PWA · CLI",
    "architecture.hostLine": "warren-headless",
    "architecture.runtimeLine": "ghostline / tmux",
    "architecture.note": "SSH、Tailscale 和 Cloudflare Tunnel 只负责把你带到那里，不属于产品模型。",
    "principle.quote":
      "关闭 Tab 是结束会话的唯一方式。退出、切换工作区、Wi-Fi 断了——那只是离开而已。",
    "principle.cite": "Warren 产品设计，§5",
    "footer.line": "会话属于 Host。",
    "footer.servedBy": "由 Cloudflare Worker 托管",
    "footer.source": "源码",
    "footer.domain": "wareenai.xyz",
  },
};

const I18nContext = createContext(null);

function detectLocale() {
  if (typeof window === "undefined") return "en";
  const stored = localStorage.getItem("warren.locale");
  if (stored === "zh" || stored === "en") return stored;
  const path = window.location.pathname.split("/")[1];
  if (path === "zh" || path === "en") return path;
  return navigator.language?.toLowerCase().startsWith("zh") ? "zh" : "en";
}

export function I18nProvider({ children }) {
  const [locale, setLocaleState] = useState(detectLocale);

  const value = useMemo(() => {
    const setLocale = (next) => {
      setLocaleState(next);
      try {
        localStorage.setItem("warren.locale", next);
      } catch {
        // Private mode; the toggle still works for this session.
      }
      document.documentElement.lang = next === "zh" ? "zh-CN" : "en";
    };
    return {
      locale,
      t: (key) => messages[locale][key] ?? messages.en[key] ?? key,
      setLocale,
    };
  }, [locale]);

  useEffect(() => {
    document.documentElement.lang = locale === "zh" ? "zh-CN" : "en";
  }, [locale]);

  return <I18nContext.Provider value={value}>{children}</I18nContext.Provider>;
}

export function useI18n() {
  return useContext(I18nContext);
}
