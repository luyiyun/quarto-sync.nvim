(function () {
  "use strict";

  if (window.__QUARTO_SYNC_ACTIVE__) {
    return;
  }
  window.__QUARTO_SYNC_ACTIVE__ = true;

  const DEFAULT_PORT = 18787;
  const HIGHLIGHT_MS = 900;
  const MANUAL_SCROLL_GRACE_MS = 450;

  const state = {
    current: null,
    highlightTimer: null,
    lastManualScrollAt: 0,
    suppressScrollEvent: false,
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

  function chooseByLine(line) {
    if (!Number.isFinite(line)) {
      return null;
    }

    let best = null;
    let bestLine = -Infinity;
    document.querySelectorAll("[data-qsync-source-line]").forEach((element) => {
      const candidateLine = numberAttr(element, "data-qsync-source-line");
      if (candidateLine !== null && candidateLine <= line && candidateLine >= bestLine) {
        best = element;
        bestLine = candidateLine;
      }
    });
    return best;
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
    return best;
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

    state.suppressScrollEvent = true;
    element.scrollIntoView({ block: "center", behavior: "smooth" });
    highlight(element);
    window.setTimeout(() => {
      state.suppressScrollEvent = false;
    }, 250);
  }

  function handlePayload(payload) {
    const line = Number(payload.line);
    const blockIndex = Number(payload.block_index);
    const target = chooseByLine(line) || chooseByBlockIndex(blockIndex);
    if (target) {
      scrollToElement(target);
    }
  }

  function connect() {
    const port = queryPort();
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

  window.addEventListener(
    "scroll",
    () => {
      if (!state.suppressScrollEvent) {
        state.lastManualScrollAt = Date.now();
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
