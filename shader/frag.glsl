#version 450
// Use this to let glslc knows the stage of shader.
#pragma shader_stage(fragment)

layout(location = 0) out vec4 outColor;
layout(location = 0) in vec3 fragColor;

void main() {
    outColor = vec4(fragColor, 1.0);
}
