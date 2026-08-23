#version 140

// Region territory wash: a very wide, very soft radial falloff. Many of these
// overlap per region and merge into the territory's silhouette, so each one is
// faint by design.

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
    mediump float t = max(0.0, 1.0 - r);
    mediump float falloff = pow(t, 2.1);
    mediump float a = var_color.a * tint.a;
    out_fragColor = vec4(var_color.rgb * a, a) * falloff;
}
