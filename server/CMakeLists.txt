project(stall_diva_server LANGUAGES CXX)
set(CMAKE_CXX_FLAGS "-std=c++23 -O3 -march=native -fno-rtti -fno-exceptions")
add_executable(stall_server main.cpp)
target_link_libraries(stall_server PRIVATE pthread fmt)