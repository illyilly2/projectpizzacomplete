include(App)
include(Base)
include(Network)
include(Rendering)
include(VMProtect)

# Include directories
include_directories(
    ../ClientBase
    ../ClientShared
    ../App.BulletPhysics
    ../App/include
    ../Network/include
)

# Executable
add_executable(UniversalClient
    "main.cpp"
    "Application.cpp"
    "Application.h"
    "FunctionMarshaller.cpp"
    "FunctionMarshaller.h"
    "View.cpp"
    "View.h"
    "RenderJob.cpp"
    "RenderJob.h"
    "UserInputUtil.cpp"
    "UserInputUtil.h"
    "UserInput.cpp"
    "UserInput.h"
    "../App/script/LuaVMClient.cpp"
    "../ClientBase/RenderSettingsItem.h"
    "../ClientBase/RenderSettingsItem.cpp"
    "../ClientBase/MachineConfiguration.h"
    "../ClientBase/MachineConfiguration.cpp"
    "../ClientBase/ReflectionMetadata.h"
    "../ClientBase/ReflectionMetadata.cpp"
    "../ClientShared/StringConv.h"
    "../ClientShared/StringConv.cpp"
)

# Object libraries and external dependencies
target_link_libraries(UniversalClient PRIVATE
    $<TARGET_OBJECTS:Base>
    $<TARGET_OBJECTS:Log>
    $<TARGET_OBJECTS:App>
    $<TARGET_OBJECTS:Network>
    $<TARGET_OBJECTS:G3D>
    $<TARGET_OBJECTS:AppDraw>
    $<TARGET_OBJECTS:RbxG3D>
    $<TARGET_OBJECTS:GfxBase>
    $<TARGET_OBJECTS:GfxCore>
    $<TARGET_OBJECTS:GfxRender>
    $<TARGET_OBJECTS:App.BulletPhysics>

    ZLIB::ZLIB

    Boost::filesystem
    Boost::iostreams
    Boost::program_options
    Boost::system
    Boost::thread
    Boost::exception
    Boost::pool

    CURL::libcurl
    OpenSSL::Crypto
    OpenSSL::SSL
    Freetype::Freetype
    PNG::PNG
)

# Platform-specific linking
if(WIN32)
    target_link_libraries(UniversalClient PRIVATE
        fmod_vc
        "${CMAKE_SOURCE_DIR}/Rendering/GfxCore/glew/glew32s.lib"
        OpenGL::GL
        SDL2::SDL2
    )
elseif(EMSCRIPTEN)
    target_link_options(UniversalClient PRIVATE
        "-Wl,--no-check-features"
        "-sFULL_ES3=1"
        "-sEXPORTED_RUNTIME_METHODS=ccall,cwrap,setValue,getValue"
        "-sALLOW_MEMORY_GROWTH=1"
        "-sSTACK_SIZE=1048576"
        "-sINITIAL_MEMORY=536870912"
        "-sMAX_WEBGL_VERSION=2"
        "-sPTHREAD_POOL_SIZE=100"
        "-sPROXY_TO_PTHREAD=1"
        "-O1"
    )

    if(NOT DEFINED FMOD_ROOT)
        message(FATAL_ERROR "FMOD_ROOT is not defined")
    endif()

    target_link_libraries(UniversalClient PRIVATE
        "${FMOD_ROOT}/lib/w32/fmodP_wasm.a"
        "-lembind"
    )
elseif(UNIX)
    target_link_libraries(UniversalClient PRIVATE
        -lfmod
        -lGLEW
        OpenGL::GL
        SDL2::SDL2
    )
    if(ENABLE_PROFILER)
        target_link_libraries(UniversalClient PRIVATE OpenGL::EGL)
    endif()
endif()

target_compile_definitions(UniversalClient PRIVATE SDL_MAIN_HANDLED)
