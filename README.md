# vllm-mlx-siesta

Idle-lifecycle reverse proxy for [vllm-mlx](https://github.com/waybarrios/vllm-mlx) on macOS Apple Silicon.

Keeps your model hot while you're actively using it, naps after a short idle, and frees the memory entirely after a longer idle. Next request either resumes the nap instantly or cold-starts fresh.

## Quick install (one line, macOS)

```sh
curl -fsSL https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta/main/install.sh | bash
```

That will:

1. Install [vllm-mlx](https://github.com/waybarrios/vllm-mlx) if it's not already on PATH.
2. Install `vllm-mlx-siesta` via `uv tool` (or `pipx` if `uv` isn't present; installs `pipx` via Homebrew if neither is).
3. Write `~/.config/vllm-mlx-siesta/config.toml` with sensible defaults (`mlx-community/Qwen2.5-7B-Instruct-4bit`, listen `:8080`, upstream `:8000`, pause after 60s, unload after 600s).
4. Render `~/Library/LaunchAgents/com.axiomantic.vllm-mlx-siesta.plist` and `launchctl load` it, so siesta starts at every login.

After it finishes:

```sh
curl http://127.0.0.1:8080/healthz
```

Add `--no-vllm-mlx` to the one-liner if you want to manage vllm-mlx yourself.

### Pick a different model or ports

```sh
curl -fsSL https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta/main/install.sh | bash -s -- \
  --model mlx-community/Llama-3.3-70B-Instruct-4bit \
  --listen-port 8080 --upstream-port 8000 \
  --pause 60 --idle 600
```

All flags are optional. After install, edit `~/.config/vllm-mlx-siesta/config.toml` to tune further.

### Skip LaunchAgent (install binary + config only)

```sh
curl -fsSL https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta/main/install.sh | bash -s -- --no-launchd
```

### Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta/main/install.sh | bash -s -- --uninstall
```

(Removes the LaunchAgent and the binary; leaves `~/.config/vllm-mlx-siesta/` in place so your settings aren't lost.)

## Why

vllm-mlx gives high throughput on Apple Silicon but stays resident once loaded. On a workstation where you want both fast follow-ups *and* RAM back when you walk away, neither "always on" nor "always cold" is right. Siesta adds two knobs:

- `pause_after_seconds` — after this much idle, send `SIGSTOP`. CPU frees instantly, process lives, wake is `<100ms` via `SIGCONT`. RAM is not freed immediately but macOS may compress inactive pages over time.
- `idle_timeout_seconds` — after this much idle (whether already paused or not), send `SIGTERM`. RAM fully freed. Next request cold-starts a new process (weights usually still in the fs page cache, so this is faster than a fresh boot).

## State machine

```mermaid
stateDiagram-v2
    [*] --> IDLE
    IDLE --> STARTING: request arrives<br/>(ensure_ready)
    STARTING --> READY: health probe OK
    STARTING --> IDLE: probe timeout<br/>or process exit
    READY --> PAUSED: idle ≥ pause_after_seconds<br/>(SIGSTOP)
    READY --> STOPPING: idle ≥ idle_timeout_seconds<br/>(SIGTERM, if pause disabled)
    PAUSED --> READY: request arrives<br/>(SIGCONT, KV preserved)
    PAUSED --> STOPPING: idle ≥ idle_timeout_seconds<br/>(SIGCONT + SIGTERM)
    STOPPING --> IDLE: process exited
```

The idle watcher only acts while `in_flight == 0`, so a streaming request that outlives the idle timer never gets paused or killed.

## How requests flow

```mermaid
flowchart LR
    C[clients] -->|HTTP / OpenAI-compatible| S[siesta<br/>:8080]
    S -->|httpx stream| U[vllm-mlx<br/>:8000]
    S -. spawn / SIGSTOP / SIGCONT / SIGTERM .-> U
```

On each request: `siesta` resolves the current state, spawns or resumes the upstream as needed, increments an in-flight counter, streams the response, then decrements. An asyncio background task checks `now - last_activity` against `pause_after_seconds` and `idle_timeout_seconds` at `idle_check_interval_seconds` granularity.

## Running without the installer

### Install manually

```sh
uv tool install "git+https://github.com/axiomantic/vllm-mlx-siesta"
# or
pipx install "git+https://github.com/axiomantic/vllm-mlx-siesta"
# or, editable dev install:
git clone https://github.com/axiomantic/vllm-mlx-siesta && cd vllm-mlx-siesta && pip install -e .
```

### Run

One-liner with `--model`:

```sh
vllm-mlx-siesta --model mlx-community/Qwen2.5-7B-Instruct-4bit
```

Siesta synthesizes `vllm-mlx serve --model MODEL --host 127.0.0.1 --port 8000`. Add `--listen-port`, `--upstream-port`, `--pause-after-seconds`, `--idle-timeout-seconds` to tune.

With a config file:

```sh
vllm-mlx-siesta --config ~/.config/vllm-mlx-siesta/config.toml
```

Settings resolve in this order: CLI flags > `SIESTA_*` env vars > TOML file > built-in defaults. See [`examples/config.toml`](examples/config.toml) for the full set of options.

Point any OpenAI-compatible client at `http://127.0.0.1:8080/v1/...`.

### LaunchAgent without the installer

```sh
mkdir -p ~/.config/vllm-mlx-siesta
cp examples/config.toml ~/.config/vllm-mlx-siesta/config.toml   # edit as needed
./launchd/install.sh
```

Environment overrides: `SIESTA_BIN`, `CONFIG_PATH`, `LOG_DIR`, `WORKDIR`, `AGENT_PATH`.

## Health

```sh
curl http://127.0.0.1:8080/healthz
```

Returns supervisor state (`idle` / `starting` / `ready` / `paused` / `stopping`), upstream PID, in-flight request count, last-activity timestamp, and start/stop counters.

## Wake-up behavior

- **From `paused`:** the first request sends `SIGCONT` and proceeds. Typically under 100ms. The KV cache is preserved because the process itself never died.
- **From `idle`:** the first request spawns a new vllm-mlx process and blocks on its health probe (`/v1/models` by default). Usually 5–15s on Apple Silicon because MLX mmaps safetensors and macOS's buffer cache keeps the weight bytes resident across the restart — only process init and Metal context setup pay real cost.
- If startup fails (bad command, port conflict, model OOM), the request returns `503` with `Retry-After: 5` so well-behaved clients retry.

## What about the KV cache across a full unload?

Gone. Serializing KV across process exits isn't a standard vllm-mlx path and would cost many GB. That's the explicit tradeoff: use `paused` for fast follow-ups (KV preserved), accept `idle` as a clean slate.

## Scope

v0.1 wraps one upstream process. Multi-model routing (multiple upstreams, switch by requested model name) is a future concern — for now the upstream itself decides whether to serve one or many.

## License

MIT. See [LICENSE](LICENSE).
