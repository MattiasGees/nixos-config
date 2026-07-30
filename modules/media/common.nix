# Shared foundation for the media stack (Plex now; Sonarr/Radarr later).
# Defines the `media` group everything in the stack uses to read/write the
# library, and sets up /srv/media so new files inherit that group.
{ ... }:
{
  # Fixed GID so ownership on tank/media (files already on disk) survives
  # reinstalls — the group must always resolve to the same numeric ID.
  users.groups.media = {
    gid = 3000;
  };

  # root:media, setgid (2775) so files/dirs created under /srv/media inherit
  # the media group regardless of which service account wrote them.
  systemd.tmpfiles.rules = [
    "d /srv/media 2775 root media - -"
  ];
}
