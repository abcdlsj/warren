import { useEffect, useRef, useState } from "react";
import { useI18n } from "./i18n.jsx";
import TerminalDemo from "./TerminalDemo.jsx";

function Reveal({ className = "", delay = 0, children }) {
  const ref = useRef(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      el.classList.add("in");
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            entry.target.classList.add("in");
            observer.unobserve(entry.target);
          }
        }
      },
      { threshold: 0.12 },
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  return (
    <div
      ref={ref}
      className={`reveal ${className}`}
      style={delay ? { "--reveal-delay": `${delay}ms` } : undefined}
    >
      {children}
    </div>
  );
}

function Nav() {
  const { t, locale, setLocale } = useI18n();
  return (
    <header className="nav">
      <a className="nav-brand" href="#top">
        <img src="/favicon.svg" alt="" width="20" height="20" />
        <span>Warren</span>
      </a>
      <nav className="nav-links">
        <a href="#top">{t("nav.overview")}</a>
        <a href="#terminal">{t("nav.terminal")}</a>
        <a href="#why">{t("nav.why")}</a>
      </nav>
      <div className="nav-right">
        <a
          className="github-link"
          href="https://github.com/abcdlsj/warren"
          target="_blank"
          rel="noreferrer"
        >
          <svg viewBox="0 0 16 16" width="15" height="15" aria-hidden="true" fill="currentColor">
            <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27s1.36.09 2 .27c1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8z" />
          </svg>
          <span>GitHub</span>
        </a>
        <div className="lang" role="group" aria-label="Language">
          <button
            type="button"
            className={locale === "en" ? "active" : ""}
            onClick={() => setLocale("en")}
          >
            EN
          </button>
          <button
            type="button"
            className={locale === "zh" ? "active" : ""}
            onClick={() => setLocale("zh")}
          >
            中文
          </button>
        </div>
      </div>
    </header>
  );
}

function Hero() {
  const { t } = useI18n();
  const [downloadState, setDownloadState] = useState("idle");

  async function handleDownload() {
    if (downloadState !== "idle") return;
    setDownloadState("loading");
    try {
      const response = await fetch("/api/latest-release");
      if (!response.ok) throw new Error(`release API ${response.status}`);
      const release = await response.json();
      if (!release?.url) throw new Error("no release url");
      setDownloadState("ready");
      window.location.assign(release.url);
      window.setTimeout(() => setDownloadState("idle"), 4000);
    } catch {
      setDownloadState("error");
      window.location.assign("https://github.com/abcdlsj/warren/releases/latest");
      window.setTimeout(() => setDownloadState("idle"), 4000);
    }
  }

  const downloadLabel = {
    idle: t("hero.ctaDownload"),
    loading: t("hero.downloading"),
    ready: t("hero.downloadReady"),
    error: t("hero.downloadFallback"),
  }[downloadState];

  return (
    <section id="top" className="hero">
      <Reveal className="hero-kicker">{t("hero.kicker")}</Reveal>
      <h1 className="hero-title">
        <span>{t("hero.titleA")}</span>
        <span className="hero-title-accent">{t("hero.titleB")}</span>
      </h1>
      <Reveal className="hero-lede" delay={120}>
        {t("hero.lede")}
      </Reveal>
      <Reveal className="hero-actions" delay={220}>
        <button
          type="button"
          className={`btn primary download-btn${downloadState !== "idle" ? " is-busy" : ""}`}
          onClick={handleDownload}
          disabled={downloadState !== "idle"}
        >
          <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" fill="currentColor">
            <path d="M8 1.5a.75.75 0 0 1 .75.75v6.19l2.22-2.22a.75.75 0 1 1 1.06 1.06l-3.5 3.5a.75.75 0 0 1-1.06 0l-3.5-3.5a.75.75 0 1 1 1.06-1.06l2.22 2.22V2.25A.75.75 0 0 1 8 1.5Z" />
            <path d="M2.5 10.75a.75.75 0 0 1 .75.75v1.5c0 .414.336.75.75.75h8a.75.75 0 0 0 .75-.75v-1.5a.75.75 0 0 1 1.5 0v1.5A2.25 2.25 0 0 1 12 15.25H4a2.25 2.25 0 0 1-2.25-2.25v-1.5a.75.75 0 0 1 .75-.75Z" />
          </svg>
          {downloadLabel}
        </button>
        <a className="btn ghost" href="#terminal">
          {t("hero.ctaTerminal")}
        </a>
        <a
          className="btn ghost"
          href="https://github.com/abcdlsj/warren"
          target="_blank"
          rel="noreferrer"
        >
          {t("hero.ctaDocs")}
        </a>
      </Reveal>
      <Reveal className="hero-meta" delay={320}>
        <span className="status-dot" aria-hidden="true" />
        <span>{t("hero.status")}</span>
        <span className="hero-meta-sep" aria-hidden="true" />
        <span>{t("hero.platform")}</span>
      </Reveal>
    </section>
  );
}

function Ticker() {
  const { t } = useI18n();
  const items = t("ticker.items");
  const row = [...items, ...items];
  return (
    <div className="ticker" aria-hidden="true">
      <div className="ticker-track">
        {row.map((item, index) => (
          <span className="ticker-item" key={`${item}-${index}`}>
            <span>{item}</span>
            <i className="ticker-star">✦</i>
          </span>
        ))}
      </div>
    </div>
  );
}

function ProductShot() {
  const { t } = useI18n();
  return (
    <section className="section product">
      <Reveal className="section-head">
        <p className="kicker">{t("product.kicker")}</p>
        <h2>{t("product.title")}</h2>
      </Reveal>
      <Reveal delay={100}>
        <figure className="product-frame">
          <img src="/screenshot-desktop.png" alt={t("product.alt")} loading="lazy" />
          <figcaption>{t("product.caption")}</figcaption>
        </figure>
      </Reveal>
    </section>
  );
}

function Features() {
  const { t } = useI18n();
  const items = t("features.items");
  return (
    <section id="why" className="section features">
      <Reveal className="section-head">
        <p className="kicker">{t("features.kicker")}</p>
        <h2>{t("features.title")}</h2>
        <p className="section-lede">{t("features.lede")}</p>
      </Reveal>
      <div className="feature-grid">
        {items.map((item, index) => (
          <Reveal className="feature-card" delay={index * 60} key={item.title}>
            <span className="feature-index">{String(index + 1).padStart(2, "0")}</span>
            <h3>{item.title}</h3>
            <p>{item.body}</p>
          </Reveal>
        ))}
      </div>
    </section>
  );
}

function Architecture() {
  const { t } = useI18n();
  return (
    <section id="architecture" className="section architecture">
      <Reveal className="section-head">
        <p className="kicker">{t("architecture.kicker")}</p>
        <h2>{t("architecture.title")}</h2>
        <p className="section-lede">{t("architecture.lede")}</p>
      </Reveal>
      <Reveal className="arch">
        <div className="arch-node">
          <span className="arch-tag">{t("architecture.clients")}</span>
          <strong>{t("architecture.clientLine")}</strong>
        </div>
        <div className="arch-link">
          <span>WebSocket · v1</span>
        </div>
        <div className="arch-node arch-node-host">
          <span className="arch-tag">{t("architecture.host")}</span>
          <strong>{t("architecture.hostLine")}</strong>
        </div>
        <div className="arch-link">
          <span>pty · durable store</span>
        </div>
        <div className="arch-node">
          <span className="arch-tag">{t("architecture.runtime")}</span>
          <strong>{t("architecture.runtimeLine")}</strong>
        </div>
      </Reveal>
      <Reveal className="arch-note">{t("architecture.note")}</Reveal>
    </section>
  );
}

function Principle() {
  const { t } = useI18n();
  return (
    <section className="section principle">
      <Reveal className="principle-inner">
        <span className="principle-mark" aria-hidden="true">
          "
        </span>
        <blockquote>{t("principle.quote")}</blockquote>
        <cite>{t("principle.cite")}</cite>
      </Reveal>
    </section>
  );
}

function Footer() {
  const { t } = useI18n();
  return (
    <footer className="footer">
      <div className="footer-main">
        <div className="footer-brand">
          <img src="/favicon.svg" alt="" width="18" height="18" />
          <span>Warren</span>
        </div>
        <p>{t("footer.line")}</p>
      </div>
      <div className="footer-meta">
        <span>{t("footer.servedBy")}</span>
        <span className="footer-sep" aria-hidden="true">
          ·
        </span>
        <a href="https://github.com/abcdlsj/warren" target="_blank" rel="noreferrer">
          {t("footer.source")}
        </a>
        <span className="footer-sep" aria-hidden="true">
          ·
        </span>
        <span>{t("footer.domain")}</span>
      </div>
    </footer>
  );
}

export default function App() {
  return (
    <div className="site">
      <div className="grain" aria-hidden="true" />
      <Nav />
      <main>
        <Hero />
        <Ticker />
        <ProductShot />
        <TerminalDemo />
        <Features />
        <Architecture />
        <Principle />
      </main>
      <Footer />
    </div>
  );
}
