#version 140

// Two jobs, one falloff. Browsing a seed, the wash is soft region blobs: wide
// radial falloff, many overlapping per region. In a game it is the political
// map's province FILL: main/territory.lua fans each owned cell into triangles
// whose UVs are pinned to the quad centre, where this falloff evaluates to 1 -
// so the same shader paints them flat, edge to edge. The province's drawn
// border is not here; build_lanes strokes it along the cell edges.

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
