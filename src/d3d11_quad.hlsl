Texture2D tex0 : register(t0);
Texture2D tex1 : register(t1);
Texture2D tex2 : register(t2);
Texture2D tex3 : register(t3);
Texture2D tex4 : register(t4);
Texture2D tex5 : register(t5);
Texture2D tex6 : register(t6);
Texture2D tex7 : register(t7);
SamplerState smp0 : register(s0);
cbuffer QuadConstants : register(b0) { float2 viewport; float2 _pad; };

struct VSIn {
  float4 dst : POSITION;
  float4 uvrect : TEXCOORD0;
  float4 color : COLOR0;
  float4 style : TEXCOORD1;
  uint vertex_id : SV_VertexID;
};

struct VSOut {
  float4 pos : SV_Position;
  float2 uv : TEXCOORD0;
  float4 color : COLOR0;
  float4 style : TEXCOORD1;
};

struct PSOut {
  float4 color : SV_Target0;
  float4 coverage : SV_Target1;
};

VSOut vs_main(VSIn input) {
  VSOut output;
  float2 positions[4] = {
    float2(input.dst.x, input.dst.w),
    float2(input.dst.x, input.dst.y),
    float2(input.dst.z, input.dst.w),
    float2(input.dst.z, input.dst.y)
  };
  float2 uvs[4] = {
    float2(input.uvrect.x, input.uvrect.w),
    float2(input.uvrect.x, input.uvrect.y),
    float2(input.uvrect.z, input.uvrect.w),
    float2(input.uvrect.z, input.uvrect.y)
  };
  uint vid = input.vertex_id & 3;
  float2 p = float2(
    (positions[vid].x / viewport.x) * 2.0f - 1.0f,
    1.0f - (positions[vid].y / viewport.y) * 2.0f
  );
  output.pos = float4(p, 0.0f, 1.0f);
  output.uv = uvs[vid];
  output.color = input.color;
  output.style = input.style;
  return output;
}

float4 sample_quad_texture(float slot, float2 uv) {
  if (slot < 0.5f) return tex0.Sample(smp0, uv);
  if (slot < 1.5f) return tex1.Sample(smp0, uv);
  if (slot < 2.5f) return tex2.Sample(smp0, uv);
  if (slot < 3.5f) return tex3.Sample(smp0, uv);
  if (slot < 4.5f) return tex4.Sample(smp0, uv);
  if (slot < 5.5f) return tex5.Sample(smp0, uv);
  if (slot < 6.5f) return tex6.Sample(smp0, uv);
  return tex7.Sample(smp0, uv);
}

PSOut ps_main(VSOut input) {
  PSOut output;
  if (input.style.x > 3.5f) {
    float radius = input.style.y;
    float2 size = input.style.zw;
    float2 centered = input.uv - size * 0.5f;
    float2 q = abs(centered) - (size * 0.5f - radius);
    float distance = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - radius;
    float coverage = 1.0f - smoothstep(-0.75f, 0.75f, distance);
    float a = input.color.a * coverage;
    output.color = float4(input.color.rgb * a, a);
    output.coverage = float4(a, a, a, a);
    return output;
  }
  if (input.style.x > 2.5f) {
    float a = input.color.a;
    output.color = float4(input.color.rgb * a, a);
    output.coverage = float4(a, a, a, a);
    return output;
  }
  float4 s = sample_quad_texture(input.style.y, input.uv);
  if (input.style.x < 0.5f) {
    float a = input.color.a * s.r;
    output.color = float4(input.color.rgb * a, a);
    output.coverage = float4(a, a, a, a);
    return output;
  }
  if (input.style.x < 1.5f) {
    float3 coverage = input.color.a * s.rgb;
    float a = max(coverage.r, max(coverage.g, coverage.b));
    output.color = float4(input.color.rgb * coverage, a);
    output.coverage = float4(coverage, a);
    return output;
  }
  float a = s.a * input.color.a;
  output.color = float4(s.rgb * a, a);
  output.coverage = float4(a, a, a, a);
  return output;
}
