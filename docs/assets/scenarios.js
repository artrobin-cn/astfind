(() => {
  const root = document.querySelector("[data-scenario-explorer]");
  if (!root) return;

  const tablist = root.querySelector('[role="tablist"]');
  const tabs = Array.from(root.querySelectorAll('[role="tab"]'));
  const panels = Array.from(root.querySelectorAll('[role="tabpanel"]'));
  if (!tabs.length || tabs.length !== panels.length) return;

  let current = Math.max(0, tabs.findIndex((tab) => tab.getAttribute("aria-selected") === "true"));

  const layout = window.matchMedia("(max-width: 980px)");
  function syncOrientation() {
    if (tablist) tablist.setAttribute("aria-orientation", layout.matches ? "horizontal" : "vertical");
  }
  syncOrientation();
  if (layout.addEventListener) layout.addEventListener("change", syncOrientation);

  function activate(index, focus) {
    if (index === current || index < 0 || index >= tabs.length) return;
    current = index;

    tabs.forEach((tab, i) => {
      const selected = i === index;
      tab.setAttribute("aria-selected", String(selected));
      tab.tabIndex = selected ? 0 : -1;
      if (selected && focus) tab.focus();
    });

    panels.forEach((panel, i) => {
      if (i === index) {
        panel.hidden = false;
        panel.classList.remove("is-active");
        // 重新触发配图与高亮动画
        void panel.offsetWidth;
        panel.classList.add("is-active");
      } else {
        panel.hidden = true;
        panel.classList.remove("is-active");
      }
    });

    const activeTab = tabs[index];
    if (activeTab.parentElement.scrollWidth > activeTab.parentElement.clientWidth) {
      activeTab.scrollIntoView({ block: "nearest", inline: "nearest" });
    }
  }

  tabs.forEach((tab, i) => {
    tab.addEventListener("click", () => activate(i, false));

    tab.addEventListener("keydown", (event) => {
      let next = null;
      if (event.key === "ArrowRight" || event.key === "ArrowDown") next = (i + 1) % tabs.length;
      if (event.key === "ArrowLeft" || event.key === "ArrowUp") next = (i - 1 + tabs.length) % tabs.length;
      if (event.key === "Home") next = 0;
      if (event.key === "End") next = tabs.length - 1;
      if (next === null) return;
      event.preventDefault();
      if (next === current) return;
      activate(next, true);
    });
  });
})();
