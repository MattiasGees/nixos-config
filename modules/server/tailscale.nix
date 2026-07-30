# Tailscale — CGNAT-proof mesh VPN. Used to reach polaris (and Plex) at full
# quality from outside the LAN, since port-forwarding isn't possible behind
# CGNAT. Authenticate once after deploy: `sudo tailscale up` (prints a login URL).
{ ... }:
{
  services.tailscale = {
    enable = true;
    # Open the UDP port so peers can make direct (non-relayed) connections —
    # better throughput than falling back to Tailscale's DERP relays.
    openFirewall = true;
  };
}
