#version 140

in mediump vec2 var_texcoord0;
in mediump vec4 var_color;

out vec4 out_fragColor;

uniform mediump sampler2D tex0;

uniform fs_uniforms
{
    mediump vec4 tint;
};

void main()
{
    // Defold premultiplies texture alpha at build time, so the vertex colour
    // has to be premultiplied here to match. Both the alpha-blended layers
    // (ONE, ONE_MINUS_SRC_ALPHA) and the additive ones (ONE, ONE) expect
    // premultiplied input, so this one line is correct for every layer.
    lowp vec4 texel = texture(tex0, var_texcoord0);
    mediump float a = var_color.a * tint.a;
    out_fragColor = texel * vec4(var_color.rgb * tint.rgb * a, a);
}
