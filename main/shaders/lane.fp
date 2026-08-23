#version 140

// Hyperlane: a solid band with a one-pixel antialiased edge. v runs across the
// lane's width (see meshbuild's segment()), so the profile is purely a function
// of distance from the centre line.

in mediump vec2 var_texcoord0;
in mediump vec4 var_color;

out vec4 out_fragColor;

void main()
{
    mediump float d = abs(var_texcoord0.y * 2.0 - 1.0);
    mediump float w = max(fwidth(d), 0.02);
    mediump float mask = 1.0 - smoothstep(1.0 - w, 1.0, d);
    out_fragColor = vec4(var_color.rgb * var_color.a, var_color.a) * mask;
}
