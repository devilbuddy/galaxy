#version 140

// Procedural star halo: an exponential falloff faded to zero at the quad edge.
// Smooth at every zoom level, where the 128px texture this replaces would band
// and soften once magnified.

in mediump vec2 var_texcoord0;
in mediump vec4 var_color;

out vec4 out_fragColor;

void main()
{
    mediump float r = length(var_texcoord0 * 2.0 - 1.0);
    // The second term forces alpha to reach exactly 0 at r = 1, so the quad's
    // square edge never shows.
    mediump float falloff = exp(-r * 3.4) * pow(max(0.0, 1.0 - r), 0.6);
    out_fragColor = vec4(var_color.rgb * var_color.a, var_color.a) * falloff;
}
