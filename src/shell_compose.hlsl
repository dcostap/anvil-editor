// Shell composition: one pixel-aligned rect per draw, blended as premultiplied alpha.
Texture2D layer : register(t0);
cbuffer ComposeConstants : register(b0) {
  float4 dst;      // left, top, right, bottom in backbuffer pixels
  float4 src;      // source offset in the layer, in pixels
  float4 color;    // premultiplied fill for solid rects and the lens
  float2 viewport;
  float mode;      // 0 layer, 1 solid, 2 opaque layer at `opacity`, 3 lens, 4 pill
  float opacity;
  float4 lens;     // lens: inner corner radius, frame width, glow depth, glow strength
                   // pill: corner radius, glow width around it, unused, glow strength
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

// The Peek lens: a frame along the rect's edges with rounded inner corners, and a glow that fades inward.
float4 lens_color(float2 position) {
  float2 half_size = (dst.zw - dst.xy) * 0.5f;
  float2 p = position - (dst.xy + half_size);
  float radius = lens.x;
  float2 q = abs(p) - (half_size - lens.y) + radius;
  // Signed distance to the inner rounded rect: positive in the frame, negative inside.
  float d = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - radius;
  float frame = saturate(d + 0.5f);
  float depth = saturate(1.0f + d / max(lens.z, 1.0f));
  float glow = lens.w * depth * depth * (1.0f - frame);
  return color * saturate(frame + glow);
}

// The Peek bead: a rounded bar inset by the glow width, with a glow that fades outward.
float4 pill_color(float2 position) {
  float2 half_size = (dst.zw - dst.xy) * 0.5f;
  float2 p = position - (dst.xy + half_size);
  float radius = lens.x;
  float2 q = abs(p) - (half_size - lens.y) + radius;
  // Signed distance to the bar: negative inside it.
  float d = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - radius;
  float fill = saturate(0.5f - d);
  float reach = saturate(1.0f - d / max(lens.y, 1.0f));
  float glow = lens.w * reach * reach * (1.0f - fill);
  return color * saturate(fill + glow);
}

float4 ps_main(VSOut input) : SV_Target {
  if (mode > 3.5f) return pill_color(input.pos.xy);
  if (mode > 2.5f) return lens_color(input.pos.xy);
  if (mode > 0.5f && mode < 1.5f) return color;
  int2 texel = int2(input.pos.xy - dst.xy + src.xy);
  float4 value = layer.Load(int3(texel, 0));
  if (mode > 1.5f) return float4(value.rgb * opacity, opacity);
  return value;
}
