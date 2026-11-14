# 0190: the import robot is sized by height

The ticket says 96 pt for the robot on the sheets and up to 120 pt in the ring. The art is portrait (99x120), so these are taken as heights and the width follows the aspect. Generated `ArtImage`/`StarArt` files draw only at display size and are not edited, so each client gets a small hand-written `ScaledArtImage`. The ring size is `min(0.6 * (outer - 2 * stroke), 120)`; the mac ring's stroke is centred on the frame edge, so its outer diameter is the frame side plus 80.
