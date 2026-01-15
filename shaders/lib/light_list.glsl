// Light list for block light shadows

// Buffer size must be constant - use largest possible setting
#define MAX_BLOCK_LIGHTS_BUFFER 128

struct BlockLight {
    vec4 position; // xyz = world position, w = range
};

#ifdef LIGHT_LIST_WRITE
layout(std430, binding = 1) buffer LightListBuffer {
    int lightCount;
    int pad1, pad2, pad3;
    uint slotDist[MAX_BLOCK_LIGHTS_BUFFER];   // Distance * 1000 as uint (for atomicMin)
    BlockLight lights[MAX_BLOCK_LIGHTS_BUFFER];
};
#else
layout(std430, binding = 1) readonly buffer LightListBuffer {
    int lightCount;
    int pad1, pad2, pad3;
    uint slotDist[MAX_BLOCK_LIGHTS_BUFFER];
    BlockLight lights[MAX_BLOCK_LIGHTS_BUFFER];
};
#endif
