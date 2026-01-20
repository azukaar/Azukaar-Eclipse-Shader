// Light list for block light shadows
// MAX_BLOCK_LIGHTS_BUFFER is defined in settings.glsl

#define BLOCK_LIGHT_SHADOWS_FADE_END (BLOCK_LIGHT_SHADOWS_FADE_START+8)
#define LIGHT_BUFFER_PRIORITY_THRESHOLD int(MAX_BLOCK_LIGHTS_BUFFER * 0.90)

struct BlockLight {
    vec4 position; // xyz = world position, w = range
    vec4 color;    // rgb = color, a = unused
};

#ifdef LIGHT_LIST_WRITE
layout(std430, binding = 1) buffer LightListBuffer {
    int lightCount;
    int prevLightCount;
    int pad2, pad3;
    BlockLight lights[MAX_BLOCK_LIGHTS_BUFFER];
    BlockLight prevLights[MAX_BLOCK_LIGHTS_BUFFER];
};

// Check if a light position existed in the previous frame's buffer
bool wasLightInPrevFrame(vec3 pos) {
    for (int i = 0; i < min(prevLightCount, MAX_BLOCK_LIGHTS_BUFFER); i++) {
        if (distance(prevLights[i].position.xyz, pos) < 0.5) {
            return true;
        }
    }
    return false;
}
#else
layout(std430, binding = 1) readonly buffer LightListBuffer {
    int lightCount;
    int prevLightCount;
    int pad2, pad3;
    BlockLight lights[MAX_BLOCK_LIGHTS_BUFFER];
    BlockLight prevLights[MAX_BLOCK_LIGHTS_BUFFER];
};
#endif
