#version 140

// Background dust mote: a soft point, not a hard disc.
//
// Sharing the crisp disc shader with the star cores made the starfield far too
// heavy - 1500 solid dots read as noise competing with the map. These want the
// same gentle falloff the original texture had; they are backdrop, and being
// slightly soft is correct for them.

in mediump vec2 var_texcoord0;
in mediump vec4 var_color;

out vec4 out_fragColor;

uniform fs_uniforms
{
    mediump vec4 tint;
};

void main()
{
    mediump float r = length(var_texcoord0 * 2.0 - 1.0);
    mediump float falloff = pow(max(0.0, 1.0 - r), 1.6);
    mediump float a = var_color.a * tint.a;
    out_fragColor = vec4(var_color.rgb * tint.rgb * a, a) * falloff;
}
