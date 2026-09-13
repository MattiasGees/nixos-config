# Filebrowser Quantum config — rendered by op-secrets from the polaris/filebrowser
# 1Password item at deploy time (do NOT edit the deployed copy under
# /var/lib/secrets; edit this template). Only adminPassword is a secret;
# everything else is plain config kept here so the whole file is one artifact. The
# container reads it from /home/filebrowser/config.yaml (FILEBROWSER_CONFIG, set in
# filebrowser.nix — a sibling of the data-dir volume, not nested inside it).
#
# NOTE: keep 1Password reference literals (the op scheme) and mustache
# placeholder pairs OUT of comments. op inject scans the WHOLE file, not just the
# real reference on adminPassword below, so any stray or partial one fails the
# render (this bit us once with a wildcard ref left in a header comment).
http:
  port: 80
server:
  # Each source is a host dir bind-mounted at the same path in the container (see
  # the volumes list in filebrowser.nix). Add/remove entries in lockstep with those
  # mounts.
  sources:
    # Read-write scratch/upload area (e.g. camera RAWs). Small, so it's indexed.
    - path: "/srv/files"
      name: "files"
    # Existing media library (~176 GB). Read-only (the container UID can't write it
    # anyway) and browsable-but-NOT-indexed: a folderPath "/" + viewable:true rule
    # keeps it navigable while skipping the huge index/thumbnail build on startup.
    - path: "/srv/media"
      name: "media"
      config:
        readOnly: true
        rules:
          - folderPath: "/"
            viewable: true
    # A dedicated writable store on the /srv/data volume. We expose only this
    # subfolder, NOT /srv/data itself — that holds private, unreadable service data
    # (immich library, postgres backups).
    - path: "/srv/data/files"
      name: "data"
frontend:
  name: "Polaris Files"
auth:
  # On startup Filebrowser creates (or resets) this admin from the values below —
  # so the initial password is declarative, sourced from 1Password. Change it in
  # the UI afterwards if you like; a later deploy would reset it back to this.
  adminUsername: "admin"
  adminPassword: "{{ op://polaris/filebrowser/admin-password }}"
  methods:
    password:
      enabled: true
      signup: false
