// Shell composition: one pixel-aligned rect per draw, blended as premultiplied alpha.
Texture2D layer : register(t0);
cbuffer ComposeConstants : register(b0) {
  float4 dst;      // left, top, right, bottom in backbuffer pixels
  float4 src;      // source offset in the layer, in pixels
  float4 color;    // premultiplied fill for solid rects
  float2 viewport;
  float solid;
  float pad;
};

struct VSOut {
  float4 pos : SV_Position;
};

VSOut vs_main(uint id : SV_VertexID) {
  float2 corner = float2(id & 1, id >> 1);
  float2 p = lerp(dst.xy, dst.zw, corner);
  VSOut output;
  output.pos = float4(p.x / viewport.x * 2.0f - 1.0f, 1.0f - p.y / viewport.y * 2.0f, 0.0f, 1.0f);
  return output;
}

float4 ps_main(VSOut input) : SV_Target {
  if (solid > 0.5f) return color;
  int2 texel = int2(input.pos.xy - dst.xy + src.xy);
  return layer.Load(int3(texel, 0));
}
