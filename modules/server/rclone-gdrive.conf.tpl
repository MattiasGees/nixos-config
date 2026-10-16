[personal]
type = drive
scope = drive.readonly
client_id = {{ op://polaris/gdrive-oauth/client_id }}
client_secret = {{ op://polaris/gdrive-oauth/client_secret }}
token = {{ op://polaris/gdrive-personal/token }}

[work]
type = drive
scope = drive.readonly
client_id = {{ op://polaris/gdrive-oauth/client_id }}
client_secret = {{ op://polaris/gdrive-oauth/client_secret }}
token = {{ op://polaris/gdrive-work/token }}
