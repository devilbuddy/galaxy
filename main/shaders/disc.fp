#version 140

// Procedural antialiased disc, used for star cores and background dust.
//
// A textured sprite is only as sharp as its texture: a 64px disc magnified by a
// deep zoom is visibly soft, which is what made the map feel blurry up close.
// Deriving the shape from the UV instead makes it exact at any zoom, and
// antialiasing against the screen-space derivative keeps the edge exactly one
// pixel wide however large or small the quad ends up.

in mediump vec2 var_texcoord0;
in mediump vec4 var_color;

out vec4 out_fragColor;

void main()
{
    mediump vec2 p = var_texcoord0 * 2.0 - 1.0;
    mediump float r = length(p);

    // Clamped so a disc smaller than a pixel fades out instead of aliasing to
    // nothing, and so the edge never collapses to a hard step.
    mediump float w = max(fwidth(r), 0.0015);
    mediump float mask = 1.0 - smoothstep(1.0 - w, 1.0, r);

    // Premultiplied, to match the blend modes the render script sets.
    out_fragColor = vec4(var_color.rgb * var_color.a, var_color.a) * mask;
}
