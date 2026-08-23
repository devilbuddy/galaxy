#version 140

// Ownership ring drawn around a controlled system.
//
// Procedural like the rest of the map layers, so it stays sharp at every zoom.
// The ring is an annulus: a signed distance from the circle, thresholded
// against the screen-space derivative so its thickness is crisp rather than
// blurring as the player zooms in.

in mediump vec2 var_texcoord0;
in mediump vec4 var_color;

out vec4 out_fragColor;

// Ring radius and half-thickness, in quad-normalised units.
const mediump float RADIUS = 0.72;
const mediump float THICKNESS = 0.10;

void main()
{
    mediump float r = length(var_texcoord0 * 2.0 - 1.0);
    mediump float d = abs(r - RADIUS);
    mediump float w = max(fwidth(r), 0.004);
    mediump float mask = 1.0 - smoothstep(THICKNESS - w, THICKNESS + w, d);
    mediump float a = var_color.a * mask;
    out_fragColor = vec4(var_color.rgb * a, a);
}
