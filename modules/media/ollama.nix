# Ollama — local LLM inference on the RTX 3080. Uses the CUDA package variant
# (pkgs.ollama-cuda); the NVIDIA driver + hardware.graphics from
# modules/server/nvidia.nix are already in place, so inference offloads to the
# GPU with no extra host wiring — verify with `nvidia-smi` showing an `ollama`
# process (and VRAM in use) while a prompt runs.
#
# ⚠️ The upstream `services.ollama.acceleration = "cuda"` option was REMOVED from
# the NixOS module: GPU support is now selected purely by the package variant.
# Hence `package = pkgs.ollama-cuda` rather than a config toggle. (CUDA is
# unfree — covered by the flake-wide `allowUnfree = true`, same as the driver.)
#
# Listens on 127.0.0.1:11434 (module defaults) — no firewall hole. The only
# ingress is localhost: Open WebUI (open-webui.nix) for the chat UI, plus any
# tailnet client hitting the OpenAI-compatible API through Caddy. Same posture
# as immich — Caddy is the front door, nothing binds a public interface.
#
# Storage: models live on the `scratch` ZFS pool at /srv/scratch/ollama. They're
# large but freely re-downloadable (`ollama pull`), so scratch — no RAID, and
# NOT swept by restic (modules/server/restic.nix only backs up /srv/data and
# /srv/fast/appdata) — is exactly the right home for them. `modelsDir` defaults
# to ${home}/models, i.e. /srv/scratch/ollama/models.
#
# Static user (user/group = "ollama") instead of the module's default
# DynamicUser: a transient UID drifts across reboots and would leave the
# persistent models dir unwritable. Setting BOTH user and group makes the module
# create the system user/group itself and point its home at /srv/scratch/ollama.
{ pkgs, ... }:
{
  services.ollama = {
    enable = true;
    package = pkgs.ollama-cuda;
    user = "ollama";
    group = "ollama";
    home = "/srv/scratch/ollama";
    # Pre-pull the default general-chat model on startup. Qwen3 8B (~5GB at Q4)
    # fits the 3080's VRAM with headroom and has a toggleable thinking mode
    # (/think, /no_think). Pull more models later with `ollama pull <name>`.
    loadModels = [ "qwen3:8b" ];
  };

  # The scratch pool mounts at boot (boot.zfs.extraPools in hardware/polaris-extra.nix)
  # and systemd-tmpfiles-setup runs after local-fs.target, so this `d` rule lands
  # on the mounted dataset — same non-default-path pattern as immich's
  # /srv/data/immich. The module's ReadWritePaths grants the unit access, but it
  # does not create the directory, so we do it here owned by the ollama user.
  systemd.tmpfiles.rules = [
    "d /srv/scratch/ollama 0700 ollama ollama - -"
  ];

  # Belt-and-suspenders: never start the daemon (WorkingDirectory = home) before
  # the scratch pool is mounted, so it can't silently write models to the empty
  # underlying dir on the root disk. /srv/scratch is the ZFS mountpoint.
  systemd.services.ollama.unitConfig.RequiresMountsFor = "/srv/scratch";
}
