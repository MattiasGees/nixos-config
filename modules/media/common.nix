# Shared foundation for the media stack: the `media` group every service uses
# to read/write the library, and a setgid /srv/media so new files inherit it.
{ ... }:
{
  # Fixed GID so ownership on tank/media (files already on disk) survives
  # reinstalls — the group must always resolve to the same numeric ID.
  users.groups.media = {
    gid = 3000;
  };

  systemd.tmpfiles.rules = [
    "d /srv/media 2775 root media - -"
    # Downloads land on the same tank/media dataset as the library so
    # Sonarr/Radarr imports can hardlink instead of copying.
    "d /srv/media/Downloads 2775 root media - -"
  ];
}
