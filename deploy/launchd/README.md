# launchd services

Version-controlled launchd plists for TigerDuck services that run NATIVE on the host (not inside Docker). Currently just llama-server — the backend runs in Docker compose.

## ai.tigerduck.llm

`llama-server` serving `ggml-org/gemma-4-E4B-it-GGUF` on port **40001** for the bulletin classifier. Lives outside Docker because Docker Desktop on Mac can't expose Metal GPU to containers.

### Install (once)

```bash
cd /Users/xinshoutw/selfhost/Docker/tigerduck-app

# Symlink so edits to the repo copy auto-apply on next launchctl kickstart.
ln -sf "$(pwd)/deploy/launchd/ai.tigerduck.llm.plist" \
       ~/Library/LaunchAgents/ai.tigerduck.llm.plist

# Boot it. `bootstrap gui/$UID` registers the service in the user's
# graphical session; survives logout via "KeepAlive".
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/ai.tigerduck.llm.plist

# First launch downloads ~4GB of GGUF weights into the Hugging Face cache
# (~/.cache/huggingface/hub/ by default). Be patient.
tail -f ~/Library/Logs/tigerduck-llm.err.log
```

### Verify

```bash
# Process listening?
lsof -iTCP:40001 -sTCP:LISTEN

# LLM answering?
curl -sS http://localhost:40001/v1/models | jq

# Backend container can reach it via host.docker.internal?
docker exec tigerduck-internal python -c \
  "import urllib.request; print(urllib.request.urlopen('http://host.docker.internal:40001/v1/models', timeout=3).status)"
```

### Tear down

```bash
launchctl bootout gui/$UID ~/Library/LaunchAgents/ai.tigerduck.llm.plist
rm ~/Library/LaunchAgents/ai.tigerduck.llm.plist
```

### After editing the plist

```bash
launchctl kickstart -k gui/$UID/ai.tigerduck.llm
# or if you changed the file structure:
launchctl bootout gui/$UID ~/Library/LaunchAgents/ai.tigerduck.llm.plist
launchctl bootstrap gui/$UID ~/Library/LaunchAgents/ai.tigerduck.llm.plist
```

### Troubleshooting

| Symptom | Check |
|---|---|
| Service flaps / KeepAlive restart loop | `tail -100 ~/Library/Logs/tigerduck-llm.err.log` |
| Container can't reach llama | `docker exec tigerduck-internal curl -sS http://host.docker.internal:40001/v1/models` — if 0 bytes, the `--host 0.0.0.0` line in the plist got edited to `127.0.0.1` |
| High CPU / fan noise | Either --threads is too high for your Mac, or a runaway prompt > `_MAX_BODY_CHARS` is being sent |
