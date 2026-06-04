(function () {
  "use strict";

  if (window.__QUARTO_SYNC_ACTIVE__) {
    return;
  }
  window.__QUARTO_SYNC_ACTIVE__ = true;

  const DEFAULT_PORT = 18787;
  const HIGHLIGHT_MS = 900;
  const MANUAL_SCROLL_GRACE_MS = 450;
  const MANUAL_SCROLL_INTENT_MS = 1000;
  const PROGRAMMATIC_SCROLL_QUIET_MS = 250;
  const BROWSER_SCROLL_DEBOUNCE_MS = 120;
  const SCROLL_KEYS = new Set([
    "ArrowDown",
    "ArrowLeft",
    "ArrowRight",
    "ArrowUp",
    "End",
    "Home",
    "PageDown",
    "PageUp",
    " ",
    "Spacebar",
  ]);

  const state = {
    current: null,
    highlightTimer: null,
    lastManualScrollAt: 0,
    lastManualScrollIntentAt: 0,
    pointerDown: false,
    programmaticScrollActive: false,
    programmaticScrollQuietTimer: null,
    scrollTimer: null,
    port: null,
    lastSentLine: null,
  };

  function queryPort() {
    const params = new URLSearchParams(window.location.search);
    const queryValue = params.get("qsyncPort") || params.get("quarto-sync-port");
    const port = Number(queryValue || window.QUARTO_SYNC_PORT || DEFAULT_PORT);
    return Number.isFinite(port) ? port : DEFAULT_PORT;
  }

  function numberAttr(element, name) {
    const value = Number(element.getAttribute(name));
    return Number.isFinite(value) ? value : null;
  }

  function serverBaseUrl() {
    const port = state.port || queryPort();
    return `http://127.0.0.1:${port}`;
  }

  function clearBrowserScrollTimer() {
    if (state.scrollTimer) {
      window.clearTimeout(state.scrollTimer);
      state.scrollTimer = null;
    }
  }

  function finishProgrammaticScroll() {
    state.programmaticScrollActive = false;
    if (state.programmaticScrollQuietTimer) {
      window.clearTimeout(state.programmaticScrollQuietTimer);
      state.programmaticScrollQuietTimer = null;
    }
  }

  function refreshProgrammaticScrollQuietTimer() {
    if (state.programmaticScrollQuietTimer) {
      window.clearTimeout(state.programmaticScrollQuietTimer);
    }
    state.programmaticScrollQuietTimer = window.setTimeout(
      finishProgrammaticScroll,
      PROGRAMMATIC_SCROLL_QUIET_MS
    );
  }

  function beginProgrammaticScroll() {
    state.programmaticScrollActive = true;
    clearBrowserScrollTimer();
    refreshProgrammaticScrollQuietTimer();
  }

  function markManualScrollIntent() {
    state.lastManualScrollIntentAt = Date.now();
  }

  function hasRecentManualScrollIntent(now) {
    return state.pointerDown || now - state.lastManualScrollIntentAt <= MANUAL_SCROLL_INTENT_MS;
  }

  function isEditableTarget(target) {
    if (!(target instanceof Element)) {
      return false;
    }

    return (
      target.isContentEditable ||
      target.closest("input, textarea, select, [contenteditable='true']") !== null
    );
  }

  function findByAttribute(name, value) {
    for (const element of document.querySelectorAll(`[${name}]`)) {
      if (element.getAttribute(name) === value) {
        return element;
      }
    }
    return null;
  }

  function syncContainer(element) {
    if (!element) {
      return null;
    }

    return (
      element.closest(
        ".quarto-float, .cell, [data-qsync-source-index], [data-qsync-source-line], [data-qsync-block-index]"
      ) || element
    );
  }

  function isSourceMarker(element) {
    return element && element.classList && element.classList.contains("qsync-source-marker");
  }

  function isSkippableElement(element) {
    if (!element) {
      return true;
    }

    const tag = element.tagName ? element.tagName.toLowerCase() : "";
    return isSourceMarker(element) || tag === "script" || tag === "style" || tag === "link" || tag === "meta";
  }

  function nextMeaningfulElement(marker) {
    if (!marker) {
      return null;
    }

    let element = marker.nextElementSibling;
    while (element) {
      if (!isSkippableElement(element)) {
        return syncContainer(element);
      }
      element = element.nextElementSibling;
    }

    element = marker.parentElement ? marker.parentElement.nextElementSibling : null;
    while (element) {
      if (!isSkippableElement(element)) {
        return syncContainer(element);
      }
      element = element.nextElementSibling;
    }

    return marker;
  }

  function chooseByAnchor(anchor) {
    if (typeof anchor !== "string" || anchor.length === 0) {
      return null;
    }

    const element =
      document.getElementById(anchor) ||
      findByAttribute("data-label", anchor) ||
      findByAttribute("data-qsync-anchor", anchor);

    return syncContainer(element);
  }

  function chooseByLine(line) {
    if (!Number.isFinite(line)) {
      return null;
    }

    let best = null;
    let bestLine = -Infinity;
    document.querySelectorAll(".qsync-source-marker[data-qsync-source-line]").forEach((element) => {
      const candidateLine = numberAttr(element, "data-qsync-source-line");
      if (candidateLine !== null && candidateLine <= line && candidateLine >= bestLine) {
        best = element;
        bestLine = candidateLine;
      }
    });
    if (best) {
      return nextMeaningfulElement(best);
    }

    best = null;
    bestLine = -Infinity;
    document.querySelectorAll("[data-qsync-source-line]").forEach((element) => {
      if (isSourceMarker(element)) {
        return;
      }

      const candidateLine = numberAttr(element, "data-qsync-source-line");
      if (candidateLine !== null && candidateLine <= line && candidateLine >= bestLine) {
        best = element;
        bestLine = candidateLine;
      }
    });
    return syncContainer(best);
  }

  function chooseBySourceIndex(sourceIndex) {
    if (!Number.isFinite(sourceIndex)) {
      return null;
    }

    let best = null;
    let bestIndex = -Infinity;
    document.querySelectorAll("[data-qsync-source-index]").forEach((element) => {
      const candidateIndex = numberAttr(element, "data-qsync-source-index");
      if (candidateIndex !== null && candidateIndex <= sourceIndex && candidateIndex >= bestIndex) {
        best = element;
        bestIndex = candidateIndex;
      }
    });
    return syncContainer(best);
  }

  function chooseByBlockIndex(blockIndex) {
    if (!Number.isFinite(blockIndex)) {
      return null;
    }

    let best = null;
    let bestIndex = -Infinity;
    document.querySelectorAll("[data-qsync-block-index]").forEach((element) => {
      const candidateIndex = numberAttr(element, "data-qsync-block-index");
      if (candidateIndex !== null && candidateIndex <= blockIndex && candidateIndex >= bestIndex) {
        best = element;
        bestIndex = candidateIndex;
      }
    });
    return syncContainer(best);
  }

  function highlight(element) {
    if (state.current && state.current !== element) {
      state.current.classList.remove("qsync-current");
    }

    state.current = element;
    element.classList.add("qsync-current");

    if (state.highlightTimer) {
      window.clearTimeout(state.highlightTimer);
    }
    state.highlightTimer = window.setTimeout(() => {
      element.classList.remove("qsync-current");
    }, HIGHLIGHT_MS);
  }

  function scrollToElement(element) {
    const now = Date.now();
    if (now - state.lastManualScrollAt < MANUAL_SCROLL_GRACE_MS) {
      return;
    }

    beginProgrammaticScroll();
    element.scrollIntoView({ block: "center", behavior: "smooth" });
    highlight(element);
  }

  function sourceLineForViewport() {
    const markers = Array.from(document.querySelectorAll(".qsync-source-marker[data-qsync-source-line]"));
    if (markers.length === 0) {
      return null;
    }

    const targetTop = Math.max(0, window.innerHeight * 0.35);
    let best = null;
    let bestTop = -Infinity;
    let firstBelow = null;
    let firstBelowTop = Infinity;

    markers.forEach((marker) => {
      const line = numberAttr(marker, "data-qsync-source-line");
      if (line === null) {
        return;
      }

      const top = marker.getBoundingClientRect().top;
      if (top <= targetTop && top >= bestTop) {
        best = { line, top };
        bestTop = top;
      } else if (top > targetTop && top < firstBelowTop) {
        firstBelow = { line, top };
        firstBelowTop = top;
      }
    });

    const selected = best || firstBelow;
    return selected ? selected.line : null;
  }

  function sendBrowserScroll() {
    state.scrollTimer = null;
    const line = sourceLineForViewport();
    if (line === null || line === state.lastSentLine) {
      return;
    }

    state.lastSentLine = line;
    fetch(`${serverBaseUrl()}/scroll`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ type: "scroll", line, manual: true }),
      keepalive: true,
    }).catch(() => {
      // The Neovim sync server may not be running for ordinary rendered HTML.
    });
  }

  function scheduleBrowserScrollSync() {
    if (state.scrollTimer) {
      window.clearTimeout(state.scrollTimer);
    }
    state.scrollTimer = window.setTimeout(sendBrowserScroll, BROWSER_SCROLL_DEBOUNCE_MS);
  }

  function handlePayload(payload) {
    const line = Number(payload.line);
    const sourceIndex = Number(payload.source_index);
    const blockIndex = Number(payload.block_index);
    const target =
      chooseByAnchor(payload.anchor) ||
      chooseByLine(line) ||
      chooseBySourceIndex(sourceIndex) ||
      chooseByBlockIndex(blockIndex);
    if (target) {
      scrollToElement(target);
    }
  }

  function connect() {
    const port = queryPort();
    state.port = port;
    const source = new EventSource(`http://127.0.0.1:${port}/events`);

    const onEvent = (event) => {
      try {
        handlePayload(JSON.parse(event.data));
      } catch (_) {
        // Keep the preview quiet if a partial or unrelated SSE message appears.
      }
    };

    source.addEventListener("cursor", onEvent);
    source.onmessage = onEvent;
  }

  window.addEventListener("wheel", markManualScrollIntent, { passive: true });
  window.addEventListener("touchmove", markManualScrollIntent, { passive: true });
  window.addEventListener(
    "pointerdown",
    () => {
      state.pointerDown = true;
    },
    { passive: true }
  );
  window.addEventListener(
    "pointermove",
    () => {
      if (state.pointerDown) {
        markManualScrollIntent();
      }
    },
    { passive: true }
  );
  window.addEventListener(
    "pointerup",
    () => {
      state.pointerDown = false;
    },
    { passive: true }
  );
  window.addEventListener(
    "pointercancel",
    () => {
      state.pointerDown = false;
    },
    { passive: true }
  );
  window.addEventListener("keydown", (event) => {
    if (SCROLL_KEYS.has(event.key) && !isEditableTarget(event.target)) {
      markManualScrollIntent();
    }
  });

  window.addEventListener(
    "scroll",
    () => {
      if (state.programmaticScrollActive) {
        refreshProgrammaticScrollQuietTimer();
        return;
      }

      const now = Date.now();
      if (!hasRecentManualScrollIntent(now)) {
        clearBrowserScrollTimer();
        return;
      }

      state.lastManualScrollAt = now;
      scheduleBrowserScrollSync();
    },
    { passive: true }
  );

  window.addEventListener(
    "scrollend",
    () => {
      if (state.programmaticScrollActive) {
        finishProgrammaticScroll();
      }
    },
    { passive: true }
  );

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", connect, { once: true });
  } else {
    connect();
  }
})();
