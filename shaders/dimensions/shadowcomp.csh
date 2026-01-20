#define RENDER_SHADOWCOMP

layout (local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

#if   LPV_SIZE == 8
    const ivec3 workGroups = ivec3(32, 32, 32);
#elif LPV_SIZE == 7
    const ivec3 workGroups = ivec3(16, 16, 16);
#elif LPV_SIZE == 6
    const ivec3 workGroups = ivec3(8, 8, 8);
#endif

#ifdef IS_LPV_ENABLED
    shared vec4 lpvSharedData[10*10*10];
    shared uint voxelSharedData[10*10*10];

    const vec2 LpvBlockSkyFalloff = vec2(0.96, 0.96);
    const ivec3 lpvFlatten = ivec3(1, 10, 100);

    uniform int frameCounter;
    uniform vec3 cameraPosition;
    uniform vec3 previousCameraPosition;

    #include "/lib/hsv.glsl"
    #include "/lib/util.glsl"
    #include "/lib/blocks.glsl"
    #include "/lib/entities.glsl"
    #include "/lib/lpv_common.glsl"
    #include "/lib/lpv_blocks.glsl"
    #include "/lib/lpv_buffer.glsl"
    #include "/lib/voxel_common.glsl"

    #ifdef BLOCK_LIGHT_SHADOWS
        #define LIGHT_LIST_WRITE
        #include "/lib/light_list.glsl"
    #endif

    int sumOf(ivec3 vec) {return vec.x + vec.y + vec.z;}

    int getSharedIndex(ivec3 pos) {
        return sumOf(pos * lpvFlatten);
    }

    vec4 GetLpvValue(in ivec3 texCoord) {
        if (clamp(texCoord, ivec3(0), ivec3(LpvSize) - 1) != texCoord) return vec4(0.0);

        vec4 lpvSample = (frameCounter % 2) == 0
            ? imageLoad(imgLpv2, texCoord)
            : imageLoad(imgLpv1, texCoord);

        vec4 hsv_sky = vec4(RgbToHsv(lpvSample.rgb), lpvSample.a);
        hsv_sky.zw = exp2(hsv_sky.zw * LpvBlockSkyRange) - 1.0;
        lpvSample = vec4(HsvToRgb(hsv_sky.xyz), hsv_sky.w);

        return lpvSample;
    }
    
    uint GetVoxelBlock(const in ivec3 voxelPos) {
        if (clamp(voxelPos, ivec3(0), ivec3(VoxelSize3-1u)) != voxelPos)
            return BLOCK_EMPTY;

        uint blockId = imageLoad(imgVoxelMask, voxelPos).r;

        blockId = blockId % 2000u;

        #if IRIS_VERSION < 11004
            if (blockId == ENTITY_BOAT || blockId == ENTITY_SMALLSHIPS) return BLOCK_EMPTY;
        #endif
                
        return blockId;
    }

    void PopulateSharedIndex(const in ivec3 imgCoordOffset, const in ivec3 workGroupOffset, const in uint i) {
        ivec3 pos = workGroupOffset + ivec3(i / lpvFlatten) % 10;

        lpvSharedData[i] = GetLpvValue(imgCoordOffset + pos);
        voxelSharedData[i] = GetVoxelBlock(pos);
    }

    vec4 sampleShared(ivec3 pos, int mask_index) {
        int shared_index = getSharedIndex(pos + 1);

        float mixWeight = 1.0;
        uint mask = 0xFFFF;
        uint blockId = voxelSharedData[shared_index];
        
        if (blockId > 0 && blockId != BLOCK_EMPTY) {
            uvec2 blockData = imageLoad(imgBlockData, int(blockId)).rg;
            mask = (blockData.g >> 24) & 0xFFFF;
        }

        return lpvSharedData[shared_index] * ((mask >> mask_index) & 1u);
    }

    vec4 mixNeighbours(const in ivec3 fragCoord, const in uint mask) {
        uvec3 m1 = (uvec3(mask) >> uvec3(0, 2, 4)) & uvec3(1u);
        uvec3 m2 = (uvec3(mask) >> uvec3(1, 3, 5)) & uvec3(1u);

        vec4 sX1 = sampleShared(fragCoord + ivec3(-1,  0,  0), 1) * m1.x;
        vec4 sX2 = sampleShared(fragCoord + ivec3( 1,  0,  0), 0) * m2.x;
        vec4 sY1 = sampleShared(fragCoord + ivec3( 0, -1,  0), 3) * m1.y;
        vec4 sY2 = sampleShared(fragCoord + ivec3( 0,  1,  0), 2) * m2.y;
        vec4 sZ1 = sampleShared(fragCoord + ivec3( 0,  0, -1), 5) * m1.z;
        vec4 sZ2 = sampleShared(fragCoord + ivec3( 0,  0,  1), 4) * m2.z;

        const vec4 avgFalloff = (1.0/6.0) * LpvBlockSkyFalloff.xxxy;
        return (sX1 + sX2 + sY1 + sY2 + sZ1 + sZ2) * avgFalloff;
    }
#endif


////////////////////////////// VOID MAIN //////////////////////////////

void main() {
    #ifdef IS_LPV_ENABLED
        uvec3 chunkPos = gl_WorkGroupID * gl_WorkGroupSize;
        if (any(greaterThanEqual(chunkPos, LpvSize3))) return;

        // Pre-populate shared-memory buffer for improved sampling performance
        uint i = uint(gl_LocalInvocationIndex) * 2u;
        if (i < 1000u) {
            ivec3 imgCoordOffset = ivec3(floor(cameraPosition) - floor(previousCameraPosition));
            ivec3 workGroupOffset = ivec3(gl_WorkGroupID * gl_WorkGroupSize) - 1;

            PopulateSharedIndex(imgCoordOffset, workGroupOffset, i);
            PopulateSharedIndex(imgCoordOffset, workGroupOffset, i + 1u);
        }

        barrier();

        // Reset is done by composite2

        // Exit early if outside LPV buffer size
        ivec3 imgCoord = ivec3(gl_GlobalInvocationID);
        if (any(greaterThanEqual(imgCoord, LpvSize3))) return;

        vec4 lightValue = vec4(0.0);
        vec3 lightColor = vec3(0.0);
        vec3 tintColor = vec3(1.0);
        float lightRange = 0.0;
        uint mixMask = 0xFFFF;
    
        // Decode light data for current voxel
        uint blockId = voxelSharedData[getSharedIndex(ivec3(gl_LocalInvocationID) + 1)];

        if (blockId > 0u) {
            uvec2 blockData = imageLoad(imgBlockData, int(blockId)).rg;
            vec4 lightColorRange = unpackUnorm4x8(blockData.r);
            lightColor = srgbToLinear(lightColorRange.rgb);
            lightRange = lightColorRange.a * 255.0;
            vec4 tintColorMask = unpackUnorm4x8(blockData.g);
            tintColor = srgbToLinear(tintColorMask.rgb);
            mixMask = (blockData.g >> 24) & 0xFFFF;
        }

        // Mix neighbor voxel light values
        if (any(greaterThan(tintColor, vec3(0.0)))) {
            vec4 lightMixed = mixNeighbours(ivec3(gl_LocalInvocationID), mixMask);
            lightMixed.rgb *= tintColor;
            lightValue += lightMixed;
        }

        // Add light for current voxel
        if (lightRange > 0.0) {
            vec3 hsv = RgbToHsv(lightColor);
            hsv.z = exp2(lightRange) - 1.0;
            lightValue.rgb += HsvToRgb(hsv);

            // Add to light list for shadow casting
            #ifdef BLOCK_LIGHT_SHADOWS
                // Check if this is an interior light (all 6 neighbors are same block type)
                // Skip interior lights to avoid filling buffer with large light sources like lava pools
                ivec3 localPos = ivec3(gl_LocalInvocationID) + 1;
                bool isInterior = true;

                uint neighborXN = voxelSharedData[getSharedIndex(localPos + ivec3(-1, 0, 0))];
                uint neighborXP = voxelSharedData[getSharedIndex(localPos + ivec3( 1, 0, 0))];
                uint neighborYN = voxelSharedData[getSharedIndex(localPos + ivec3( 0,-1, 0))];
                uint neighborYP = voxelSharedData[getSharedIndex(localPos + ivec3( 0, 1, 0))];
                uint neighborZN = voxelSharedData[getSharedIndex(localPos + ivec3( 0, 0,-1))];
                uint neighborZP = voxelSharedData[getSharedIndex(localPos + ivec3( 0, 0, 1))];

                // For lava, air on TOP doesn't break interior status (lava pools with air on top stay interior)
                bool isLava = (blockId == BLOCK_LAVA);

                if (neighborXN != blockId) isInterior = false;
                else if (neighborXP != blockId) isInterior = false;
                else if (neighborYN != blockId) isInterior = false;
                else if (neighborYP != blockId && (!isLava || neighborYP != 0u)) isInterior = false;
                else if (neighborZN != blockId) isInterior = false;
                else if (neighborZP != blockId) isInterior = false;

                // Only add edge/surface lights (not fully surrounded by same block)
                if (!isInterior) {
                    // Convert LPV coord to player-relative position (inverse of GetLpvPosition)
                    vec3 cameraOffset = fract(cameraPosition);
                    vec3 lightPlayerPos = vec3(imgCoord) - cameraOffset - vec3(LpvSize3) * 0.5 + 0.5;

                    // Skip lights below Y=32 in Nether (lava ocean)
                    #ifdef IS_NETHER
                        float worldYLimit = cameraPosition.y + lightPlayerPos.y;
                    #else
                        float worldYLimit = 999.0;
                    #endif

                    // Only add lights within range and with light level >= 8
                    float distToCam = length(lightPlayerPos);
                    if (distToCam < float(BLOCK_LIGHT_SHADOWS_FADE_END) + 8.0 && lightRange >= 8.0 && worldYLimit >= 32.0) {
                        // In the last 10% of buffer, prioritize lights that were in previous frame
                        bool shouldAdd = true;
                        if (lightCount >= LIGHT_BUFFER_PRIORITY_THRESHOLD) {
                            shouldAdd = wasLightInPrevFrame(lightPlayerPos);
                        }

                        if (shouldAdd) {
                            int lightId = atomicAdd(lightCount, 1);
                            if (lightId < MAX_BLOCK_LIGHTS_BUFFER) {
                                lights[lightId].position = vec4(lightPlayerPos, lightRange);
                                lights[lightId].color = vec4(lightColor, 1.0);
                            }
                        }
                    }
                }
                memoryBarrierBuffer();
            #endif
        }

        // Convert back to linear RGB space
        vec4 hsv_sky = vec4(RgbToHsv(lightValue.rgb), lightValue.a);
        hsv_sky.zw = log2(hsv_sky.zw + 1.0) / LpvBlockSkyRange;
        lightValue = vec4(HsvToRgb(hsv_sky.xyz), hsv_sky.w);

        // Store final value
        if (frameCounter % 2 == 0)
            imageStore(imgLpv1, imgCoord, lightValue);
        else
            imageStore(imgLpv2, imgCoord, lightValue);
    #endif
}
