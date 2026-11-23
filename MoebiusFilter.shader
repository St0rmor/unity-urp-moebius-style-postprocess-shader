Shader "Custom/MoebiusFilter"
{
    Properties
    {
        [Header(Outlines)]
        _OutlineColor ("Outline Color", Color) = (0.06, 0.05, 0.12, 1)
        _OutlineThickness ("Outline Thickness", Range(0.5, 5)) = 1
        _OutlineStrength ("Outline Strength", Range(0, 1)) = 1
        _DepthThreshold ("Depth Threshold", Range(0.001, 0.5)) = 0.03
        _NormalThreshold ("Normal Threshold", Range(0.001, 1)) = 0.1
        _ColorThreshold ("Color Threshold", Range(0.001, 1)) = 0.15
        _DepthStrength ("Depth Strength", Range(0, 1)) = 1
        _NormalStrength ("Normal Strength", Range(0, 1)) = 1
        _ColorStrength ("Color Strength", Range(0, 1)) = 1

        [Header(Color Adjustment)]
        _Saturation ("Saturation", Range(0, 2)) = 1
    }

    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" }

        Pass
        {
            Name "Moebius Post Process"
            ZTest Always
            ZWrite Off
            Cull Off

            Stencil
            {
                Ref 1
                Comp NotEqual
                Pass Keep
            }

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareDepthTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/DeclareNormalsTexture.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

            CBUFFER_START(UnityPerMaterial)
                float4 _OutlineColor;
                float _OutlineThickness;
                float _OutlineStrength;
                float _DepthThreshold;
                float _NormalThreshold;
                float _ColorThreshold;
                float _DepthStrength;
                float _NormalStrength;
                float _ColorStrength;
                float _Saturation;
            CBUFFER_END

            float3 GetColor(float2 uv)
            {
                return SAMPLE_TEXTURE2D_X(_BlitTexture, sampler_LinearClamp, saturate(uv)).rgb;
            }

            float GetDepth(float2 uv)
            {
                return LinearEyeDepth(SampleSceneDepth(saturate(uv)), _ZBufferParams);
            }

            float3 GetNormal(float2 uv)
            {
                return SampleSceneNormals(saturate(uv));
            }

            float GetLuminance(float3 color)
            {
                return dot(color, float3(0.299, 0.587, 0.114));
            }

            float GetOutline(float2 uv)
            {
                float2 pixel = _OutlineThickness / _ScaledScreenParams.xy;

                float depth[9];
                float3 normal[9];

                float centerDepth = GetDepth(uv);
                int index = 0;

                for (int y = -1; y <= 1; y++)
                {
                    for (int x = -1; x <= 1; x++)
                    {
                        float2 sampleUV = uv + float2(x, y) * pixel;
                        depth[index] = GetDepth(sampleUV);
                        normal[index] = GetNormal(sampleUV);
                        index++;
                    }
                }

                // Depth edges
                float depthX =
                    3 * (depth[2] - depth[0]) +
                    10 * (depth[5] - depth[3]) +
                    3 * (depth[8] - depth[6]);

                float depthY =
                    3 * (depth[6] - depth[0]) +
                    10 * (depth[7] - depth[1]) +
                    3 * (depth[8] - depth[2]);

                float depthGradient = length(float2(depthX, depthY)) / 16.0;
                depthGradient /= max(centerDepth, 1.0);

                float depthEdge = smoothstep(_DepthThreshold, _DepthThreshold * 2.0, depthGradient);

                // Normal edges
                float3 normalX =
                    3 * (normal[2] - normal[0]) +
                    10 * (normal[5] - normal[3]) +
                    3 * (normal[8] - normal[6]);

                float3 normalY =
                    3 * (normal[6] - normal[0]) +
                    10 * (normal[7] - normal[1]) +
                    3 * (normal[8] - normal[2]);

                float normalGradient = sqrt(dot(normalX, normalX) + dot(normalY, normalY)) / 16.0;
                float normalEdge = smoothstep(_NormalThreshold, _NormalThreshold * 2.0, normalGradient);

                // Color edges
                float2 dx = float2(pixel.x, 0);
                float2 dy = float2(0, pixel.y);

                float3 colorR = GetColor(uv + dx);
                float3 colorL = GetColor(uv - dx);
                float3 colorU = GetColor(uv + dy);
                float3 colorD = GetColor(uv - dy);

                float colorGradient =
                    length(colorR - colorL) +
                    length(colorU - colorD);

                float colorEdge = smoothstep(_ColorThreshold, _ColorThreshold * 2.0, colorGradient);

                return saturate(max(
                    depthEdge * _DepthStrength,
                    max(normalEdge * _NormalStrength, colorEdge * _ColorStrength)
                ));
            }

            half4 Frag(Varyings input) : SV_Target
            {
                UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

                float2 uv = input.texcoord;

                float3 color = GetColor(uv);

                // Saturation adjustment
                float lum = GetLuminance(color);
                color = max(lerp(lum.xxx, color, _Saturation), 0.0);

                // Outlines
                float outline = GetOutline(uv);
                color = lerp(color, _OutlineColor.rgb, outline * _OutlineStrength * _OutlineColor.a);

                return half4(color, 1.0);
            }

            ENDHLSL
        }
    }

    Fallback Off
}