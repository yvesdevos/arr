# arr stack on TrueNAS 25.10

Replaces the individually installed TrueNAS apps (Radarr, Sonarr, Prowlarr,
Plex, Transmission) with one Docker Compose stack managed by the TrueNAS UI,
and adds Seerr, FlareSolverr, Profilarr, Newtarr, Dozzle, and qBittorrent
with qui as the replacement download client.

Existing app configs and all media are kept. Nothing is rebuilt.

```
Seerr ─► Radarr ─┐                                  ┌► qui ─► qBittorrent ─┐
       ► Sonarr ─┴► Prowlarr (+FlareSolverr) ───────┤                      ├─► /mnt/<hdd>/downloads ─► /mnt/<hdd>/media ─► Plex
                 ▲                                  └► Transmission ───────┘
   Profilarr, Newtarr          Dozzle: logs for everything
```

Transmission stays until its torrents have been moved to qBittorrent; see
[Switching to qBittorrent and qui](#8-switching-to-qbittorrent-and-qui).

## Layout

| What | Where |
|---|---|
| Stack files (`docker-compose.yml`, `.env`, `scripts/`) | `/mnt/<SSD_POOL>/apps/arr/` (= `APPS_DATASET`) |
| Per-service config | `/mnt/<SSD_POOL>/apps/arr/<service>/`, one child dataset each |
| Media | `/mnt/<HDD_POOL>/media/` (existing dataset), mounted at `MEDIA_MOUNT` in every container |

All containers run as `PUID:PGID` (default `568:568`, the TrueNAS `apps` user)
and mount the media dataset at the same path, so hardlinks between
`downloads/` and `movies/`/`tv/` work and no permission juggling is needed.

Watchtower is deliberately not included: it fights with TrueNAS's own app
management. Update the stack from the Apps screen instead.

## Prerequisites

- TrueNAS 25.10 with the Apps service running (Apps › Settings › pool chosen).
- Shell access as root (`sudo -i` after SSH, or the web shell).
- Your existing `media` dataset on the HDD pool.

## 1. Get the files onto the NAS

Clone to a temporary spot first. The final home (`/mnt/<SSD_POOL>/apps/arr`)
is a dataset that step 3 creates; it must not exist as a plain folder before
then.

```bash
# on the NAS, as root
git clone <this repo> /root/arr      # or scp -r the repo to /root/arr
cd /root/arr
cp .env.example .env
```

## 2. Fill in `.env`

Open `.env` and set at least:

- `SSD_POOL`, `HDD_POOL`: pool names as shown in the UI.
- `MEDIA_DATASET`: your existing media dataset (default `${HDD_POOL}/media`).
- `MEDIA_SUBDIRS`: the folder names you already use inside it. Match your
  existing ones (`Movies` vs `movies` matters).
- `MEDIA_MOUNT`: **the path your old Radarr/Sonarr root folders start with.**
  Check Radarr › Settings › Media Management › Root Folders. If it says
  `/media/movies`, set `MEDIA_MOUNT=/media`. Matching this means the
  migrated configs work without editing root folders.
- `TZ`, `PUID`/`PGID`.
- `OLD_*_CONFIG`: see step 4.
- Ports if any clash with something else on the NAS.

Then check the rendered result:

```bash
./scripts/validate.sh | less
```

## 3. Create datasets

```bash
sudo ./scripts/create-datasets.sh
```

Creates `APPS_DATASET` and a child dataset per service (`atime=off`,
`lz4`, `recordsize=64K` for SQLite-heavy configs), creates any missing
`MEDIA_SUBDIRS` as folders, and chowns everything to `PUID:PGID`.

Optional, recommended for a media-only dataset:

```bash
sudo ./scripts/create-datasets.sh --tune-media   # atime=off, recordsize=1M on MEDIA_DATASET
```

This only affects blocks written from now on; existing files are untouched.
Skip it if the media dataset also holds lots of small files.

Now move the stack into its dataset and work from there:

```bash
cp -a /root/arr/. /mnt/<SSD_POOL>/apps/arr/
chown -R 568:568 /mnt/<SSD_POOL>/apps/arr
cd /mnt/<SSD_POOL>/apps/arr
```

## 4. Find and copy the old config volumes

Stop every old app in the UI first (Apps › app › Stop). Copying a live
SQLite database gives you a corrupt Radarr/Sonarr.

Find where the old volumes live:

```bash
ls /mnt/.ix-apps/app_mounts/            # one folder per app
ls /mnt/.ix-apps/app_mounts/radarr/     # usually "config"
```

Put those paths in `.env` as `OLD_RADARR_CONFIG` etc. If an app used a
host path instead of an ixVolume, use that path. Then:

```bash
sudo ./scripts/migrate-volumes.sh         # dry run
sudo ./scripts/migrate-volumes.sh --run   # copy + chown
```

The old volumes are not modified. Keep them until step 7.

### After migrating

- **Transmission:** check `/mnt/<APPS_DATASET>/transmission/settings.json`:
  `download-dir` and `incomplete-dir` must be under `MEDIA_MOUNT`
  (e.g. `/data/downloads/complete`). If your old image was not the
  linuxserver one, the file layout may differ; starting fresh here is cheap.
  `rpc-authentication-required` / `rpc-username` are overridden by
  `TRANSMISSION_USER`/`PASS` from `.env` on start.
- **Plex:** nothing to do if the old app was the official or linuxserver
  image. Both keep data under `/config/Library/Application Support/Plex Media Server`.
  Leave `PLEX_CLAIM` empty; the migrated config is already claimed.
  Transcoding uses a RAM tmpfs (`PLEX_TRANSCODE_SIZE`, default 16 GiB)
  mounted at `PLEX_TRANSCODE_MOUNT`. Set `PLEX_TRANSCODE_MOUNT` to the path
  your old app used for transcoding (check Plex › Settings › Transcoder ›
  "Transcoder temporary directory") so the migrated setting still points
  at the tmpfs. The TrueNAS Plex app used `/transcode`, which is the default.
  The iGPU is passed through as `/dev/dri` for QuickSync; after start,
  confirm Plex › Settings › Transcoder › "Use hardware acceleration" is on
  and a transcode shows "(hw)" in the dashboard.
  CPU and memory limits (`PLEX_CPUS`, `PLEX_MEMORY`) match the old app's
  6 CPUs / 24 GiB. The tmpfs is charged against that memory limit, so
  lowering `PLEX_MEMORY` without lowering `PLEX_TRANSCODE_SIZE` brings
  back the OOM crashes on subtitle transcodes.
- **Radarr/Sonarr/Prowlarr:** nothing to do if `MEDIA_MOUNT` matches the
  old root-folder prefix. Otherwise fix root folders in the UI after start
  (Settings › Media Management › Root Folders) and the Transmission download
  client's path mapping.

## 5. Install the stack in the TrueNAS UI

Apps › Discover Apps › ⋮ › **Install via YAML**. Name it `arr`. Paste
exactly this (adjust the pool name):

```yaml
include:
  - path: /mnt/<SSD_POOL>/apps/arr/docker-compose.yml
    env_file: /mnt/<SSD_POOL>/apps/arr/.env
services: {}
```

`services: {}` is required by 25.10 even though it's empty. The `include`
makes Compose load the real file with `.env` applied, so `${VAR}`s resolve
and secrets never sit in the UI. Start/Stop/Update from the Apps screen
work as normal.

After editing `docker-compose.yml` or `.env` on disk, restart the app
(Apps › arr › Stop, Start) to apply. The UI's YAML stub never needs changing.

## 6. Verify and wire up the new services

| Service | URL | What to check |
|---|---|---|
| Dozzle | `http://nas:9999` | All 12 containers green; read any red ones first |
| Radarr | `http://nas:7878` | Movies list intact; System › Status has no path warnings |
| Sonarr | `http://nas:8989` | Same |
| Prowlarr | `http://nas:9696` | Indexers still sync to Radarr/Sonarr. Apps › Radarr: server should be `http://radarr:7878` |
| Transmission | `http://nas:9091` | Download dir shows under `MEDIA_MOUNT`; a test torrent lands in `downloads/` |
| qBittorrent | `http://nas:8080` | Logs in with the password you set in step 8; save path under `DOWNLOADS_MOUNT` |
| qui | `http://nas:7476` | Instance `qbittorrent` shows connected; torrent list matches qBittorrent |
| Plex | `http://nas:32400/web` | Libraries present; Settings › Libraries › paths start with `MEDIA_MOUNT` |

Inside the compose network containers reach each other by name
(`http://radarr:7878`, `http://transmission:9091`, `http://qbittorrent:8080`,
`http://qui:7476`, `http://plex:32400`).
If the old configs used the NAS IP, those still work too.

New services:

- **FlareSolverr:** Prowlarr › Settings › Indexers › + › FlareSolverr,
  host `http://flaresolverr:8191`. Tag indexers that need it.
- **Seerr:** `http://nas:5055`. First-run wizard: sign in with Plex, server
  `http://plex:32400`, then add Radarr (`http://radarr:7878`, API key from
  Radarr › Settings › General) and Sonarr likewise.
- **Profilarr:** `http://nas:6868`. Add Radarr and Sonarr with URL + API key,
  pick a Dictionarry database, sync. This overwrites quality profiles and
  custom formats in the arrs; review what it wants to push before syncing.
- **Newtarr:** `http://nas:9705`. Add Radarr/Sonarr instances with API keys.
  Start with low hourly caps to avoid hammering indexers.

## 7. Clean up

Once everything checks out for a few days:

1. Apps › old app › Delete, for each of the five old apps. Tick "delete
   ixVolumes" to free the space. (Or keep them for a while; they cost
   nothing but disk.)
2. Optionally snapshot `APPS_DATASET` before any future update:
   Data Protection › Periodic Snapshot Tasks, recursive on
   `<SSD_POOL>/apps/arr`, e.g. daily keep 2 weeks. Rolling back a bad
   app update is then a one-click affair.

## 8. Switching to qBittorrent and qui

qBittorrent and qui run next to Transmission so the switch can happen
gradually. qBittorrent cannot read Transmission's state files, so every
torrent has to be re-added, and local ratio/upload totals start from zero.
Trackers count ratio server side, so that loss is cosmetic.

### First start

1. **qBittorrent password.** The image prints a temporary `admin` password
   to its log on every start until you set one: Dozzle › qbittorrent, or
   `docker logs qbittorrent`. Log in at `http://nas:8080`, then Tools ›
   Options › Web UI: set a password, and untick "Enable Host header
   validation" if the UI refuses `nas:8080`.
2. **Paths.** Options › Downloads: default save path
   `DOWNLOADS_MOUNT/complete` (e.g. `/downloads/complete`), keep incomplete
   torrents in `DOWNLOADS_MOUNT/incomplete`. These are the same paths
   Transmission used, so files move between clients without copying.
3. **Peer port.** Options › Connection: the port equals
   `PORT_QBITTORRENT_PEER` (set by the image). Forward it on the router as
   long as both clients run; once Transmission is gone, set
   `PORT_QBITTORRENT_PEER=51413` in `.env` and reuse the existing forward.
4. **qui.** `http://nas:7476`, create the admin user, then Instances › Add:
   name `qbittorrent`, host `http://qbittorrent:8080`, the WebUI user and
   password from step 1.
5. **Proxy keys.** qui › Settings › Client Proxy › Create Client API Key,
   one each for Radarr and Sonarr. Copy the `/proxy/<key>` path; qui shows
   it only once.

### Point the arrs at qui

In Radarr and Sonarr, Settings › Download Clients › + › qBittorrent, with
Show Advanced on:

- Host `qui`, port `7476`, URL Base `/proxy/<key>` for that app.
- Username and password empty; qui authenticates to qBittorrent.
- Category `radarr` / `sonarr`. No remote path mapping: the containers
  share `DOWNLOADS_MOUNT`.

Test, save, and leave the Transmission client enabled until its queue is
empty. New grabs now go to qBittorrent; in-flight Transmission downloads
still import when they finish.

### Move the seeding torrents

Wait until Transmission has no incomplete torrents. Partial files do not
match between the clients (Transmission writes `.part`, qBittorrent
`.!qB`), so anything unfinished would be re-downloaded.

Transmission's config dir has one `.torrent` per torrent under
`/mnt/<APPS_DATASET>/transmission/torrents/`. Each must be added to
qBittorrent with the save path it has in Transmission. Two ways:

- **Script.** [transmission-to-qbittorrent](https://github.com/Mythologyli/transmission-to-qbittorrent)
  reads each torrent's save path over Transmission's RPC and adds it over
  qBittorrent's API. Run it from the NAS with `torrent_dir` set to the host
  path above, both web UIs reachable on the `PORT_*` ports. Try it on a few
  torrents first. With `skip_check` off, qBittorrent rechecks every file,
  which takes hours on a large seeding set; with it on, it trusts the
  paths, so only turn it on once a sample has verified clean.
- **By hand.** If every torrent lives in `downloads/complete`, drag the
  `.torrent` files into qBittorrent with "Skip hash check" ticked and the
  default save path. Torrents in other folders need their path set
  individually.

Then, in qui, confirm the torrents show as seeding, not "missing files",
and that Transmission and qBittorrent are not both seeding the same
torrent for longer than needed: stop Transmission (Dozzle › transmission ›
Stop, or remove its torrents without deleting data).

### Retire Transmission

1. Delete the Transmission download client in Radarr and Sonarr.
2. Remove the `transmission` service from `docker-compose.yml` and
   `scripts/create-datasets.sh`, and `TRANSMISSION_*` / `OLD_TRANSMISSION_*`
   from `.env`. Set `PORT_QBITTORRENT_PEER=51413`.
3. Restart the app. Keep the `transmission` dataset for a few weeks in case
   a torrent needs to be re-added.

## Updating images

Apps › arr › Update pulls `:latest` for every service. To pin a version,
change the tag in `docker-compose.yml` and restart the app.

## Troubleshooting

- **"Permission denied" in a container log:** the config dataset owner
  must be `PUID:PGID`. `chown -R 568:568 /mnt/<APPS_DATASET>/<service>`.
- **Hardlinks not working / imports copy instead of link:** downloads and
  library must be inside the *same* dataset. Check `zfs list` that
  `downloads/` isn't its own dataset.
- **Radarr/Sonarr "path does not exist":** `MEDIA_MOUNT` doesn't match the
  root folder prefix stored in the migrated database. Fix in the UI or
  change `MEDIA_MOUNT` and restart.
- **Port conflict on start:** change the `PORT_*` in `.env`, restart.
- **qBittorrent WebUI "Unauthorized" from qui or the arrs:** the password
  in qui › Instances does not match qBittorrent's. If you never set one,
  it changes on every container start; set it in Tools › Options › Web UI.
- **qui cannot reach qBittorrent:** the instance host must be
  `http://qbittorrent:8080` (container port), not the `PORT_QBITTORRENT`
  host port.
- **Plex transcodes in software despite the iGPU:** check `ls -l /dev/dri`
  on the host shows `renderD128`, and that `docker exec plex ls -l /dev/dri`
  shows the same. The linuxserver image handles group membership; if it
  still fails, add the host's `render` group id to the service with
  `group_add: ["<gid>"]`.
- **Dozzle fails to mount docker.sock:** another custom app already maps
  the socket. Only one app may; drop Dozzle from the other or from here.
- **Something fails to start:** `docker logs <container>` or Dozzle; the
  middleware's own errors are under Apps › arr › Logs.
