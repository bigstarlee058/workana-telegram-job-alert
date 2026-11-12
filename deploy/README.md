# Deploy Workana to an Ubuntu VPS

Run the deployment from PowerShell in the repository root. The SSH account must be root. The server needs outbound HTTPS access to Workana, Telegram, PyPI, and the Playwright browser downloads.

1. Set the Telegram token, chat ID, Workana URL, and filters in your local `.env`.
2. Run the deployment script with your VPS address and SSH key.

   ```powershell
   .\deploy\deploy.ps1 -HostName 5.161.98.251 -IdentityFile D:\codebase\freelancer_bot\id_ed25519_wepaser_hetzner
   ```

The script creates a Python environment and installs Chromium and its system dependencies using the [Playwright browser installation commands](https://playwright.dev/python/docs/browsers). It verifies a live Workana fetch and Telegram channel permissions before it starts the service. The bot sends its normal startup message when the service starts. A failed integration check leaves the previous release running.

3. Connect to the VPS and check the running worker.

   ```bash
   systemctl status workana-bot --no-pager
   /opt/workana-bot/current/.venv/bin/python /opt/workana-bot/current/deploy/verify_runtime.py --service
   journalctl -u workana-bot -f
   ```

   Expect an active service, `UnitFileState=enabled`, and a successful startup check. The service starts at boot and restarts after a crash.

4. To change settings, edit `/etc/workana-bot.env` on the VPS and restart the worker.

   ```bash
   systemctl restart workana-bot
   ```

   Redeployment preserves the existing server settings. The script uses the local `.env` only when `/etc/workana-bot.env` is empty or absent.

5. To deploy code changes, rerun the same PowerShell command.

   Each deployment creates a release under `/opt/workana-bot/releases`. `/opt/workana-bot/current` points to the active release. Keep `/var/lib/workana-bot/seen_jobs.json` when you rebuild the server. This file stores the job history across releases. Each process startup still baselines the jobs currently listed, so jobs posted while the worker was stopped do not generate alerts.

6. If the live check reports Cloudflare blocking, configure `WORKANA_PROXY` or the private fetch bridge described in the main [README](../README.md). Rerun deployment after the live fetch works.

   To repeat the integration check without sending a test message, run it as the service account from a release directory.

   ```bash
   runuser -u workana-bot -- env PLAYWRIGHT_BROWSERS_PATH=/opt/workana-bot/browsers /opt/workana-bot/current/.venv/bin/python /opt/workana-bot/current/deploy/verify_runtime.py --live
   ```

7. To stop alerts, stop the service.

   ```bash
   systemctl stop workana-bot
   ```
