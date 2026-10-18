# Extras: let the GPU sleep when Strata is idle

Strata keeps its model on the card the whole time the container runs; it cannot
unload and keep listening. A Radeon with a model loaded never drops into its
deepest idle state, so the fans and a few watts stay on. These two pieces, used
together, give the card back when nobody is using Strata and bring it back on the
next request:

| | what it does |
|---|---|
| `idle-stop/` | a systemd timer that stops the container after `IDLE_MIN` idle minutes (optionally only inside `WINDOW` hours, e.g. overnight) |
| `wake-proxy/` | a small proxy on the port your clients use; a model request (`POST /v1/...`) while Strata is stopped starts it, waits for the model to load (1-3 min), then answers |

Either works alone. The idle-stop alone means starting Strata by hand
(`docker start strata`); the proxy alone does nothing useful.

Both need `python3`, `curl` and `docker` on the host, and run as root.

## Install

1. Move Strata off the clients' port, so the proxy can take it. In `.env`:

   ```
   STRATA_BIND=127.0.0.1
   STRATA_PORT=18081
   ```

   then `docker compose up -d` to recreate the container on the new port.

2. The proxy (listens on 0.0.0.0:8081 by default):

   ```bash
   sudo install -m 755 wake-proxy/strata-wake-proxy.py /usr/local/sbin/
   sudo install -m 644 wake-proxy/strata-wake-proxy.service /etc/systemd/system/
   # optional settings, e.g. listen on this PC only:
   #   echo STRATA_PROXY_HOST=127.0.0.1 | sudo tee /etc/default/strata-wake-proxy
   sudo systemctl daemon-reload && sudo systemctl enable --now strata-wake-proxy
   ```

3. The idle stop. It reads `/metrics`, which needs the API key:

   ```bash
   grep '^STRATA_API_KEY=' ../.env | cut -d= -f2- | sudo tee /etc/strata-api-key >/dev/null
   sudo chmod 600 /etc/strata-api-key
   sudo install -m 755 idle-stop/strata-idle-stop.sh /usr/local/sbin/
   sudo install -m 644 idle-stop/strata-idle-stop.{service,timer} /etc/systemd/system/
   # optional: only stop overnight, after 45 min idle
   #   printf 'WINDOW=23-9\nIDLE_MIN=45\n' | sudo tee /etc/default/strata-idle-stop
   sudo systemctl daemon-reload && sudo systemctl enable --now strata-idle-stop.timer
   ```

## Check

```bash
sudo /usr/local/sbin/strata-idle-stop.sh --dry-run    # says why it would or would not stop
journalctl -u strata-idle-stop -u strata-wake-proxy -o cat --since today
curl -s http://127.0.0.1:8081/health                  # through the proxy
```

While Strata is stopped, the proxy answers `/health` and dashboard polls with a
503 `"status": "asleep"` and does not start it: only a model request does. A
client's first request after a stop waits for the load, so give clients a
timeout of 5 minutes or more.

## Notes

- `docker compose up -d` and the proxy can race: if a request starts the old
  container while compose is recreating it, compose leaves the new one named
  `<id>_strata`. Stop the proxy (`systemctl stop strata-wake-proxy`) before
  changing the stack, or fix it after with `docker rename <id>_strata strata`.
- `STRATA_BLOCKER=<container>` in `/etc/default/strata-wake-proxy` makes the
  proxy refuse to wake Strata while that container runs, for a PC that shares
  the card with another GPU program. The proxy never stops anything itself.
- Reading the card's sensors (`rocm-smi`, `amdgpu_top`, monitoring dashboards)
  keeps it awake too; stop those polling if the card never sleeps.
