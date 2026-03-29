# Telegram Integration - Deployment Checklist

## Pre-Deployment ✓

- [x] All Python files compile without syntax errors
- [x] All imports resolve correctly
- [x] Backend app initializes (25 routes)
- [x] Telegram endpoint returns correct JSON
- [x] Credentials configured in `telegram_config.json`
- [x] Telethon dependency installed (1.36.0)
- [x] Tests pass 5/5
- [x] Documentation complete

## Deployment Steps

### Phase 1: Initial Setup (First Time Only)

**Goal:** Create Telegram session for automatic authentication

```bash
# 1. Run session initializer
python init_telegram.py

# 2. When prompted, enter OTP code from Telegram
# 3. Wait for "Successfully authenticated" message
# 4. Verify telegram_session file created

# Result: Session file created, ready for sync
```

**Troubleshooting Phase 1:**
- If OTP doesn't arrive: Check Telegram account is accessible
- If "Session not found": Telethon might need new API credentials
- If timeout: Internet connection might be slow

### Phase 2: Backend Testing

**Goal:** Verify sync pipeline includes Telegram fetch

```bash
# 1. Start backend
python run_backend.py

# 2. Monitor console output for:
#    - Backend initialization messages
#    - ✓ Database initialized
#    - ✓ Scheduler (disabled - but that's OK)
#    - ✓ Backend initialized

# 3. Verify API endpoint
#    curl http://localhost:8000/api/sources/telegram
#    Should return 10 channels

# Result: Backend running, Telegram endpoint available
```

**Troubleshooting Phase 2:**
- If port 8000 in use: `lsof -i :8000` to find process
- If database error: Delete `articles_cache.json` and retry
- If Telethon error: Run `python init_telegram.py` again

### Phase 3: Frontend Testing

**Goal:** Verify UI displays Telegram channels and messages

```bash
# 1. Start frontend (in separate terminal)
cd frontend
npm install
npm run dev

# 2. Open http://localhost:3000
# 3. Verify page loads and shows:
#    - "Réseaux Sociaux & Ressources" section below articles
#    - 10 Telegram channel cards in 3-column grid
#    - Each with name, handle, description

# 4. Click "Mise à jour" (Update) button
# 5. Monitor sync logs on right panel:
#    - Should see "[STEP 1a] 🌐 Scraping RSS sources..."
#    - Should see "[STEP 1b] 📱 Fetching Telegram messages..."  ← KEY STEP
#    - Should see message counts for both

# Result: UI displays channels, sync fetches messages
```

**Troubleshooting Phase 3:**
- If channels don't show: Check frontend still has endpoint call
- If no Telegram messages: Session might need re-init
- If sync hangs: Check backend logs for errors

### Phase 4: Full Integration Test

**Goal:** End-to-end verify Telegram messages appear as articles

```bash
# 1. Keep backend and frontend running
# 2. Click "Mise à jour" button multiple times
# 3. Watch article list update
# 4. Look for articles with:
#    - source = Telegram channel name (e.g., "NASA", "ESA")
#    - category = "telegram"
#    - link = https://t.me/...

# 5. Click on Telegram article
# 6. Verify synthesis generated (brown capsule with text)
# 7. Verify events extracted (if any)

# Result: Full pipeline working, messages → articles → enriched
```

**Verification Checklist:**
- [ ] Article count > 0
- [ ] Some articles have source = "NASA", "ESA", etc.
- [ ] Telegram messages have synthesis in brown capsule
- [ ] Click event jumps to article with highlight
- [ ] "Réseaux Sociaux" section shows 10 channels clickable

## Rollback Plan

If Telegram integration causes issues:

```bash
# 1. Revert to RSS-only mode
#    Comment out STEP 1b in backend/main.py (lines ~340-345)

# 2. Or disable Telethon entirely
#    Stop backend, delete telegram_session file
#    Restart backend

# 3. Or keep Telegram but don't initialize session
#    Backend will log "[TELEGRAM] Session not authorized"
#    and continue with RSS only

# No code changes needed - graceful fallback built in
```


## Nginx : Configuration des fichiers uploads (IMPORTANT)

Pour éviter les erreurs d'accès aux images (404), ajoutez ou vérifiez ce bloc dans la configuration nginx (fichier `/etc/nginx/sites-available/orbitalis`), **en haut du bloc `server` HTTPS, avant tout bloc plus général comme `location /`** :

```nginx
location ^~ /uploads/ {
    alias /var/www/orbitalis/uploads/;
    autoindex on;
    add_header Access-Control-Allow-Origin *;
}
```

Ce bloc doit précéder tout bloc `location /` ou autre bloc plus général, sinon il risque d'être ignoré et provoquer des erreurs 404 lors de l'accès aux images.

Pensez à recharger nginx après modification :
```bash
sudo nginx -t
sudo systemctl reload nginx
```

---
## Post-Deployment Monitoring

### Daily Checks

```bash
# Monitor sync logs
tail -f sync_progress.log

# Watch for:
# ✓ "[STEP 1b] 📱 Fetching Telegram messages..."
# ✓ "[OK] Fetched N Telegram messages"
# ✓ No "[TELEGRAM ERROR]" messages
# ✓ "[COMPLETE] ✅ Sync finished"
```

### Weekly Checks

```bash
# Verify Telegram session still valid
python -c "
from backend.services.telegram_service import load_telegram_credentials
creds = load_telegram_credentials()
print(f'✓ Credentials loaded: {creds.get(\"phone\")}')"

# If session expires: Run init_telegram.py again
```

### Metrics to Track

1. **Message Fetch Rate**: Messages/channel (should be 0-5)
2. **Enrichment Success**: Synthesis generated for all articles
3. **Event Extraction**: Observable events found in 30-50% of articles
4. **User Engagement**: Clicks on Telegram articles vs RSS articles

## Security Audit

- [ ] `telegram_config.json` NOT in git (add to .gitignore)
- [ ] `telegram_session` NOT in git
- [ ] API credentials never logged to console/files
- [ ] Session file has restrictive permissions (not world-readable)
- [ ] Credentials only loaded from trusted JSON file

## Secrets & BROADCASTER_KEY (Recommended)

- **Do not commit** production secrets (including `BROADCASTER_KEY`) into the repository.
- Use a secret manager or the hosting platform's protected environment variables (e.g., Azure Key Vault, AWS Secrets Manager, DigitalOcean Secrets, or server's `/etc/environment` with restricted permissions).
- If you must copy a file, transfer it over SSH with restricted permissions and do **not** keep it in the working tree. Example:

```powershell
# Locally: create a one-line .env.production with only secrets
Set-Content -Path .\.env.production -Value "BROADCASTER_KEY=<your-secret>" -Encoding UTF8

# Secure copy to server (example)
scp -i $env:USERPROFILE\.ssh\id_ed25519_deploy .\.env.production root@147.93.94.130:/var/www/orbitalis/.env.production

# On server: copy into place and set strict permissions
ssh -i $env:USERPROFILE\.ssh\id_ed25519_deploy root@147.93.94.130 "cp /var/www/orbitalis/.env.production /var/www/orbitalis/.env && chmod 600 /var/www/orbitalis/.env"

# Remove local temporary file after deploy
Remove-Item .env.production -Force
```

- The deploy script `deploy_orbitalis.ps1` includes an opt-in (`FORCE_COPY_ENV=1`) to upload `.env.production`. Prefer using a secret manager instead and keep this opt-in for exceptional cases only.


## Performance Notes

- **Telegram fetch time**: ~5-10 seconds (depends on network)
- **LLM enrichment time**: ~2-3 seconds per article
- **Total sync time**: ~30-60 seconds (RSS + Telegram combined)
- **Backend memory**: +20-30MB for Telethon client

## Scale Plan (Future)

If adding more channels:

```python
# In backend/services/telegram_service.py
TELEGRAM_CHANNELS = {
    # Add new channels here
    "new_channel": {
        "handle": "@new_channel",
        "name": "New Channel",
        "description": "..."
    }
}
```

Then restart backend - no other changes needed.

## Support Contacts

For issues with:
- **Telethon library**: https://github.com/LonamiWebs/Telethon
- **Telegram API**: https://core.telegram.org
- **OTP issues**: Check Telegram app -> Settings -> Active Sessions
- **Session issues**: Delete `telegram_session` and re-run `init_telegram.py`

## Success Criteria

- [x] Backend compiles without errors
- [x] All 5 tests pass
- [x] Telegram endpoint available
- [ ] Session initialized (run `init_telegram.py`)
- [ ] Sync includes Telegram fetch step
- [ ] Articles display with Telegram source
- [ ] Synthesis generated for Telegram articles
- [ ] Events extracted correctly
- [ ] No console errors during sync

---

**Status:** Ready for Phase 1 (Session Initialization)

**Next command:** `python init_telegram.py`
