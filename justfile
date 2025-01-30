Output_FName_Debug := "vulkan_learn_debug"
Output_FName_Rel := "vulkan_learn_Rel"
BFlag_Debug := "-debug --out=./build/" + Output_FName_Debug
BFlag_Rel := "-disable-assert --out=./build/" + Output_FName_Rel

run_debug:
    just build_debug
    cd ./build/ && ./{{ Output_FName_Debug }}

build_debug: c_all_shader
    odin build . {{ BFlag_Debug }} 

build: c_all_shader
    odin build .  {{ BFlag_Rel }} 

run:
    just build
    cd ./build/ && ./{{ Output_FName_Rel }}

c_all_shader:
    #!/usr/bin/bash
    for shader in ./shader/*.glsl; do
        just _c_shader ${shader}
    done

_c_shader shader_name:
    #!/usr/bin/bash
    shader_name={{ shader_name }}
    shader_name_without_ext="${shader_name%.*}"
    echo $shader_name_without_ext
    glslc {{ shader_name }} -o $shader_name_without_ext.sprv

clear_all_shader:
    rm ./shader/*.spv
