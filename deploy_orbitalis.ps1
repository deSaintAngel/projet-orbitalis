# <# :
# .SYNOPSIS
# Ce script a été réenregistré en UTF-8 sans BOM pour corriger les problèmes d'encodage.
# :>
# ============================================================================
# ORBITALIS - SCRIPT DE DEPLOIEMENT v1.0
# ============================================================================
# Déploie Orbitalis sur Hostinger avec HTTPS
# ============================================================================

# Configuration
$Server = "***.**.**.***"
$User = "root"
$LocalProjectPath = "c:\Users\julien_orbitalis\Documents\projet_orbitalis"
$RemoteBackendPath = "/var/www/orbitalis"
$SSHKeyPath = "$env:USERPROFILE\.ssh\*******************"
$Domain = "orbitalis.fr"

$ItemsToDeploy = @(
    "backend",
    "frontend",
    # .env.production is sensitive and not deployed by default to avoid leaking secrets.
    # To force-copy it, set the environment variable FORCE_COPY_ENV=1 before running this script.
    # Example (PowerShell): $env:FORCE_COPY_ENV = "1"; .\deploy_orbitalis.ps1
    "README.md",
    "constellation_lines.json",
    "constellation_hips.json",
    "filtered_stars.json"
)

# Remove .env.production from the list unless explicitly forced via env var
if ($env:FORCE_COPY_ENV -ne "1") {
    $ItemsToDeploy = $ItemsToDeploy | Where-Object { $_ -ne ".env.production" }
    Write-Status "Note: .env.production will NOT be uploaded (FORCE_COPY_ENV not set)" "WARNING"
} else {
    Write-Status "FORCE_COPY_ENV=1 detected: .env.production will be uploaded" "INFO"
}

$ColorSuccess = "Green"
$ColorError = "Red"
$ColorWarning = "Yellow"
$ColorInfo = "Cyan"

# Functions
function Write-Status {
    param([string]$Message, [string]$Status = "INFO")
    $colors = @{
        "INFO"    = $ColorInfo
        "SUCCESS" = $ColorSuccess
        "ERROR"   = $ColorError
        "WARNING" = $ColorWarning
    }
    $symbols = @{
        "INFO"    = "[*]"
        "SUCCESS" = "[OK]"
        "ERROR"   = "[!!]"
        "WARNING" = "[!]"
    }
    Write-Host "$($symbols[$Status]) $Message" -ForegroundColor $colors[$Status]
}

function Invoke-SSH {
    param([string]$Command)
    # Pass the whole command as a single quoted argument to ssh to preserve shell operators
    return & ssh -i $SSHKeyPath "$User@$Server" "$Command" 2>&1
}

function Invoke-SCP {
    param([string]$Source, [string]$Destination, [bool]$Recursive = $false)
    if ($Recursive) {
        scp -i $SSHKeyPath -r -q "$Source" "$Destination" 2>&1 | Out-Null
    } else {
        scp -i $SSHKeyPath -q "$Source" "$Destination" 2>&1 | Out-Null
    }
}

# ============================================================================
# DÉBUT
# ============================================================================
Write-Host ""
Write-Host "=========================================================" -ForegroundColor $ColorInfo
Write-Host "  ORBITALIS - DEPLOIEMENT v1.0" -ForegroundColor $ColorSuccess
Write-Host "=========================================================" -ForegroundColor $ColorInfo
Write-Host ""
Write-Status "Initialisation..." "INFO"
Write-Host "  Serveur: $Server" -ForegroundColor $ColorInfo
Write-Host "  Domaine: $Domain" -ForegroundColor $ColorInfo
Write-Host "  Projet: $LocalProjectPath" -ForegroundColor $ColorInfo
Write-Host ""

# ============================================================================
# ÉTAPE 1: VÉRIFIER SSH
# ============================================================================
Write-Status "[ETAPE 1] Verification SSH..." "INFO"

if (-not (Test-Path $SSHKeyPath)) {
    Write-Status "Cle SSH non trouvee!" "ERROR"
    exit 1
}

$testConnection = Invoke-SSH "echo 'OK'"
if ($testConnection -ne "OK") {
    Write-Status "Impossible de se connecter au serveur" "ERROR"
    exit 1
}

Write-Status "SSH OK" "SUCCESS"
Write-Host ""

# ============================================================================
# ÉTAPE 1.1: COPIER LA SESSION TELEGRAM (OPTIONNEL)
# ============================================================================
Write-Status "[ETAPE 1.1] Copier session Telegram (optionnel)" "INFO"

$localSession = Join-Path $LocalProjectPath "telegram_session.session"
if (Test-Path $localSession) {
    Write-Host "  Fichier de session local trouvé: $localSession" -ForegroundColor $ColorInfo
    Write-Host "  Upload de la session vers le serveur..." -ForegroundColor $ColorInfo
    Invoke-SCP "$localSession" "${User}@${Server}:/tmp/telegram_session.session" -Recursive $false

    $moveSessionCmd = "mv /tmp/telegram_session.session $RemoteBackendPath/telegram_session.session && chown root:root $RemoteBackendPath/telegram_session.session && chmod 600 $RemoteBackendPath/telegram_session.session && echo SESSION_DEPLOYED || echo SESSION_FAILED"
    $moveResult = Invoke-SSH $moveSessionCmd
    if ($moveResult -like "*SESSION_DEPLOYED*") {
        Write-Status "Session Telegram deployee et securisee" "SUCCESS"
    } else {
        Write-Status "Erreur lors du deploiement de la session (voir sortie)" "WARNING"
        Write-Host $moveResult
    }
} else {
    Write-Host "  Aucun fichier 'telegram_session.session' local trouve - etape optionnelle ignoree" -ForegroundColor $ColorInfo
}

Write-Host ""

# ============================================================================
# ÉTAPE 2: BUILD FRONTEND
# ============================================================================
Write-Status "[ETAPE 2] Build du frontend..." "INFO"

Push-Location "$LocalProjectPath\frontend"
Write-Host "  Installation des dependances npm..." -ForegroundColor $ColorInfo
npm install --silent 2>$null | Out-Null

Write-Host "  Build production..." -ForegroundColor $ColorInfo
npm run build 2>&1 | Out-Null

if ($LASTEXITCODE -eq 0) {
    Write-Status "Frontend builde avec succes" "SUCCESS"

} else {
    Write-Status "Erreur build frontend" "ERROR"
    Pop-Location
    exit 1
}

Pop-Location
Write-Host ""

# ============================================================================
# ÉTAPE 3: VÉRIFIER LE VENV
# ============================================================================
Write-Status "[ETAPE 3] Verification environnement Python..." "INFO"

$checkVenvCmd = '[ -d ' + $RemoteBackendPath + '/venv ] && echo EXISTS || echo MISSING'
$venvStatus = Invoke-SSH $checkVenvCmd

$firstDeploy = $false

if ($venvStatus -like "*MISSING*") {
    Write-Host "  Creation du venv..." -ForegroundColor $ColorWarning
    
    $createVenvCmd = 'mkdir -p ' + $RemoteBackendPath + ' && cd ' + $RemoteBackendPath + ' && python3 -m venv venv && echo CREATED || echo FAILED'
    $result = Invoke-SSH $createVenvCmd
    
    if ($result -like "*CREATED*") {
        Write-Status "Venv cree" "SUCCESS"
        $firstDeploy = $true
    } else {
        Write-Status "Erreur creation venv" "ERROR"
        exit 1
    }
} else {
    Write-Status "Venv existant conserve" "SUCCESS"
}

Write-Host ""

# ============================================================================
# ÉTAPE 4: DÉPLOYER LES FICHIERS
# ============================================================================
Write-Status "[ETAPE 4] Deploiement des fichiers..." "INFO"

$totalItems = $ItemsToDeploy.Count
$currentItem = 0

foreach ($item in $ItemsToDeploy) {
    $currentItem++
    $localItem = Join-Path $LocalProjectPath $item
    if (-not (Test-Path $localItem)) {
        Write-Host "  [$currentItem/$totalItems] [!] $item - NON TROUVE" -ForegroundColor $ColorWarning
        continue
    }
    Write-Host "  [$currentItem/$totalItems] [>>] $item..." -ForegroundColor $ColorInfo -NoNewline
    $isDirectory = (Get-Item $localItem).PSIsContainer
    if ($isDirectory) {
        Invoke-SCP "$localItem" "${User}@${Server}:${RemoteBackendPath}/" -Recursive $true
    } else {
        Invoke-SCP "$localItem" "${User}@${Server}:${RemoteBackendPath}/$item" -Recursive $false
    }
    Write-Host " [OK]" -ForegroundColor $ColorSuccess
}

Write-Status "Fichiers deployes" "SUCCESS"
Write-Host ""

# ============================================================================
# ÉTAPE 4.2: S'assurer que .env existe sur le serveur (copie de .env.production)
# ============================================================================
Write-Status "[ETAPE 4.2] Assurer .env sur le serveur (depuis .env.production)" "INFO"
$copyEnvCmd = "if [ -f ${RemoteBackendPath}/.env.production ]; then cp -f ${RemoteBackendPath}/.env.production ${RemoteBackendPath}/.env && chmod 600 ${RemoteBackendPath}/.env && echo ENV_OK || echo ENV_COPY_FAILED; else echo ENV_MISSING; fi"
$copyEnvResult = Invoke-SSH $copyEnvCmd
Write-Host $copyEnvResult
if ($copyEnvResult -like "*ENV_OK*") {
    Write-Status ".env present et permissions appliquées" "SUCCESS"
} elseif ($copyEnvResult -like "*ENV_MISSING*") {
    Write-Status ".env.production absent sur le serveur (vérifier ItemsToDeploy)" "WARNING"
} else {
    Write-Status "Echec copie .env (voir sortie)" "WARNING"
}
Write-Host ""

# Copie de broadcaster.html dans frontend/dist/ APRÈS le build
Write-Host "  Copie de broadcaster.html dans frontend/dist/broadcast.html..." -ForegroundColor $ColorInfo
$srcBroadcaster = Join-Path $LocalProjectPath "streamorbitalis\public\broadcaster.html"
$dstBroadcaster = Join-Path $LocalProjectPath "frontend\dist\broadcast.html"
if (Test-Path $srcBroadcaster) {
    Copy-Item $srcBroadcaster $dstBroadcaster -Force
    Write-Host "  [OK] broadcaster.html copié dans dist/" -ForegroundColor $ColorSuccess
    # Correction des permissions sur broadcast.html
    $fixPermsCmd = "chmod 644 /var/www/orbitalis/frontend/dist/broadcast.html && chown www-data:www-data /var/www/orbitalis/frontend/dist/broadcast.html && chmod 755 /var/www/orbitalis/frontend/dist"
    Invoke-SSH $fixPermsCmd | Out-Null
    Write-Host "  [OK] Permissions corrigées sur broadcast.html" -ForegroundColor $ColorSuccess
} else {
    Write-Host "  [ERREUR] broadcaster.html source introuvable !" -ForegroundColor $ColorError
}

# Copie explicite de broadcaster.html (streamorbitalis/public)
$localBroadcaster = Join-Path $LocalProjectPath "streamorbitalis\public\broadcaster.html"
if (Test-Path $localBroadcaster) {
    Write-Host "  [EXTRA] Copie de broadcaster.html..." -ForegroundColor $ColorInfo
        # Créer le dossier cible si besoin
        $createDirCmd = "mkdir -p /var/www/orbitalis/streamorbitalis/public"
        Invoke-SSH $createDirCmd | Out-Null
    Invoke-SCP "$localBroadcaster" "${User}@${Server}:/var/www/orbitalis/streamorbitalis/public/broadcaster.html" -Recursive $false
    Write-Host "  [OK] broadcaster.html copié" -ForegroundColor $ColorSuccess
} else {
    Write-Host "  [ERREUR] broadcaster.html local introuvable !" -ForegroundColor $ColorError
}

# Vérification de broadcaster.html sur le serveur
Write-Status "[CHECK] Vérification broadcaster.html sur le serveur..." "INFO"
$checkBroadcasterCmd = "if [ -f /var/www/orbitalis/streamorbitalis/public/broadcaster.html ]; then echo '[OK] broadcaster.html présent :'; ls -lh /var/www/orbitalis/streamorbitalis/public/broadcaster.html; sha256sum /var/www/orbitalis/streamorbitalis/public/broadcaster.html; head -n 10 /var/www/orbitalis/streamorbitalis/public/broadcaster.html; else echo '[ERREUR] broadcaster.html absent !'; fi"
$broadcasterCheckResult = Invoke-SSH $checkBroadcasterCmd
Write-Host $broadcasterCheckResult
Write-Host ""

# ============================================================================
# ÉTAPE 4.1: VERIFIER LE CATALOGUE ASTRO (RAG)
# ============================================================================
Write-Status "[ETAPE 4.1] Verification catalogue astro (RAG)..." "INFO"

$catalogCheckCmd = 'test -f ' + $RemoteBackendPath + '/backend/data/astro_object_catalog.json && test -f ' + $RemoteBackendPath + '/backend/services/astronomy_catalog_service.py && test -f ' + $RemoteBackendPath + '/backend/scripts/update_astro_catalog.py && echo CATALOG_OK || echo CATALOG_MISSING'
$catalogCheckResult = Invoke-SSH $catalogCheckCmd

if ($catalogCheckResult -like "*CATALOG_OK*") {
    Write-Status "Fichiers catalogue astro presents" "SUCCESS"
    $catalogStatsCmd = 'grep -c "\"id\"" ' + $RemoteBackendPath + '/backend/data/astro_object_catalog.json 2>/dev/null | awk ''{print "CATALOG_OBJECTS", $1}'' || echo CATALOG_COUNT_UNKNOWN'
    $catalogStats = Invoke-SSH $catalogStatsCmd
    Write-Host "  $catalogStats" -ForegroundColor $ColorInfo
} else {
    Write-Status "Catalogue astro incomplet sur le serveur" "WARNING"
}

Write-Host ""

Write-Host "  Correction des permissions..." -ForegroundColor $ColorInfo
$permCmd = 'chmod -R 755 ' + $RemoteBackendPath + ' && chown -R www-data:www-data ' + $RemoteBackendPath + '/frontend/dist && echo ''PERMISSIONS_OK'''
$permResult = Invoke-SSH $permCmd
if ($permResult -like "*PERMISSIONS_OK*") {
    Write-Status "Permissions corrigees" "SUCCESS"
}
Write-Host ""

# ============================================================================
# ÉTAPE 5: INSTALLER DÉPENDANCES
# ============================================================================
Write-Status "[ETAPE 5] Installation des dependances..." "INFO"

if ($firstDeploy -eq $true) {
    Write-Host "  Installation initiale (peut prendre 2-3 minutes)..." -ForegroundColor $ColorInfo
    
    $installCmd = 'cd ' + $RemoteBackendPath + ' && . venv/bin/activate && pip install --upgrade pip -q && pip install -r backend/requirements.txt -q && echo INSTALLED || echo FAILED'
    $result = Invoke-SSH $installCmd
    
    if ($result -like "*INSTALLED*") {
        Write-Status "Dependances installees" "SUCCESS"
    } else {
        Write-Status "Erreur installation" "ERROR"
        exit 1
    }
} else {
    Write-Host "  Verification dependances..." -ForegroundColor $ColorInfo
    $installCmd = 'cd ' + $RemoteBackendPath + ' && . venv/bin/activate && pip install -r backend/requirements.txt -q && echo OK || echo FAILED'
    $result = Invoke-SSH $installCmd
    
    if ($result -like "*OK*" -or $result -like "*INSTALLED*") {
        Write-Status "Dependances a jour" "SUCCESS"
    }
}

Write-Host ""

# ============================================================================
# ÉTAPE 6: REDÉMARRER L'APPLICATION
# ============================================================================
Write-Status "[ETAPE 6] Redemarrage de l'application..." "INFO"

Write-Host "  Arret des anciens processus..." -ForegroundColor $ColorInfo
    $killCmd = "pkill -f uvicorn.*main:app.*8001 ; sleep 2 ; lsof -ti:8001 | xargs kill -9 2>/dev/null || true ; echo KILLED"
Invoke-SSH $killCmd | Out-Null
Start-Sleep -Seconds 3

Write-Host "  Demarrage de FastAPI sur port 8001..." -ForegroundColor $ColorInfo
$startCmd = @"
cd $RemoteBackendPath && \
. venv/bin/activate && \
# Charger les variables d'environnement depuis .env si present (inclut BROADCASTER_KEY)
set -a; [ -f .env ] && . .env; set +a && \
nohup uvicorn backend.main:app --host 0.0.0.0 --port 8001 --workers 2 > /var/log/orbitalis-api.log 2>&1 & \
disown
sleep 3
lsof -ti:8001 > /dev/null 2>&1 && echo STARTED || echo STARTING
"@
$result = Invoke-SSH $startCmd
if ($result -like "*STARTED*" -or $result -like "*STARTING*") {
    Write-Status "Application démarrée sur port 8001" "SUCCESS"
} else {
    Write-Host "  Tentative alternative..." -ForegroundColor $ColorWarning
    $altCmd = "pgrep -f uvicorn && echo PROCESS_EXISTS || echo FAILED"
    $altResult = Invoke-SSH $altCmd
    if ($altResult -like "*PROCESS_EXISTS*") {
        Write-Status "Application en cours de démarrage" "SUCCESS"
    } else {
        Write-Status "Erreur démarrage application (vérifier les logs)" "ERROR"
    }
}
Start-Sleep -Seconds 2

# ============================================================================
# ÉTAPE 6.1: VÉRIFICATION TELETHON POST-DEPLOY (OPTIONNEL)
# ============================================================================
Write-Status "[ETAPE 6.1] Verification Telethon (connexion session)" "INFO"
    # Create a small Python script locally, upload it to the server, run it and remove it.
    $pythonScript = @'
from telethon import TelegramClient
import os
def load_env(path):
    d={}
    try:
        with open(path) as f:
            for l in f:
                l=l.strip()
                if not l or l.startswith("#"): continue
                if "=" in l:
                    k,v=l.split("=",1); d[k]=v
    except:
        pass
    return d
env = load_env("/var/www/orbitalis/.env")
api_id = int(env.get("TELEGRAM_API_ID","0"))
api_hash = env.get("TELEGRAM_API_HASH","")
session_path = "/var/www/orbitalis/telegram_session.session"
print("telethon", __import__("telethon").__version__)
print("session_exists", os.path.exists(session_path))
try:
    client = TelegramClient(session_path, api_id, api_hash)
    import asyncio
    async def check():
        await client.connect()
        print("is_user_authorized", await client.is_user_authorized())
        await client.disconnect()
    asyncio.run(check())
except Exception as e:
    print("tele_error", type(e).__name__, e)
'@

    $tmpPy = [System.IO.Path]::GetTempFileName()
    Set-Content -Path $tmpPy -Value $pythonScript -Encoding UTF8
    scp -i $SSHKeyPath -q $tmpPy "${User}@${Server}:/tmp/check_telethon.py" 2>&1 | Out-Null
    Remove-Item $tmpPy

    $remoteCmd = "cd $RemoteBackendPath && . venv/bin/activate && python /tmp/check_telethon.py 2>&1 || true"
    $teleResult = Invoke-SSH $remoteCmd
    # cleanup remote script
    Invoke-SSH "rm -f /tmp/check_telethon.py" | Out-Null
    Write-Host $teleResult

    if ($teleResult -like "*is_user_authorized True*") {
        Write-Status "Telethon: session autorisee" "SUCCESS"
    } else {
        Write-Status "Telethon: session non autorisee ou erreur (voir sortie)" "WARNING"
    }


# ============================================================================
# ÉTAPE 6.5: NETTOYER LES ANCIENNES CONFIGS NGINX
# ============================================================================
Write-Host "  Nettoyage anciennes configs Nginx..." -ForegroundColor $ColorInfo
$cleanCmd = "rm -f /etc/nginx/sites-enabled/orbitalis.fr /etc/nginx/sites-available/orbitalis.fr && echo CLEANED"
$cleanResult = Invoke-SSH $cleanCmd
if ($cleanResult -like "*CLEANED*") {
    Write-Status "Anciennes configs supprimees" "SUCCESS"
}
Write-Host ""

# ============================================================================
# ÉTAPE 7: CONFIGURER NGINX & SSL
# ============================================================================
Write-Status "[ETAPE 7] Configuration Nginx et SSL..." "INFO"

# Créer config Nginx
$nginxConfig = @"
upstream orbitalis_backend {
    server 127.0.0.1:8001;
}

server {
    listen 80;
    server_name orbitalis.fr www.orbitalis.fr;
    
    location /.well-known/acme-challenge/ {
        root /var/www/orbitalis;
    }
    
    location / {
        return 301 https://`$server_name`$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name orbitalis.fr www.orbitalis.fr;
    
    ssl_certificate /etc/letsencrypt/live/orbitalis.fr/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/orbitalis.fr/privkey.pem;
    
    root /var/www/orbitalis/frontend/dist;
    index index.html;

    # Bloc pour servir les fichiers uploads (images, etc.)
    location ^~ /uploads/ {
        alias /var/www/orbitalis/uploads/;
        autoindex on;
        add_header Access-Control-Allow-Origin *;
    }
    
    # API proxy
    location /api/ {
        proxy_pass http://orbitalis_backend;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto `$scheme;
        proxy_redirect off;
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        
        # Disable caching for API
        proxy_no_cache 1;
        proxy_cache_bypass 1;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0, s-maxage=0";
        add_header Pragma "no-cache";
        add_header Expires "0";
        
        # For streaming endpoints (logs, events)
        proxy_buffering off;
        proxy_request_buffering off;
    }
    


    # Diffuseur statique
    location = /broadcast.html {
        try_files /broadcast.html =404;
    }
    location = /broadcast {
        try_files /broadcast.html =404;
    }
    location = /broadcast/ {
        try_files /broadcast.html =404;
    }

    # Frontend SPA
    location / {
        try_files `$uri `$uri/ /index.html;
    }
    
    # Cache statics
    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
    }
}
"@

Write-Host "  Upload config Nginx..." -ForegroundColor $ColorInfo

# Sauvegarder config temporaire
$tempNginxFile = [System.IO.Path]::GetTempFileName()
Set-Content -Path $tempNginxFile -Value $nginxConfig

scp -i $SSHKeyPath -q $tempNginxFile "${User}@${Server}:/etc/nginx/sites-available/orbitalis" 2>&1 | Out-Null
Remove-Item $tempNginxFile

# Activer site
Invoke-SSH "ln -sf /etc/nginx/sites-available/orbitalis /etc/nginx/sites-enabled/ 2>/dev/null ; true" | Out-Null

# Tester config
$nginxTest = Invoke-SSH "nginx -t 2>&1"
if ($nginxTest -like "*successful*" -or $nginxTest -like "*ok*") {
    Write-Status "Config Nginx validee" "SUCCESS"
} else {
    Write-Status "ATTENTION: Config Nginx peut avoir des erreurs" "WARNING"
}

Write-Host "  Installation Certbot et certificat SSL..." -ForegroundColor $ColorInfo

$certbotCmd = "apt-get update -qq && apt-get install -y certbot python3-certbot-nginx -qq && certbot certonly --nginx -d orbitalis.fr -d www.orbitalis.fr --non-interactive --agree-tos --email admin@orbitalis.fr 2>&1 | tail -5"
$certResult = Invoke-SSH $certbotCmd

if ($certResult -like "*obtained*" -or $certResult -like "*certificate*") {
    Write-Status "Certificat SSL installe" "SUCCESS"
} else {
    Write-Status "Certificat SSL en cours (peut prendre quelques secondes)" "INFO"
}

Write-Host "  Redemarrage Nginx..." -ForegroundColor $ColorInfo
Invoke-SSH "systemctl restart nginx 2>&1" | Out-Null
Start-Sleep -Seconds 3

Write-Status "Nginx configure avec HTTPS" "SUCCESS"
Write-Host ""

# ============================================================================
# ÉTAPE 8: VÉRIFICATIONS FINALES
# ============================================================================
Write-Status "[ETAPE 8] Verifications finales..." "INFO"

Write-Host "  Verification API..." -ForegroundColor $ColorInfo
$checkCmd = "sleep 2 ; curl -s http://127.0.0.1:8001/api/transits/iss?latitude=46&longitude=-1&days=5&body=sun&satellite=ISS%20%28ZARYA%29 2>/dev/null | head -c 50 || echo NOT_READY"
$apiCheck = Invoke-SSH $checkCmd

if ($apiCheck -like "*sun*" -or $apiCheck -like "*transits*") {
    Write-Status "API operationnelle" "SUCCESS"
} else {
    Write-Status "API en demarrage (verifier dans 30 secondes)" "INFO"
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor $ColorSuccess
Write-Host "  DEPLOIEMENT TERMINE!" -ForegroundColor $ColorSuccess
Write-Host "=========================================================" -ForegroundColor $ColorSuccess
Write-Host ""
Write-Host "Site: https://orbitalis.fr" -ForegroundColor $ColorSuccess
Write-Host "API: https://orbitalis.fr/api/" -ForegroundColor $ColorSuccess
Write-Host "Logs: ssh root@$Server tail -f /var/log/orbitalis-api.log" -ForegroundColor $ColorInfo
Write-Host ""

# ============================================================================
# ÉTAPE 9: REDÉMARRER LE SERVEUR DE STREAMING (Node.js)
# ============================================================================
Write-Status "[ETAPE 9] Redemarrage du serveur de streaming (Node.js)..." "INFO"

# Tuer l'ancien process (si existe)
$killNodeCmd = "pkill -f streamorbitalis/server/index.js || true"
Invoke-SSH $killNodeCmd | Out-Null
Start-Sleep -Seconds 2

# Redémarrer le serveur Node.js en arrière-plan
$startNodeCmd = @"
cd /var/www/orbitalis/streamorbitalis/server && \
nohup node index.js > /var/log/orbitalis-stream.log 2>&1 & \
disown
sleep 2
pgrep -f streamorbitalis/server/index.js > /dev/null 2>&1 && echo STREAM_STARTED || echo STREAM_START_FAILED
"@
$nodeResult = Invoke-SSH $startNodeCmd
if ($nodeResult -like "*STREAM_STARTED*") {
    Write-Status "Serveur de streaming Node.js redémarré" "SUCCESS"
} else {
    Write-Status "Erreur démarrage serveur Node.js (vérifier logs)" "ERROR"
}
Write-Host ""
