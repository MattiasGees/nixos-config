# Filebrowser Quantum config — rendered by op-secrets from op://polaris/filebrowser/*
# at deploy time (do NOT edit the deployed copy under /var/lib/secrets; edit this
# template). Only adminPassword is a secret; everything else is plain config kept
# here so the whole file is one artifact. The container reads it from
# /home/filebrowser/data/config.yaml (FILEBROWSER_CONFIG default in the image).
http:
  port: 80
server:
  # The single managed root. Host /srv/files is bind-mounted to /srv in the
  # container; add more entries here to expose additional scoped folders.
  sources:
    - path: "/srv"
      name: "files"
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
