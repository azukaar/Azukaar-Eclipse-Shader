#include "/lib/blocks.glsl"

#if defined MAIN_SHADOW_PASS && defined LPV_HANDHELD_SHADOWS && defined IS_LPV_ENABLED
    float swapperlinZ2(float depth, float _near, float _far) {
        return (2.0 * _near) / (_far + _near - depth * (_far - _near));
    }

    float SSRT_Handlight_Shadows(vec3 viewPos, bool depthCheck, vec3 lightDir, float noise, vec3 normals, bool hand){
        
        if(hand) return 1.0;

        vec3 WlightDir = normalize((gbufferModelViewInverse*vec4(lightDir, 1.0)).xyz);

        float NdotL = dot(normals, WlightDir);
        NdotL = smoothstep(0.0, 0.2, abs(NdotL));

        float shadows = 1.0;
        #if LPV_HANDHELD_SHADOWS_QUALITY == 0
            float samples = 10.0;
            float div = 0.0015;
        #else
            float samples = 20.0;
            float div = 0.0005;
        #endif

        float _near = near; float _far = far*4.0;

        if (depthCheck) {
            _near = dhVoxyNearPlane;
            _far = dhVoxyFarPlane;
        }

        vec3 position = toClipSpace3_DH(viewPos, depthCheck) ;
        
        //prevents the ray from going behind the camera
        float rayLength = ((viewPos.z + lightDir.z * _far * sqrt(3.)) > -_near) ? (-_near - viewPos.z) / lightDir.z : _far * sqrt(3.);

        vec3 direction = toClipSpace3_DH(viewPos + lightDir*rayLength, depthCheck) - position;
        direction.xyz = direction.xyz / max(max(abs(direction.x)/div, abs(direction.y)/div),400.0);	//fixed step size
        direction *= 6.0;

        position.xy *= RENDER_SCALE;
        direction.xy *= RENDER_SCALE;
        
        vec3 newPos = position + direction*noise;
        // literally shadow bias to fight shadow acne due to precision problems when comparing sampled depth and marched position
        //newPos += direction*0.3;


        for (int i = 0; i < int(samples); i++) {
            
            float samplePos;
		
            #if defined DISTANT_HORIZONS || defined VOXY
                if(depthCheck) {
                    samplePos = texelFetch(dhVoxyDepthTex1, ivec2(newPos.xy/texelSize),0).x;
                } else
            #endif
                {
                    samplePos = texelFetch(depthtex2, ivec2(newPos.xy/texelSize),0).x;
                }

            if(samplePos < newPos.z && samplePos > 0.0){// && (samplePos <= max(minZ,maxZ) && samplePos >= min(minZ,maxZ))){
                shadows = 0.0;
                break;
            } 
        
            newPos += direction;
        }

        return clamp(shadows*NdotL, 1.0-LPV_HANDHELD_SHADOWS_STRENGTH, 1.0);
    }
#endif

// Block light shadow tracing - VOXEL SPACE (view-independent)
// Returns vec3 color tint (1.0 = no shadow, 0.0 = full shadow, colored = tinted)
#if defined BLOCK_LIGHT_SHADOWS && defined IS_LPV_ENABLED

    // Noise for jittering AABB bounds (set per-trace)
    float aabbJitter = 0.0;

    // Ray-AABB intersection test
    // rayOrigin/rayDir in voxel space, boxMin/boxMax in local [0,1] space relative to voxelCoord
    bool rayHitsAABB(vec3 rayOrigin, vec3 rayDir, vec3 boxMin, vec3 boxMax, vec3 voxelPos) {
        // Jitter bounds slightly so non-full blocks get temporal blur like full blocks
        float jitter = (aabbJitter - 0.5) * 0.2;
        vec3 worldMin = voxelPos + boxMin + jitter;
        vec3 worldMax = voxelPos + boxMax - jitter;

        vec3 invDir = 1.0 / rayDir;
        vec3 t1 = (worldMin - rayOrigin) * invDir;
        vec3 t2 = (worldMax - rayOrigin) * invDir;

        vec3 tMin = min(t1, t2);
        vec3 tMax = max(t1, t2);

        float tNear = max(max(tMin.x, tMin.y), tMin.z);
        float tFar = min(min(tMax.x, tMax.y), tMax.z);

        return tNear <= tFar && tFar > 0.0;
    }

    // Test if ray intersects the actual block shape (not just the voxel cube)
    // Returns true if ray is occluded by block geometry
    bool testBlockShape(uint blockId, vec3 rayOrigin, vec3 rayDir, vec3 voxelPos) {

        // === FENCES / IRON BARS (block.51, block.52 in block.properties) ===
        // These use BLOCK_LPV_MIN/MED IDs for LPV occlusion, but we need shape testing for shadows
        // Fence: center post 4x16x4 pixels (0.25 x 1.5 x 0.25, extends above block)
        if (blockId == BLOCK_LPV_MIN) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.375, 0.0, 0.375), vec3(0.625, 1.0, 0.625), voxelPos);
        }

        // Iron bars: thin cross shape (approximate as center + cross)
        if (blockId == BLOCK_LPV_MED) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.4375, 0.0, 0.0), vec3(0.5625, 1.0, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.4375), vec3(1.0, 1.0, 0.5625), voxelPos);
        }

        // === LANTERNS - fake cage shadow (cross + top/bottom) ===
        // Simulates light inside lantern casting shadows through the frame
        if (blockId == BLOCK_LANTERN || blockId == BLOCK_SOUL_LANTERN || blockId == BLOCK_COPPER_LANTERN) {
            // Cross bars (N-S and E-W thin planes through center)
            bool crossNS = rayHitsAABB(rayOrigin, rayDir, vec3(0.35, 0.0, 0.0), vec3(0.65, 1.0, 1.0), voxelPos);
            bool crossEW = rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.35), vec3(1.0, 1.0, 0.65), voxelPos);
            // Top and bottom plates
            bool top = rayHitsAABB(rayOrigin, rayDir, vec3(0.2, 0.85, 0.2), vec3(0.8, 1.0, 0.8), voxelPos);
            bool bottom = rayHitsAABB(rayOrigin, rayDir, vec3(0.2, 0.0, 0.2), vec3(0.8, 0.15, 0.8), voxelPos);
            return crossNS || crossEW || top || bottom;
        }

        // === SLABS ===
        if (blockId == BLOCK_SLAB_TOP) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.0), vec3(1.0, 1.0, 1.0), voxelPos);
        }
        if (blockId == BLOCK_SLAB_BOTTOM) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.5, 1.0), voxelPos);
        }

        // === CARPET / PRESSURE PLATE / SNOW ===
        if (blockId == BLOCK_CARPET || blockId == BLOCK_PRESSURE_PLATE) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.0625, 1.0), voxelPos);
        }
        if (blockId == BLOCK_SNOW_LAYERS) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.25, 1.0), voxelPos);
        }

        // === TRAPDOORS (closed) ===
        if (blockId == BLOCK_TRAPDOOR_BOTTOM) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.1875, 1.0), voxelPos);
        }
        if (blockId == BLOCK_TRAPDOOR_TOP) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.8125, 0.0), vec3(1.0, 1.0, 1.0), voxelPos);
        }
        // Trapdoors open (vertical)
        if (blockId == BLOCK_TRAPDOOR_N) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 1.0, 0.1875), voxelPos);
        }
        if (blockId == BLOCK_TRAPDOOR_S) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.8125), vec3(1.0, 1.0, 1.0), voxelPos);
        }
        if (blockId == BLOCK_TRAPDOOR_W) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(0.1875, 1.0, 1.0), voxelPos);
        }
        if (blockId == BLOCK_TRAPDOOR_E) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.8125, 0.0, 0.0), vec3(1.0, 1.0, 1.0), voxelPos);
        }

        // === STAIRS (bottom) - L-shaped, test 2 boxes ===
        // Bottom slab + back portion based on facing
        if (blockId == BLOCK_STAIRS_BOTTOM_N) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.5, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.0), vec3(1.0, 1.0, 0.5), voxelPos);
        }
        if (blockId == BLOCK_STAIRS_BOTTOM_S) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.5, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.5), vec3(1.0, 1.0, 1.0), voxelPos);
        }
        if (blockId == BLOCK_STAIRS_BOTTOM_W) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.5, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.0), vec3(0.5, 1.0, 1.0), voxelPos);
        }
        if (blockId == BLOCK_STAIRS_BOTTOM_E) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.5, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.5, 0.5, 0.0), vec3(1.0, 1.0, 1.0), voxelPos);
        }

        // === STAIRS (top, upside-down) ===
        if (blockId == BLOCK_STAIRS_TOP_N) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.0), vec3(1.0, 1.0, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.5, 0.5), voxelPos);
        }
        if (blockId == BLOCK_STAIRS_TOP_S) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.0), vec3(1.0, 1.0, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.5), vec3(1.0, 0.5, 1.0), voxelPos);
        }
        if (blockId == BLOCK_STAIRS_TOP_W) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.0), vec3(1.0, 1.0, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(0.5, 0.5, 1.0), voxelPos);
        }
        if (blockId == BLOCK_STAIRS_TOP_E) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.0), vec3(1.0, 1.0, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.5, 0.0, 0.0), vec3(1.0, 0.5, 1.0), voxelPos);
        }

        // === STAIRS (inner corners - 3/4 block) ===
        if (blockId >= BLOCK_STAIRS_BOTTOM_INNER_S_E && blockId <= BLOCK_STAIRS_BOTTOM_INNER_N_E) {
            // Inner corners are mostly solid - approximate as full bottom + 3/4 top
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.5, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.0), vec3(1.0, 1.0, 0.5), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.5), vec3(0.5, 1.0, 1.0), voxelPos);
        }
        if (blockId >= BLOCK_STAIRS_TOP_INNER_S_E && blockId <= BLOCK_STAIRS_TOP_INNER_N_E) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.0), vec3(1.0, 1.0, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.5, 0.5), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.5), vec3(0.5, 0.5, 1.0), voxelPos);
        }

        // === STAIRS (outer corners - 1/4 block on top) ===
        if (blockId >= BLOCK_STAIRS_BOTTOM_OUTER_N_W && blockId <= BLOCK_STAIRS_BOTTOM_OUTER_S_W) {
            // Outer corners: bottom slab + small corner piece
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 0.5, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.0), vec3(0.5, 1.0, 0.5), voxelPos);
        }
        if (blockId >= BLOCK_STAIRS_TOP_OUTER_N_W && blockId <= BLOCK_STAIRS_TOP_OUTER_S_W) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.5, 0.0), vec3(1.0, 1.0, 1.0), voxelPos) ||
                   rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(0.5, 0.5, 0.5), voxelPos);
        }

        // === WALLS - center post (4x16x4 pixels = 0.25 x 1.0 x 0.25) ===
        if (blockId >= BLOCK_WALL_MIN && blockId <= BLOCK_WALL_MAX) {
            // All walls have center post
            bool hit = rayHitsAABB(rayOrigin, rayDir, vec3(0.3125, 0.0, 0.3125), vec3(0.6875, 1.0, 0.6875), voxelPos);

            // Check for arm extensions based on connection state
            // Wall connections extend from center to edge
            // LOW walls are 0.8125 tall, TALL walls are full height
            float wallHeight = 1.0; // Simplified - treat all as full height for shadows

            // North arm (negative Z)
            if (blockId == BLOCK_WALL_POST_LOW_N || blockId == BLOCK_WALL_POST_LOW_N_S ||
                blockId == BLOCK_WALL_POST_LOW_N_W || blockId == BLOCK_WALL_POST_LOW_N_E ||
                blockId == BLOCK_WALL_POST_LOW_N_W_S || blockId == BLOCK_WALL_POST_LOW_N_E_S ||
                blockId == BLOCK_WALL_POST_LOW_W_N_E || blockId == BLOCK_WALL_POST_LOW_ALL ||
                blockId == BLOCK_WALL_POST_TALL_N || blockId == BLOCK_WALL_POST_TALL_N_S ||
                blockId == BLOCK_WALL_POST_TALL_N_W || blockId == BLOCK_WALL_POST_TALL_N_E ||
                blockId == BLOCK_WALL_LOW_N_S || blockId == BLOCK_WALL_LOW_N_W || blockId == BLOCK_WALL_LOW_N_E ||
                blockId == BLOCK_WALL_TALL_N_S || blockId == BLOCK_WALL_TALL_N_W || blockId == BLOCK_WALL_TALL_N_E) {
                hit = hit || rayHitsAABB(rayOrigin, rayDir, vec3(0.3125, 0.0, 0.0), vec3(0.6875, wallHeight, 0.3125), voxelPos);
            }
            // South arm (positive Z)
            if (blockId == BLOCK_WALL_POST_LOW_S || blockId == BLOCK_WALL_POST_LOW_N_S ||
                blockId == BLOCK_WALL_POST_LOW_S_W || blockId == BLOCK_WALL_POST_LOW_S_E ||
                blockId == BLOCK_WALL_POST_LOW_N_W_S || blockId == BLOCK_WALL_POST_LOW_N_E_S ||
                blockId == BLOCK_WALL_POST_LOW_W_S_E || blockId == BLOCK_WALL_POST_LOW_ALL ||
                blockId == BLOCK_WALL_POST_TALL_S || blockId == BLOCK_WALL_POST_TALL_N_S ||
                blockId == BLOCK_WALL_POST_TALL_S_W || blockId == BLOCK_WALL_POST_TALL_S_E ||
                blockId == BLOCK_WALL_LOW_N_S || blockId == BLOCK_WALL_LOW_S_W || blockId == BLOCK_WALL_LOW_S_E ||
                blockId == BLOCK_WALL_TALL_N_S || blockId == BLOCK_WALL_TALL_S_W || blockId == BLOCK_WALL_TALL_S_E) {
                hit = hit || rayHitsAABB(rayOrigin, rayDir, vec3(0.3125, 0.0, 0.6875), vec3(0.6875, wallHeight, 1.0), voxelPos);
            }
            // West arm (negative X)
            if (blockId == BLOCK_WALL_POST_LOW_W || blockId == BLOCK_WALL_POST_LOW_W_E ||
                blockId == BLOCK_WALL_POST_LOW_N_W || blockId == BLOCK_WALL_POST_LOW_S_W ||
                blockId == BLOCK_WALL_POST_LOW_N_W_S || blockId == BLOCK_WALL_POST_LOW_W_N_E ||
                blockId == BLOCK_WALL_POST_LOW_W_S_E || blockId == BLOCK_WALL_POST_LOW_ALL ||
                blockId == BLOCK_WALL_POST_TALL_W || blockId == BLOCK_WALL_POST_TALL_W_E ||
                blockId == BLOCK_WALL_POST_TALL_N_W || blockId == BLOCK_WALL_POST_TALL_S_W ||
                blockId == BLOCK_WALL_LOW_W_E || blockId == BLOCK_WALL_LOW_N_W || blockId == BLOCK_WALL_LOW_S_W ||
                blockId == BLOCK_WALL_TALL_W_E || blockId == BLOCK_WALL_TALL_N_W || blockId == BLOCK_WALL_TALL_S_W) {
                hit = hit || rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.3125), vec3(0.3125, wallHeight, 0.6875), voxelPos);
            }
            // East arm (positive X)
            if (blockId == BLOCK_WALL_POST_LOW_E || blockId == BLOCK_WALL_POST_LOW_W_E ||
                blockId == BLOCK_WALL_POST_LOW_N_E || blockId == BLOCK_WALL_POST_LOW_S_E ||
                blockId == BLOCK_WALL_POST_LOW_N_E_S || blockId == BLOCK_WALL_POST_LOW_W_N_E ||
                blockId == BLOCK_WALL_POST_LOW_W_S_E || blockId == BLOCK_WALL_POST_LOW_ALL ||
                blockId == BLOCK_WALL_POST_TALL_E || blockId == BLOCK_WALL_POST_TALL_W_E ||
                blockId == BLOCK_WALL_POST_TALL_N_E || blockId == BLOCK_WALL_POST_TALL_S_E ||
                blockId == BLOCK_WALL_LOW_W_E || blockId == BLOCK_WALL_LOW_N_E || blockId == BLOCK_WALL_LOW_S_E ||
                blockId == BLOCK_WALL_TALL_W_E || blockId == BLOCK_WALL_TALL_N_E || blockId == BLOCK_WALL_TALL_S_E) {
                hit = hit || rayHitsAABB(rayOrigin, rayDir, vec3(0.6875, 0.0, 0.3125), vec3(1.0, wallHeight, 0.6875), voxelPos);
            }

            return hit;
        }

        // === DOORS (thin vertical panels) ===
        if (blockId == BLOCK_DOOR_N) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 1.0, 0.1875), voxelPos);
        }
        if (blockId == BLOCK_DOOR_S) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.8125), vec3(1.0, 1.0, 1.0), voxelPos);
        }
        if (blockId == BLOCK_DOOR_W) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(0.1875, 1.0, 1.0), voxelPos);
        }
        if (blockId == BLOCK_DOOR_E) {
            return rayHitsAABB(rayOrigin, rayDir, vec3(0.8125, 0.0, 0.0), vec3(1.0, 1.0, 1.0), voxelPos);
        }

        // Default: pass through (don't shadow) - only explicitly defined shapes cast shadows
        return rayHitsAABB(rayOrigin, rayDir, vec3(0.0, 0.0, 0.0), vec3(1.0, 1.0, 1.0), voxelPos);
    }

    vec3 traceBlockLightShadow(vec3 surfacePlayerPos, vec3 lightPlayerPos, float noise) {
    // Convert to voxel grid coordinates
    vec3 cameraOffset = fract(cameraPosition);
    vec3 surfaceVoxel = surfacePlayerPos + cameraOffset + vec3(VoxelSize3) * 0.5;
    vec3 lightVoxel = lightPlayerPos + cameraOffset + vec3(VoxelSize3) * 0.5;

    // Ray from surface to light in voxel space
    vec3 rayVec = lightVoxel - surfaceVoxel;
    float rayLength = length(rayVec);
    if (rayLength < 0.5) return vec3(1.0);
    vec3 rayDir = rayVec / rayLength;

    // Also jitter AABB bounds so non-full blocks blur similarly
    aabbJitter = noise;

    // Jitter ray start perpendicular to ray direction for soft shadow edges
    // This creates blur at full block edges (AABB jitter alone is too small relative to block size)
    vec3 tangent = normalize(cross(rayDir, vec3(0.0, 1.0, 0.001)));
    vec3 bitangent = cross(rayDir, tangent);
    vec2 diskJitter = (vec2(noise, fract(noise * 12.9898)) - 0.5) * 0.25;
    vec3 startPos = surfaceVoxel + rayDir * 0.5 + tangent * diskJitter.x + bitangent * diskJitter.y;

    // Light source voxel (for lantern self-shadow check)
    ivec3 lightVoxelCoord = ivec3(floor(lightVoxel));

    // DDA setup
    ivec3 voxelCoord = ivec3(floor(startPos));
    ivec3 stepDir = ivec3(sign(rayDir));
    
    // Handle zero direction components to avoid division by zero
    vec3 safeDirInv = 1.0 / max(abs(rayDir), vec3(1e-6)) * sign(rayDir + 1e-6);
    vec3 tDelta = abs(safeDirInv);
    
    // Distance to next voxel boundary on each axis
    vec3 nextBoundary = vec3(voxelCoord) + max(stepDir, ivec3(0));
    vec3 tMax = (nextBoundary - startPos) * safeDirInv;

    // Accumulated shadow color (starts fully lit)
    vec3 shadowTint = vec3(1.0);

    // Max iterations as safety cap
    for (int i = 0; i < 16; i++) {
        // Check if we've reached the light
        float currentDist = distance(vec3(voxelCoord) + 0.5, surfaceVoxel);
        if (currentDist >= rayLength - 0.4) break;

        // Bounds check
        if (any(lessThan(voxelCoord, ivec3(0))) || any(greaterThanEqual(voxelCoord, ivec3(VoxelSize3)))) {
            // Step to next voxel before continuing (might re-enter bounds)
            if (tMax.x < tMax.y && tMax.x < tMax.z) {
                voxelCoord.x += stepDir.x;
                tMax.x += tDelta.x;
            } else if (tMax.y < tMax.z) {
                voxelCoord.y += stepDir.y;
                tMax.y += tDelta.y;
            } else {
                voxelCoord.z += stepDir.z;
                tMax.z += tDelta.z;
            }
            continue;
        }

        // Sample voxel - check if solid block exists
        uint blockId = imageLoad(imgVoxelMask, voxelCoord).r;

        // If there's a block
        if (blockId > 0u && blockId != 65535u) {
            // Get block data for tint color
            uvec2 blockData = imageLoad(imgBlockData, int(blockId % 2000u)).rg;

            // Check if it's a light emitter
            bool isLantern = (blockId == BLOCK_LANTERN || blockId == BLOCK_SOUL_LANTERN || blockId == BLOCK_COPPER_LANTERN);
            bool isLightSource = (voxelCoord == lightVoxelCoord);
            float blockLightRange = unpackUnorm4x8(blockData.r).a * 255.0;
            
            // Test if ray actually hits the block's shape
            if (!testBlockShape(blockId, surfaceVoxel, rayDir, vec3(voxelCoord))) {
                // Step to next voxel
                if (tMax.x < tMax.y && tMax.x < tMax.z) {
                    voxelCoord.x += stepDir.x;
                    tMax.x += tDelta.x;
                } else if (tMax.y < tMax.z) {
                    voxelCoord.y += stepDir.y;
                    tMax.y += tDelta.y;
                } else {
                    voxelCoord.z += stepDir.z;
                    tMax.z += tDelta.z;
                }
                continue;
            }

            // Check if this is a transparent block (glass, ice, slime, etc.)
            bool isTransparent = (blockId >= 301u && blockId <= 322u);

            // if water, override color and transparency
            if (blockId == BLOCK_WATER) {
                isTransparent = true;
                shadowTint *= vec3(0.5, 0.6, 0.7); // bluish tint
            }

            if (!isTransparent) {
                // Opaque block - full shadow
                return vec3(0.0);
            }

            // Transparent block - use tint color for colored shadows
            vec3 tintColor = unpackUnorm4x8(blockData.g).rgb;
            float tintBrightness = max(max(tintColor.r, tintColor.g), tintColor.b);

            // If tint is near black, it's opaque - full shadow
            if (tintBrightness < 0.1) {
                return vec3(0.0);
            }

            // Accumulate tint color
            shadowTint *= tintColor;

            // If accumulated tint is too dark, stop
            if (max(max(shadowTint.r, shadowTint.g), shadowTint.b) < 0.05) {
                return vec3(0.0);
            }
        }

        // DDA step - advance along the axis with smallest tMax
        if (tMax.x < tMax.y && tMax.x < tMax.z) {
            voxelCoord.x += stepDir.x;
            tMax.x += tDelta.x;
        } else if (tMax.y < tMax.z) {
            voxelCoord.y += stepDir.y;
            tMax.y += tDelta.y;
        } else {
            voxelCoord.z += stepDir.z;
            tMax.z += tDelta.z;
        }
    }

    return shadowTint;
}

#endif

#ifdef IS_LPV_ENABLED
    vec3 GetHandLight(const in int itemId, const in vec3 playerPos, inout float lightRange) {
        vec3 lightFinal = vec3(0.0);
        vec3 lightColor = vec3(0.0);

        uvec2 blockData = texelFetch(texBlockData, itemId, 0).rg;
        vec4 lightColorRange = unpackUnorm4x8(blockData.r);
        lightColor = srgbToLinear(lightColorRange.rgb);
        lightRange = lightColorRange.a * 255.0;

        if (lightRange > 0.0) {
            float lightDist = length(playerPos+relativeEyePosition);
            // vec3 lightDir = playerPos / lightDist;
            float NoL = 1.0;//max(dot(normal, lightDir), 0.0);
            float falloff = pow(1.0 - lightDist / lightRange, 3.0);
            lightFinal = lightColor * NoL * max(falloff, 0.0);
        }

        return lightFinal;
    }
#endif

vec3 doBlockLightLighting(
    vec3 lightColor, float lightmap,
    vec3 playerPos, vec3 lpvPos
    #ifdef MAIN_SHADOW_PASS
    , vec3 viewPos, bool depthCheck, float noise, vec3 normals, bool hand
    #endif
){
    lightmap = clamp(lightmap,0.0,1.0);

    float lightmapBrightspot = min(max(lightmap-0.7,0.0)*3.3333,1.0);
    lightmapBrightspot *= lightmapBrightspot*lightmapBrightspot;

    float lightmapLight = 1.0-sqrt(1.0-lightmap);
    lightmapLight *= lightmapLight;

    float lightmapCurve = mix(lightmapLight, 2.5, lightmapBrightspot);
    vec3 blockLight = lightmapCurve * lightColor;
    
    #if defined IS_LPV_ENABLED && defined MC_GL_ARB_shader_image_load_store
        vec4 lpvSample = SampleLpvLinear(lpvPos);
        #ifdef VANILLA_LIGHTMAP_MASK
            lpvSample.rgb *= lightmapCurve;
        #endif
        // vec3 lpvBlockLight = GetLpvBlockLight(lpvSample);

        // create a smooth falloff at the edges of the voxel volume.
        float fadeLength = 10.0; // in meters
        vec3 cubicRadius = clamp(min(((LpvSize3-1.0) - lpvPos)/fadeLength, lpvPos/fadeLength), 0.0, 1.0);
        float voxelRangeFalloff = cubicRadius.x*cubicRadius.y*cubicRadius.z;
        voxelRangeFalloff = 1.0 - pow(1.0-pow(voxelRangeFalloff,1.5),3.0);
        
        // outside the voxel volume, lerp to vanilla lighting as a fallback
        blockLight = mix(blockLight, lpvSample.rgb + lightColor * 2.5 * min(max(lightmap-0.999,0.0)/(1.0-0.999),1.0), voxelRangeFalloff);

        #ifdef Hand_Held_lights
            // create handheld lightsources

            if (heldItemId > 0){
                    float lightRange = 0.0;
                    vec3 handLightCol = GetHandLight(heldItemId, playerPos, lightRange);

                    #if defined MAIN_SHADOW_PASS && defined LPV_HANDHELD_SHADOWS
                        if (lightRange > 0.0 && firstPersonCamera) handLightCol *=  SSRT_Handlight_Shadows(viewPos, depthCheck, -(viewPos + vec3(-0.25, 0.2, 0.0)), noise, normals, hand);
                    #endif

                    #ifdef WEATHER
                        handLightCol *= 0.5;
                    #endif

                    blockLight += handLightCol;
            }
            

            if (heldItemId2 > 0){
                    float lightRange2 = 0.0;
                    vec3 handLightCol2 = GetHandLight(heldItemId2, playerPos, lightRange2);
                    
                    #if defined MAIN_SHADOW_PASS && defined LPV_HANDHELD_SHADOWS
                        if (lightRange2 > 0.0 && firstPersonCamera) handLightCol2 *= SSRT_Handlight_Shadows(viewPos, depthCheck, -(viewPos + vec3(0.25, 0.2, 0.0)), noise, normals, hand);
                    #endif

                    #ifdef WEATHER
                        handLightCol2 *= 0.5;
                    #endif

                    blockLight += handLightCol2;
            }
        #endif
    #endif

    return blockLight * TORCH_AMOUNT;
}

vec3 doIndirectLighting(
    vec3 lightColor, vec3 minimumLightColor, float lightmap
){

    // float lightmapCurve = pow(1.0-pow(1.0-lightmap,2.0),2.0);
    // float lightmapCurve = lightmap*lightmap;
    float lightmapCurve = (pow(lightmap,15.0)*2.0 + lightmap*lightmap)/3.0; //make sure its 0.0-1.0

    vec3 indirectLight = lightColor * lightmapCurve * ambient_brightness;  

    // indirectLight = max(indirectLight, minimumLightColor * (MIN_LIGHT_AMOUNT * 0.02 * 0.2 + nightVision));
    indirectLight += mix(minimumLightColor * (MIN_LIGHT_AMOUNT * 0.004 + nightVision*0.02), minimumLightColor * (MIN_LIGHT_AMOUNT_INSIDE * 0.004 + nightVision*0.02), 1.0-lightmap);

    return indirectLight;
}

#ifndef VOXY_PROGRAM
uniform float centerDepthSmooth;

#if defined VIVECRAFT
	uniform bool vivecraftIsVR;
	uniform vec3 vivecraftRelativeMainHandPos;
	uniform vec3 vivecraftRelativeOffHandPos;
	uniform mat4 vivecraftRelativeMainHandRot;
	uniform mat4 vivecraftRelativeOffHandRot;
#endif

vec3 calculateFlashlight(in vec2 texcoord, in vec3 viewPos, in vec3 albedo, in vec3 normal, out vec4 flashLightSpecularData, bool hand){

	// vec3 shiftedViewPos = viewPos + vec3(-0.25, 0.2, 0.0);
	// vec3 shiftedPlayerPos = mat3(gbufferModelViewInverse) * shiftedViewPos + gbufferModelViewInverse[3].xyz + (cameraPosition - previousCameraPosition) * 3.0;
	// shiftedViewPos = mat3(gbufferPreviousModelView) * shiftedPlayerPos + gbufferPreviousModelView[3].xyz;
	vec3 shiftedViewPos;
    vec3 shiftedPlayerPos;
	float forwardOffset;

    #ifdef VIVECRAFT
        if (vivecraftIsVR) {
	        forwardOffset = 0.0;
            shiftedPlayerPos = mat3(gbufferModelViewInverse) * viewPos + gbufferModelViewInverse[3].xyz + vivecraftRelativeMainHandPos;
            shiftedViewPos = shiftedPlayerPos * mat3(vivecraftRelativeMainHandRot);
        } else
    #endif
    {
	    forwardOffset = 0.5;
        shiftedViewPos = viewPos + vec3(-0.25, 0.2, 0.0);
        shiftedPlayerPos = mat3(gbufferModelViewInverse) * shiftedViewPos + gbufferModelViewInverse[3].xyz + (cameraPosition - previousCameraPosition) * 3.0;
        shiftedViewPos = mat3(gbufferPreviousModelView) * shiftedPlayerPos + gbufferPreviousModelView[3].xyz;
    }

    
    
    vec2 scaledViewPos = shiftedViewPos.xy / max(-shiftedViewPos.z - forwardOffset, 1e-7);
	float linearDistance = length(shiftedPlayerPos);
	float shiftedLinearDistance = length(scaledViewPos);

	float lightFalloff = 1.0 - clamp(1.0-linearDistance/FLASHLIGHT_RANGE, -0.999,1.0);
	lightFalloff = max(exp(-10.0 * FLASHLIGHT_BRIGHTNESS_FALLOFF_MULT * lightFalloff),0.0);

	#if defined FLASHLIGHT_SPECULAR && (defined DEFERRED_SPECULAR || defined FORWARD_SPECULAR)
		float flashLightSpecular = lightFalloff * exp2(-7.0*shiftedLinearDistance*shiftedLinearDistance) * FLASHLIGHT_BRIGHTNESS_MULT;
		flashLightSpecularData = vec4(normalize(shiftedPlayerPos), flashLightSpecular);	
	#endif

	float projectedCircle = clamp(1.0 - shiftedLinearDistance*FLASHLIGHT_SIZE,0.0,1.0);
	float lenseDirt = texture(noisetex, scaledViewPos * 0.2 + 0.1).b;
	float lenseShape = (pow(abs(pow(abs(projectedCircle-1.0),2.0)*2.0 - 0.5),2.0) + lenseDirt*0.2) * 10.0;
	
	float offsetNdotL = clamp(dot(-normal, normalize(shiftedPlayerPos)),0,1);
	vec3 flashlightDiffuse = vec3(1.0) * lightFalloff * offsetNdotL * pow(1.0-pow(1.0-projectedCircle,2),2) * lenseShape * FLASHLIGHT_BRIGHTNESS_MULT;
	
	if(hand){
		flashlightDiffuse = vec3(0.0);
		flashLightSpecularData = vec4(0.0);
	}

	#ifdef FLASHLIGHT_BOUNCED_INDIRECT
		float lightWidth = 1.0+linearDistance*3.0;
		vec3 pointPos = mat3(gbufferModelViewInverse) *  (toScreenSpace(vec3(texcoord, centerDepthSmooth)) + vec3(-0.25, 0.2, 0.0));
		float flashLightHitPoint = distance(pointPos, shiftedPlayerPos);

		float indirectFlashLight = exp(-10.0 * (1.0 - clamp(1.0-length(shiftedViewPos.xy)/lightWidth,0.0,1.0)) );
		indirectFlashLight *= pow(clamp(1.0-flashLightHitPoint/lightWidth,0,1),2.0);

		flashlightDiffuse += albedo/150.0 * indirectFlashLight * lightFalloff;
	#endif

	return flashlightDiffuse * vec3(FLASHLIGHT_R,FLASHLIGHT_G,FLASHLIGHT_B);
}
#endif
