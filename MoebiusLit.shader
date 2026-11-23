Shader "Custom/MoebiusLit"
{
    Properties
    {
        [Header(Surface)]
        _BaseMap ("Base Texture", 2D) = "white" {}
        _BaseColor ("Base Color", Color) = (1, 1, 1, 1)

        [Header(Material)]
        _Metallic ("Metallic", Range(0, 1)) = 0
        _Smoothness ("Smoothness", Range(0, 1)) = 0.5

        [Header(Cel Shading)]
        [IntRange] _Bands ("Shadow Bands", Range(2, 8)) = 8
        _ShadowColor ("Shadow Color", Color) = (0, 0, 0, 1)
        _ShadowThreshold ("Shadow Threshold", Range(-0.5, 0.5)) = 0
        _BandSmoothness ("Band Smoothness", Range(0, 0.5)) = 0.01

        [Header(Cel Reflections)]
        [IntRange] _MetallicBands ("Metallic Bands", Range(2, 8)) = 8
        _MetallicBandSmoothness ("Metallic Band Smoothness", Range(0, 0.5)) = 0.01
        _MetallicExposure ("Metallic Exposure", Range(0.1, 5)) = 3
    }

    SubShader
    {
        Tags
        {
            "RenderType" = "Opaque"
            "RenderPipeline" = "UniversalPipeline"
            "Queue" = "Geometry"
        }

        HLSLINCLUDE

        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

        TEXTURE2D(_BaseMap);
        SAMPLER(sampler_BaseMap);

        CBUFFER_START(UnityPerMaterial)
            float4 _BaseMap_ST;
            float4 _BaseColor;
            float4 _ShadowColor;

            float _Metallic;
            float _Smoothness;

            float _Bands;
            float _ShadowThreshold;
            float _BandSmoothness;

            float _MetallicBands;
            float _MetallicBandSmoothness;
            float _MetallicExposure;
        CBUFFER_END

        ENDHLSL

        // ========================================
        // Forward Lighting Pass
        // ========================================

        Pass
        {
            Name "CelShading"
            Tags { "LightMode" = "UniversalForwardOnly" }

            Cull Back
            ZWrite On
            ZTest LEqual

            HLSLPROGRAM

            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.5

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS _MAIN_LIGHT_SHADOWS_CASCADE _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma multi_compile_fragment _ _SHADOWS_SOFT
            #pragma multi_compile_fragment _ _SHADOWS_SOFT_LOW _SHADOWS_SOFT_MEDIUM _SHADOWS_SOFT_HIGH

            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BLENDING
            #pragma multi_compile_fragment _ _REFLECTION_PROBE_BOX_PROJECTION

            #pragma multi_compile _ _ADDITIONAL_LIGHTS
            #pragma multi_compile_fragment _ _ADDITIONAL_LIGHT_SHADOWS
            #pragma multi_compile _ _FORWARD_PLUS
            #pragma multi_compile _ _CLUSTER_LIGHT_LOOP

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
                float2 uv : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 positionWS : TEXCOORD0;
                float3 normalWS : TEXCOORD1;
                float2 uv : TEXCOORD2;
                float4 screenPos : TEXCOORD3;
            };

            Varyings vert(Attributes IN)
            {
                Varyings OUT;

                VertexPositionInputs position = GetVertexPositionInputs(IN.positionOS.xyz);

                OUT.positionCS = position.positionCS;
                OUT.positionWS = position.positionWS;
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                OUT.uv = TRANSFORM_TEX(IN.uv, _BaseMap);
                OUT.screenPos = ComputeScreenPos(position.positionCS);

                return OUT;
            }

            // ========================================
            // Shared Quantization
            // ========================================

            float Quantize(float value, float bands, float softness)
            {
                bands = clamp(round(bands), 2.0, 8.0);
                value = saturate(value);

                float scaled = value * (bands - 1.0);

                float lower = floor(scaled);
                float fraction = frac(scaled);

                if (softness <= 0.0001)
                    return round(scaled) / (bands - 1.0);

                float blend = smoothstep(0.5 - softness, 0.5 + softness, fraction);

                return saturate((lower + blend) / (bands - 1.0));
            }

            // ========================================
            // Reflection Quantization
            // ========================================

            half3 QuantizeReflection(half3 color)
            {
                color = max(color, 0);

                float intensity = max(color.r, max(color.g, color.b));

                if (intensity < 0.00001)
                    return half3(0, 0, 0);

                float reflectionRange = lerp(0.04, 1.0, _Metallic);

                float exposed = intensity * _MetallicExposure / reflectionRange;

                float quantized = Quantize(exposed, _MetallicBands, _MetallicBandSmoothness);

                return color * (quantized / max(exposed, 0.00001));
            }

            // ========================================
            // Fragment Shader
            // ========================================

            void CalculateAdditionalLight(
                Light light,
                BRDFData brdfData,
                float3 normal,
                float3 viewDir,
                inout half3 diffuse,
                inout half3 specular
            )
            {
                float3 lightDir = normalize(light.direction);

                float NdotL = saturate(dot(normal, lightDir));

                float lighting = saturate(dot(normal, lightDir) - _ShadowThreshold);

                lighting *= light.distanceAttenuation;
                lighting *= light.shadowAttenuation;

                float cel = Quantize(lighting, _Bands, _BandSmoothness);

                diffuse += brdfData.diffuse * light.color * cel;

                specular += brdfData.specular
                    * DirectBRDFSpecular(brdfData, normal, lightDir, viewDir)
                    * light.color
                    * NdotL
                    * light.distanceAttenuation
                    * light.shadowAttenuation;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                float3 normal = normalize(IN.normalWS);
                float3 viewDir = GetWorldSpaceNormalizeViewDir(IN.positionWS);

                InputData inputData = (InputData)0;

                inputData.positionWS = IN.positionWS;
                inputData.normalWS = normal;
                inputData.viewDirectionWS = viewDir;
                inputData.normalizedScreenSpaceUV = GetNormalizedScreenSpaceUV(IN.positionCS);

                // Main light shadows
                float4 shadowCoord;

                #if defined(_MAIN_LIGHT_SHADOWS_SCREEN)
                    shadowCoord = IN.screenPos;
                #else
                    shadowCoord = TransformWorldToShadowCoord(IN.positionWS);
                #endif

                Light mainLight = GetMainLight(shadowCoord);

                float3 lightDir = normalize(mainLight.direction);

                half4 baseColor = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv) * _BaseColor;

                // PBR material
                BRDFData brdfData;

                InitializeBRDFData(baseColor.rgb, _Metallic, half3(0, 0, 0), _Smoothness, baseColor.a, brdfData);

                // Main light diffuse
                float NdotL = saturate(dot(normal, lightDir));

                float lighting = saturate(dot(normal, lightDir) - _ShadowThreshold);

                lighting *= mainLight.shadowAttenuation;

                float cel = Quantize(lighting, _Bands, _BandSmoothness);

                half3 shadowColor = brdfData.diffuse * _ShadowColor.rgb;
                half3 lightColor = brdfData.diffuse * mainLight.color;

                half3 diffuse = lerp(shadowColor, lightColor, cel);

                // Main light specular
                half3 specular = brdfData.specular
                    * DirectBRDFSpecular(brdfData, normal, lightDir, viewDir)
                    * mainLight.color
                    * NdotL
                    * mainLight.shadowAttenuation;

                // Additional directional lights in Forward+
                #if USE_FORWARD_PLUS || USE_CLUSTER_LIGHT_LOOP

                    UNITY_LOOP
                    for (uint lightIndex = 0; lightIndex < min(URP_FP_DIRECTIONAL_LIGHTS_COUNT, MAX_VISIBLE_LIGHTS); lightIndex++)
                    {
                        Light light = GetAdditionalLight(lightIndex, IN.positionWS, half4(1, 1, 1, 1));

                        CalculateAdditionalLight(light, brdfData, normal, viewDir, diffuse, specular);
                    }

                #endif

                // Additional point and spot lights
                #if defined(_ADDITIONAL_LIGHTS) || USE_FORWARD_PLUS || USE_CLUSTER_LIGHT_LOOP

                    uint pixelLightCount = GetAdditionalLightsCount();

                    LIGHT_LOOP_BEGIN(pixelLightCount)

                        Light light = GetAdditionalLight(lightIndex, IN.positionWS, half4(1, 1, 1, 1));

                        CalculateAdditionalLight(light, brdfData, normal, viewDir, diffuse, specular);

                    LIGHT_LOOP_END

                #endif

                // Global illumination
                half3 bakedGI = SampleSH(normal);

                half3 indirect = GlobalIllumination(brdfData, bakedGI, 1.0, IN.positionWS, normal, viewDir);

                half3 ambient = bakedGI * brdfData.diffuse;

                half3 environmentReflection = max(indirect - ambient, 0);

                // Quantize all reflections
                half3 reflections = specular + environmentReflection;

                reflections = QuantizeReflection(reflections);

                // Final surface color
                half3 finalColor = diffuse + ambient + reflections;

                return half4(finalColor, baseColor.a);
            }
            ENDHLSL
        }

        // ========================================
        // Shadow Caster Pass
        // ========================================

        Pass
        {
            Name "ShadowCaster"
            Tags { "LightMode" = "ShadowCaster" }

            Cull Back
            ZWrite On
            ZTest LEqual
            ColorMask 0

            HLSLPROGRAM

            #pragma vertex ShadowVert
            #pragma fragment ShadowFrag

            #pragma multi_compile_vertex _ _CASTING_PUNCTUAL_LIGHT_SHADOW

            float3 _LightDirection;
            float3 _LightPosition;

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };

            Varyings ShadowVert(Attributes IN)
            {
                Varyings OUT;

                float3 positionWS = TransformObjectToWorld(IN.positionOS.xyz);
                float3 normalWS = TransformObjectToWorldNormal(IN.normalOS);

                #if defined(_CASTING_PUNCTUAL_LIGHT_SHADOW)
                    float3 lightDirectionWS = normalize(_LightPosition - positionWS);
                #else
                    float3 lightDirectionWS = _LightDirection;
                #endif

                positionWS = ApplyShadowBias(positionWS, normalWS, lightDirectionWS);

                OUT.positionCS = TransformWorldToHClip(positionWS);

                #if UNITY_REVERSED_Z
                    OUT.positionCS.z = min(OUT.positionCS.z, OUT.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #else
                    OUT.positionCS.z = max(OUT.positionCS.z, OUT.positionCS.w * UNITY_NEAR_CLIP_VALUE);
                #endif

                return OUT;
            }

            half4 ShadowFrag(Varyings IN) : SV_Target
            {
                return 0;
            }

            ENDHLSL
        }

        // ========================================
        // Depth Only Pass
        // ========================================

        Pass
        {
            Name "DepthOnly"
            Tags { "LightMode" = "DepthOnly" }

            Cull Back
            ZWrite On
            ColorMask R

            HLSLPROGRAM

            #pragma vertex DepthVert
            #pragma fragment DepthFrag

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
            };

            Varyings DepthVert(Attributes IN)
            {
                Varyings OUT;

                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);

                return OUT;
            }

            half4 DepthFrag(Varyings IN) : SV_Target
            {
                return IN.positionCS.z;
            }

            ENDHLSL
        }

        // ========================================
        // Depth Normals Pass
        // ========================================

        Pass
        {
            Name "DepthNormals"
            Tags { "LightMode" = "DepthNormalsOnly" }

            Cull Back
            ZWrite On

            HLSLPROGRAM

            #pragma vertex DepthNormalsVert
            #pragma fragment DepthNormalsFrag

            #pragma multi_compile_fragment _ _GBUFFER_NORMALS_OCT

            struct Attributes
            {
                float4 positionOS : POSITION;
                float3 normalOS : NORMAL;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float3 normalWS : TEXCOORD0;
            };

            Varyings DepthNormalsVert(Attributes IN)
            {
                Varyings OUT;

                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);

                return OUT;
            }

            half4 DepthNormalsFrag(Varyings IN) : SV_Target
            {
                float3 normalWS = normalize(IN.normalWS);

                #if defined(_GBUFFER_NORMALS_OCT)

                    float2 octNormalWS = PackNormalOctQuadEncode(normalWS);
                    float2 remappedNormal = saturate(octNormalWS * 0.5 + 0.5);
                    half3 packedNormal = PackFloat2To888(remappedNormal);

                    return half4(packedNormal, 0);

                #else

                    return half4(normalWS, 0);

                #endif
            }

            ENDHLSL
        }
    }

    FallBack Off
}