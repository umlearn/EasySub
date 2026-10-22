const en = {
  navHow: "How it works", navFeatures: "Features", navFaq: "FAQ", download: "Download",
  release: "Prebuilt version now available", hero1: "Subtitles", hero2: "simplified",
  heroCopy: "Drop in a video. Search, match, and save subtitles automatically. No extra steps.",
  downloadLatest: "Download latest", seeHow: "See how it works", requirements: "macOS 14 or later",
  unsigned: "Currently unsigned", allVideos: "All videos", pending: "Pending", completed: "Completed",
  attention: "Needs attention", settings: "Settings", format: "Format", keepExisting: "Keep existing",
  video: "Video", size: "Size", status: "Status", videosCount: "videos · 1 completed · 0 need attention",
  saveLocation: "Saved to the selected folder",
  downloadPending: "Download pending", mockCaption: "Click “Download pending” to try the search flow",
  resetDemo: "Reset demo", searching: "Searching…", searchComplete: "All subtitles found",
  videosComplete: "videos · 5 completed · 0 need attention", howEyebrow: "How it works",
  howTitle: "Video to subtitle in three steps.", step1Title: "Drop in videos",
  step1Copy: "Add one video or a whole folder. EasySub scans and removes duplicates.",
  step2Title: "Match automatically", step2Copy: "Search multiple sources in parallel and rank by title, year, episode, and language.",
  step3Title: "Save subtitles", step3Copy: "Choose ASS, SRT, or both. Subtitles land right beside each video.",
  featuresEyebrow: "Why EasySub", featuresTitle: "Effortless, without taking control away.",
  smartMatch: "Smart matching", matchTitle: "Understands releases, not just filenames.",
  matchCopy: "Title, year, episode, language, format, and release traits all shape the ranking. Automatic mode moves fast; manual mode keeps every choice.",
  languages: "Language preferences", languageTitle: "Search in your order.",
  languageCopy: "Choose up to three subtitle languages with automatic fallback.", localFirst: "Local first",
  localTitle: "Your videos stay on your Mac.",
  localCopy: "Only the needed filename is sent, or a partial fingerprint is calculated locally. Videos are never uploaded.",
  sources: "Subtitle sources", sourcesTitle: "One search. Multiple sources.",
  sourcesCopy: "Enable OpenSubtitles, Xunlei, ASSRT, and Shooter as needed. One source failing never blocks the others.",
  sourceDetails: "Read source details", xunlei: "Xunlei", noticeTitle: "About the current unsigned build",
  noticeCopy: "EasySub is not yet signed or notarized with an Apple Developer ID. macOS may show a security message the first time it opens. Only download from this project's GitHub Releases.",
  openGuide: "How to open it", faqEyebrow: "Before you begin", faqTitle: "Common questions",
  faq1Q: "How do I open the unsigned build on macOS?",
  faq1A: "In Finder, right-click EasySub and choose Open. If it is still blocked, go to System Settings → Privacy & Security and confirm that you want to open it.",
  faq2Q: "Does EasySub upload my videos?",
  faq2A: "No. Videos always stay local. Some providers use a cleaned filename, or a fingerprint calculated locally from small parts of the file.",
  faq3Q: "Do I need an account or token?",
  faq3A: "It depends on the source. Xunlei needs no token; ASSRT uses your personal token; OpenSubtitles uses an API Key. Combine them freely in Settings.",
  faq4Q: "Which formats are supported?",
  faq4A: "Subtitles support ASS and SRT. Video formats include MKV, MOV, MP4, M4V, RMVB, AVI, MPEG, MPG, TS, M2TS, and WebM.",
  cta1: "For your next video", cta2: "let subtitles fall into place",
  ctaCopy: "Native, lightweight, and open source. Made for local video on macOS.", license: "License"
};

const zh = {};
document.querySelectorAll("[data-i18n]").forEach((node) => { zh[node.dataset.i18n] = node.textContent; });
Object.assign(zh, {
  searching: "正在搜索…", searchComplete: "字幕已全部找到", videosComplete: "个视频 · 5 个已完成 · 0 个需注意"
});

let language = localStorage.getItem("easysub-language") || (navigator.language.startsWith("zh") ? "zh" : "en");
let demoTimers = [];
let demoFinished = false;

function t(key) {
  return language === "zh" ? zh[key] : (en[key] || zh[key]);
}

function setLanguage(next) {
  language = next;
  document.documentElement.lang = next === "zh" ? "zh-CN" : "en";
  document.querySelectorAll("[data-i18n]").forEach((node) => { node.textContent = t(node.dataset.i18n); });
  const button = document.querySelector(".language-button");
  button.querySelector("span").textContent = next === "zh" ? "EN" : "中文";
  button.setAttribute("aria-label", next === "zh" ? "Switch to English" : "切换到中文");
  document.title = next === "zh" ? "EasySub — 字幕下载，简单一点" : "EasySub — Subtitles, simplified";
  if (demoFinished) {
    document.querySelector("[data-run-label]").textContent = t("searchComplete");
    document.querySelector("[data-summary]").textContent = t("videosComplete");
  }
  localStorage.setItem("easysub-language", next);
}

function setTheme(next) {
  document.documentElement.dataset.theme = next;
  const button = document.querySelector(".theme-button");
  button.setAttribute("aria-label", next === "dark" ? (language === "zh" ? "切换到浅色模式" : "Switch to light mode") : (language === "zh" ? "切换到深色模式" : "Switch to dark mode"));
  localStorage.setItem("easysub-theme", next);
}

function setRowState(row, state) {
  const status = row.querySelector("[data-status]");
  const use = status.querySelector("use");
  const label = status.querySelector("span");
  row.classList.remove("searching", "done");
  status.classList.remove("pending", "searching", "complete");
  status.querySelector("svg").classList.remove("spin");
  if (state === "searching") {
    row.classList.add("searching"); status.classList.add("searching");
    use.setAttribute("href", "#i-loader"); label.textContent = t("searching");
    status.querySelector("svg").classList.add("spin");
  } else if (state === "complete") {
    row.classList.add("done"); status.classList.add("complete");
    use.setAttribute("href", "#i-check-circle"); label.textContent = t("completed");
  } else {
    status.classList.add("pending"); use.setAttribute("href", "#i-clock"); label.textContent = t("pending");
  }
}

function resetDemo() {
  demoTimers.forEach(clearTimeout); demoTimers = []; demoFinished = false;
  document.querySelectorAll("[data-demo-row]").forEach((row) => setRowState(row, "pending"));
  document.querySelector("[data-count='pending']").textContent = "4";
  document.querySelector("[data-count='completed']").textContent = "1";
  document.querySelector("[data-summary]").textContent = t("videosCount");
  const button = document.getElementById("run-demo");
  button.disabled = false;
  button.querySelector("[data-run-icon]").classList.remove("spin");
  button.querySelector("use").setAttribute("href", "#i-download");
  button.querySelector("[data-run-label]").textContent = t("downloadPending");
}

function runDemo() {
  resetDemo();
  const rows = [...document.querySelectorAll("[data-demo-row]")];
  const button = document.getElementById("run-demo");
  button.disabled = true;
  button.querySelector("use").setAttribute("href", "#i-loader");
  button.querySelector("[data-run-icon]").classList.add("spin");
  button.querySelector("[data-run-label]").textContent = t("searching");
  rows.forEach((row, index) => {
    demoTimers.push(setTimeout(() => setRowState(row, "searching"), index * 420));
    demoTimers.push(setTimeout(() => {
      setRowState(row, "complete");
      const complete = index + 2;
      document.querySelector("[data-count='pending']").textContent = String(rows.length - index - 1);
      document.querySelector("[data-count='completed']").textContent = String(complete);
      if (index === rows.length - 1) {
        demoFinished = true;
        button.querySelector("[data-run-icon]").classList.remove("spin");
        button.querySelector("use").setAttribute("href", "#i-check-circle");
        button.querySelector("[data-run-label]").textContent = t("searchComplete");
        document.querySelector("[data-summary]").textContent = t("videosComplete");
      }
    }, index * 420 + 850));
  });
}

document.querySelector(".language-button").addEventListener("click", () => {
  setLanguage(language === "zh" ? "en" : "zh");
  setTheme(document.documentElement.dataset.theme);
});
document.querySelector(".theme-button").addEventListener("click", () => setTheme(document.documentElement.dataset.theme === "dark" ? "light" : "dark"));
document.getElementById("run-demo").addEventListener("click", runDemo);
document.querySelector(".reset-demo").addEventListener("click", resetDemo);

const menuButton = document.querySelector(".menu-button");
const mobileMenu = document.querySelector(".mobile-menu");
menuButton.addEventListener("click", () => {
  const open = menuButton.getAttribute("aria-expanded") === "true";
  menuButton.setAttribute("aria-expanded", String(!open)); mobileMenu.hidden = open;
});
mobileMenu.querySelectorAll("a").forEach((link) => link.addEventListener("click", () => {
  menuButton.setAttribute("aria-expanded", "false"); mobileMenu.hidden = true;
}));

const observer = new IntersectionObserver((entries) => entries.forEach((entry) => {
  if (entry.isIntersecting) { entry.target.classList.add("visible"); observer.unobserve(entry.target); }
}), { threshold: .1 });
document.querySelectorAll(".reveal").forEach((node) => observer.observe(node));

const savedTheme = localStorage.getItem("easysub-theme");
setTheme(savedTheme || (matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark"));
document.getElementById("year").textContent = new Date().getFullYear();
setLanguage(language);
