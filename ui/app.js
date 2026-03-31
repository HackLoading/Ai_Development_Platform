const el = (id) => document.getElementById(id);

const gatewayUrlInput = el("gatewayUrl");
const apiKeyInput = el("apiKey");
const modelInput = el("model");
const maxTokensInput = el("maxTokens");
const temperatureInput = el("temperature");
const promptInput = el("prompt");
const sendBtn = el("sendBtn");
const clearBtn = el("clearBtn");
const stopBtn = el("stopBtn");
const messagesEl = el("messages");
const statusEl = el("status");
const errorEl = el("error");
const gatewayLabel = el("gatewayLabel");

let abortController = null;
let activeAssistantMessageEl = null;
let isStreaming = false;

function setStatus(text) {
  statusEl.textContent = text;
}

function setError(text) {
  errorEl.textContent = text || "";
}

function addMessage(role, content) {
  const msg = document.createElement("div");
  msg.className = "msg";

  const meta = document.createElement("div");
  meta.className = "meta";
  meta.textContent = role === "user" ? "You" : "Assistant";

  const c = document.createElement("div");
  c.className = "content";
  c.textContent = content || "";

  msg.appendChild(meta);
  msg.appendChild(c);

  messagesEl.appendChild(msg);
  messagesEl.scrollTop = messagesEl.scrollHeight;

  return c;
}

function appendToAssistant(content) {
  if (!activeAssistantMessageEl) return;
  activeAssistantMessageEl.textContent += content;
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

function extractGatewayUrl() {
  return gatewayUrlInput.value.trim().replace(/\/+$/, "");
}

function sseParseLines(text) {
  // We support responses like:
  // data: {json}\n
  // data: [DONE]\n
  // and may get chunked boundaries in the middle.
  return text
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
}

async function sendChat() {
  const gatewayUrl = extractGatewayUrl();
  const apiKey = apiKeyInput.value.trim();
  const model = modelInput.value.trim();
  const max_tokens = Number(maxTokensInput.value);
  const temperature = Number(temperatureInput.value);
  const userPrompt = promptInput.value.trim();

  if (!userPrompt) {
    setError("Prompt is empty.");
    return;
  }

  if (!apiKey) {
    setError("API key is required.");
    return;
  }

  setError("");
  setStatus("Request sent. Streaming...");
  isStreaming = true;

  // Render user message.
  addMessage("user", userPrompt);
  promptInput.value = "";

  // Render assistant message (stream into it).
  activeAssistantMessageEl = addMessage("assistant", "");

  abortController = new AbortController();
  stopBtn.disabled = false;
  sendBtn.disabled = true;

  try {
    const res = await fetch(`${gatewayUrl}/v1/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": apiKey,
      },
      body: JSON.stringify({
        model,
        messages: [
          { role: "system", content: "You are a helpful AI assistant." },
          { role: "user", content: userPrompt },
        ],
        max_tokens,
        temperature,
        stream: true,
      }),
      signal: abortController.signal,
    });

    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`Gateway error: ${res.status}. ${text}`);
    }

    const reader = res.body.getReader();
    const decoder = new TextDecoder("utf-8");

    let buffer = "";
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;

      buffer += decoder.decode(value, { stream: true });

      // Process complete lines.
      const lines = buffer.split("\n");
      buffer = lines.pop() || "";

      for (const rawLine of sseParseLines(lines.join("\n"))) {
        if (!rawLine.startsWith("data:")) continue;
        const dataStr = rawLine.slice("data:".length).trim();

        if (dataStr === "[DONE]") {
          setStatus("Done.");
          stopBtn.disabled = true;
          sendBtn.disabled = false;
          abortController = null;
          return;
        }

        try {
          const data = JSON.parse(dataStr);
          const token = data?.choices?.[0]?.delta?.content;
          if (token) appendToAssistant(token);
        } catch {
          // Ignore non-JSON lines.
        }
      }
    }

    setStatus("Done.");
  } catch (err) {
    if (abortController) {
      setError(`Request aborted: ${err?.message || String(err)}`);
    } else {
      setError(`Error: ${err?.message || String(err)}`);
    }
  } finally {
    sendBtn.disabled = false;
    stopBtn.disabled = true;
    abortController = null;
    isStreaming = false;
  }
}

async function pollGatewayHealth() {
  if (isStreaming) return;
  const gatewayUrl = extractGatewayUrl();
  try {
    const res = await fetch(`${gatewayUrl}/health`);
    if (!res.ok) return;
    const data = await res.json();
    if (data?.gateway === "ok" && String(data?.backend_vllm ?? "").startsWith("ok")) {
      setStatus("Gateway: OK (vLLM reachable).");
      setError("");
    } else {
      setStatus("Gateway: OK, waiting for vLLM...");
    }
  } catch {
    // ignore
  }
}

function wireUi() {
  gatewayLabel.textContent = gatewayUrlInput.value.trim();
  gatewayUrlInput.addEventListener("input", () => {
    gatewayLabel.textContent = gatewayUrlInput.value.trim();
  });

  sendBtn.addEventListener("click", () => sendChat());
  clearBtn.addEventListener("click", () => {
    messagesEl.innerHTML = "";
    setStatus("Ready.");
    setError("");
  });

  stopBtn.addEventListener("click", () => {
    if (abortController) {
      abortController.abort();
    }
  });

  promptInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendChat();
    }
  });

  setInterval(pollGatewayHealth, 5000);
}

wireUi();

