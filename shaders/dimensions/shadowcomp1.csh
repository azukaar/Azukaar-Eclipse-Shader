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
}
