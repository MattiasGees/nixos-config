# Rendered by op-secrets; edit this template, not the deployed copy. Keep
# 1Password references and mustache pairs out of comments (op inject scans all).
http:
  port: 80
server:
  sources:
    - path: "/srv/files"
      name: "files"
    # Read-only; folderPath "/" + viewable keeps the large library browsable but
    # excluded from indexing.
    - path: "/srv/media"
      name: "media"
      config:
        readOnly: true
        rules:
          - folderPath: "/"
            viewable: true
    # A dedicated subfolder, not all of /srv/data (which holds private service data).
    - path: "/srv/data/files"
      name: "data"
frontend:
  name: "Polaris Files"
auth:
  # adminPassword is applied on every startup (declarative reset).
  adminUsername: "admin"
  adminPassword: "{{ op://polaris/filebrowser/admin-password }}"
  methods:
    password:
      enabled: true
      signup: false
