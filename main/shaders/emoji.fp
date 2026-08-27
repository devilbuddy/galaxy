#version 140

// The star layer's emoji glyphs, sampled from /main/assets/emoji/sheet.png.
//
// This is the deliberate exception to the map's procedural-shapes rule: a
// glyph is art, not a shape, so it cannot be derived from the UV. The sheet
// is sized so a glyph never magnifies past ~70% of its 256px cell at maximum
// zoom, and mipmapped (galaxy.texture_profiles) so minification at the widest
// zoom does not shimmer.
//
// Not mesh.fp, although it is nearly the same line: mesh.fp requires a `tint`
// constant the star material would have to declare and nothing would ever
// set - the stars have no zoom fade. The vertex colour is white with fog in
// the alpha, premultiplied here to match the build-time premultiplied texel.

in mediump vec2 var_texcoord0;
in mediump vec4 var_color;

out vec4 out_fragColor;

uniform mediump sampler2D tex0;

void main()
{
    lowp vec4 texel = texture(tex0, var_texcoord0);
    out_fragColor = texel * vec4(var_color.rgb * var_color.a, var_color.a);
}
