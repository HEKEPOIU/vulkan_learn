#version 450
// Use this to let glslc knows the stage of shader.
#pragma shader_stage(vertex)

layout(location = 0) in vec2 inPositon;
layout(location = 1) in vec3 inColor;

layout(location = 0) out vec3 fragColor;

void main() {
    gl_Position = vec4(inPositon, 0.0, 1.0);
    fragColor = inColor;
}
