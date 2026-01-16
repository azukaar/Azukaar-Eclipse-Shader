// Sort lights by distance after shadowcomp collects them

layout (local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);

#include "/lib/settings.glsl"

#ifdef BLOCK_LIGHT_SHADOWS
    uniform vec3 cameraPosition;

    #define LIGHT_LIST_WRITE
    #include "/lib/light_list.glsl"
#endif

void main() {
    #ifdef BLOCK_LIGHT_SHADOWS
        memoryBarrierBuffer();

        // Try to acquire lock - only one thread can proceed
        // Use atomicExchange: if we get back 1, someone already locked this frame
        int oldLock = atomicExchange(sortLock, 1);
        if (oldLock == 1) {
            return; // Already sorted this frame
        }

        // We have the lock, proceed with sorting
        int numLights = min(rawLightCount, MAX_BLOCK_LIGHTS_RAW);
        int numToSort = min(numLights, BLOCK_LIGHT_SHADOWS_MAX_LIGHTS);

        // For each slot in sorted output
        for (int slot = 0; slot < numToSort; slot++) {
            int closestIdx = -1;
            float closestDist = 1e30;

            // Find closest unpicked light (w > 0)
            for (int i = 0; i < numLights; i++) {
                if (rawLights[i].position.w > 0.0) {
                    float dist = length(rawLights[i].position.xyz - cameraPosition);
                    if (dist < closestDist) {
                        closestDist = dist;
                        closestIdx = i;
                    }
                }
            }

            if (closestIdx >= 0) {
                // Copy to sorted buffer
                sortedLights[slot].position = rawLights[closestIdx].position;
                // Mark as picked
                rawLights[closestIdx].position.w = -1.0;
            }
        }

        sortedLightCount = numToSort;
        memoryBarrierBuffer();

        // Lock stays set - will be reset by composite3
    #endif
}
