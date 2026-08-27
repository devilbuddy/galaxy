#version 140

// Soft dark disc, drawn under every emoji glyph. On paper it is the shadow
// that makes a glyph read as a sticker sitting on the page rather than
// floating clip art. Replaces the additive star halo, which is meaningless
// on a light ground - and the layer's blend flipped to alpha with it (see
// the render script's ADDITIVE note).

in mediump vec2 var_texcoord0;
in mediump vec4 var_color;

out vec4 out_fragColor;

void main()
{
    mediump float r = length(var_texcoord0 * 2.0 - 1.0);
    mediump float falloff = pow(max(0.0, 1.0 - r), 2.5);
    out_fragColor = vec4(var_color.rgb * var_color.a, var_color.a) * falloff;
}
