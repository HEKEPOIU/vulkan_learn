Output_FName_Debug := "vulkan_learn_debug"
Output_FName_Rel := "vulkan_learn_Rel"
BFlag_Debug := "-debug --out=./build/" + Output_FName_Debug
BFlag_Rel := "-disable-assert --out=./build/" + Output_FName_Rel


build_debug: c_all_shader
    odin build . {{ BFlag_Debug }} 

build: c_all_shader
    odin build .  {{ BFlag_Rel }} 

c_all_shader:
    #!/bin/bash
    for shader in ./shader/*.glsl; do
        just _c_shader ${shader}
    done

_c_shader shader_name:
    #!/bin/bash
    shader_name={{ shader_name }}
    shader_name_without_ext="${shader_name%.*}"
    echo $shader_name_without_ext
    glslc {{ shader_name }} -o $shader_name_without_ext.sprv

clear_all_shader:
    rm ./shader/*.spv
