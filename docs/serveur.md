# Mémo serveur — planif (HP 240 G7, Debian 13)

Même logique que le serveur portfolio : Debian minimale, Tailscale pour l'accès
distant, `ufw` + `fail2ban` + SSH par clé. Deux différences, expliquées plus bas.

---

## 1. Le principe en une image

```
Mon Mac / iPhone  ──── Tailscale ────►  HP 240 G7 (Debian)
   (n'importe où)                          │
                                           ├── planif-db   PostgreSQL 16
                                           └── planif-api  FastAPI + bot Telegram
                                                  │
                            tailscale serve ──► https://planif.<tailnet>.ts.net
```

**Rien n'est exposé sur Internet.** La Freebox n'est pas touchée : ses ports
80/443 restent dirigés vers l'Atom.

### Deux différences avec le serveur portfolio

**Pas de Caddy.** Le portfolio en a besoin pour les certificats Let's Encrypt
d'un domaine public. Ici, `tailscale serve` fournit le HTTPS et un vrai
certificat sur le nom tailnet, en une commande.

**Le serveur compile.** L'Atom ne pouvait rien construire, d'où la
pré-compilation sur GitHub Actions. Le HP a un Pentium Gold et 4 Go : il fait
tourner Docker sans difficulté, et le déploiement se résume à un `git pull`.

---

## 2. Préparer la clé USB (depuis le Mac)

Image *netinst* Debian 13 amd64 — <https://www.debian.org/CD/netinst/>

```bash
diskutil list                          # repérer le disqueN (external, physical)
diskutil unmountDisk /dev/diskN

sudo dd if="$HOME/Downloads/debian-13.6.0-amd64-netinst.iso" \
        of=/dev/rdiskN bs=4m status=progress

diskutil eject /dev/diskN
```

Trois points qui font perdre du temps :

- **`"$HOME"` et non `~`** : zsh ne développe pas le tilde après un `=`, et `dd`
  répond « No such file or directory ».
- **`rdiskN` avec le `r`** : sans lui, compter vingt minutes au lieu de trois.
- Vérifier deux fois le numéro : `dd` écrase sans demander, et `disk0` est le Mac.

Juste après, macOS affiche *« Le disque inséré n'est pas lisible »* — il ne sait
pas lire une partition Linux. Cliquer **Ignorer**, surtout pas **Initialiser**.

---

## 3. BIOS

**Échap** au démarrage, puis **F9** pour choisir la clé.

Deux réglages seulement : USB en premier dans l'ordre de démarrage, et Secure
Boot peut rester activé (Debian 13 est signé).

**Ne pas chercher « After Power Loss »** : absent de la gamme 240. Sur un
portable la batterie tient lieu d'onduleur — une coupure ne réveille même pas
le serveur.

---

## 4. Installation

**Install** (pas la version graphique).

| Écran | Choix |
|---|---|
| Nom de machine | `planif` |
| Domaine | vide |
| Partitionnement | assisté, disque entier, une seule partition |
| Analyse des paquets | Non |

**Dernier écran, le plus important.** Tout décocher sauf :

```
[ ] Environnement de bureau Debian      ← surtout pas
[*] serveur SSH
[*] utilitaires usuels du système
```

---

## 5. L'écran rabattu — le piège du portable

Par défaut, refermer le capot met la machine en veille et le serveur disparaît.

```bash
sudo nano /etc/systemd/logind.conf
```

```ini
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
```

```bash
sudo systemctl restart systemd-logind
```

**Tester avant d'aller plus loin** : refermer, attendre une minute, vérifier que
le `ssh` répond encore.

---

## 6. Réseau

Réservation DHCP dans la Freebox, comme pour l'Atom. Aucune redirection de port
n'est nécessaire — tout passe par Tailscale.

Le **filaire est préférable** : le Wi-Fi d'un portable se rendort parfois.

---

## 7. Tailscale

Installé tôt, contrairement à ce qu'on pourrait croire : c'est par lui que
passe le SSH ensuite.

```bash
sudo apt update && sudo apt install -y curl git
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Suivre le lien affiché pour authentifier la machine, puis :

```bash
tailscale status        # les machines du tailnet
tailscale ip -4         # l'adresse de celle-ci
```

À partir d'ici, se connecter par le nom tailnet plutôt que par l'IP locale :

```bash
ssh thomas@planif
```

---

## 8. Sécurité

Même configuration que l'Atom.

```bash
sudo apt install -y ufw fail2ban

sudo ufw allow in on tailscale0
sudo ufw allow from 192.168.1.0/24 to any port 22
sudo ufw --force enable
sudo ufw status
```

Aucune règle pour 80/443 : rien n'est public.

**SSH par clé uniquement.** Copier la clé depuis le Mac *avant* de couper les
mots de passe, sinon on se ferme la porte :

```bash
# Depuis le Mac
ssh-copy-id thomas@planif
ssh thomas@planif        # doit passer sans mot de passe
```

Puis, sur le serveur :

```bash
sudo nano /etc/ssh/sshd_config
```

```
PasswordAuthentication no
PermitRootLogin no
```

```bash
sudo systemctl restart ssh
```

---

## 9. Docker

```bash
sudo apt install -y ca-certificates
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg \
     -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io \
                    docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
```

Se déconnecter / reconnecter, puis `docker run --rm hello-world`.

---

## 10. Le projet

```bash
git clone https://github.com/docxydre/Projet_Emploie_du_temps.git
cd Projet_Emploie_du_temps
cp .env.example .env
nano .env
```

À renseigner :

```
POSTGRES_PASSWORD=...
PLANIF_CLE_THOMAS=...        # LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 48
PLANIF_CLE_LORETTE=...
TELEGRAM_TOKEN=...
SNCF_TOKEN=...
IMAP_HOTE=imap.gmail.com
IMAP_UTILISATEUR=...
IMAP_MOT_DE_PASSE=...
IMAP_DOSSIER=SNCF
API_BIND=127.0.0.1           # tailscale serve s'occupe de l'exposition
HOTE_PUBLIC=planif.<tailnet>.ts.net
```

`API_BIND=127.0.0.1` et non `0.0.0.0` : le port 8000 n'a pas à être ouvert sur
le réseau, `tailscale serve` le relaie depuis la machine elle-même.

```bash
docker compose up -d
./sql/appliquer.sh

CLE_T=$(grep '^PLANIF_CLE_THOMAS=' .env | cut -d= -f2- | tr -d "\"' ")
CLE_L=$(grep '^PLANIF_CLE_LORETTE=' .env | cut -d= -f2- | tr -d "\"' ")
docker exec -i planif-db psql -U planif -d planif <<SQL
INSERT INTO utilisateur (pseudo, nom, role, cle_api) VALUES
  ('thomas',  'Thomas',  'admin',    '$CLE_T'),
  ('lorette', 'Lorette', 'standard', '$CLE_L');
SQL
docker compose restart api
```

Les conteneurs portent `restart: unless-stopped` : ils repartent seuls au
démarrage, sans service systemd à écrire.

**Les tests ne sont pas dans le dépôt** — le serveur n'en a pas besoin.

---

## 11. HTTPS par Tailscale

L'API n'écoute qu'en `127.0.0.1:8000`. `tailscale serve` place devant elle un
portier qui parle HTTPS sur le tailnet, avec un certificat Let's Encrypt. C'est
le rôle que tient Caddy sur le serveur portfolio, en une commande.

Il faut l'autoriser d'abord dans la console Tailscale, page **DNS**
(<https://login.tailscale.com/admin/dns>) — et non dans Settings :

1. **MagicDNS** → *Enable*
2. **HTTPS Certificates** → *Enable HTTPS*, puis accepter la publication des
   noms de machines dans le registre public des certificats. C'est le
   fonctionnement normal du web ; `planif` ne révèle rien.

Puis :

```bash
sudo tailscale serve --bg 8000
tailscale serve status
```

Le planning devient joignable à `https://planif.<tailnet>.ts.net`, avec un
certificat valide. C'est cette adresse à mettre dans `HOTE_PUBLIC`, et celle
que le bot donnera pour l'abonnement au calendrier.

Le certificat se renouvelle seul, comme celui de Caddy sur l'Atom.

---

## 12. Sauvegarde

```bash
sudo tee /etc/cron.daily/sauvegarde-planif > /dev/null <<'EOF'
#!/bin/sh
DEST=/var/backups/planif
mkdir -p "$DEST"
docker exec planif-db pg_dump -U planif planif \
  | gzip > "$DEST/planif-$(date +%F).sql.gz"
find "$DEST" -name 'planif-*.sql.gz' -mtime +15 -delete
EOF

sudo chmod +x /etc/cron.daily/sauvegarde-planif
sudo /etc/cron.daily/sauvegarde-planif && ls -lh /var/backups/planif
```

Une sauvegarde qui reste sur la même machine ne protège que des erreurs
logicielles, pas d'un disque mort. La recopier ailleurs de temps en temps.

---

## 13. Mise à jour du projet

```bash
ssh thomas@planif
cd Projet_Emploie_du_temps
git pull
./sql/appliquer.sh
docker compose up -d --build api
```

Dans cet ordre : les migrations avant le redémarrage, sinon l'API démarre en
appelant des fonctions qui n'existent pas encore.

Mises à jour système :

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades    # répondre Oui
```

---

## 14. Vérifications avant de fermer l'écran

```bash
curl -s localhost:8000/sante | python3 -m json.tool
```

`"base": "ok"` et **huit tâches** dans `ordonnanceur` : collectes, boîte SNCF,
bilan, week-ends, relance, uniforme, report, et le bot nommé.

Puis, pour de bon :

```bash
sudo reboot
```

Deux minutes plus tard, depuis le Mac :

```bash
curl -s https://planif.<tailnet>.ts.net/sante
```

Si ça répond, c'est en place. Le bilan du matin partira à 7h sans que personne
n'ait à réveiller quoi que ce soit.

---

## 15. Dépannage express

```bash
docker compose ps                    # les deux conteneurs tournent-ils ?
docker compose logs --tail=50 api    # l'API démarre-t-elle ?
docker compose logs --tail=20 db
tailscale status                     # accès distant OK ?
tailscale serve status               # le HTTPS est-il branché ?
sudo ufw status
curl -s localhost:8000/sante         # l'API répond-elle en local ?
```

Toujours vérifier **où** je tape la commande : `docxydre@macbook…` = le Mac,
`thomas@planif` = le serveur.

### Symptômes déjà rencontrés

| Symptôme | Cause probable |
|---|---|
| L'API redémarre en boucle | migrations non appliquées : `./sql/appliquer.sh` |
| Le calendrier ne se rafraîchit plus | Tailscale coupé sur l'iPhone |
| Le bot ne répond pas | `TELEGRAM_TOKEN` absent — l'API tourne quand même, les notifications s'empilent en file |
| `curl` sans réponse après un `up -d` | l'API démarre encore : boucler sur `/sante` |
